#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REQUIREMENTS_PATH="$PROJECT_DIR/Sources/Resources/requirements.txt"

fail() {
    echo "Error: $*" >&2
    exit 1
}

if [ $# -ne 1 ]; then
    fail "Usage: $0 /path/to/Qwen Voice.app"
fi

APP_PATH="$1"
if [ ! -d "$APP_PATH" ]; then
    fail "App bundle not found: $APP_PATH"
fi

RESOURCES_DIR="$APP_PATH/Contents/Resources"
PYTHON_ROOT="$RESOURCES_DIR/python"
PYTHON_BIN="$PYTHON_ROOT/bin/python3"
FFMPEG_BIN="$RESOURCES_DIR/ffmpeg"
SERVER_SCRIPT="$RESOURCES_DIR/backend/server.py"
if [ ! -f "$SERVER_SCRIPT" ] && [ -f "$RESOURCES_DIR/server.py" ]; then
    SERVER_SCRIPT="$RESOURCES_DIR/server.py"
fi
MANIFEST_PATH="$PYTHON_ROOT/.qwenvoice-runtime-manifest.json"

echo "=== Qwen Voice: Verify Release Bundle ==="
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
"$PYTHON_BIN" -c "import mlx; import mlx_audio; import transformers; import numpy; import soundfile; import huggingface_hub"
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
"$PYTHON_BIN" - "$MANIFEST_PATH" "$EXPECTED_REQUIREMENTS_HASH" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
expected_hash = sys.argv[2]
data = json.loads(manifest_path.read_text(encoding="utf-8"))

required_keys = {
    "python_version",
    "python_short_version",
    "requirements_path",
    "requirements_sha256",
    "mlx_audio_version",
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
