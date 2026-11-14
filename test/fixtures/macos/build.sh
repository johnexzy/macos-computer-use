#!/bin/sh
set -eu

fixture_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture_app="$fixture_dir/.build/CUAFixture.app"
mkdir -p "$fixture_app/Contents/MacOS"
xcrun swiftc -O -framework AppKit "$fixture_dir/main.swift" -o "$fixture_app/Contents/MacOS/CUAFixture"
cp "$fixture_dir/Info.plist" "$fixture_app/Contents/Info.plist"
printf '%s\n' "$fixture_app/Contents/MacOS/CUAFixture"
