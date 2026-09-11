#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
framework="$script_dir/Frameworks/Mpv.xcframework"
links="$script_dir/Frameworks/.symlinks/mpv"

test -d "$framework/ios-arm64/Mpv.framework"
test -d "$framework/ios-arm64_x86_64-simulator/Mpv.framework"

rm -rf "$script_dir/Frameworks/.symlinks"
mkdir -p "$links"
ln -s ../../Mpv.xcframework/ios-arm64 "$links/ios"
ln -s ../../Mpv.xcframework/ios-arm64_x86_64-simulator "$links/ios-simulator"
