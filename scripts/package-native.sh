#!/bin/sh
# Build a relocatable, compiler-free end-user archive. Never publishes or installs it.
set -eu

package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_output=${1:-"$package_root/.artifacts/native-dist"}
mkdir -p "$package_output"
package_output=$(CDPATH= cd -- "$package_output" && pwd)
package_version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$package_root/crates/useui-host/Cargo.toml")
package_name="useui-native-$package_version-macos-universal"
package_archive="$package_output/$package_name.tar.gz"
if [ -e "$package_archive" ]; then
  printf '%s\n' "Archive already exists; use a new output directory: $package_archive" >&2
  exit 1
fi
package_temporary=$(mktemp -d "$package_output/.native-package.XXXXXX")
trap 'rm -rf -- "$package_temporary"' EXIT HUP INT TERM
package_stage="$package_temporary/$package_name"
package_build="$package_root/.artifacts/native-build"
mkdir -p "$package_stage/bin" "$package_build"
export MACOSX_DEPLOYMENT_TARGET=13.0

for package_arch in arm64 x86_64; do
  case "$package_arch" in
    arm64) package_rust_target=aarch64-apple-darwin ;;
    x86_64) package_rust_target=x86_64-apple-darwin ;;
  esac
  # Older Rust/LLVM strip can misalign proc-macro LINKEDIT on macOS 27.
  # These compiler plugins are build-only; do not strip them before rustc loads them.
  cargo build --locked --manifest-path "$package_root/Cargo.toml" --release -p useui-host --target "$package_rust_target" \
    --config 'profile.release.build-override.strip="none"'
  swift build --package-path "$package_root" --scratch-path "$package_build/swift-$package_arch" \
    --triple "$package_arch-apple-macosx13.0" -c release --product useui-runtime
  package_swift_bin=$(swift build --package-path "$package_root" --scratch-path "$package_build/swift-$package_arch" \
    --triple "$package_arch-apple-macosx13.0" -c release --show-bin-path)
  install -m 755 "$package_root/target/$package_rust_target/release/useui" "$package_build/useui-$package_arch"
  install -m 755 "$package_swift_bin/useui-runtime" "$package_build/useui-runtime-$package_arch"
done
for package_binary in useui useui-runtime; do
  xcrun lipo -create "$package_build/$package_binary-arm64" "$package_build/$package_binary-x86_64" -output "$package_stage/bin/$package_binary"
  chmod 755 "$package_stage/bin/$package_binary"
  codesign --force --sign - --timestamp=none --identifier "com.johnoba.useui.$package_binary" "$package_stage/bin/$package_binary"
  codesign --verify --strict --all-architectures "$package_stage/bin/$package_binary"
done
install -m 644 "$package_root/LICENSE" "$package_stage/LICENSE"
install -m 644 "$package_root/docs/native-delivery.md" "$package_stage/README.md"
cat > "$package_stage/mcp-config.example.json" <<'JSON'
{
  "mcpServers": {
    "useui": {
      "command": "/absolute/path/with spaces/useui-native/bin/useui",
      "args": []
    }
  }
}
JSON
python3 "$package_root/scripts/native-package-info.py" "$package_stage" "$package_root" > "$package_stage/manifest.json"
(
  cd "$package_stage"
  shasum -a 256 bin/useui bin/useui-runtime LICENSE README.md mcp-config.example.json manifest.json > SHA256SUMS
)
COPYFILE_DISABLE=1 tar -C "$package_temporary" -czf "$package_temporary/archive.tar.gz" "$package_name"
mv "$package_temporary/archive.tar.gz" "$package_archive"
(
  cd "$package_output"
  shasum -a 256 "$package_name.tar.gz" > "$package_name.tar.gz.sha256"
)
printf '%s\n' "$package_archive"
