#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REQUIREMENTS_PATH="$PROJECT_DIR/Sources/Resources/requirements.txt"
APP_MIN_MACOS_VERSION="15.0"
EXPECT_SIGNED_RELEASE="${QWENVOICE_EXPECT_SIGNED_RELEASE:-0}"
EXPECTED_MLX_WHEEL_TAG="cp313-cp313-macosx_15_0_arm64"
EXPECTED_MLX_METAL_WHEEL_TAG="py3-none-macosx_15_0_arm64"
EXPECTED_MLX_CORE_MINOS="$APP_MIN_MACOS_VERSION"

fail() {
    echo "Error: $*" >&2
    exit 1
}

is_macho_file() {
    local target="$1"
    file -b "$target" 2>/dev/null | grep -q "Mach-O"
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

verify_embedded_runtime_entitlements() {
    local target="$1"
    local entitlements_payload
    entitlements_payload="$(codesign --display --entitlements - --xml "$target" 2>/dev/null)"
    ENTITLEMENTS_PAYLOAD="$entitlements_payload" python3 -c '
import os
import plistlib
import sys

target = sys.argv[1]
payload = os.environ["ENTITLEMENTS_PAYLOAD"].encode("utf-8")
if not payload.strip():
    raise SystemExit(f"Embedded runtime entitlements missing for {target}")

try:
    entitlements = plistlib.loads(payload)
except Exception as exc:  # pragma: no cover - defensive shell validation
    raise SystemExit(f"Could not parse entitlements for {target}: {exc}") from exc

expected = {
    "com.apple.security.cs.allow-unsigned-executable-memory": True,
    "com.apple.security.cs.disable-library-validation": True,
}

if entitlements != expected:
    raise SystemExit(
        f"Unexpected embedded runtime entitlements for {target}: {entitlements!r}"
    )
' "$target"
}

if [ $# -ne 1 ]; then
    fail "Usage: $0 /path/to/QwenVoice.app"
fi

APP_PATH="$1"
if [ ! -d "$APP_PATH" ]; then
    fail "App bundle not found: $APP_PATH"
fi
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"

RESOURCES_DIR="$APP_PATH/Contents/Resources"
BACKEND_DIR="$RESOURCES_DIR/backend"
APP_BINARY="$APP_PATH/Contents/MacOS/QwenVoice"
PYTHON_ROOT="$RESOURCES_DIR/python"
PYTHON_BIN="$PYTHON_ROOT/bin/python3"
FFMPEG_BIN="$RESOURCES_DIR/ffmpeg"
SERVER_SCRIPT="$BACKEND_DIR/server.py"
HELPER_DIR="$BACKEND_DIR"
MANIFEST_PATH="$PYTHON_ROOT/.qwenvoice-runtime-manifest.json"
MLX_METALLIB_PATH="$(find "$PYTHON_ROOT/lib" -path '*/site-packages/mlx/lib/mlx.metallib' -type f | head -n1)"

export PYTHONDONTWRITEBYTECODE=1

echo "=== QwenVoice: Verify Release Bundle ==="
echo ""

echo "[1/8] Checking required files..."
"$SCRIPT_DIR/check_backend_resource_contract.sh" --app-bundle "$APP_PATH" >/dev/null
[ -x "$APP_BINARY" ] || fail "App binary missing: $APP_BINARY"
[ -x "$PYTHON_BIN" ] || fail "Bundled Python missing: $PYTHON_BIN"
[ -x "$FFMPEG_BIN" ] || fail "Bundled ffmpeg missing: $FFMPEG_BIN"
[ -f "$SERVER_SCRIPT" ] || fail "Bundled backend missing: $SERVER_SCRIPT"
[ -f "$MANIFEST_PATH" ] || fail "Bundled runtime manifest missing: $MANIFEST_PATH"
[ -f "$MLX_METALLIB_PATH" ] || fail "Bundled mlx.metallib missing under $PYTHON_ROOT/lib"
if find "$RESOURCES_DIR" -name "*.whl" -print -quit | grep -q .; then
    fail "Vendored wheel files should not be packaged into the app bundle"
fi
if find "$RESOURCES_DIR" \( -name "*.pyc" -o -type d -name "__pycache__" \) -print -quit | grep -q .; then
    fail "Compiled Python artifacts should not be packaged into the app bundle"
fi
echo "[1/8] Required files OK"
echo ""

echo "[2/9] Verifying app code signature..."
if [ "$EXPECT_SIGNED_RELEASE" = "1" ]; then
    codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || fail "Signed release code signature verification failed"
    if ! codesign_has_runtime_metadata "$APP_PATH"; then
        fail "Signed release is missing hardened runtime metadata"
    fi
    if [ -x "$FFMPEG_BIN" ] && is_macho_file "$FFMPEG_BIN"; then
        codesign_has_runtime_metadata "$FFMPEG_BIN" || fail "Bundled ffmpeg is missing hardened runtime metadata"
    fi
    while IFS= read -r -d '' py_bin; do
        is_macho_file "$py_bin" || continue
        codesign_has_runtime_metadata "$py_bin" || fail "Bundled Python executable is missing hardened runtime metadata: $py_bin"
        verify_embedded_runtime_entitlements "$py_bin"
    done < <(find "$PYTHON_ROOT/bin" -type f -print0 2>/dev/null)
    echo "[2/9] Signed release checks OK"
else
    echo "[2/9] Signature checks skipped (set QWENVOICE_EXPECT_SIGNED_RELEASE=1 for release verification)"
fi
echo ""

echo "[3/9] Verifying bundled Python executable..."
"$PYTHON_BIN" --version >/dev/null
echo "[3/9] Bundled Python runs"
echo ""

echo "[4/9] Verifying bundled Python imports..."
"$PYTHON_BIN" -c "import mlx; import mlx.core as mx; import mlx_audio; import transformers; import numpy; import soundfile; import huggingface_hub; x = mx.array([1.0], dtype=mx.float32); mx.eval(x)"
echo "[4/9] Core imports OK"
echo ""

echo "[5/9] Verifying bundled mlx-audio helper..."
"$PYTHON_BIN" -c "import sys; sys.path.insert(0, '$HELPER_DIR'); import mlx_audio_qwen_speed_patch as p; import sys as _sys; _sys.exit(0 if hasattr(p, 'try_enable_speech_tokenizer_encoder') else 1)"
echo "[5/9] Helper is present"
echo ""

echo "[6/9] Verifying bundled ffmpeg..."
"$FFMPEG_BIN" -version >/dev/null
echo "[6/9] Bundled ffmpeg runs"
echo ""

echo "[7/9] Verifying runtime manifest and native-library linkage..."
EXPECTED_REQUIREMENTS_HASH="$(shasum -a 256 "$REQUIREMENTS_PATH" | awk '{print $1}')"
"$PYTHON_BIN" - "$MANIFEST_PATH" "$REQUIREMENTS_PATH" "$EXPECTED_REQUIREMENTS_HASH" "$APP_MIN_MACOS_VERSION" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
requirements_path = Path(sys.argv[2])
expected_hash = sys.argv[3]
supported_macos = sys.argv[4]
data = json.loads(manifest_path.read_text(encoding="utf-8"))

required_keys = {
    "python_version",
    "python_short_version",
    "requirements_path",
    "requirements_sha256",
    "mlx_version",
    "mlx_metal_version",
    "mlx_lm_version",
    "mlx_audio_version",
    "transformers_version",
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
if data["used_vendor_wheels"]:
    raise SystemExit("Manifest still reports vendor wheels were used")
if data["supported_minimum_macos"] != supported_macos:
    raise SystemExit(
        f"Manifest minimum macOS mismatch: {data['supported_minimum_macos']} != {supported_macos}"
    )
expected_exact_values = {
    "mlx_wheel_tag": "cp313-cp313-macosx_15_0_arm64",
    "mlx_metal_wheel_tag": "py3-none-macosx_15_0_arm64",
    "mlx_core_minos": supported_macos,
}
for key, expected_value in expected_exact_values.items():
    actual_value = data.get(key)
    if actual_value != expected_value:
        raise SystemExit(
            f"Manifest {key} mismatch: {actual_value} != {expected_value}"
        )

expected_core_versions = {}
for raw_line in requirements_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or line.startswith("--"):
        continue
    requirement = line.split(";", 1)[0].strip()
    if "==" not in requirement:
        continue
    package, version = requirement.split("==", 1)
    package = package.strip()
    if package in {"mlx", "mlx-metal", "mlx-lm", "mlx-audio", "transformers"}:
        expected_core_versions[package] = version.strip()

required_manifest_versions = {
    "mlx": "mlx_version",
    "mlx-metal": "mlx_metal_version",
    "mlx-lm": "mlx_lm_version",
    "mlx-audio": "mlx_audio_version",
    "transformers": "transformers_version",
}
for package, manifest_key in required_manifest_versions.items():
    expected_version = expected_core_versions.get(package)
    actual_version = data.get(manifest_key)
    if expected_version != actual_version:
        raise SystemExit(
            f"Manifest {manifest_key} mismatch: {actual_version} != {expected_version}"
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

"$PYTHON_BIN" - "$PYTHON_ROOT" "$APP_MIN_MACOS_VERSION" "$EXPECTED_MLX_WHEEL_TAG" "$EXPECTED_MLX_METAL_WHEEL_TAG" "$EXPECTED_MLX_CORE_MINOS" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

python_root = Path(sys.argv[1])
supported_macos = sys.argv[2]
expected_mlx_wheel_tag = sys.argv[3]
expected_mlx_metal_wheel_tag = sys.argv[4]
expected_mlx_core_minos = sys.argv[5]

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
mlx_metallib_path = site_packages / "mlx" / "lib" / "mlx.metallib"
if not mlx_metallib_path.is_file():
    raise SystemExit(f"Could not locate bundled mlx.metallib at {mlx_metallib_path}")

from importlib.metadata import version

def read_wheel_tag(prefix: str) -> str:
    matches = sorted(site_packages.glob(f"{prefix}*.dist-info"))
    if not matches:
        raise SystemExit(f"Missing dist-info directory for {prefix}")
    wheel_path = matches[0] / "WHEEL"
    for line in wheel_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("Tag: "):
            return line.split(":", 1)[1].strip()
    raise SystemExit(f"Missing Tag entry in {wheel_path}")

resolved_wheel_tags = {
    "mlx": read_wheel_tag("mlx-"),
    "mlx-metal": read_wheel_tag("mlx_metal-"),
}
expected_wheel_tags = {
    "mlx": expected_mlx_wheel_tag,
    "mlx-metal": expected_mlx_metal_wheel_tag,
}
for label, tag in resolved_wheel_tags.items():
    if tag != expected_wheel_tags[label]:
        raise SystemExit(f"{label} wheel tag mismatch: {tag} != {expected_wheel_tags[label]}")

core_candidates = sorted((site_packages / "mlx").glob("core.cpython-*-darwin.so"))
if not core_candidates:
    raise SystemExit("Could not locate mlx core extension")
core_path = core_candidates[0]
otool_output = subprocess.check_output(["otool", "-l", str(core_path)], text=True)
minos_match = re.search(r"\bminos\s+(\d+\.\d+)", otool_output)
if not minos_match:
    raise SystemExit(f"Could not extract minos from {core_path}")
if minos_match.group(1) != expected_mlx_core_minos:
    raise SystemExit(
        f"mlx core extension minos mismatch: {minos_match.group(1)} != {expected_mlx_core_minos}"
    )

resolved_versions = {
    "mlx": version("mlx"),
    "mlx-metal": version("mlx-metal"),
    "mlx-lm": version("mlx-lm"),
    "mlx-audio": version("mlx-audio"),
    "transformers": version("transformers"),
}
manifest_path = python_root / ".qwenvoice-runtime-manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest_versions = {
    "mlx": manifest["mlx_version"],
    "mlx-metal": manifest["mlx_metal_version"],
    "mlx-lm": manifest["mlx_lm_version"],
    "mlx-audio": manifest["mlx_audio_version"],
    "transformers": manifest["transformers_version"],
}
manifest_wheel_values = {
    "mlx_wheel_tag": manifest["mlx_wheel_tag"],
    "mlx_metal_wheel_tag": manifest["mlx_metal_wheel_tag"],
    "mlx_core_minos": manifest["mlx_core_minos"],
}
for package, actual_version in resolved_versions.items():
    if manifest_versions[package] != actual_version:
        raise SystemExit(
            f"Bundled runtime resolved {package}={actual_version}, "
            f"but manifest recorded {manifest_versions[package]}"
        )
if manifest_wheel_values["mlx_wheel_tag"] != expected_mlx_wheel_tag:
    raise SystemExit(
        f"Manifest mlx_wheel_tag mismatch: {manifest_wheel_values['mlx_wheel_tag']} != {expected_mlx_wheel_tag}"
    )
if manifest_wheel_values["mlx_metal_wheel_tag"] != expected_mlx_metal_wheel_tag:
    raise SystemExit(
        f"Manifest mlx_metal_wheel_tag mismatch: {manifest_wheel_values['mlx_metal_wheel_tag']} != {expected_mlx_metal_wheel_tag}"
    )
if manifest_wheel_values["mlx_core_minos"] != expected_mlx_core_minos:
    raise SystemExit(
        f"Manifest mlx_core_minos mismatch: {manifest_wheel_values['mlx_core_minos']} != {expected_mlx_core_minos}"
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
echo "[7/9] Manifest and linkage checks OK"
echo ""

echo "[8/9] Running backend smoke test..."
TMP_APP_SUPPORT="$(mktemp -d)"
TMP_UI_HOME=""
TMP_UI_FIXTURE=""
TMP_UI_STDOUT=""
TMP_UI_STDERR=""
cleanup() {
    pkill -x QwenVoice 2>/dev/null || true
    rm -rf "$TMP_APP_SUPPORT"
    [ -n "$TMP_UI_HOME" ] && rm -rf "$TMP_UI_HOME"
    [ -n "$TMP_UI_FIXTURE" ] && rm -rf "$TMP_UI_FIXTURE"
    [ -n "$TMP_UI_STDOUT" ] && rm -f "$TMP_UI_STDOUT"
    [ -n "$TMP_UI_STDERR" ] && rm -f "$TMP_UI_STDERR"
}
trap cleanup EXIT

PATH="/usr/bin:/bin:/usr/sbin:/sbin" QWENVOICE_FFMPEG_PATH="$FFMPEG_BIN" "$PYTHON_BIN" - "$PYTHON_BIN" "$SERVER_SCRIPT" "$TMP_APP_SUPPORT" "$FFMPEG_BIN" <<'PY'
import json
import os
import subprocess
import sys
import time
import wave
from pathlib import Path

python_bin = sys.argv[1]
server_script = sys.argv[2]
app_support_dir = sys.argv[3]
ffmpeg_bin = sys.argv[4]

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

    work_dir = Path(app_support_dir)
    source_wav = work_dir / "verify_source.wav"
    encoded_input = work_dir / "verify_source.m4a"
    converted_output = work_dir / "verify_converted.wav"

    with wave.open(str(source_wav), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(24000)
        handle.writeframes(b"\x00\x00" * 2400)

    encode_proc = subprocess.run(
        [
            ffmpeg_bin,
            "-y",
            "-v",
            "error",
            "-i",
            str(source_wav),
            str(encoded_input),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if encode_proc.returncode != 0:
        raise RuntimeError(
            "Bundled ffmpeg failed to create the verification input: "
            + (encode_proc.stderr.strip() or f"exit {encode_proc.returncode}")
        )

    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "convert_audio",
        "params": {
            "input_path": str(encoded_input),
            "output_path": str(converted_output),
        },
    }
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()

    deadline = time.time() + 60
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                raise RuntimeError("Backend exited during convert_audio")
            continue
        message = json.loads(line)
        if message.get("id") != 3:
            continue
        if "error" in message:
            raise RuntimeError(
                "convert_audio returned error: "
                + message["error"].get("message", "unknown error")
            )
        wav_path = message.get("result", {}).get("wav_path")
        if not wav_path or not Path(wav_path).exists():
            raise RuntimeError(f"convert_audio returned missing wav_path: {message}")
        break
    else:
        raise RuntimeError("Timed out waiting for convert_audio response")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY

echo "[8/9] Backend smoke test OK"
echo ""

echo "[9/9] Running isolated packaged-app startup smoke..."
TMP_UI_HOME="$(mktemp -d)"
TMP_UI_FIXTURE="$(mktemp -d)"
TMP_UI_STDOUT="$(mktemp)"
TMP_UI_STDERR="$(mktemp)"

pkill -x QwenVoice 2>/dev/null || true
sleep 1

env -i \
    HOME="$TMP_UI_HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    SHELL="/bin/zsh" \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
    PYTHONDONTWRITEBYTECODE="1" \
    QWENVOICE_UI_TEST="1" \
    QWENVOICE_UI_TEST_BACKEND_MODE="stub" \
    QWENVOICE_UI_TEST_SETUP_DELAY_MS="1" \
    QWENVOICE_UI_TEST_FIXTURE_ROOT="$TMP_UI_FIXTURE" \
    QWENVOICE_UI_TEST_DEFAULTS_SUITE="QwenVoiceReleaseSmoke.$RANDOM.$RANDOM" \
    /usr/bin/open -n "$APP_PATH" --args \
    --uitest \
    --uitest-disable-animations \
    --uitest-fast-idle \
    >"$TMP_UI_STDOUT" 2>"$TMP_UI_STDERR"

if ! "$PYTHON_BIN" - "$PYTHON_ROOT" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

python_root = sys.argv[1]
base_url = "http://127.0.0.1:19876"
deadline = time.time() + 60
last_state = {}
health_seen = False

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
        active_python_path = last_state.get("activePythonPath", "")
        active_ffmpeg_path = last_state.get("activeFFmpegPath", "")
        expected_prefix = python_root.rstrip("/") + "/"
        expected_ffmpeg = python_root.rsplit("/python", 1)[0] + "/ffmpeg"
        normalized_active_python_path = os.path.realpath(active_python_path) if active_python_path else ""
        normalized_expected_prefix = os.path.realpath(expected_prefix.rstrip("/")) + "/"
        normalized_active_ffmpeg_path = os.path.realpath(active_ffmpeg_path) if active_ffmpeg_path else ""
        normalized_expected_ffmpeg = os.path.realpath(expected_ffmpeg)
        if runtime_source != "bundled":
            raise SystemExit(
                f"Packaged app reported unexpected runtimeSource={runtime_source!r}; state={last_state}"
            )
        if not normalized_active_python_path.startswith(normalized_expected_prefix):
            raise SystemExit(
                "Packaged app did not resolve the bundled Python runtime: "
                f"activePythonPath={active_python_path!r} expected_prefix={expected_prefix!r}"
            )
        if normalized_active_ffmpeg_path != normalized_expected_ffmpeg:
            raise SystemExit(
                "Packaged app did not resolve the bundled ffmpeg binary: "
                f"activeFFmpegPath={active_ffmpeg_path!r} expected={expected_ffmpeg!r}"
            )
        sys.exit(0)

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

echo "[9/9] Packaged app startup smoke OK"
echo ""
echo "Release bundle verification passed."
