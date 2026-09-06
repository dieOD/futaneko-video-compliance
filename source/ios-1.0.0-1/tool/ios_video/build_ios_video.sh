#!/bin/bash
# mpv/FFmpegをiOS向けのローカルファイル再生専用構成で再生成する。
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck source=versions.env
source "$script_dir/versions.env"

# FFmpeg 8.1.2のconfigureはソースパス中の空白を正しく扱えないため、既定の
# 作業場所は空白を含まない/private/tmp配下とする。成果物だけをプラグインへ戻す。
build_root="${NIJINEKO_IOS_VIDEO_BUILD_ROOT:-/private/tmp/nijineko-ios-video-$UID}"
if [[ ! "$build_root" =~ ^/private/tmp/nijineko-ios-video-[A-Za-z0-9._-]+$ ]]; then
  echo "作業ディレクトリは /private/tmp/nijineko-ios-video-<安全な名前> に限定します。" >&2
  exit 64
fi
download_dir="$build_root/downloads"
source_dir="$build_root/sources"
target_root="$build_root/targets"
framework_work="$build_root/frameworks"
plugin_ios="$repo_dir/packages/media_kit_libs_ios_video/ios"
output_xcframework="$plugin_ios/Frameworks/Mpv.xcframework"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$source_dir" "$target_root" "$framework_work" "$output_xcframework"
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "使い方: $0 [--clean]" >&2
  exit 64
fi

for command_name in curl meson ninja nasm patch pkg-config shasum tar xcodebuild xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "必要なコマンドがありません: $command_name" >&2
    exit 69
  fi
done

verify_local_file() {
  local expected_sha256=$1
  local local_file=$2
  echo "$expected_sha256  $local_file" | shasum -a 256 --check --status
}

verify_local_file "$FFMPEG_MINIMAL_PATCH_SHA256" \
  "$script_dir/patches/ffmpeg-8.1.2-minimal-config.patch"
verify_local_file "$FFMPEG_HARDENING_PATCH_SHA256" \
  "$script_dir/patches/ffmpeg-8.1.2-post-release-hardening.patch"
verify_local_file "$MPV_NO_SUBTITLES_PATCH_SHA256" \
  "$script_dir/patches/mpv-0.41.0-no-subtitles.patch"
verify_local_file "$MPV_SHARED_AUDIO_PATCH_SHA256" \
  "$script_dir/patches/mpv-0.41.0-shared-audio-session.patch"
verify_local_file "$MPV_LOCAL_ONLY_PATCH_SHA256" \
  "$script_dir/patches/mpv-0.41.0-local-only.patch"
verify_local_file "$MPV_NO_SUBTITLES_SOURCE_SHA256" \
  "$script_dir/mpv_no_subtitles.c"

video_patchset="ffmpeg-minimal=$FFMPEG_MINIMAL_PATCH_SHA256;ffmpeg-hardening=$FFMPEG_HARDENING_PATCH_SHA256;mpv-no-subtitles=$MPV_NO_SUBTITLES_PATCH_SHA256;mpv-audio-session=$MPV_SHARED_AUDIO_PATCH_SHA256;mpv-local-only=$MPV_LOCAL_ONLY_PATCH_SHA256;mpv-no-subtitles-source=$MPV_NO_SUBTITLES_SOURCE_SHA256"

mkdir -p "$download_dir" "$source_dir" "$target_root" "$framework_work"

fetch_verified() {
  local file_name=$1
  local url=$2
  local expected_sha256=$3
  local destination="$download_dir/$file_name"
  local temporary="$destination.part"

  if [[ -f "$destination" ]] &&
      echo "$expected_sha256  $destination" | shasum -a 256 --check --status; then
    return
  fi

  rm -f "$temporary" "$destination"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 600 \
    --output "$temporary" "$url"
  echo "$expected_sha256  $temporary" | shasum -a 256 --check --status
  mv "$temporary" "$destination"
}

echo "固定ソースを取得・検証しています。"
fetch_verified "mpv-$MPV_VERSION.tar.gz" "$MPV_URL" "$MPV_SHA256"
fetch_verified "ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_URL" "$FFMPEG_SHA256"
fetch_verified "dav1d-$DAV1D_VERSION.tar.bz2" "$DAV1D_URL" "$DAV1D_SHA256"
fetch_verified "libplacebo-$LIBPLACEBO_VERSION.tar.bz2" \
  "$LIBPLACEBO_URL" "$LIBPLACEBO_SHA256"
fetch_verified "jinja-$JINJA_COMMIT.tar.gz" "$JINJA_URL" "$JINJA_SHA256"
fetch_verified "markupsafe-$MARKUPSAFE_COMMIT.tar.gz" \
  "$MARKUPSAFE_URL" "$MARKUPSAFE_SHA256"
fetch_verified "vulkan-headers-$VULKAN_HEADERS_COMMIT.tar.gz" \
  "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_SHA256"
fetch_verified "fast-float-$FAST_FLOAT_COMMIT.tar.gz" \
  "$FAST_FLOAT_URL" "$FAST_FLOAT_SHA256"

extract_source() {
  local archive=$1
  local destination=$2
  rm -rf "$destination"
  mkdir -p "$destination"
  tar -xf "$archive" -C "$destination" --strip-components=1
}

echo "検証済みソースを展開しています。"
extract_source "$download_dir/mpv-$MPV_VERSION.tar.gz" "$source_dir/mpv"
extract_source "$download_dir/ffmpeg-$FFMPEG_VERSION.tar.xz" "$source_dir/ffmpeg"
extract_source "$download_dir/dav1d-$DAV1D_VERSION.tar.bz2" "$source_dir/dav1d"
extract_source "$download_dir/libplacebo-$LIBPLACEBO_VERSION.tar.bz2" \
  "$source_dir/libplacebo"

rm -rf "$source_dir/libplacebo/3rdparty/jinja" \
  "$source_dir/libplacebo/3rdparty/markupsafe" \
  "$source_dir/libplacebo/3rdparty/Vulkan-Headers" \
  "$source_dir/libplacebo/3rdparty/fast_float"
mkdir -p "$source_dir/libplacebo/3rdparty/jinja" \
  "$source_dir/libplacebo/3rdparty/markupsafe" \
  "$source_dir/libplacebo/3rdparty/Vulkan-Headers" \
  "$source_dir/libplacebo/3rdparty/fast_float"
tar -xf "$download_dir/jinja-$JINJA_COMMIT.tar.gz" \
  -C "$source_dir/libplacebo/3rdparty/jinja" --strip-components=1
tar -xf "$download_dir/markupsafe-$MARKUPSAFE_COMMIT.tar.gz" \
  -C "$source_dir/libplacebo/3rdparty/markupsafe" --strip-components=1
tar -xf "$download_dir/vulkan-headers-$VULKAN_HEADERS_COMMIT.tar.gz" \
  -C "$source_dir/libplacebo/3rdparty/Vulkan-Headers" --strip-components=1
tar -xf "$download_dir/fast-float-$FAST_FLOAT_COMMIT.tar.gz" \
  -C "$source_dir/libplacebo/3rdparty/fast_float" --strip-components=1

(
  cd "$source_dir/ffmpeg"
  patch --batch --forward -p1 < \
    "$script_dir/patches/ffmpeg-8.1.2-minimal-config.patch"
  patch --batch --forward -p1 < \
    "$script_dir/patches/ffmpeg-8.1.2-post-release-hardening.patch"
)

(
  cd "$source_dir/mpv"
  patch --batch --forward -p1 < "$script_dir/patches/mpv-0.41.0-no-subtitles.patch"
  patch --batch --forward -p1 < \
    "$script_dir/patches/mpv-0.41.0-shared-audio-session.patch"
  patch --batch --forward -p1 < \
    "$script_dir/patches/mpv-0.41.0-local-only.patch"
  cp "$script_dir/mpv_no_subtitles.c" sub/no_subtitles.c
)

clang_path=$(xcrun --find clang)
clangxx_path=$(xcrun --find clang++)
ar_path=$(xcrun --find ar)
ranlib_path=$(xcrun --find ranlib)
strip_path=$(xcrun --find strip)

write_cross_file() {
  local path=$1
  local sdk=$2
  local target=$3
  local cpu_family=$4
  local cpu=$5
  local sysroot=$6

  # Mesonのcross fileはビルド先ごとに生成し、ホスト側のライブラリ探索を遮断する。
  {
    echo "[binaries]"
    printf "c = '%s'\n" "$clang_path"
    printf "cpp = '%s'\n" "$clangxx_path"
    printf "objc = '%s'\n" "$clang_path"
    printf "objcpp = '%s'\n" "$clangxx_path"
    printf "ar = '%s'\n" "$ar_path"
    printf "strip = '%s'\n" "$strip_path"
    echo "pkg-config = 'pkg-config'"
    echo
    echo "[built-in options]"
    printf "c_args = ['-target', '%s', '-isysroot', '%s', '-O2', '-fPIC']\n" \
      "$target" "$sysroot"
    printf "cpp_args = ['-target', '%s', '-isysroot', '%s', '-O2', '-fPIC']\n" \
      "$target" "$sysroot"
    printf "objc_args = ['-target', '%s', '-isysroot', '%s', '-O2', '-fPIC']\n" \
      "$target" "$sysroot"
    printf "objcpp_args = ['-target', '%s', '-isysroot', '%s', '-O2', '-fPIC']\n" \
      "$target" "$sysroot"
    printf "c_link_args = ['-target', '%s', '-isysroot', '%s']\n" "$target" "$sysroot"
    printf "cpp_link_args = ['-target', '%s', '-isysroot', '%s']\n" "$target" "$sysroot"
    printf "objc_link_args = ['-target', '%s', '-isysroot', '%s']\n" "$target" "$sysroot"
    echo
    echo "[host_machine]"
    echo "system = 'darwin'"
    printf "cpu_family = '%s'\n" "$cpu_family"
    printf "cpu = '%s'\n" "$cpu"
    echo "endian = 'little'"
    echo
    echo "[properties]"
    echo "needs_exe_wrapper = true"
  } > "$path"
}

build_target() {
  local name=$1
  local sdk=$2
  local arch=$3
  local cpu_family=$4
  local cpu=$5
  local target=$6
  local sysroot
  local work="$target_root/$name"
  local prefix="$work/prefix"
  local cross="$work/cross.ini"
  local ffmpeg_arch
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)

  rm -rf "$work"
  mkdir -p "$work" "$prefix"
  write_cross_file "$cross" "$sdk" "$target" "$cpu_family" "$cpu" "$sysroot"

  echo "[$name] dav1d $DAV1D_VERSION"
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH= \
    meson setup "$work/dav1d" "$source_dir/dav1d" \
      --cross-file "$cross" --prefix "$prefix" --libdir lib \
      --buildtype release --default-library static \
      -Dbitdepths=8,16 -Denable_asm=true -Denable_tools=false \
      -Denable_examples=false -Denable_tests=false -Denable_docs=false \
      -Dlogging=false
  meson compile -C "$work/dav1d"
  meson install -C "$work/dav1d"

  case "$arch" in
    arm64) ffmpeg_arch=aarch64 ;;
    x86_64) ffmpeg_arch=x86_64 ;;
    *) echo "未対応のアーキテクチャです: $arch" >&2; exit 65 ;;
  esac

  echo "[$name] FFmpeg $FFMPEG_VERSION"
  (
    cd "$work"
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH= \
      "$source_dir/ffmpeg/configure" \
        --prefix="$prefix" --libdir="$prefix/lib" \
        --target-os=darwin --arch="$ffmpeg_arch" --enable-cross-compile \
        --cc="$clang_path" --cxx="$clangxx_path" --ar="$ar_path" \
        --ranlib="$ranlib_path" --strip="$strip_path" --sysroot="$sysroot" \
        --extra-cflags="-target $target -isysroot $sysroot -O2 -fPIC" \
        --extra-cxxflags="-target $target -isysroot $sysroot -O2 -fPIC" \
        --extra-ldflags="-target $target -isysroot $sysroot" \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --disable-autodetect --disable-everything --disable-unstable \
        --disable-network \
        --disable-shared --enable-static --enable-pic --enable-small \
        --disable-programs --disable-doc --disable-debug \
        --disable-avdevice --disable-hwaccels \
        --disable-videotoolbox --disable-audiotoolbox \
        --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
        --disable-sdl2 --disable-securetransport \
        --disable-gpl --disable-nonfree --disable-version3 \
        --enable-avcodec --enable-avfilter --enable-avformat --enable-avutil \
        --enable-swresample --enable-swscale --enable-pthreads \
        --enable-libdav1d \
        --enable-protocol=file \
        --enable-demuxer=matroska,mov \
        --enable-decoder=vp8,vp9,libdav1d,h264,opus,vorbis,aac \
        --enable-parser=vp8,vp9,av1,h264,opus,vorbis,aac
    make -j"$(sysctl -n hw.logicalcpu)"
    make install
  )

  echo "[$name] libplacebo $LIBPLACEBO_VERSION"
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH= \
    meson setup "$work/libplacebo" "$source_dir/libplacebo" \
      --cross-file "$cross" --prefix "$prefix" --libdir lib \
      --buildtype release --default-library static --wrap-mode nodownload \
      -Dvulkan=disabled -Dvk-proc-addr=disabled \
      -Dopengl=disabled -Dgl-proc-addr=disabled -Dd3d11=disabled \
      -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled \
      -Ddovi=disabled -Dlibdovi=disabled -Dunwind=disabled \
      -Dxxhash=disabled -Ddemos=false -Dtests=false -Dbench=false \
      -Dfuzz=false -Ddebug-abort=false
  meson compile -C "$work/libplacebo"
  meson install -C "$work/libplacebo"

  echo "[$name] mpv $MPV_VERSION"
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH= \
    meson setup "$work/mpv" "$source_dir/mpv" \
      --cross-file "$cross" --prefix "$prefix" --libdir lib \
      --buildtype release --default-library static --wrap-mode nodownload \
      -Dauto_features=disabled -Dgpl=false -Dcplayer=false -Dlibmpv=true \
      -Dbuild-date=false -Dtests=false -Dfuzzers=false \
      -Dgl=enabled -Dplain-gl=enabled -Dios-gl=enabled \
      -Daudiounit=enabled -Dlibavdevice=disabled
  meson compile -C "$work/mpv"
  meson install -C "$work/mpv"

  create_thin_framework "$name" "$target" "$sysroot" "$prefix"
}

create_framework_plist() {
  local plist=$1
  local minimum_os=$2
  plutil -create xml1 "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDevelopmentRegion string en' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Mpv' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.nijineko.Mpv' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Mpv' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string FMWK' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 2.3.0' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 2.3.0' "$plist"
  /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $minimum_os" "$plist"
}

create_thin_framework() {
  local name=$1
  local target=$2
  local sysroot=$3
  local prefix=$4
  local framework="$framework_work/$name/Mpv.framework"
  local exports="$target_root/$name/mpv.exports"
  local probe_object="$target_root/$name/version_probe.o"
  local libmpv="$prefix/lib/libmpv.a"
  local libraries=(
    "$libmpv"
    "$prefix/lib/libavfilter.a"
    "$prefix/lib/libavformat.a"
    "$prefix/lib/libavcodec.a"
    "$prefix/lib/libswresample.a"
    "$prefix/lib/libswscale.a"
    "$prefix/lib/libavutil.a"
    "$prefix/lib/libplacebo.a"
    "$prefix/lib/libdav1d.a"
  )
  local linker_args=()
  local library

  for library in "${libraries[@]}"; do
    if [[ ! -f "$library" ]]; then
      echo "静的ライブラリが見つかりません: $library" >&2
      exit 66
    fi
    linker_args+=("-Wl,-force_load,$library")
  done

  "$clang_path" -c "$script_dir/version_probe.c" -o "$probe_object" \
    -target "$target" -isysroot "$sysroot" -O2 -fPIC \
    "-DNIJINEKO_VIDEO_PATCHSET=\"$video_patchset\"" \
    -I"$prefix/include"

  nm -gU "$libmpv" | awk '{ print $NF }' | grep '^_mpv_' | sort -u > "$exports"
  nm -gU "$probe_object" | awk '{ print $NF }' | \
    grep '^_nijineko_video_' | sort -u >> "$exports"
  if ! grep -qx '_mpv_client_api_version' "$exports"; then
    echo "libmpvの公開シンボルを抽出できませんでした。" >&2
    exit 70
  fi

  rm -rf "$framework"
  mkdir -p "$framework"
  "$clang_path" -dynamiclib -target "$target" -isysroot "$sysroot" \
    -o "$framework/Mpv" \
    -install_name '@rpath/Mpv.framework/Mpv' \
    -compatibility_version 2.0.0 -current_version 2.3.0 \
    "-Wl,-exported_symbols_list,$exports" \
    "${linker_args[@]}" \
    "$probe_object" \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio \
    -framework CoreFoundation -framework CoreMedia -framework CoreVideo \
    -framework Foundation -framework OpenGLES -framework QuartzCore \
    -framework UIKit -framework VideoToolbox -lc++
  create_framework_plist "$framework/Info.plist" "$IOS_DEPLOYMENT_TARGET"
}

# ビルド成果物に日時を埋め込む上流機能は無効。アーカイブ順序も固定する。
export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH=1766275200

rm -rf "$target_root" "$framework_work" "$output_xcframework"
mkdir -p "$target_root" "$framework_work" "$(dirname "$output_xcframework")"

build_target ios-arm64 iphoneos arm64 aarch64 arm64 \
  "arm64-apple-ios$IOS_DEPLOYMENT_TARGET"
build_target iossimulator-arm64 iphonesimulator arm64 aarch64 arm64 \
  "arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator"
build_target iossimulator-x86_64 iphonesimulator x86_64 x86_64 x86_64 \
  "x86_64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator"

simulator_framework="$framework_work/ios-arm64_x86_64-simulator/Mpv.framework"
rm -rf "$simulator_framework"
mkdir -p "$simulator_framework"
lipo -create \
  "$framework_work/iossimulator-arm64/Mpv.framework/Mpv" \
  "$framework_work/iossimulator-x86_64/Mpv.framework/Mpv" \
  -output "$simulator_framework/Mpv"
cp "$framework_work/iossimulator-arm64/Mpv.framework/Info.plist" \
  "$simulator_framework/Info.plist"

xcodebuild -create-xcframework \
  -framework "$framework_work/ios-arm64/Mpv.framework" \
  -framework "$simulator_framework" \
  -output "$output_xcframework"

sh "$plugin_ios/create_framework_symlinks.sh"

build_info="$plugin_ios/build-info.txt"
{
  echo "NijiNeko iOS video foundation"
  echo "mpv=$MPV_VERSION commit=$MPV_COMMIT sha256=$MPV_SHA256"
  echo "ffmpeg=$FFMPEG_VERSION commit=$FFMPEG_COMMIT sha256=$FFMPEG_SHA256"
  echo "dav1d=$DAV1D_VERSION commit=$DAV1D_COMMIT sha256=$DAV1D_SHA256"
  echo "libplacebo=$LIBPLACEBO_VERSION commit=$LIBPLACEBO_COMMIT sha256=$LIBPLACEBO_SHA256"
  echo "jinja_commit=$JINJA_COMMIT sha256=$JINJA_SHA256"
  echo "markupsafe_commit=$MARKUPSAFE_COMMIT sha256=$MARKUPSAFE_SHA256"
  echo "vulkan_headers_commit=$VULKAN_HEADERS_COMMIT sha256=$VULKAN_HEADERS_SHA256"
  echo "fast_float_commit=$FAST_FLOAT_COMMIT sha256=$FAST_FLOAT_SHA256"
  echo "ffmpeg_minimal_patch_sha256=$FFMPEG_MINIMAL_PATCH_SHA256"
  echo "ffmpeg_hardening_patch_sha256=$FFMPEG_HARDENING_PATCH_SHA256"
  echo "ffmpeg_post_release_commits=$FFMPEG_POST_RELEASE_COMMITS"
  echo "mpv_no_subtitles_patch_sha256=$MPV_NO_SUBTITLES_PATCH_SHA256"
  echo "mpv_shared_audio_patch_sha256=$MPV_SHARED_AUDIO_PATCH_SHA256"
  echo "mpv_local_only_patch_sha256=$MPV_LOCAL_ONLY_PATCH_SHA256"
  echo "mpv_no_subtitles_source_sha256=$MPV_NO_SUBTITLES_SOURCE_SHA256"
  echo "runtime_patchset=$video_patchset"
  echo "version_probe_source_sha256=$(shasum -a 256 "$script_dir/version_probe.c" | awk '{print $1}')"
  echo "iOS deployment target=$IOS_DEPLOYMENT_TARGET"
  echo "network=disabled protocols=file demuxers=matroska,mov"
  echo "decoders=vp8,vp9,libdav1d,h264,opus,vorbis,aac"
  echo "gpl=false nonfree=false encoders=none muxers=none subtitles=none"
  echo "parsers=vp8,vp9,av1,h264,opus,vorbis,aac bsf=vp9_superframe_split"
  echo "avfilters=abuffer,buffer,abuffersink,buffersink (mpv-required API endpoints; no conversion filters)"
  echo "mpv_demuxers=lavf command_allowlist=13 external_config=disabled scripts=none"
} > "$build_info"

echo "生成完了: $output_xcframework"
lipo -info "$output_xcframework/ios-arm64/Mpv.framework/Mpv"
lipo -info \
  "$output_xcframework/ios-arm64_x86_64-simulator/Mpv.framework/Mpv"
