#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
MODEL_DIR="$ROOT/models"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "Fetching and converting OPUS-MT models..."

# Create venv
if [ ! -d "$VENV_DIR" ]; then
    echo "  Creating Python venv..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install --upgrade pip -q
pip install ctranslate2 transformers sentencepiece -q

mkdir -p "$MODEL_DIR"

# Convert EN->RU model
if [ ! -d "$MODEL_DIR/opus-mt-en-ru" ]; then
    echo "  Converting Helsinki-NLP/opus-mt-en-ru (int8)..."
    ct2-transformers-converter \
        --model Helsinki-NLP/opus-mt-en-ru \
        --output_dir "$MODEL_DIR/opus-mt-en-ru" \
        --quantization int8
else
    echo "  ✓ opus-mt-en-ru already converted"
fi

# Convert RU->EN model
if [ ! -d "$MODEL_DIR/opus-mt-ru-en" ]; then
    echo "  Converting Helsinki-NLP/opus-mt-ru-en (int8)..."
    ct2-transformers-converter \
        --model Helsinki-NLP/opus-mt-ru-en \
        --output_dir "$MODEL_DIR/opus-mt-ru-en" \
        --quantization int8
else
    echo "  ✓ opus-mt-ru-en already converted"
fi

# Verify SentencePiece models are present
# OPUS-MT uses source.spm and target.spm naming
for dir in "$MODEL_DIR/opus-mt-en-ru" "$MODEL_DIR/opus-mt-ru-en"; do
    echo ""
    echo "  Contents of $(basename "$dir"):"
    ls -la "$dir/" 2>/dev/null || echo "    (directory not found)"

    # The converter should create these, but if not, try downloading
    if [ ! -f "$dir/source.spm" ] && [ -f "$dir/sentencepiece.bpe.model" ]; then
        echo "  Copying sentencepiece.bpe.model as source.spm..."
        cp "$dir/sentencepiece.bpe.model" "$dir/source.spm"
    fi
done

deactivate
echo ""
echo "Models ready in: $MODEL_DIR"
