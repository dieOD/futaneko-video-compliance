#!/bin/bash
# 既存の動画ライブラリのビルド中間物を読み取り、隔離したコピーだけを改変する。
# 本体ソースのコンパイル、元frameworkの上書き、署名、端末操作、公開は行わない。
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "使い方: bash tool/ios_video/probe_library_relink.sh <動画ライブラリのビルド作業ディレクトリ>" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_root=$(CDPATH= cd -- "$1" && pwd)
source_root="$build_root/sources/mpv"
for name in ios-arm64 iossimulator-arm64; do
  for required in prefix/lib/libmpv.a version_probe.o mp4_export.o mpv.exports; do
    [[ -f "$build_root/targets/$name/$required" ]] || {
      echo "中間物がありません: $name/$required" >&2
      exit 66
    }
  done
done
[[ -f "$source_root/common/version.c" ]] || exit 66

probe_root=$(mktemp -d /private/tmp/futaneko-lgpl-relink.XXXXXX)
cp "$source_root/common/version.c" "$probe_root/version.c"
patch --batch --directory "$probe_root" -p1 --input "$script_dir/relink_probe.patch"

for name in ios-arm64 iossimulator-arm64; do
  sdk=iphoneos
  target=arm64-apple-ios15.0
  if [[ "$name" == iossimulator-arm64 ]]; then
    sdk=iphonesimulator
    target=arm64-apple-ios15.0-simulator
  fi
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  work="$build_root/targets/$name"
  prefix="$work/prefix"
  output="$probe_root/$name"
  framework="$output/Mpv.framework"
  mkdir -p "$framework"

  xcrun clang -c "$probe_root/version.c" -o "$output/common_version.c.o" \
    -target "$target" -isysroot "$sysroot" -std=c11 -O2 -fPIC \
    -fvisibility=hidden -D_GNU_SOURCE -DNO_BUILD_TIMESTAMPS \
    -DPL_HAVE_PTHREAD -DPL_STATIC \
    -I"$work/mpv" -I"$work/mpv/common" \
    -I"$source_root" -I"$source_root/common" -I"$source_root/include" -I"$prefix/include"

  cp "$prefix/lib/libmpv.a" "$output/libmpv.a"
  xcrun ar -r "$output/libmpv.a" "$output/common_version.c.o"
  xcrun ranlib "$output/libmpv.a"
  args=("-Wl,-force_load,$output/libmpv.a")
  for library in avfilter avformat avcodec swresample swscale avutil placebo dav1d; do
    args+=("-Wl,-force_load,$prefix/lib/lib$library.a")
  done

  xcrun clang -dynamiclib -target "$target" -isysroot "$sysroot" \
    -o "$framework/Mpv" -install_name '@rpath/Mpv.framework/Mpv' \
    -compatibility_version 2.0.0 -current_version 2.3.0 \
    "-Wl,-exported_symbols_list,$work/mpv.exports" \
    "${args[@]}" "$work/version_probe.o" "$work/mp4_export.o" \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio \
    -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
    -framework CoreVideo -framework Foundation -framework OpenGLES \
    -framework QuartzCore -framework UIKit -framework VideoToolbox -lc++
  cp "$build_root/frameworks/$name/Mpv.framework/Info.plist" "$framework/Info.plist"

  # マーカーが元の部品にはなく、改変した部品にだけ含まれることを確認する。
  if strings "$build_root/frameworks/$name/Mpv.framework/Mpv" | \
    rg 'FUTANEKO_LGPL_MODIFIED_MPV_LOADED_20260906' >/dev/null; then
    echo "元のライブラリに試験用マーカーが含まれています" >&2
    exit 70
  fi
  strings "$framework/Mpv" | rg 'FUTANEKO_LGPL_MODIFIED_MPV_LOADED_20260906'
  shasum -a 256 "$framework/Mpv"
done

echo "改変済みコピー: $probe_root"
echo "これは再リンクの技術試験です。ライセンス適合や実機動作の判定ではありません。"
