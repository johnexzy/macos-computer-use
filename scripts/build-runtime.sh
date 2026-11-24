#!/bin/sh
set -eu

runtime_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_install="$runtime_root/.artifacts/runtime-install"
cargo build --locked --manifest-path "$runtime_root/Cargo.toml" --release -p useui-host
swift build --package-path "$runtime_root" -c release --product useui-runtime
runtime_swift_bin=$(swift build --package-path "$runtime_root" -c release --show-bin-path)
mkdir -p "$runtime_install"
install -m 755 "$runtime_root/target/release/useui" "$runtime_install/useui"
install -m 755 "$runtime_swift_bin/useui-runtime" "$runtime_install/useui-runtime"
codesign --force --sign - "$runtime_install/useui-runtime"
printf '%s\n' "$runtime_install/useui"
