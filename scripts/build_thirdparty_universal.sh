#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

THIRDPARTY="$ROOT/ThirdParty"
SP_SRC="$THIRDPARTY/sentencepiece"
CT2_SRC="$THIRDPARTY/CTranslate2"

# Final merged output
OUTPUT_DIR="$THIRDPARTY/build"
OUTPUT_LIB="$OUTPUT_DIR/lib"
OUTPUT_INC="$OUTPUT_DIR/include"

# Per-arch staging
SP_BUILD_ARM64="$THIRDPARTY/_build/sentencepiece-arm64"
SP_BUILD_X86="$THIRDPARTY/_build/sentencepiece-x86_64"
SP_INSTALL_ARM64="$THIRDPARTY/_install/sentencepiece-arm64"
SP_INSTALL_X86="$THIRDPARTY/_install/sentencepiece-x86_64"

CT2_BUILD_ARM64="$THIRDPARTY/_build/ctranslate2-arm64"
CT2_BUILD_X86="$THIRDPARTY/_build/ctranslate2-x86_64"
CT2_INSTALL_ARM64="$THIRDPARTY/_install/ctranslate2-arm64"
CT2_INSTALL_X86="$THIRDPARTY/_install/ctranslate2-x86_64"

NPROC=$(sysctl -n hw.logicalcpu)

# Skip if already built
if [ -f "$OUTPUT_LIB/libctranslate2.a" ] && [ -f "$OUTPUT_LIB/libsentencepiece.a" ]; then
    echo "Third-party libraries already built. Skipping."
    echo "  To rebuild, remove: $OUTPUT_DIR"
    lipo -info "$OUTPUT_LIB/libsentencepiece.a"
    lipo -info "$OUTPUT_LIB/libctranslate2.a"
    exit 0
fi

# Verify sources exist
if [ ! -d "$SP_SRC" ]; then
    echo "ERROR: SentencePiece source not found at $SP_SRC"
    echo "Run: git clone --depth 1 https://github.com/google/sentencepiece.git $SP_SRC"
    exit 1
fi
if [ ! -d "$CT2_SRC" ]; then
    echo "ERROR: CTranslate2 source not found at $CT2_SRC"
    echo "Run: git clone --depth 1 https://github.com/OpenNMT/CTranslate2.git $CT2_SRC"
    exit 1
fi

echo "============================================"
echo " Building Third-Party Libraries (universal2)"
echo "============================================"

# ─── SentencePiece ────────────────────────────────────────────────

build_sentencepiece() {
    local ARCH="$1"
    local BUILD_DIR="$2"
    local INSTALL_DIR="$3"

    echo ""
    echo "--- SentencePiece ($ARCH) ---"

    # Determine CMake OSX_ARCHITECTURES
    local CMAKE_ARCH
    if [ "$ARCH" = "arm64" ]; then
        CMAKE_ARCH="arm64"
    else
        CMAKE_ARCH="x86_64"
    fi

    mkdir -p "$BUILD_DIR"
    cmake -S "$SP_SRC" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="15.0" \
        -DSPM_BUILD_TEST=OFF \
        -DSPM_ENABLE_SHARED=OFF \
        -DSPM_ENABLE_TCMALLOC=OFF \
        -DSPM_USE_BUILTIN_PROTOBUF=ON \
        -DBUILD_SHARED_LIBS=OFF

    cmake --build "$BUILD_DIR" -j "$NPROC"
    cmake --install "$BUILD_DIR"

    echo "  SentencePiece ($ARCH) installed to $INSTALL_DIR"
}

build_sentencepiece "arm64" "$SP_BUILD_ARM64" "$SP_INSTALL_ARM64"
build_sentencepiece "x86_64" "$SP_BUILD_X86" "$SP_INSTALL_X86"

# Merge SentencePiece into universal
echo ""
echo "--- Merging SentencePiece (universal2) ---"
mkdir -p "$OUTPUT_LIB" "$OUTPUT_INC"

# Copy headers from arm64 (identical across arches)
cp -R "$SP_INSTALL_ARM64/include/"* "$OUTPUT_INC/" 2>/dev/null || true

# Lipo merge each static library produced by SentencePiece
for lib in libsentencepiece.a libsentencepiece_train.a; do
    ARM64_LIB="$SP_INSTALL_ARM64/lib/$lib"
    X86_LIB="$SP_INSTALL_X86/lib/$lib"
    if [ -f "$ARM64_LIB" ] && [ -f "$X86_LIB" ]; then
        lipo -create "$ARM64_LIB" "$X86_LIB" -output "$OUTPUT_LIB/$lib"
        echo "  Created universal: $lib"
        lipo -info "$OUTPUT_LIB/$lib"
    elif [ -f "$ARM64_LIB" ]; then
        cp "$ARM64_LIB" "$OUTPUT_LIB/$lib"
        echo "  Copied arm64 only: $lib"
    fi
done

# Also merge protobuf-lite if SentencePiece built it
for lib in libprotobuf-lite.a libprotobuf.a; do
    ARM64_LIB="$SP_INSTALL_ARM64/lib/$lib"
    X86_LIB="$SP_INSTALL_X86/lib/$lib"
    if [ -f "$ARM64_LIB" ] && [ -f "$X86_LIB" ]; then
        lipo -create "$ARM64_LIB" "$X86_LIB" -output "$OUTPUT_LIB/$lib"
        echo "  Created universal: $lib"
    elif [ -f "$ARM64_LIB" ]; then
        cp "$ARM64_LIB" "$OUTPUT_LIB/$lib"
    fi
done

# ─── CTranslate2 ─────────────────────────────────────────────────

build_ctranslate2() {
    local ARCH="$1"
    local BUILD_DIR="$2"
    local INSTALL_DIR="$3"
    local SP_INSTALL="$4"

    echo ""
    echo "--- CTranslate2 ($ARCH) ---"

    local CMAKE_ARCH
    if [ "$ARCH" = "arm64" ]; then
        CMAKE_ARCH="arm64"
    else
        CMAKE_ARCH="x86_64"
    fi

    mkdir -p "$BUILD_DIR"
    cmake -S "$CT2_SRC" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="15.0" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DWITH_MKL=OFF \
        -DWITH_OPENBLAS=OFF \
        -DWITH_ACCELERATE=ON \
        -DWITH_CUDA=OFF \
        -DWITH_CUDNN=OFF \
        -DWITH_DNNL=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DOPENMP_RUNTIME=NONE \
        -DBUILD_CLI=OFF \
        -DBUILD_TESTS=OFF \
        -DWITH_TESTS=OFF \
        -DCMAKE_PREFIX_PATH="$SP_INSTALL" \
        -DSentencePiece_DIR="$SP_INSTALL" \
        -DCMAKE_FIND_ROOT_PATH="$SP_INSTALL" \
        -Dsentencepiece_INCLUDE_DIR="$SP_INSTALL/include" \
        -Dsentencepiece_STATIC_LIB="$SP_INSTALL/lib/libsentencepiece.a"

    cmake --build "$BUILD_DIR" -j "$NPROC"
    cmake --install "$BUILD_DIR"

    echo "  CTranslate2 ($ARCH) installed to $INSTALL_DIR"
}

build_ctranslate2 "arm64" "$CT2_BUILD_ARM64" "$CT2_INSTALL_ARM64" "$SP_INSTALL_ARM64"
build_ctranslate2 "x86_64" "$CT2_BUILD_X86" "$CT2_INSTALL_X86" "$SP_INSTALL_X86"

# Merge CTranslate2 into universal
echo ""
echo "--- Merging CTranslate2 (universal2) ---"

# Copy headers from arm64 (identical across arches)
if [ -d "$CT2_INSTALL_ARM64/include" ]; then
    cp -R "$CT2_INSTALL_ARM64/include/"* "$OUTPUT_INC/" 2>/dev/null || true
fi

# Lipo merge CTranslate2 static library
for lib in libctranslate2.a; do
    ARM64_LIB="$CT2_INSTALL_ARM64/lib/$lib"
    X86_LIB="$CT2_INSTALL_X86/lib/$lib"

    # CTranslate2 may install to lib64 on some systems
    if [ ! -f "$ARM64_LIB" ] && [ -f "$CT2_INSTALL_ARM64/lib64/$lib" ]; then
        ARM64_LIB="$CT2_INSTALL_ARM64/lib64/$lib"
    fi
    if [ ! -f "$X86_LIB" ] && [ -f "$CT2_INSTALL_X86/lib64/$lib" ]; then
        X86_LIB="$CT2_INSTALL_X86/lib64/$lib"
    fi

    if [ -f "$ARM64_LIB" ] && [ -f "$X86_LIB" ]; then
        lipo -create "$ARM64_LIB" "$X86_LIB" -output "$OUTPUT_LIB/$lib"
        echo "  Created universal: $lib"
        lipo -info "$OUTPUT_LIB/$lib"
    elif [ -f "$ARM64_LIB" ]; then
        cp "$ARM64_LIB" "$OUTPUT_LIB/$lib"
        echo "  WARNING: Only arm64 lib found for $lib"
    else
        echo "  ERROR: Could not find $lib for either architecture"
        echo "  Searched: $CT2_INSTALL_ARM64/lib/ and $CT2_INSTALL_ARM64/lib64/"
        exit 1
    fi
done

# Also handle any additional CT2 support libraries (cpu_features, etc.)
for suffix in arm64 x86_64; do
    if [ "$suffix" = "arm64" ]; then
        INSTALL_DIR="$CT2_INSTALL_ARM64"
    else
        INSTALL_DIR="$CT2_INSTALL_X86"
    fi

    for lib_path in "$INSTALL_DIR/lib/"*.a "$INSTALL_DIR/lib64/"*.a; do
        if [ -f "$lib_path" ]; then
            lib_name=$(basename "$lib_path")
            # Skip already processed libs
            if [ "$lib_name" = "libctranslate2.a" ]; then
                continue
            fi
            if [ ! -f "$OUTPUT_LIB/$lib_name" ]; then
                # Check if the other arch has it too
                if [ "$suffix" = "arm64" ]; then
                    OTHER="$CT2_INSTALL_X86"
                else
                    OTHER="$CT2_INSTALL_ARM64"
                fi
                OTHER_LIB="$OTHER/lib/$lib_name"
                if [ ! -f "$OTHER_LIB" ]; then
                    OTHER_LIB="$OTHER/lib64/$lib_name"
                fi
                if [ -f "$OTHER_LIB" ]; then
                    lipo -create "$lib_path" "$OTHER_LIB" -output "$OUTPUT_LIB/$lib_name"
                    echo "  Created universal: $lib_name"
                else
                    cp "$lib_path" "$OUTPUT_LIB/$lib_name"
                    echo "  Copied single-arch: $lib_name ($suffix)"
                fi
            fi
        fi
    done
done

# ─── Verification ─────────────────────────────────────────────────

echo ""
echo "============================================"
echo " Verification"
echo "============================================"
echo ""
echo "Libraries in $OUTPUT_LIB:"
ls -lh "$OUTPUT_LIB/"*.a 2>/dev/null || echo "  (none found - ERROR)"
echo ""

VERIFY_OK=true
for lib in libsentencepiece.a libctranslate2.a; do
    if [ -f "$OUTPUT_LIB/$lib" ]; then
        echo "$lib:"
        lipo -info "$OUTPUT_LIB/$lib"
        # Check both architectures present
        ARCHES=$(lipo -info "$OUTPUT_LIB/$lib" 2>/dev/null || true)
        if echo "$ARCHES" | grep -q "arm64" && echo "$ARCHES" | grep -q "x86_64"; then
            echo "  OK - universal2 (arm64 + x86_64)"
        else
            echo "  WARNING - not universal2: $ARCHES"
        fi
    else
        echo "ERROR: $lib not found!"
        VERIFY_OK=false
    fi
done

echo ""
echo "Headers in $OUTPUT_INC:"
ls "$OUTPUT_INC/" 2>/dev/null || echo "  (none found - ERROR)"

if [ "$VERIFY_OK" = false ]; then
    echo ""
    echo "ERROR: Some libraries are missing. Build failed."
    exit 1
fi

echo ""
echo "Third-party build complete."
