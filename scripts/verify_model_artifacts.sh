#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ARTIFACT_DIR="${1:-$ROOT/dist/model-artifacts}"
MANIFEST="$ARTIFACT_DIR/manifest-v1.json"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest not found at $MANIFEST"
  exit 1
fi

python3 - <<PY
import hashlib
import json
from pathlib import Path

manifest_path = Path(r"$MANIFEST")
artifact_dir = Path(r"$ARTIFACT_DIR")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

if manifest.get("schema_version") != 1:
    raise SystemExit("Unsupported schema_version")

for model in manifest.get("models", []):
    model_id = model["id"]
    model_dir = artifact_dir / model_id
    if not model_dir.exists():
        raise SystemExit(f"Missing model directory: {model_dir}")

    for file_entry in model.get("files", []):
        rel = file_entry["path"]
        expected_sha = file_entry.get("sha256", "")
        p = model_dir / rel
        if not p.exists():
            raise SystemExit(f"Missing file: {p}")

        if expected_sha:
            h = hashlib.sha256()
            with p.open("rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    h.update(chunk)
            actual = h.hexdigest()
            if actual.lower() != expected_sha.lower():
                raise SystemExit(f"Checksum mismatch for {p}: expected {expected_sha}, got {actual}")

print("Artifact verification succeeded")
PY
