#!/bin/bash
# 起動済みSimulatorで専用変換bridgeと上限制御を実形式検証する。
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
build_root="${NIJINEKO_IOS_VIDEO_BUILD_ROOT:-/private/tmp/nijineko-ios-video-$UID}"
if [[ ! "$build_root" =~ ^/private/tmp/nijineko-ios-video-[A-Za-z0-9._-]+$ ]]; then exit 64; fi
prefix="$build_root/targets/iossimulator-arm64/prefix"
work=$(mktemp -d /private/tmp/futaneko-mp4-export-test.XXXXXX)
framework="$repo_dir/packages/media_kit_libs_ios_video/ios/Frameworks/Mpv.xcframework/ios-arm64_x86_64-simulator/Mpv.framework"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
common=(-fblocks -fno-objc-arc -target arm64-apple-ios15.0-simulator -isysroot "$sdk")
system_frameworks=(-framework AVFoundation -framework Foundation -framework CoreMedia -framework CoreVideo -framework CoreGraphics)
cp -R "$framework" "$work/Mpv.framework"
mkdir "$work/input" "$work/normal"
for name in webm-vp8-vorbis.webm webm-vp9-opus.webm webm-av1-opus.webm webm-vp8-silent.webm mov-h264-aac.mov truncated.webm spoofed.mp4 external-url.m3u; do
  cp "$repo_dir/test/fixtures/video/$name" "$work/input/$name"
done
xcrun clang "${common[@]}" "$script_dir/mp4_export_test.m" \
  -F "$work" -framework Mpv "${system_frameworks[@]}" \
  "-Wl,-rpath,$work" -o "$work/test"
xcrun simctl spawn booted "$work/test" "$work/input" "$work/normal"

# 制限値を縮めるのは試験実行ファイルだけ。製品frameworkの定数は変更しない。
for limit in seconds dimension output; do
  case "$limit" in
    seconds) definition=-DNIJI_EXPORT_MAX_SECONDS=0.5 ;;
    dimension) definition=-DNIJI_EXPORT_MAX_DIMENSION=80 ;;
    output) definition=-DNIJI_EXPORT_MAX_OUTPUT_BYTES=1024 ;;
  esac
  mkdir "$work/$limit"
  xcrun clang "${common[@]}" -DNIJI_EXPORT_LIMIT_TEST "$definition" \
    -I "$prefix/include" "$script_dir/mp4_export.m" "$script_dir/mp4_export_test.m" \
    -L "$prefix/lib" -lavformat -lavcodec -lswscale -lswresample -lavutil -ldav1d \
    "${system_frameworks[@]}" -o "$work/test-$limit"
  xcrun simctl spawn booted "$work/test-$limit" "$work/input" "$work/$limit"
done
echo "MP4変換試験: 合格。確認用出力: $work"
