#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$ROOT_DIR/third_party_patches/mlx-audio"
SOURCE_HELPER="$PATCH_DIR/qwenvoice_speed_patch.py"
BACKEND_HELPER="$ROOT_DIR/Sources/Resources/backend/mlx_audio_qwen_speed_patch.py"

if [[ ! -f "$SOURCE_HELPER" ]]; then
  echo "Missing helper source: $SOURCE_HELPER" >&2
  exit 1
fi

mkdir -p "$(dirname "$BACKEND_HELPER")"
if cmp -s "$SOURCE_HELPER" "$BACKEND_HELPER"; then
  echo "Backend helper already in sync: $BACKEND_HELPER"
else
  cp "$SOURCE_HELPER" "$BACKEND_HELPER"
  echo "Synced backend helper: $BACKEND_HELPER"
fi
