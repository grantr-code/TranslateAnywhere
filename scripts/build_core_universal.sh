#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CORE_DIR="$ROOT/Core/translator_core"

echo "Building Rust staticlib (universal2)..."

# Ensure targets (skip if rustup not available, e.g. Homebrew Rust)
if command -v rustup &>/dev/null; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin
else
    echo "  (rustup not found — assuming targets already available via Homebrew Rust)"
fi

# Build for arm64
echo "  Building arm64..."
cargo build --manifest-path "$CORE_DIR/Cargo.toml" --release --target aarch64-apple-darwin

# Build for x86_64
echo "  Building x86_64..."
cargo build --manifest-path "$CORE_DIR/Cargo.toml" --release --target x86_64-apple-darwin

# Lipo merge
mkdir -p "$ROOT/build/lib"
lipo -create \
    "$CORE_DIR/target/aarch64-apple-darwin/release/libtranslator_core.a" \
    "$CORE_DIR/target/x86_64-apple-darwin/release/libtranslator_core.a" \
    -output "$ROOT/build/lib/libtranslator_core.a"

echo "=== Rust staticlib ==="
lipo -info "$ROOT/build/lib/libtranslator_core.a"
echo "Done."
