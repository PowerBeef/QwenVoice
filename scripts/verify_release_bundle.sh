#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REQUIREMENTS_PATH="$PROJECT_DIR/Sources/Resources/requirements.txt"
APP_MIN_MACOS_VERSION="15.0"

fail() {
    echo "Error: $*" >&2
    exit 1
}

if [ $# -ne 1 ]; then
    fail "Usage: $0 /path/to/QwenVoice.app"
fi

APP_PATH="$1"
if [ ! -d "$APP_PATH" ]; then
    fail "App bundle not found: $APP_PATH"
fi

RESOURCES_DIR="$APP_PATH/Contents/Resources"
PYTHON_ROOT="$RESOURCES_DIR/python"
PYTHON_BIN="$PYTHON_ROOT/bin/python3"
FFMPEG_BIN="$RESOURCES_DIR/ffmpeg"
SERVER_SCRIPT="$RESOURCES_DIR/server.py"
if [ ! -f "$SERVER_SCRIPT" ] && [ -f "$RESOURCES_DIR/backend/server.py" ]; then
    SERVER_SCRIPT="$RESOURCES_DIR/backend/server.py"
fi
MANIFEST_PATH="$PYTHON_ROOT/.qwenvoice-runtime-manifest.json"

export PYTHONDONTWRITEBYTECODE=1

echo "=== QwenVoice: Verify Release Bundle ==="
echo ""

echo "[1/7] Checking required files..."
[ -x "$PYTHON_BIN" ] || fail "Bundled Python missing: $PYTHON_BIN"
[ -x "$FFMPEG_BIN" ] || fail "Bundled ffmpeg missing: $FFMPEG_BIN"
[ -f "$SERVER_SCRIPT" ] || fail "Bundled backend missing: $SERVER_SCRIPT"
[ -f "$MANIFEST_PATH" ] || fail "Bundled runtime manifest missing: $MANIFEST_PATH"
if find "$RESOURCES_DIR" -name "*.whl" -print -quit | grep -q .; then
    fail "Vendored wheel files should not be packaged into the app bundle"
fi
if find "$RESOURCES_DIR" \( -name "*.pyc" -o -type d -name "__pycache__" \) -print -quit | grep -q .; then
    fail "Compiled Python artifacts should not be packaged into the app bundle"
fi
echo "[1/7] Required files OK"
echo ""

echo "[2/7] Verifying bundled Python executable..."
"$PYTHON_BIN" --version >/dev/null
echo "[2/7] Bundled Python runs"
echo ""

echo "[3/7] Verifying bundled Python imports..."
"$PYTHON_BIN" -c "import mlx; import mlx.core as mx; import mlx_audio; import transformers; import numpy; import soundfile; import huggingface_hub; x = mx.array([1.0], dtype=mx.float32); mx.eval(x)"
echo "[3/7] Core imports OK"
echo ""

echo "[4/7] Verifying bundled mlx-audio helper..."
"$PYTHON_BIN" -c "import mlx_audio.qwenvoice_speed_patch as p; import sys; sys.exit(0 if hasattr(p, 'try_enable_speech_tokenizer_encoder') else 1)"
echo "[4/7] Helper is present"
echo ""

echo "[5/7] Verifying bundled ffmpeg..."
"$FFMPEG_BIN" -version >/dev/null
echo "[5/7] Bundled ffmpeg runs"
echo ""

echo "[6/7] Verifying runtime manifest and native-library linkage..."
EXPECTED_REQUIREMENTS_HASH="$(shasum -a 256 "$REQUIREMENTS_PATH" | awk '{print $1}')"
"$PYTHON_BIN" - "$MANIFEST_PATH" "$EXPECTED_REQUIREMENTS_HASH" "$APP_MIN_MACOS_VERSION" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
expected_hash = sys.argv[2]
supported_macos = sys.argv[3]
data = json.loads(manifest_path.read_text(encoding="utf-8"))

required_keys = {
    "python_version",
    "python_short_version",
    "requirements_path",
    "requirements_sha256",
    "mlx_audio_version",
    "mlx_wheel_tag",
    "mlx_metal_wheel_tag",
    "mlx_core_minos",
    "supported_minimum_macos",
    "used_vendor_wheels",
    "built_at_utc",
}
missing = sorted(required_keys.difference(data))
if missing:
    raise SystemExit(f"Manifest missing keys: {', '.join(missing)}")
if data["requirements_sha256"] != expected_hash:
    raise SystemExit(
        f"Manifest requirements hash mismatch: {data['requirements_sha256']} != {expected_hash}"
    )
if not data["used_vendor_wheels"]:
    raise SystemExit("Manifest reports vendor wheels were not used")
if data["supported_minimum_macos"] != supported_macos:
    raise SystemExit(
        f"Manifest minimum macOS mismatch: {data['supported_minimum_macos']} != {supported_macos}"
    )

def parse_version(value: str) -> tuple[int, int]:
    parts = value.split(".")
    major = int(parts[0])
    minor = int(parts[1]) if len(parts) > 1 else 0
    return major, minor

def parse_tag_version(tag: str) -> tuple[int, int]:
    match = re.search(r"macosx_(\d+)_(\d+)_arm64", tag)
    if not match:
        raise SystemExit(f"Could not parse macOS target from wheel tag: {tag}")
    return int(match.group(1)), int(match.group(2))

max_version = parse_version(supported_macos)
for key in ("mlx_wheel_tag", "mlx_metal_wheel_tag"):
    if parse_tag_version(data[key]) > max_version:
        raise SystemExit(
            f"{key} targets newer macOS than supported minimum {supported_macos}: {data[key]}"
        )

if parse_version(data["mlx_core_minos"]) > max_version:
    raise SystemExit(
        f"mlx_core_minos targets newer macOS than supported minimum {supported_macos}: {data['mlx_core_minos']}"
    )
PY

"$PYTHON_BIN" - "$PYTHON_ROOT" "$APP_MIN_MACOS_VERSION" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

python_root = Path(sys.argv[1])
supported_macos = sys.argv[2]

def parse_version(value: str) -> tuple[int, int]:
    parts = value.split(".")
    major = int(parts[0])
    minor = int(parts[1]) if len(parts) > 1 else 0
    return major, minor

def parse_tag_version(tag: str) -> tuple[int, int]:
    match = re.search(r"macosx_(\d+)_(\d+)_arm64", tag)
    if not match:
        raise SystemExit(f"Could not parse macOS target from wheel tag: {tag}")
    return int(match.group(1)), int(match.group(2))

site_packages_candidates = sorted(python_root.glob("lib/python*/site-packages"))
if not site_packages_candidates:
    raise SystemExit(f"Could not locate site-packages under {python_root}")
site_packages = site_packages_candidates[0]

def read_wheel_tag(prefix: str) -> str:
    matches = sorted(site_packages.glob(f"{prefix}*.dist-info"))
    if not matches:
        raise SystemExit(f"Missing dist-info directory for {prefix}")
    wheel_path = matches[0] / "WHEEL"
    for line in wheel_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("Tag: "):
            return line.split(":", 1)[1].strip()
    raise SystemExit(f"Missing Tag entry in {wheel_path}")

max_version = parse_version(supported_macos)
for label, tag in (("mlx", read_wheel_tag("mlx-")), ("mlx-metal", read_wheel_tag("mlx_metal-"))):
    if parse_tag_version(tag) > max_version:
        raise SystemExit(f"{label} wheel tag is incompatible with macOS {supported_macos}: {tag}")

core_candidates = sorted((site_packages / "mlx").glob("core.cpython-*-darwin.so"))
if not core_candidates:
    raise SystemExit("Could not locate mlx core extension")
core_path = core_candidates[0]
otool_output = subprocess.check_output(["otool", "-l", str(core_path)], text=True)
minos_match = re.search(r"\bminos\s+(\d+\.\d+)", otool_output)
if not minos_match:
    raise SystemExit(f"Could not extract minos from {core_path}")
if parse_version(minos_match.group(1)) > max_version:
    raise SystemExit(
        f"mlx core extension minos is incompatible with macOS {supported_macos}: {minos_match.group(1)}"
    )
PY

LEAKED_LIBS=0
while IFS= read -r -d '' native_file; do
    while IFS= read -r dep_line; do
        dep_path="$(echo "$dep_line" | awk '{print $1}')"
        case "$dep_path" in
            /opt/homebrew/*|/usr/local/*)
                echo "Leaked host dependency: $native_file -> $dep_path" >&2
                LEAKED_LIBS=1
                ;;
        esac
    done < <(otool -L "$native_file" 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//')
done < <(find "$PYTHON_ROOT" \( -name "*.so" -o -name "*.dylib" \) -print0)

if [ "$LEAKED_LIBS" -ne 0 ]; then
    fail "Embedded native libraries link against host-specific paths"
fi
echo "[6/7] Manifest and linkage checks OK"
echo ""

echo "[7/7] Running backend smoke test..."
TMP_APP_SUPPORT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_APP_SUPPORT"
}
trap cleanup EXIT

QWENVOICE_FFMPEG_PATH="$FFMPEG_BIN" "$PYTHON_BIN" - "$PYTHON_BIN" "$SERVER_SCRIPT" "$TMP_APP_SUPPORT" <<'PY'
import json
import os
import subprocess
import sys
import time

python_bin = sys.argv[1]
server_script = sys.argv[2]
app_support_dir = sys.argv[3]

proc = subprocess.Popen(
    [python_bin, "-u", server_script],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
)

try:
    deadline = time.time() + 30
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                raise RuntimeError("Backend exited before ready notification")
            continue
        message = json.loads(line)
        if message.get("method") == "ready":
            break
    else:
        raise RuntimeError("Timed out waiting for backend ready notification")

    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "init",
            "params": {"app_support_dir": app_support_dir},
        },
    ]

    for request in requests:
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()

        deadline = time.time() + 30
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                if proc.poll() is not None:
                    raise RuntimeError(f"Backend exited during {request['method']}")
                continue
            message = json.loads(line)
            if message.get("id") == request["id"]:
                if "error" in message:
                    raise RuntimeError(
                        f"{request['method']} returned error: {message['error'].get('message')}"
                    )
                break
        else:
            raise RuntimeError(f"Timed out waiting for {request['method']} response")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY

echo "[7/7] Backend smoke test OK"
echo ""
echo "Release bundle verification passed."
