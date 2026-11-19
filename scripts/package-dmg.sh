#!/bin/sh
# Build a drag-and-drop review disk image for the standalone native server.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$root/.artifacts/dmg-dist"}
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd)
version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$root/crates/cua-host/Cargo.toml")
image_name="macos-computer-use-$version-macos-universal.dmg"
image="$output/$image_name"
if [ -e "$image" ] || [ -e "$image.sha256" ]; then
  printf '%s\n' "Review image already exists; use a new output directory: $image" >&2
  exit 1
fi

temporary=$(mktemp -d "$output/.dmg-package.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
sh "$root/scripts/package-native.sh" "$temporary"
native_name="cua-native-$version-macos-universal"
tar -xzf "$temporary/$native_name.tar.gz" -C "$temporary"
native="$temporary/$native_name"

stage="$temporary/image"
app_name="macOS Computer Use"
bundle="$stage/$app_name.app"
executables="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"
mkdir -p "$executables" "$resources"
install -m 755 "$native/bin/cua-host" "$native/bin/cua-runtime" "$executables/"
install -m 644 "$native/LICENSE" "$resources/LICENSE"
install -m 644 "$native/manifest.json" "$resources/native-manifest.json"
plist="$bundle/Contents/Info.plist"
install -m 644 "$root/packaging/macos/Info.plist" "$plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$version" "$plist"
/usr/bin/plutil -insert CFBundleVersion -string "$version" "$plist"
/usr/bin/plutil -lint "$plist"

for architecture in arm64 x86_64; do
  xcrun --sdk macosx swiftc -O -parse-as-library -target "$architecture-apple-macosx13.0" \
    "$root/packaging/macos/Setup.swift" -o "$temporary/cua-setup-$architecture"
done
xcrun lipo -create "$temporary/cua-setup-arm64" "$temporary/cua-setup-x86_64" -output "$executables/cua-setup"
setup_architectures=$(xcrun lipo -archs "$executables/cua-setup")
case "$setup_architectures" in
  "arm64 x86_64"|"x86_64 arm64") ;;
  *)
    printf '%s\n' "Unexpected setup architectures: $setup_architectures" >&2
    exit 1 ;;
esac
codesign --force --sign - --timestamp=none "$bundle"
codesign --verify --deep --strict --all-architectures "$bundle"

ln -s /Applications "$stage/Applications"
hdiutil create -srcfolder "$stage" -volname "$app_name" -fs HFS+ -format UDZO "$temporary/$image_name"
hdiutil verify "$temporary/$image_name"
(
  cd "$temporary"
  shasum -a 256 "$image_name" > "$image_name.sha256"
)
mv "$temporary/$image_name" "$temporary/$image_name.sha256" "$output/"
printf '%s\n' "$image"
