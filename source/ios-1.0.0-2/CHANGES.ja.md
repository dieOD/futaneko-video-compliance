# 動画部品の変更履歴

このファイルは、対応ソースキットに含める変更の公開用概要です。上流ソースの著作権表示とライセンス条件は、変更後も各原典ファイルおよび `licenses/<component>/` に保持します。

## 2026-08-31 — iOS動画基盤

固定したmpv、FFmpeg、dav1d、libplaceboと、libplaceboの再構築に必要なJinja、MarkupSafe、Vulkan-Headers、fast_floatを使用する最小動画基盤を整えました。実機arm64、シミュレータarm64、シミュレータx86_64を対象にします。

5つの変更セットの概要は次のとおりです。

1. `ffmpeg-8.1.2-minimal-config.patch`
   - ローカルファイル再生に必要なFFmpegの構成へ限定し、不要な復号経路のビルド時不整合を補正します。
2. `ffmpeg-8.1.2-post-release-hardening.patch`
   - 8.1.2公開後のIAMF等の入力検証を取り込み、異常な長さ・空要素を拒否します。
3. `mpv-0.41.0-no-subtitles.patch`
   - libassと字幕描画を外し、字幕無効化用の最小部品をビルド対象にします。
4. `mpv-0.41.0-shared-audio-session.patch`
   - iOS Audio Sessionの共有利用と参照数管理を追加します。
5. `mpv-0.41.0-local-only.patch`
   - 検査済みローカル動画の再生に限定し、外部設定、スクリプト、ネットワーク等の入口を狭めます。

FFmpegではGPL、nonfree、version 3構成を無効にし、mpvではGPL専用部分を選択しない設定にします。ソースアーカイブに残るGPLの原典ファイルを、この設定によって再許諾したり削除したりするものではありません。

## 2026-09-06 — MP4出力とSwiftパス検査の修正

この節はビルド2にのみ適用します。ビルド1にはMP4変換とSwift変換接続コードを含みません。`version_probe.c` と `mpv_no_subtitles.c` は8月31日から使用する共通部品です。

自作の追加部品3点と、接続コードの変更概要は次のとおりです。

- `mpv_no_subtitles.c`: 字幕・mpv内蔵OSDを使わないための最小実装。
- `version_probe.c`: 最終Frameworkにリンクされたmpv、FFmpeg、dav1d、libplaceboの版・構成・ライセンス文字列・公開APIを読み取る検査用API。
- `mp4_export.m`: 検査済みローカル動画をAppleのH.264/AAC MP4へ変換する部品。FFmpegのエンコーダ・muxer構成を有効化するものではありません。
- `NijiMp4ExportPaths.swift`: キャッシュ配下の正規パス、固定形式のファイル名、シンボリックリンク、不存在の出力先を検査してからMP4出力へ渡すSwift側の修正。

## 2026-09-06 — 対応資料の公開

ビルド別の対応ソースと再リンク材料を分け、原典ライセンス・ハッシュ一覧・利用者の署名で差し替える道具を同梱しました。再構築時に既定の変更ファイルへ日付入りの通知を付ける補助コードを追加しています。これは元のアプリ実行バイナリを更新する変更ではありません。

この変更履歴は機能と変更箇所の概要であり、各上流部分の完全な変更理由、著作権者、ライセンス範囲を置き換えません。自作の追加部品と再構築補助コードの条件は `LICENSE_SCOPE.ja.md` に記載します。
