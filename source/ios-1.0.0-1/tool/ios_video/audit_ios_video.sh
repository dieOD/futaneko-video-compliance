#!/bin/bash
# 生成済みXCFrameworkの構成・依存・公開シンボルを静的監査する。
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck source=versions.env
source "$script_dir/versions.env"
framework="$repo_dir/packages/media_kit_libs_ios_video/ios/Frameworks/Mpv.xcframework"
device_binary="$framework/ios-arm64/Mpv.framework/Mpv"
simulator_binary="$framework/ios-arm64_x86_64-simulator/Mpv.framework/Mpv"

for command_name in lipo nm otool shasum strings; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "監査コマンドがありません: $command_name" >&2
    exit 69
  }
done
for binary in "$device_binary" "$simulator_binary"; do
  [[ -f "$binary" ]] || {
    echo "XCFrameworkがありません。先にbuild_ios_video.shを実行してください。" >&2
    exit 66
  }
done

[[ "$(lipo -archs "$device_binary")" == 'arm64' ]]
simulator_archs="$(lipo -archs "$simulator_binary")"
[[ "$simulator_archs" == *arm64* && "$simulator_archs" == *x86_64* ]]

unexpected_links=$(otool -L "$device_binary" | tail -n +2 | awk '{print $1}' | \
  grep -Ev '^(@rpath/Mpv\.framework/Mpv|/System/Library/Frameworks/.*|/usr/lib/lib(c\+\+\.1|System\.B|objc\.A)\.dylib)$' || true)
if [[ -n "$unexpected_links" ]]; then
  echo "許可していない動的依存があります:" >&2
  echo "$unexpected_links" >&2
  exit 70
fi

exports=$(nm -gU "$device_binary" | awk '{print $NF}')
unexpected_exports=$(echo "$exports" | grep -Ev '^_(mpv_|nijineko_video_)' || true)
if [[ -n "$unexpected_exports" ]]; then
  echo "許可していない公開シンボルがあります:" >&2
  echo "$unexpected_exports" >&2
  exit 70
fi
for symbol in \
  _nijineko_video_mpv_version \
  _nijineko_video_ffmpeg_version \
  _nijineko_video_ffmpeg_configuration \
  _nijineko_video_patchset \
  _nijineko_video_dav1d_version \
  _nijineko_video_libplacebo_version \
  _nijineko_video_input_protocol_count \
  _nijineko_video_demuxer_count \
  _nijineko_video_mpv_demuxer_count \
  _nijineko_video_decoder_count \
  _nijineko_video_encoder_count \
  _nijineko_video_parser_count \
  _nijineko_video_has_parser \
  _nijineko_video_bitstream_filter_count \
  _nijineko_video_has_bitstream_filter \
  _nijineko_video_filter_count \
  _nijineko_video_has_filter \
  _nijineko_video_muxer_count \
  _nijineko_video_network_open_is_blocked \
  _nijineko_video_command_allowlist_is_exact \
  _nijineko_video_external_config_is_blocked; do
  echo "$exports" | grep -qx "$symbol"
done

embedded=$(strings "$device_binary")
echo "$embedded" | grep -F 'FFmpeg version 8.1.2' >/dev/null
echo "$embedded" | grep -F -- '--disable-unstable' >/dev/null
echo "$embedded" | grep -F -- '--disable-network' >/dev/null
echo "$embedded" | grep -F -- '--disable-gpl' >/dev/null
echo "$embedded" | grep -F -- '--disable-nonfree' >/dev/null
echo "$embedded" | grep -F -- '--enable-protocol=file' >/dev/null
echo "$embedded" | grep -F -- "--enable-demuxer='matroska,mov'" >/dev/null
echo "$embedded" | grep -F -- "--enable-decoder='vp8,vp9,libdav1d,h264,opus,vorbis,aac'" >/dev/null
echo "$embedded" | grep -F -- '-Dgpl=false' >/dev/null
echo "$embedded" | grep -F -- '-Dcplayer=false' >/dev/null
echo "$embedded" | grep -F -- '-Dauto_features=disabled' >/dev/null
expected_patchset="ffmpeg-minimal=$FFMPEG_MINIMAL_PATCH_SHA256;ffmpeg-hardening=$FFMPEG_HARDENING_PATCH_SHA256;mpv-no-subtitles=$MPV_NO_SUBTITLES_PATCH_SHA256;mpv-audio-session=$MPV_SHARED_AUDIO_PATCH_SHA256;mpv-local-only=$MPV_LOCAL_ONLY_PATCH_SHA256;mpv-no-subtitles-source=$MPV_NO_SUBTITLES_SOURCE_SHA256"
echo "$embedded" | grep -F -- "$expected_patchset" >/dev/null

echo "XCFramework静的監査: 合格"
echo "実機: $(lipo -info "$device_binary")"
echo "Simulator: $(lipo -info "$simulator_binary")"
echo "実機バイナリ SHA-256: $(shasum -a 256 "$device_binary" | awk '{print $1}')"
