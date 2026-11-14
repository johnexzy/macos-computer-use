#!/bin/sh
set -eu

runtime_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_install="$runtime_root/.artifacts/runtime-install"
cargo build --locked --manifest-path "$runtime_root/Cargo.toml" --release -p cua-host
swift build --package-path "$runtime_root" -c release --product cua-runtime
runtime_swift_bin=$(swift build --package-path "$runtime_root" -c release --show-bin-path)
mkdir -p "$runtime_install"
install -m 755 "$runtime_root/target/release/cua-host" "$runtime_install/cua-host"
install -m 755 "$runtime_swift_bin/cua-runtime" "$runtime_install/cua-runtime"
codesign --force --sign - "$runtime_install/cua-runtime"
printf '%s\n' "$runtime_install/cua-host"
