#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
build_dir=$(mktemp -d)

cleanup() {
  rm -rf -- "$build_dir"
}
trap cleanup EXIT

xcrun swiftc -O -target arm64-apple-macosx13.0 \
  "$repo_dir/native_helper.swift" \
  -o "$build_dir/native_helper-arm64"
xcrun swiftc -O -target x86_64-apple-macosx13.0 \
  "$repo_dir/native_helper.swift" \
  -o "$build_dir/native_helper-x86_64"
xcrun lipo -create \
  "$build_dir/native_helper-arm64" \
  "$build_dir/native_helper-x86_64" \
  -output "$repo_dir/native_helper"
codesign --force --sign - "$repo_dir/native_helper"
chmod 755 "$repo_dir/native_helper"
