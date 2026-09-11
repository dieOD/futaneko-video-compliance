# 動画部品の配布ライセンス範囲

この文書は、対応ソースキットと再リンク確認キットに含む動画部品側のライセンス範囲を示します。適用開始日: 2026年9月6日。原典のライセンス全文も同梱しています。技術的な検査結果を法的適合性の保証として示すものではありません。

## NijiNeko側で提供する範囲

このキットでFutaNeko側が変更したFFmpeg・mpvの該当部分、自作の追加部品（`version_probe.c`、`mpv_no_subtitles.c`、ビルド2以降の `mp4_export.m`）、および動画部品の再構築・検証・再リンクを補助する自作コードを、**LGPL 2.1以降（LGPL-2.1-or-later）** の条件で提供します。これらの自作部分の表示は Copyright (c) 2026 FutaNeko contributors とします。libplaceboの上流ソースには独自パッチを加えていません。

対象は、ソースキットの `tool/ios_video/` 内にある自作コード・変更パッチと、キット直下の `rebuild.py`・`verify.py`・`add_source_notices.py`・`mpv-modification-example.patch`、再リンクキット直下の `replace_and_sign.py`・`verify.py` です。上流コードの既存条件を変更するものではありません。ライセンス全文は `COPYING.LGPL-2.1` を参照してください。

`modified-sources/` に収録する対応ファイルの写しにも、同じ区分の条件が適用されます。上流から変更したファイルでは元の著作権表示を残し、FutaNeko向けの変更日と対応パッチを通知しています。

これはアプリ本体へLGPLを一括適用する宣言ではありません。アプリ本体は非公開のまま、このキットにソースコードを含めず、本体の既存ライセンスや提供条件を変更しません。リポジトリ全体のLICENSEへ波及させるものでもありません。新しい本体EULAや、商標・第三者素材の再配布権をこの文書から付与するものでもありません。

`packages/media_kit_libs_ios_video/LICENSE` の既存MIT条件と、`packages/media_kit_libs_ios_video/ios/Classes` のSwift・header glueの既存MIT条件は、そのまま保持します。この限定スコープによって、それらをLGPLへ一括変更しません。

対象コードはLGPLに従って利用・改変・再配布でき、商用利用や他のアプリへの利用も排除しません。LGPLが定める保証の否認・責任の制限を含め、全文の条件が適用されます。本体バイナリの自身の利用のための改変とデバッグに関する追加許可は、再リンクキットの `BINARY_USE_TERMS.ja.md` に記載します。

## 上流条件の保持

上流アーカイブのコード、著作権表示、ライセンス全文、特許表示は、NijiNeko側の変更範囲とは別に原典の条件を保持します。原典ファイルに個別の条件や帰属表示がある場合は、その条件が優先します。

| 部品 | 原典条件の概要 |
| --- | --- |
| mpv、FFmpeg、libplacebo | 該当するLGPL 2.1以降の部分。ソースアーカイブにはGPLおよび別バージョンのライセンス文書も残ります |
| libplacebo 7.360.1 | `tool/ios_video/versions.env` の `LIBPLACEBO_VERSION=7.360.1` で固定する上流版。NijiNeko独自のlibplaceboパッチはありません |
| dav1d | BSD 2-Clause、および同梱されるAOM特許ライセンス表示 |
| Jinja、MarkupSafe | BSD 3-Clause |
| Vulkan-Headers | ファイルごとのApache-2.0またはMIT |
| fast_float | 今回選択する通知はMIT。原典アーカイブにあるApache、Boostの全文も保持 |
| libplaceboのデモ | CC0 1.0。今回のビルドではデモを生成しません |

`licenses/<component>/` には上流の原典全文を置き、ソースファイルに含まれる追加の著作権・帰属表示も削除しません。FFmpegの `--disable-gpl` / `--disable-version3`、mpvの `-Dgpl=false` は、最終バイナリのビルド構成を選択する指定にすぎず、GPLソースをLGPLへ変更するものでも、単独でライセンス許諾を作るものでもありません。

## 改変・再構築と法的判断の区別

`verify.py` は `SHA256SUMS` に列挙された全同梱ファイルと実体が完全一致するかだけを検査します。版・取得先・構成は `COMPONENTS.json` と `tool/ios_video/versions.env`、生成Frameworkの監査は `audit_ios_video.sh`、アプリのMach-O・ABI・署名状態の検査は `replace_and_sign.py` が担当します。これらの技術検査に合格しても、LGPL、Appleの規約、第三者の著作権・特許・商標その他の法的適合性を判定するものではありません。バイト単位の一致も、SDK、ツールチェーン、作業環境などにより保証されません。

第三者の権利については、各上流の原典表示と条件を優先します。資料の版と配布アプリの対応は各 `MANIFEST.json` で確認してください。

問い合わせ先: `futaneko_contact@icloud.com`
