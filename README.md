# SeaSideX【Keyball wireless kit】 について

SeaSideXは、はま([@ybybybmh](https://x.com/ybybybmh))が開発したKeyballを無線化するための自作キットです。<br>
このキットで無線化したKeyballをSeaSide39やSeaSide44と呼んだりもします。

Seeed XIAO BLE nRF52840というマイコンとZMKファームウェアを使用し、できるだけシンプルな形でKeyballの無線化を実現しています。

<div><video controls src="https://github.com/user-attachments/assets/3d5d6f6d-1471-4f76-9b5a-f62b32a67766" muted="false"></video></div>
素のKeyball39をSeaSide39に置き換えて無線化する様子です。手軽さが伝わると幸いです。（使用しているSeaSide39は開発中のものなので一部仕様が異なります。）


<br>
<br>

販売ページは[こちら](https://seasideworks.booth.pm/)

ビルドガイドは[こちら](https://github.com/hama-be/SeaSideX-documentation/blob/main/docs/buildguide.md)

# このリポジトリについて

このリポジトリは、SeaSideXを右手トラックボール版のKeyball39で使用するためのファームウェアを提供しています。<br>
ビルドガイドを参照に、使用するモデルに合ったファームウェアを使用してください。

# ファームウェアの書き込み (tools/flash.ps1)

ブートローダー中はキーボードとトラックボールが停止するため、エクスプローラへのドラッグ&ドロップには別のマウスが必要になる。<br>
`tools/flash.ps1` を**先に起動しておく**と、UF2 ドライブの出現を検知して uf2 を自動コピーするので、リセットボタン押下と USB ケーブルの抜き差しという物理操作だけで書き込みが完結する。

```powershell
.\tools\flash.ps1               # キーマップ更新 (右のみ・1 ステップ)。既定
.\tools\flash.ps1 -Target Both  # 左右フル手順 (各デバイスで settings_reset → 本 FW の 4 ステップ)
.\tools\flash.ps1 -Download     # Actions の最新成功 run から取得 (要 gh auth login)
```

右だけが既定なのは、R がセントラル (`Kconfig.defconfig` の `SHIELD_SeaSide39_R` → `ZMK_SPLIT_ROLE_CENTRAL=y`) で、キーマップの変更は右の書き込みだけで反映されるため。左はペリフェラルでキースキャンと BLE 送信しか担わない。

`-Target Both` は後半の右書き込み中にキーボードが完全停止し、打ち切られると再開コマンドも打てなくなるため、既定で無期限に待つ (中断は Ctrl+C)。

詳細は `Get-Help .\tools\flash.ps1 -Full` を参照。

> 実機で確認済みなのは右のみ (`-Target R`)。`-Target Both` は未検証。