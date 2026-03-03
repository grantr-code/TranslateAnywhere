#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CORE_DIR="$ROOT/Core/translator_core"

echo "Building Rust staticlib..."

# Ensure targets (skip if rustup not available, e.g. Homebrew Rust)
if command -v rustup &>/dev/null; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin
fi

mkdir -p "$ROOT/build/lib"

# Try building for both architectures; fall back to host-only if cross-compile fails
CAN_ARM64=true
CAN_X86=true

echo "  Building x86_64..."
if ! cargo build --manifest-path "$CORE_DIR/Cargo.toml" --release --target x86_64-apple-darwin 2>/dev/null; then
    echo "  x86_64 build failed"
    CAN_X86=false
fi

echo "  Building arm64..."
if ! cargo build --manifest-path "$CORE_DIR/Cargo.toml" --release --target aarch64-apple-darwin 2>/dev/null; then
    echo "  arm64 build failed (cross-compile target likely not installed)"
    CAN_ARM64=false
fi

ARM64_LIB="$CORE_DIR/target/aarch64-apple-darwin/release/libtranslator_core.a"
X86_LIB="$CORE_DIR/target/x86_64-apple-darwin/release/libtranslator_core.a"
OUTPUT="$ROOT/build/lib/libtranslator_core.a"

if [ "$CAN_ARM64" = true ] && [ "$CAN_X86" = true ]; then
    lipo -create "$ARM64_LIB" "$X86_LIB" -output "$OUTPUT"
    echo "  Created universal2 (arm64 + x86_64)"
elif [ "$CAN_X86" = true ]; then
    cp "$X86_LIB" "$OUTPUT"
    echo "  Created x86_64-only (arm64 target not available)"
elif [ "$CAN_ARM64" = true ]; then
    cp "$ARM64_LIB" "$OUTPUT"
    echo "  Created arm64-only (x86_64 target not available)"
else
    echo "ERROR: No architectures could be built"
    exit 1
fi

echo "=== Rust staticlib ==="
lipo -info "$OUTPUT"
echo "Done."
