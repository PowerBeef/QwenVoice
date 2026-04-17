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
import json
import time
import urllib.error
import urllib.request

base_url = "http://127.0.0.1:19876"
deadline = time.time() + 60
health_seen = False
last_state: dict[str, object] = {}

while time.time() < deadline:
    try:
        with urllib.request.urlopen(f"{base_url}/health", timeout=1.5):
            health_seen = True
    except Exception:
        time.sleep(0.5)
        continue

    try:
        with urllib.request.urlopen(f"{base_url}/state", timeout=2) as response:
            last_state = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        time.sleep(0.5)
        continue

    if last_state.get("interactiveReady") is True:
        runtime_source = last_state.get("runtimeSource")
        active_python_path = (last_state.get("activePythonPath") or "").strip()
        active_ffmpeg_path = (last_state.get("activeFFmpegPath") or "").strip()
        backend_last_error = (last_state.get("backendLastError") or "").strip()

        if runtime_source != "native":
            raise SystemExit(
                f"Packaged app reported unexpected runtimeSource={runtime_source!r}; state={last_state}"
            )
        if active_python_path:
            raise SystemExit(
                f"Packaged app should not expose an active Python path: {active_python_path!r}"
            )
        if active_ffmpeg_path:
            raise SystemExit(
                f"Packaged app should not expose an active ffmpeg path: {active_ffmpeg_path!r}"
            )
        if backend_last_error:
            raise SystemExit(
                f"Packaged app reported an unexpected runtime error: {backend_last_error!r}"
            )
        raise SystemExit(0)

    time.sleep(0.5)

reason = "state_server_unreachable"
if health_seen:
    reason = last_state.get("readinessBlocker") or last_state.get("launchPhase") or "interactive_ready_timeout"
raise SystemExit(
    f"Timed out waiting for packaged app readiness: reason={reason} last_state={last_state}"
)
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
