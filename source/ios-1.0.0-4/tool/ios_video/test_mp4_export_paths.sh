#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS専用のSwiftパス検証試験です" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
helper="$repo_dir/packages/media_kit_libs_ios_video/ios/Classes/NijiMp4ExportPaths.swift"
test_source="$script_dir/mp4_export_paths_test.swift"

if [[ ! -f "$helper" ]]; then
  echo "製品helperがありません: $helper" >&2
  exit 2
fi
if [[ ! -f "$test_source" ]]; then
  echo "試験ソースがありません: $test_source" >&2
  exit 2
fi
command -v swiftc >/dev/null

work_parent="/private/tmp"
work_prefix="nijineko-mp4-export-paths."
work_dir="$(mktemp -d /private/tmp/nijineko-mp4-export-paths.XXXXXX)"
cleanup() {
  local suffix
  if [[ -z "${work_dir:-}" || "$work_dir" != "$work_parent/$work_prefix"* ]]; then
    return
  fi
  suffix="${work_dir#"$work_parent/$work_prefix"}"
  if [[ ${#suffix} -ne 6 || "$suffix" == */* || ! -d "$work_dir" || -L "$work_dir" ]]; then
    return
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT INT TERM

swiftc -O "$helper" "$test_source" -o "$work_dir/mp4_export_paths_test"
"$work_dir/mp4_export_paths_test"
