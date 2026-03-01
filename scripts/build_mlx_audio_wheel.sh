#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$ROOT_DIR/third_party_patches/mlx-audio"
VENDOR_DIR="$ROOT_DIR/Sources/Resources/vendor"
SOURCE_HELPER="$PATCH_DIR/qwenvoice_speed_patch.py"
PATCH_NOTE="$PATCH_DIR/qwenvoice-speed.patch"
BASE_VERSION="0.3.1"
TARGET_VERSION="0.3.1.post1"

if [[ ! -f "$SOURCE_HELPER" ]]; then
  echo "Missing helper source: $SOURCE_HELPER" >&2
  exit 1
fi

if [[ ! -f "$PATCH_NOTE" ]]; then
  echo "Missing patch note: $PATCH_NOTE" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DOWNLOAD_DIR="$TMP_DIR/download"
UNPACK_DIR="$TMP_DIR/unpacked"
mkdir -p "$DOWNLOAD_DIR" "$UNPACK_DIR" "$VENDOR_DIR"

python3 -m pip download \
  --disable-pip-version-check \
  --no-deps \
  --only-binary=:all: \
  "mlx-audio==${BASE_VERSION}" \
  -d "$DOWNLOAD_DIR" >/dev/null

SOURCE_WHEEL="$(find "$DOWNLOAD_DIR" -maxdepth 1 -name 'mlx_audio-0.3.1-*.whl' | head -n 1)"
if [[ -z "$SOURCE_WHEEL" ]]; then
  echo "Could not download upstream mlx-audio wheel" >&2
  exit 1
fi

unzip -q "$SOURCE_WHEEL" -d "$UNPACK_DIR"

cp "$SOURCE_HELPER" "$UNPACK_DIR/mlx_audio/qwenvoice_speed_patch.py"

VERSION_FILE="$UNPACK_DIR/mlx_audio/version.py"
if [[ -f "$VERSION_FILE" ]]; then
  python3 - "$VERSION_FILE" "$TARGET_VERSION" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
target = sys.argv[2]
text = path.read_text(encoding="utf-8")
path.write_text(f'__version__ = "{target}"\n', encoding="utf-8")
PY
fi

OLD_DIST_INFO="$UNPACK_DIR/mlx_audio-${BASE_VERSION}.dist-info"
NEW_DIST_INFO="$UNPACK_DIR/mlx_audio-${TARGET_VERSION}.dist-info"
if [[ -d "$OLD_DIST_INFO" ]]; then
  mv "$OLD_DIST_INFO" "$NEW_DIST_INFO"
else
  echo "Could not find dist-info directory for upstream wheel" >&2
  exit 1
fi

METADATA_FILE="$NEW_DIST_INFO/METADATA"
python3 - "$METADATA_FILE" "$BASE_VERSION" "$TARGET_VERSION" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
base = sys.argv[2]
target = sys.argv[3]
text = path.read_text(encoding="utf-8")
text = text.replace(f"Version: {base}", f"Version: {target}")
path.write_text(text, encoding="utf-8")
PY

OUTPUT_WHEEL="$VENDOR_DIR/mlx_audio-${TARGET_VERSION}-py3-none-any.whl"

python3 - "$UNPACK_DIR" "$OUTPUT_WHEEL" "$TARGET_VERSION" <<'PY'
import base64
import csv
import hashlib
import io
import pathlib
import sys
import zipfile

unpack_dir = pathlib.Path(sys.argv[1])
output_wheel = pathlib.Path(sys.argv[2])
version = sys.argv[3]
dist_info = f"mlx_audio-{version}.dist-info"
record_path = unpack_dir / dist_info / "RECORD"

if record_path.exists():
    record_path.unlink()

rows = []
with zipfile.ZipFile(output_wheel, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in sorted(unpack_dir.rglob("*")):
        if path.is_dir():
            continue
        rel_path = path.relative_to(unpack_dir).as_posix()
        data = path.read_bytes()
        zf.writestr(rel_path, data)
        digest = hashlib.sha256(data).digest()
        encoded = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
        rows.append((rel_path, f"sha256={encoded}", str(len(data))))

    rows.append((f"{dist_info}/RECORD", "", ""))
    record_buffer = io.StringIO()
    writer = csv.writer(record_buffer, lineterminator="\n")
    writer.writerows(rows)
    zf.writestr(f"{dist_info}/RECORD", record_buffer.getvalue().encode("utf-8"))
PY

rm -f "$VENDOR_DIR/mlx_audio-${BASE_VERSION}-py3-none-any.whl"
echo "Built $OUTPUT_WHEEL"
