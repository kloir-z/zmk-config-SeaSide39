<#
.SYNOPSIS
    ZMK ファームウェアを UF2 ブートローダーへ自動で書き込む。

.DESCRIPTION
    ブートローダー中はキーボードもトラックボールも停止するため、エクスプローラでの
    ドラッグ&ドロップには別のマウスが必要になる。このスクリプトを先に起動しておけば、
    UF2 ドライブの出現を検知して自動でコピーするため、マウスは要らなくなる。

    自動化するのは「ドライブの検知」と「正しい uf2 のコピー」だけ。
    ケーブルの抜き差しとリセットボタン押下は人間が行う。スクリプトは次にやることを
    1 ステップずつ表示して待ち、書き込みが終わったら次の指示に進む。

    Both でも別のポインティングデバイスは要らない。人間の作業は物理操作だけになり、
    マウスが必要だったドラッグ&ドロップが無くなるため。
    なお R がセントラルなので、左を書き込んでいる間も右側のキーとトラックボールは
    生きている。完全に操作不能になるのは右を書き込む後半 2 ステップだけで、
    そこはスクリプトが自動で処理する。
    その間に取りこぼさないよう、待ち時間は既定で長めに取ってある。

    R がセントラル (Kconfig.defconfig の SHIELD_SeaSide39_R → ZMK_SPLIT_ROLE_CENTRAL=y)
    のため、キーマップだけの変更なら R の書き込みだけで反映される。これが既定。
    L はペリフェラルでキースキャンと BLE 送信しか担わない。

.PARAMETER Target
    R     … 右のみ。キーマップ変更時はこれで足りる (既定)
    L     … 左のみ
    Reset … settings_reset のみ
    Both  … 左右をフル手順で書き込む。各デバイスに settings_reset → 本 FW の
            2 回の書き込みが必要で、途中で USB ケーブルの挿し替えが入る

.PARAMETER Uf2Dir
    uf2 または firmware.zip を探すフォルダ。既定はダウンロードフォルダ。

.PARAMETER Download
    gh CLI で最新の成功した Actions run から firmware を取得する。
    事前に `gh auth login` が必要。

.PARAMETER TimeoutSec
    1 ステップあたりのブートローダー待ち秒数。既定 600 (10 分)。
    右を書き込んでいる間はキーボードが全て停止していて操作できないため、
    ケーブルの挿し替えやリセット押下をあわてずに行えるよう長めにしてある。
    0 を指定すると無期限に待つ (中断は Ctrl+C)。

.EXAMPLE
    .\tools\flash.ps1
    ダウンロードフォルダの最新 firmware から右だけ書き込む。キーマップ更新はこれで足りる。

.EXAMPLE
    .\tools\flash.ps1 -Target Both
    左右をフル手順 (各デバイスで settings_reset → 本 FW) で書き込む。

.EXAMPLE
    .\tools\flash.ps1 -Download
    Actions の最新成功 run から取得して右だけ書き込む (要 gh auth login)。
#>
[CmdletBinding()]
param(
    [ValidateSet('R', 'L', 'Both', 'Reset')]
    [string]$Target = 'R',

    [string]$Uf2Dir = (Join-Path $env:USERPROFILE 'Downloads'),

    [switch]$Download,

    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$Repo = 'kloir-z/zmk-config-SeaSide39'

# uf2 のファイル名は shield 名から生成される。
# ワイルドカードは大文字小文字を区別しないため、'*_R*' だと settings_reset の '_r' にも
# マッチしてしまう。取り違えるとペアリングが飛ぶので shield 名から厳密に指定する。
$Patterns = @{
    'R'     = 'SeaSide39_R*.uf2'
    'L'     = 'SeaSide39_L*.uf2'
    'Reset' = 'settings_reset*.uf2'
}

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    $Text" -ForegroundColor Yellow }

# gh で最新の成功 run から firmware artifact を取得する
function Get-FirmwareFromActions {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "gh CLI が見つかりません。winget install GitHub.cli で導入してください。" }

    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gh が未認証です。先に ``gh auth login`` を実行してください。" }

    Write-Step "Actions から最新のファームウェアを取得中..."
    $runId = gh run list --repo $Repo --workflow build.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId'
    if (-not $runId) { throw "成功した run が見つかりません。" }

    $dest = Join-Path $env:TEMP "zmk-firmware-$runId"
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        gh run download $runId --repo $Repo --name firmware --dir $dest
        if ($LASTEXITCODE -ne 0) { throw "artifact のダウンロードに失敗しました。" }
    }
    Write-Ok "run $runId を $dest に展開しました"
    return $dest
}

# 指定フォルダから uf2 を集める。firmware.zip しかなければ展開する
function Get-Uf2Source {
    param([string]$Dir)

    if (-not (Test-Path $Dir)) { throw "フォルダが見つかりません: $Dir" }

    # ここは意図的に -Recurse しない。ダウンロードフォルダには手動展開した
    # firmware フォルダが世代違いで残りがちで、再帰すると古い uf2 まで拾ってしまう
    $uf2 = @(Get-ChildItem -Path $Dir -Filter '*.uf2' -File -ErrorAction SilentlyContinue)
    if ($uf2.Count -gt 0) {
        Write-Ok "$Dir 直下の .uf2 を使います ($($uf2.Count) 件)"
        return $Dir
    }

    $zips = @(Get-ChildItem -Path $Dir -Filter 'firmware*.zip' -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    if ($zips.Count -eq 0) { throw "$Dir に .uf2 も firmware*.zip も見つかりません。" }

    $zip = $zips[0]
    if ($zips.Count -gt 1) {
        Write-Warn "firmware*.zip が $($zips.Count) 個あります。最終更新が最新のものを選びました。"
    }
    Write-Ok "使用する zip : $($zip.Name)  ($($zip.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"

    # 古い世代を焼く事故が一番怖いので、鮮度が疑わしければ明示的に警告する
    $days = ((Get-Date) - $zip.LastWriteTime).TotalDays
    if ($days -ge 1) {
        Write-Warn ("この zip は約 {0:N0} 日前のものです。最新をビルドしたなら -Download を使うか、先に取得してください。" -f $days)
    }

    $dest = Join-Path $env:TEMP ("zmk-" + $zip.BaseName + "-" + $zip.LastWriteTime.ToString('yyyyMMddHHmmss'))
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $dest -Force
    }
    return $dest
}

function Resolve-Uf2 {
    param([string]$Dir, [string]$Kind)

    # artifact の zip はフラット構造なので再帰不要。世代混在を避けるため直下のみ見る
    $hits = @(Get-ChildItem -Path $Dir -Filter $Patterns[$Kind] -File -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) { throw "$Kind 用の uf2 が見つかりません (パターン: $($Patterns[$Kind]))" }
    if ($hits.Count -gt 1) {
        # 取り違えは事故に直結するため、曖昧なら黙って新しい方を選ばずに止める
        $names = ($hits | ForEach-Object { $_.FullName }) -join "`n      "
        throw "$Kind 用の uf2 が複数見つかりました。1 つに絞ってください:`n      $names"
    }
    return $hits[0].FullName
}

# UF2 ブートローダーは必ずルートに INFO_UF2.TXT を置く。ボリュームラベルより確実
function Get-Uf2Drive {
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path (Join-Path ($_.DeviceID + '\') 'INFO_UF2.TXT')) { $_.DeviceID }
    }
}

function Wait-Uf2Drive {
    param([int]$Seconds)

    # 0 以下なら無期限。操作不能な状態で打ち切られるのが一番困るので逃げ道を用意する
    $deadline = if ($Seconds -le 0) { [DateTime]::MaxValue } else { (Get-Date).AddSeconds($Seconds) }
    $dots = 0
    while ((Get-Date) -lt $deadline) {
        $drive = @(Get-Uf2Drive)
        if ($drive.Count -gt 0) {
            Write-Host ''
            return $drive[0]
        }
        Start-Sleep -Milliseconds 500
        $dots++
        if ($dots % 4 -eq 0) { Write-Host '.' -NoNewline }
    }
    Write-Host ''
    return $null
}

function Wait-DriveGone {
    param([string]$Drive, [int]$Seconds = 30)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path ($Drive + '\'))) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# 実際の書き込み手順。ケーブルの抜き差しとリセット押下は人間側の作業なので、
# 何をすべきかを 1 ステップずつ出して待つ
function Get-Sequence {
    param([string]$Target)

    switch ($Target) {
        'R' { ,@(
            @{ Kind = 'R'; Hint = '右側をブートローダーに入れてください (Y+U+N+M コンボ、または USB 接続してリセット2回押し)' }
        ) }
        'L' { ,@(
            @{ Kind = 'L'; Hint = 'USB ケーブルを左デバイスに挿し、リセットボタンを2回押してください' }
        ) }
        'Reset' { ,@(
            @{ Kind = 'Reset'; Hint = '対象デバイスをブートローダーに入れてください' }
        ) }
        'Both' { ,@(
            @{ Kind = 'Reset'; Hint = '[左 1/2] USB ケーブルを左デバイスに挿し、リセットボタンを2回押してください' },
            @{ Kind = 'L';     Hint = '[左 2/2] 続けて、もう一度リセットボタンを2回押してください' },
            @{ Kind = 'Reset'; Hint = '[右 1/2] USB ケーブルを右デバイスに挿し替え、リセットボタンを2回押してください' },
            @{ Kind = 'R';     Hint = '[右 2/2] 続けて、もう一度リセットボタンを2回押してください' }
        ) }
    }
}

function Invoke-Flash {
    param([int]$Step, [int]$Total, [string]$Kind, [string]$Hint, [string]$Uf2, [int]$Seconds)

    Write-Step "($Step/$Total) $Hint"
    Write-Host "    書き込むファイル: $(Split-Path $Uf2 -Leaf)" -ForegroundColor DarkGray
    Write-Host "    待機中 " -NoNewline

    $drive = Wait-Uf2Drive -Seconds $Seconds
    if (-not $drive) {
        Write-Warn "タイムアウトしました。$Kind はスキップします。"
        # 検出条件は「リムーバブル かつ INFO_UF2.TXT がある」。切り分けの材料を出す
        $rm = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.DeviceID) [$($_.VolumeName)]" })
        if ($rm.Count -gt 0) {
            Write-Warn "認識中のリムーバブルドライブ: $($rm -join ', ')"
            Write-Warn "INFO_UF2.TXT が無いため対象外と判定しました。"
        } else {
            Write-Warn "リムーバブルドライブが 1 台も見えていません。ブートローダーに入っていない可能性があります。"
        }
        return $false
    }

    Write-Ok "ブートローダーを検出: $drive"
    try {
        Copy-Item -LiteralPath $Uf2 -Destination ($drive + '\') -Force -ErrorAction Stop
        Write-Ok "コピー完了"
    } catch {
        # UF2 ブートローダーは書き込み完了と同時にリセットするため、コピーの最終段階で
        # デバイスが消えて例外になることがある。これは失敗ではない
        Write-Ok "コピー中にデバイスが切断されました (UF2 では正常な挙動です)"
    }

    if (Wait-DriveGone -Drive $drive) {
        Write-Ok "$Kind の書き込みが完了し、再起動しました"
    } else {
        Write-Warn "ドライブが消えません。書き込みに失敗した可能性があります。"
        return $false
    }
    return $true
}

# --- メイン ---------------------------------------------------------------

try {
    # Both は後半でキーボードが完全に停止し、打ち切られると再開コマンドすら打てない。
    # リセットボタンは物理ボタンなので待ち続けさえすれば必ず復帰できる。
    # よって明示指定が無ければ無期限で待つ。
    if ($Target -eq 'Both' -and -not $PSBoundParameters.ContainsKey('TimeoutSec')) {
        $TimeoutSec = 0
        Write-Warn "Both のため各ステップを無期限で待ちます (中断は Ctrl+C)。"
    }

    $srcDir = if ($Download) { Get-FirmwareFromActions } else { Get-Uf2Source -Dir $Uf2Dir }

    $seq = Get-Sequence -Target $Target

    # 先に全ての uf2 を解決しておく。書き込み途中でファイルが無いと気付くのを避ける
    $uf2map = @{}
    foreach ($k in ($seq | ForEach-Object { $_.Kind } | Select-Object -Unique)) {
        $uf2map[$k] = Resolve-Uf2 -Dir $srcDir -Kind $k
    }

    Write-Step "書き込み計画 (全 $($seq.Count) ステップ)"
    for ($i = 0; $i -lt $seq.Count; $i++) {
        Write-Host ("    {0}. {1,-6} {2}" -f ($i + 1), $seq[$i].Kind, (Split-Path $uf2map[$seq[$i].Kind] -Leaf))
    }

    $done = 0
    for ($i = 0; $i -lt $seq.Count; $i++) {
        $step = $seq[$i]
        $ok = Invoke-Flash -Step ($i + 1) -Total $seq.Count -Kind $step.Kind `
                           -Hint $step.Hint -Uf2 $uf2map[$step.Kind] -Seconds $TimeoutSec
        if (-not $ok) {
            # 以降のステップは前段が終わっている前提の順序なので、崩れたら続行しない
            Write-Host ''
            Write-Host "ステップ $($i + 1) で中断しました ($done / $($seq.Count) 完了)。" -ForegroundColor Yellow
            Write-Host "残りの手順:" -ForegroundColor Yellow
            for ($r = $i; $r -lt $seq.Count; $r++) {
                Write-Host ("  {0}. {1,-6} {2}" -f ($r + 1), $seq[$r].Kind, $seq[$r].Hint) -ForegroundColor DarkYellow
            }
            Write-Host "-Target Reset / R / L を個別に指定して続きから再開できます。" -ForegroundColor Yellow
            Write-Host "待ち時間が足りない場合は -TimeoutSec 0 で無期限にできます。" -ForegroundColor Yellow
            exit 1
        }
        $done++
    }

    Write-Host ''
    Write-Host "すべて完了しました ($done / $($seq.Count))。" -ForegroundColor Green
} catch {
    Write-Host "`nエラー: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
