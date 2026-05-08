#!/usr/bin/env bash
# Download QA-only ASR and forced-alignment models used by the autonomous
# audio review lane. This populates the cache layout expected by
# Qwen3AudioReviewModels; it does not add any app runtime dependency.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
MANIFEST_PATH="$PROJECT_DIR/tests/audio-review-models.json"
MODELS_ROOT="${QWENVOICE_AUDIO_REVIEW_MODELS_ROOT:-$HOME/Library/Application Support/QwenVoice/audio-review-models}"

python3 - "$MANIFEST_PATH" "$MODELS_ROOT" <<'PY'
import json
import sys
from pathlib import Path

try:
    from huggingface_hub import snapshot_download
except ImportError as exc:
    raise SystemExit(
        "Missing huggingface_hub. Install with:\n"
        "  python3 -m pip install --user -r scripts/requirements-audio-review-bootstrap.txt"
    ) from exc

manifest_path = Path(sys.argv[1])
models_root = Path(sys.argv[2]).expanduser()
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
cache_root = models_root / "mlx-audio"
cache_root.mkdir(parents=True, exist_ok=True)

for model in manifest["models"]:
    repo_id = model["repoID"]
    revision = model["revision"]
    local_dir = cache_root / repo_id.replace("/", "_")
    local_dir.mkdir(parents=True, exist_ok=True)
    print(f"==> Downloading {repo_id}@{revision}")
    print(f"    -> {local_dir}")
    snapshot_download(
        repo_id=repo_id,
        revision=revision,
        local_dir=str(local_dir),
        allow_patterns=["*.json", "*.safetensors", "*.txt", "*.wav"],
    )

print(f"==> Audio review models ready at {models_root}")
PY
