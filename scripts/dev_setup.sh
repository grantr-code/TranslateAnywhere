#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

echo "=============================="
echo " TranslateAnywhere Dev Setup"
echo "=============================="

# 1. Check/install brew deps
echo ""
echo "[1/6] Checking dependencies..."
for cmd in cmake python3 rustc cargo; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "  Installing $cmd..."
        case "$cmd" in
            cmake) brew install cmake ;;
            python3) brew install python3 ;;
            rustc|cargo) curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y ;;
        esac
    else
        echo "  ✓ $cmd found"
    fi
done

# Ensure Rust targets
rustup target add aarch64-apple-darwin x86_64-apple-darwin 2>/dev/null || true

# 2. Git submodules
echo ""
echo "[2/6] Initializing git submodules..."
cd "$ROOT"
git submodule update --init --recursive 2>/dev/null || {
    echo "  Setting up ThirdParty sources..."
    mkdir -p ThirdParty
    if [ ! -d "ThirdParty/CTranslate2/.git" ]; then
        git clone --depth 1 https://github.com/OpenNMT/CTranslate2.git ThirdParty/CTranslate2
    fi
    if [ ! -d "ThirdParty/sentencepiece/.git" ]; then
        git clone --depth 1 https://github.com/google/sentencepiece.git ThirdParty/sentencepiece
    fi
}

# 3. Build third-party
echo ""
echo "[3/6] Building third-party libraries (universal2)..."
"$SCRIPT_DIR/build_thirdparty_universal.sh"

# 4. Fetch and convert models
echo ""
echo "[4/6] Fetching and converting translation models..."
"$SCRIPT_DIR/fetch_and_convert_models.sh"

# 5. Build core
echo ""
echo "[5/6] Building Rust core library (universal2)..."
"$SCRIPT_DIR/build_core_universal.sh"

# 6. Build app
echo ""
echo "[6/6] Building TranslateAnywhere app (Debug)..."
xcodebuild -project "$ROOT/App/TranslateAnywhere.xcodeproj" \
    -scheme TranslateAnywhere \
    -configuration Debug \
    build 2>&1 | tail -5

echo ""
echo "=============================="
echo " Setup complete!"
echo "=============================="
echo ""
echo "To run: open App/TranslateAnywhere.xcodeproj and click Run"
echo "To package: ./scripts/package.sh"
