# 動画部品・対応ソースキット

このキットは、NijiNeko の iOS 動画部品について、固定した上流アーカイブ、変更セット、再構築補助コードをまとめた公開用の対応ソースです。アプリ本体のソースコード、署名用秘密鍵、Apple 配布者用プロファイルは含みません。

配布元は [FutaNeko動画部品資料](https://github.com/dieOD/futaneko-video-compliance) です。問い合わせ先は `futaneko_contact@icloud.com` です。本ソフトウェアはLGPL 2.1以降の [FFmpeg](https://ffmpeg.org/) を使用し、その対応ソースをこのキットの `archives/` と変更パッチで提供します。

対象のアプリ版・ビルド番号は `MANIFEST.json` を確認してください。ビルド1はMP4出力追加前のTestFlight版、ビルド2はMP4出力を含むストア提出候補です。以下のMP4・Swift接続コード・試験素材の項目はビルド2だけに含まれます。

## キットの構成

```text
archives/
  mpv-0.41.0.tar.gz
  ffmpeg-8.1.2.tar.xz
  dav1d-1.5.4.tar.bz2
  libplacebo-7.360.1.tar.bz2
  jinja-15206881c006c79667fe5154fe80c01c65410679.tar.gz
  markupsafe-297fc8e356e6836a62087949245d09a28e9f1b13.tar.gz
  vulkan-headers-450bd2232225d6c7728a4108055ac2e37cef6475.tar.gz
  fast-float-97b54ca9e75f5303507699d27c6b4f4efe4641a1.tar.gz
licenses/<component>/  # 各上流アーカイブから取り出した原典全文
modified-sources/     # 既定パッチ適用済み・変更通知付きのファイルの写し
MODIFIED_SOURCES.json # 通知の前後のハッシュと変更日
tool/ios_video/
  versions.env
  build_ios_video.sh
  audit_ios_video.sh
  patches/
  mp4_export.m         # ビルド2のみ
  version_probe.c
  mpv_no_subtitles.c
  probe_library_relink.sh、relink_probe.patch  # ビルド2のみ
  test_mp4_export.sh、mp4_export_test.m、test_mp4_export_paths.sh、mp4_export_paths_test.swift  # ビルド2のみ
packages/media_kit_libs_ios_video/
  LICENSE
  ios/Classes/         # ビルド2のみ
  ios/create_framework_symlinks.sh
rebuild.py
verify.py
add_source_notices.py
COPYING.LGPL-2.1
mpv-modification-example.patch  # 改変例。通常ビルドへは適用しない
COMPONENTS.json
MANIFEST.json
SHA256SUMS
```

`archives/` のファイル名、公式取得先、commit、SHA-256は `COMPONENTS.json`、`tool/ios_video/versions.env`、`SHA256SUMS` に記録します。`MANIFEST.json` はアプリ版とキット種別などの情報を中心に記録します。次の原典表示は、抜粋や要約ではなく、対応する原本を `licenses/<component>/` に保持します。

`modified-sources/` は、原本へ既定の変更を加え、日付入りの変更通知を付けたファイルそのものです。全文原本と変更パッチも保持しているため、対応関係を追跡できます。再構築は原本＋パッチ＋同じ通知処理から行い、元のプログラム行と行番号を保ちます。

| コンポーネント | 保持する原典ファイル |
| --- | --- |
| mpv | `LICENSE.LGPL`、`LICENSE.GPL`、`Copyright` |
| FFmpeg | `LICENSE.md`、`COPYING.LGPLv2.1`、`COPYING.LGPLv3`、`COPYING.GPLv2`、`COPYING.GPLv3` |
| dav1d | `COPYING`、`doc/PATENTS` |
| libplacebo | `LICENSE`、`demos/LICENSE` |
| Jinja | `LICENSE.txt` |
| MarkupSafe | `LICENSE.txt` |
| Vulkan-Headers | `LICENSE.md`、`LICENSES/Apache-2.0.txt`、`LICENSES/MIT.txt`、`.reuse/dep5` |
| fast_float | `LICENSE-MIT`、`LICENSE-APACHE`、`LICENSE-BOOST`、`AUTHORS` |

`docs/license.rst` のようなinclude指示だけのファイルを、ライセンス全文の代用にはしません。各ソースファイルに埋め込まれた著作権表示・帰属表示も、対応ソースの一部として保持します。

## ビルド対象とビルド専用入力

- mpv、FFmpeg、dav1d、libplacebo は動画Frameworkのビルド対象です。
- fast_float はヘッダー専用ですが、libplaceboのコンパイル済みコードに取り込まれるため、単なるビルド専用入力ではありません。
- Jinja と MarkupSafe は libplacebo のホスト側コード生成にだけ使用し、iOSアプリのPythonランタイムには含めません。
- Vulkan-Headers はヘッダーとビルド入力として保持します。今回の構成ではVulkanバックエンドとプロシージャアドレス機能を無効にし、Vulkanランタイムライブラリはリンクしません。
- libplaceboのデモとテストはビルドしませんが、原典のライセンス表示はソースキットに残します。

FFmpeg は `--disable-gpl --disable-version3 --disable-nonfree`、mpv は `-Dgpl=false` を指定します。これらは最終バイナリの構成を選ぶビルド設定であり、ソースアーカイブからGPLのファイルやライセンス文書を削除する指定ではありません。対応ソースには、上流のGPL関連ファイルと原典表示を残します。

## 再構築

macOS上で、キットのルートから実行します。XcodeとXcode Command Line Tools、Python 3.10以降が必要です。実際のビルドスクリプトは、`curl`、`meson`、`ninja`、`nasm`、`patch`、`pkg-config`、`shasum`、`tar`、`xcodebuild`、`xcrun` の存在を確認します。生成物の監査では `lipo`、`nm`、`otool`、`shasum`、`strings` を、再リンク試験では `rg` も使用します。

```sh
# SHA-256検証と隔離作業コピーの作成だけを行う
python3 -B rebuild.py --prepare-only

# 実機arm64、シミュレータarm64、シミュレータx86_64を再構築する
python3 -B rebuild.py

# 利用者が内容を確認して信頼する追加-p1パッチを使う場合
python3 -B rebuild.py --mpv-patch PATH --ffmpeg-patch PATH

# 読み込み時のログだけを追加する同梱改変例（通常配布用には使わない）
python3 -B rebuild.py --mpv-patch mpv-modification-example.patch
```

`--prepare-only` はSHA-256検証と隔離コピーの作成までで、アーカイブの展開や既定パッチの適用は行いません。通常実行時に、作業コピー内のビルドスクリプトがそれらを行います。既定変更を加えたファイルには `add_source_notices.py` が変更日・変更元の通知を末尾へ付け、元の行番号と上流の表示を維持します。通知前後のハッシュは作業場所の `source-modification-notices.json` へ記録します。追加パッチは利用者自身が内容を確認した信頼できる `-p1` パッチだけを指定し、自分の追加変更にもライセンスに応じた変更通知を付けてください。

実行ごとに `/private/tmp` の下へ `nijineko-ios-video-kit.*` という新しい作業コピーを作り、その中で3アーキテクチャをビルドします。入力キット、既存アプリ、既存のFrameworkは変更しません。

出力されたJSONの `workspace` 内にある `packages/media_kit_libs_ios_video/ios/Frameworks/Mpv.xcframework/ios-arm64/Mpv.framework` が実機用の成果物です。同梱改変例では起動時に `FUTANEKO_LGPL_MODIFIED_MPV_LOADED_20260906` が記録されます。元の版番号やAPIは変えません。

`verify.py` は、`SHA256SUMS` に列挙された全同梱ファイルと実体の完全一致（不足・追加・改変を含む）だけを検査します。生成Frameworkの版・構成・公開シンボル等は `audit_ios_video.sh`、アプリの再署名・Mach-O・ABI・署名状態は `replace_and_sign.py` が別に担当します。これらの技術検査に合格しても、LGPLその他のライセンス条件、Appleの配布条件、第三者権利への法的適合を判定したことにはなりません。

対応ソースキットと再リンク確認キットは、同一ビルドのリリース欄からセットで取得してください。再リンク確認キットにも `licenses/` の原典全文と、動画パッケージの `LICENSE` を写した `VIDEO_THIRD_PARTY_NOTICES.txt` を含めます。バイナリの追加許可は `BINARY_USE_TERMS.ja.md` に記載します。各キットはそれぞれの内容に対応する `MANIFEST.json` と `SHA256SUMS` を持つため、片方だけを別版へ差し替えた場合の結果は、このキットの対応範囲外です。

ビルド1は保存ソースから再構築し、配布IPA内の版・機能構成・パッチ識別子・公開API・動的依存を照合しています。ただし当時のIPAにソース管理の識別子がなく、全実行バイトが一致する再現ビルドを証明したという意味ではありません。ビルド2は元のネイティブ成果物との実装section照合と追加ソースのハッシュ確認も行っています。SDKや作業パスが異なる再ビルドのバイト一致はいずれも保証しません。

## 対応ソースの利用

変更済みソースを調査、改変、デバッグし、同じ構成または利用者自身の変更で再構築できるように、原本アーカイブ、変更ファイル、自作の追加部品、自作補助コード、ハッシュ一覧をまとめて提供します。変更内容の概要は `CHANGES.ja.md`、ライセンス範囲は `LICENSE_SCOPE.ja.md` を参照してください。
