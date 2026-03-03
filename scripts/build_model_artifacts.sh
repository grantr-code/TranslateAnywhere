#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
OUT_DIR="${1:-$ROOT/dist/model-artifacts}"
VENV_DIR="$SCRIPT_DIR/.venv-artifacts"

ARTIFACT_BASE_URL="${MODEL_ARTIFACT_BASE_URL:-https://huggingface.co/grantr-code/translateanywhere-models/resolve/main}"

echo "Building runtime model artifacts into: $OUT_DIR"
mkdir -p "$OUT_DIR"

PYTHON_BIN="python3"
if command -v python3.12 &>/dev/null; then
  PYTHON_BIN="python3.12"
fi

if [ ! -d "$VENV_DIR" ]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install --upgrade pip -q
pip install "ctranslate2==3.24.0" "transformers==4.36.0" sentencepiece "torch==2.2.2" "numpy<2" huggingface_hub -q

build_opus_pair() {
  local model_a="$1"
  local model_b="$2"
  local out_subdir="$3"

  local target_dir="$OUT_DIR/$out_subdir"
  mkdir -p "$target_dir"

  if [ ! -d "$target_dir/$model_a" ]; then
    echo "Converting $model_a"
    ct2-transformers-converter --model "Helsinki-NLP/$model_a" --output_dir "$target_dir/$model_a" --quantization int8
  fi

  if [ ! -d "$target_dir/$model_b" ]; then
    echo "Converting $model_b"
    ct2-transformers-converter --model "Helsinki-NLP/$model_b" --output_dir "$target_dir/$model_b" --quantization int8
  fi

  cat > "$target_dir/model_profile.json" <<JSON
{
  "model_id": "$out_subdir",
  "model_family": "opus",
  "version": "1"
}
JSON
}

build_nllb() {
  local repo="$1"
  local out_subdir="$2"

  local target_dir="$OUT_DIR/$out_subdir"
  mkdir -p "$target_dir"

  python - <<PY
from huggingface_hub import hf_hub_download
from pathlib import Path
import shutil

target = Path(r"$target_dir")
repo = "$repo"

for name in ["model.bin", "shared_vocabulary.json", "config.json", "generation_config.json"]:
    src = hf_hub_download(repo_id=repo, filename=name)
    shutil.copy2(src, target / name)

spm_src = hf_hub_download(repo_id="facebook/nllb-200-distilled-600M", filename="sentencepiece.bpe.model")
shutil.copy2(spm_src, target / "sentencepiece.bpe.model")
PY

  cat > "$target_dir/model_profile.json" <<JSON
{
  "model_id": "$out_subdir",
  "model_family": "nllb",
  "version": "1"
}
JSON
}

build_opus_pair "opus-mt-en-ru" "opus-mt-ru-en" "opus_base"
build_opus_pair "opus-mt-en-zle" "opus-mt-zle-en" "opus_big"
build_nllb "OpenNMT/nllb-200-distilled-1.3B-ct2-int8" "nllb_1_3b"
build_nllb "OpenNMT/nllb-200-3.3B-ct2-int8" "nllb_3_3b"

python - <<PY
import hashlib
import json
from pathlib import Path

base_url = "$ARTIFACT_BASE_URL".rstrip("/")
out = Path(r"$OUT_DIR")

family = {
    "opus_base": "opus",
    "opus_big": "opus",
    "nllb_1_3b": "nllb",
    "nllb_3_3b": "nllb",
}

manifest = {
    "schema_version": 1,
    "models": [],
}

for model_id in ["opus_base", "opus_big", "nllb_1_3b", "nllb_3_3b"]:
    model_dir = out / model_id
    files = []
    for path in sorted([p for p in model_dir.rglob("*") if p.is_file()]):
        rel = str(path.relative_to(model_dir)).replace("\\", "/")
        h = hashlib.sha256()
        with path.open("rb") as f:
            while True:
                chunk = f.read(1024 * 1024)
                if not chunk:
                    break
                h.update(chunk)
        files.append({
            "path": rel,
            "url": f"{base_url}/{model_id}/{rel}",
            "sha256": h.hexdigest(),
            "size_bytes": path.stat().st_size,
        })

    manifest["models"].append({
        "id": model_id,
        "family": family[model_id],
        "version": "1",
        "files": files,
    })

manifest_path = out / "manifest-v1.json"
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"Wrote manifest: {manifest_path}")
PY

deactivate

echo "Done. Artifacts + manifest are in: $OUT_DIR"
echo "Next: upload each model directory + manifest-v1.json to your Hugging Face artifact repo."
