#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECT_SIGNED_RELEASE="${QWENVOICE_EXPECT_SIGNED_RELEASE:-0}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

codesign_has_runtime_metadata() {
    local target="$1"
    local codesign_output
    if ! codesign_output="$(codesign -dv --verbose=4 "$target" 2>&1)"; then
        printf '%s\n' "$codesign_output" >&2
        return 1
    fi
    grep -q "Runtime Version" <<<"$codesign_output"
}

if [ $# -ne 1 ]; then
    fail "Usage: $0 /path/to/QwenVoice.app"
fi

APP_PATH="$1"
if [ ! -d "$APP_PATH" ]; then
    fail "App bundle not found: $APP_PATH"
fi
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"

APP_BINARY="$APP_PATH/Contents/MacOS/QwenVoice"
XPC_SERVICE_PATH="$APP_PATH/Contents/XPCServices/QwenVoiceEngineService.xpc"
XPC_SERVICE_BINARY="$XPC_SERVICE_PATH/Contents/MacOS/QwenVoiceEngineService"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
TMP_UI_HOME=""
TMP_UI_FIXTURE=""
TMP_UI_STDOUT=""
TMP_UI_STDERR=""

cleanup() {
    pkill -x QwenVoice 2>/dev/null || true
    [ -n "$TMP_UI_HOME" ] && rm -rf "$TMP_UI_HOME"
    [ -n "$TMP_UI_FIXTURE" ] && rm -rf "$TMP_UI_FIXTURE"
    [ -n "$TMP_UI_STDOUT" ] && rm -f "$TMP_UI_STDOUT"
    [ -n "$TMP_UI_STDERR" ] && rm -f "$TMP_UI_STDERR"
}
trap cleanup EXIT

echo "=== QwenVoice: Verify Release Bundle ==="
echo ""

echo "[1/4] Checking native bundle contents..."
[ -x "$APP_BINARY" ] || fail "App binary missing: $APP_BINARY"
[ -d "$XPC_SERVICE_PATH" ] || fail "Bundled XPC service missing: $XPC_SERVICE_PATH"
[ -x "$XPC_SERVICE_BINARY" ] || fail "Bundled XPC service binary missing: $XPC_SERVICE_BINARY"
"$SCRIPT_DIR/check_backend_resource_contract.sh" --app-bundle "$APP_PATH" >/dev/null
if find "$RESOURCES_DIR" -name "*.whl" -print -quit | grep -q .; then
    fail "Vendored wheel files must not be packaged into the native app bundle"
fi
if find "$RESOURCES_DIR" \( -name "*.pyc" -o -type d -name "__pycache__" \) -print -quit | grep -q .; then
    fail "Compiled Python artifacts must not be packaged into the native app bundle"
fi
echo "[1/4] Native bundle contents OK"
echo ""

echo "[2/4] Verifying app code signature..."
if [ "$EXPECT_SIGNED_RELEASE" = "1" ]; then
    codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || fail "Signed release code signature verification failed"
    codesign_has_runtime_metadata "$APP_PATH" || fail "Signed release is missing hardened runtime metadata"
    codesign --verify --strict "$XPC_SERVICE_PATH" >/dev/null 2>&1 || fail "Bundled XPC service code signature verification failed"
    codesign_has_runtime_metadata "$XPC_SERVICE_PATH" || fail "Bundled XPC service is missing hardened runtime metadata"
    echo "[2/4] Signed release checks OK"
else
    echo "[2/4] Signature checks skipped (set QWENVOICE_EXPECT_SIGNED_RELEASE=1 for release verification)"
fi
echo ""

echo "[3/4] Launching packaged app in isolated native mode..."
TMP_UI_HOME="$(mktemp -d)"
TMP_UI_FIXTURE="$(mktemp -d)"
TMP_UI_STDOUT="$(mktemp)"
TMP_UI_STDERR="$(mktemp)"

mkdir -p \
    "$TMP_UI_FIXTURE/models" \
    "$TMP_UI_FIXTURE/outputs" \
    "$TMP_UI_FIXTURE/voices" \
    "$TMP_UI_FIXTURE/cache" \
    "$TMP_UI_FIXTURE/cache/stream_sessions"

pkill -x QwenVoice 2>/dev/null || true

HOME="$TMP_UI_HOME" \
USER="${USER:-$(id -un)}" \
LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
QWENVOICE_UI_TEST="1" \
QWENVOICE_UI_TEST_BACKEND_MODE="live" \
QWENVOICE_UI_TEST_SETUP_DELAY_MS="1" \
QWENVOICE_UI_TEST_DEFAULTS_SUITE="QwenVoiceReleaseSmoke.$RANDOM.$RANDOM" \
QWENVOICE_APP_SUPPORT_DIR="$TMP_UI_FIXTURE" \
/usr/bin/open -n "$APP_PATH" --args \
--uitest \
--uitest-disable-animations \
--uitest-fast-idle \
>"$TMP_UI_STDOUT" 2>"$TMP_UI_STDERR"

if ! python3 - <<'PY'
import subprocess
import time

deadline = time.time() + 30
process_seen = False

def is_running() -> bool:
    proc = subprocess.run(
        ["pgrep", "-x", "QwenVoice"],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0

while time.time() < deadline:
    if is_running():
        process_seen = True
        time.sleep(2.0)
        if is_running():
            raise SystemExit(0)
        raise SystemExit("QwenVoice launched but did not remain running long enough to pass startup smoke")
    time.sleep(0.25)

if process_seen:
    raise SystemExit("QwenVoice process exited before startup smoke completed")
raise SystemExit("Timed out waiting for packaged QwenVoice process to launch")
PY
then
    echo "Packaged-app smoke stdout tail:" >&2
    tail -n 40 "$TMP_UI_STDOUT" >&2 || true
    echo "Packaged-app smoke stderr tail:" >&2
    tail -n 80 "$TMP_UI_STDERR" >&2 || true
    fail "Isolated packaged-app startup smoke failed"
fi

echo "[3/4] Packaged app startup smoke OK"
echo ""

echo "[4/4] Release bundle verification passed."
