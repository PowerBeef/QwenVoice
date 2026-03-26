#!/bin/bash
set -euo pipefail

# Bundle Python arm64 + required app packages into the app's Resources/python/
# Target: QwenVoice.app/Contents/Resources/python/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/Sources/Resources"
PYTHON_BUNDLE="$RESOURCES_DIR/python"
REQUIREMENTS="$RESOURCES_DIR/requirements.txt"
VENDOR_DIR="$RESOURCES_DIR/vendor"
MANIFEST_PATH="$PYTHON_BUNDLE/.qwenvoice-runtime-manifest.json"

PYTHON_VERSION="3.13"
PYTHON_BUILD_STANDALONE_VERSION="20260211"
PYTHON_BUILD_STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_STANDALONE_VERSION}/cpython-${PYTHON_VERSION}.12+${PYTHON_BUILD_STANDALONE_VERSION}-aarch64-apple-darwin-install_only.tar.gz"
APP_MIN_MACOS_VERSION="15.0"

# --- How to update the Python standalone URL ---
# The URL above points to a specific release from astral-sh/python-build-standalone.
# If this release is removed or you want a newer Python patch version:
#   1. Visit https://github.com/astral-sh/python-build-standalone/releases
#   2. Find the latest release tag (e.g. 20260301)
#   3. Look for the asset named: cpython-3.13.X+YYYYMMDD-aarch64-apple-darwin-install_only.tar.gz
#   4. Update PYTHON_BUILD_STANDALONE_VERSION and the minor version in the URL above
# The "install_only" variant is a pre-built, relocatable Python — no compilation needed.

echo "=== QwenVoice: Bundle Python ==="
echo ""

EXPECTED_MLX_AUDIO_VERSION="$(grep -E '^mlx-audio==' "$REQUIREMENTS" | head -n 1 | sed 's/^mlx-audio==//')"
if [ -z "$EXPECTED_MLX_AUDIO_VERSION" ]; then
    echo "Error: Could not determine pinned mlx-audio version from $REQUIREMENTS"
    exit 1
fi
EXPECTED_MLX_VERSION="$(grep -E '^mlx==' "$REQUIREMENTS" | head -n 1 | sed 's/^mlx==//')"
if [ -z "$EXPECTED_MLX_VERSION" ]; then
    echo "Error: Could not determine pinned mlx version from $REQUIREMENTS"
    exit 1
fi
EXPECTED_MLX_METAL_VERSION="$(grep -E '^mlx-metal==' "$REQUIREMENTS" | head -n 1 | sed 's/^mlx-metal==//')"
if [ -z "$EXPECTED_MLX_METAL_VERSION" ]; then
    echo "Error: Could not determine pinned mlx-metal version from $REQUIREMENTS"
    exit 1
fi

# Step 1: Download standalone Python
DOWNLOAD_DIR="/tmp/qwenvoice-python-build"
mkdir -p "$DOWNLOAD_DIR"

TARBALL="$DOWNLOAD_DIR/python-standalone.tar.gz"
if [ ! -f "$TARBALL" ]; then
    echo "[1/5] Downloading Python ${PYTHON_VERSION} (arm64 standalone)..."
    if ! curl --fail --retry 3 --retry-delay 5 -L -o "$TARBALL" "$PYTHON_BUILD_STANDALONE_URL"; then
        rm -f "$TARBALL"
        echo "Error: Failed to download Python standalone after retries"
        exit 1
    fi
    # Sanity check: Python tarball should be >10MB
    TARBALL_SIZE=$(stat -f%z "$TARBALL" 2>/dev/null || echo 0)
    if [ "$TARBALL_SIZE" -lt 10485760 ]; then
        rm -f "$TARBALL"
        echo "Error: Downloaded Python tarball is too small (${TARBALL_SIZE} bytes) — likely a failed download"
        exit 1
    fi
else
    echo "[1/5] Using cached Python download"
fi

# Step 2: Extract and verify
echo "[2/5] Extracting Python..."
rm -rf "$PYTHON_BUNDLE"
mkdir -p "$PYTHON_BUNDLE"
tar xzf "$TARBALL" -C "$PYTHON_BUNDLE" --strip-components=1

if [ ! -x "$PYTHON_BUNDLE/bin/python3" ]; then
    rm -f "$TARBALL"
    echo "Error: python3 binary not found after extraction — deleting cached tarball"
    exit 1
fi

EXTRACTED_VERSION=$("$PYTHON_BUNDLE/bin/python3" --version 2>&1)
echo "    Extracted: $EXTRACTED_VERSION"
PYTHON_SHORT_VERSION=$("$PYTHON_BUNDLE/bin/python3" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
SITE_PACKAGES="$PYTHON_BUNDLE/lib/python${PYTHON_SHORT_VERSION}/site-packages"
REQUIREMENTS_HASH=$(shasum -a 256 "$REQUIREMENTS" | awk '{print $1}')

# Step 3: Install required packages
echo "[3/5] Installing pip packages..."
"$PYTHON_BUNDLE/bin/python3" -m pip install --quiet --upgrade pip
"$PYTHON_BUNDLE/bin/python3" -m pip install --quiet --find-links "$VENDOR_DIR" -r "$REQUIREMENTS"

# Force macOS 15-compatible MLX wheels even when bundling on newer host OS versions.
MLX_WHEEL_CACHE_DIR="$DOWNLOAD_DIR/mlx-wheels-macos15"
mkdir -p "$MLX_WHEEL_CACHE_DIR"
"$PYTHON_BUNDLE/bin/python3" -m pip download \
    --quiet \
    --only-binary=:all: \
    --platform macosx_15_0_arm64 \
    --python-version "${PYTHON_SHORT_VERSION/./}" \
    --implementation cp \
    --abi "cp${PYTHON_SHORT_VERSION/./}" \
    "mlx==$EXPECTED_MLX_VERSION" \
    "mlx-metal==$EXPECTED_MLX_METAL_VERSION" \
    -d "$MLX_WHEEL_CACHE_DIR"
MLX_WHEEL_PATH="$(ls -1 "$MLX_WHEEL_CACHE_DIR"/mlx-"$EXPECTED_MLX_VERSION"-*.whl | head -n 1)"
MLX_METAL_WHEEL_PATH="$(ls -1 "$MLX_WHEEL_CACHE_DIR"/mlx_metal-"$EXPECTED_MLX_METAL_VERSION"-*.whl | head -n 1)"
if [ -z "$MLX_WHEEL_PATH" ] || [ -z "$MLX_METAL_WHEEL_PATH" ]; then
    echo "Error: Failed to resolve macOS 15-compatible MLX wheel paths"
    exit 1
fi
"$PYTHON_BUNDLE/bin/python3" -m pip install --quiet --force-reinstall --no-deps \
    "$MLX_WHEEL_PATH" \
    "$MLX_METAL_WHEEL_PATH"

# Validate core imports
echo "    Validating core imports..."
if ! "$PYTHON_BUNDLE/bin/python3" -c "import mlx; import mlx.core as mx; import mlx_audio; import transformers; import numpy; import soundfile; import huggingface_hub; x = mx.array([1.0], dtype=mx.float32); mx.eval(x)" 2>&1; then
    rm -f "$TARBALL"
    echo "Error: Core import/compute validation failed — bundled MLX runtime is not usable"
    exit 1
fi
if ! "$PYTHON_BUNDLE/bin/python3" -c "import mlx_audio.qwenvoice_speed_patch as p; import sys; sys.exit(0 if hasattr(p, 'try_enable_speech_tokenizer_encoder') else 1)" 2>&1; then
    rm -f "$TARBALL"
    echo "Error: mlx_audio.qwenvoice_speed_patch is missing or incomplete"
    exit 1
fi
INSTALLED_MLX_AUDIO_VERSION=$("$PYTHON_BUNDLE/bin/python3" -c "from importlib.metadata import version; print(version('mlx-audio'))")
if [ "$INSTALLED_MLX_AUDIO_VERSION" != "$EXPECTED_MLX_AUDIO_VERSION" ]; then
    rm -f "$TARBALL"
    echo "Error: Expected mlx-audio $EXPECTED_MLX_AUDIO_VERSION but found $INSTALLED_MLX_AUDIO_VERSION"
    exit 1
fi
CORE_VERSIONS=$("$PYTHON_BUNDLE/bin/python3" - <<'PY'
from importlib.metadata import version

packages = {
    "mlx_version": "mlx",
    "mlx_metal_version": "mlx-metal",
    "mlx_lm_version": "mlx-lm",
    "mlx_audio_version": "mlx-audio",
    "transformers_version": "transformers",
}
for key, package in packages.items():
    print(f"{key}={version(package)}")
PY
)
INSTALLED_MLX_VERSION=""
INSTALLED_MLX_METAL_VERSION=""
INSTALLED_MLX_LM_VERSION=""
INSTALLED_TRANSFORMERS_VERSION=""
while IFS='=' read -r key value; do
    case "$key" in
        mlx_version) INSTALLED_MLX_VERSION="$value" ;;
        mlx_metal_version) INSTALLED_MLX_METAL_VERSION="$value" ;;
        mlx_lm_version) INSTALLED_MLX_LM_VERSION="$value" ;;
        mlx_audio_version) INSTALLED_MLX_AUDIO_VERSION="$value" ;;
        transformers_version) INSTALLED_TRANSFORMERS_VERSION="$value" ;;
    esac
done <<< "$CORE_VERSIONS"

if [ -z "$INSTALLED_MLX_VERSION" ] || [ -z "$INSTALLED_MLX_METAL_VERSION" ] || [ -z "$INSTALLED_MLX_LM_VERSION" ] || [ -z "$INSTALLED_TRANSFORMERS_VERSION" ]; then
    rm -f "$TARBALL"
    echo "Error: Failed to capture installed core runtime versions"
    exit 1
fi
COMPATIBILITY_INFO=$("$PYTHON_BUNDLE/bin/python3" - "$SITE_PACKAGES" "$APP_MIN_MACOS_VERSION" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

site_packages = Path(sys.argv[1])
max_version = tuple(int(part) for part in sys.argv[2].split(".", 1))

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

def read_wheel_tag(prefix: str) -> str:
    matches = sorted(site_packages.glob(f"{prefix}*.dist-info"))
    if not matches:
        raise SystemExit(f"Missing dist-info directory for {prefix} in {site_packages}")
    wheel_path = matches[0] / "WHEEL"
    for line in wheel_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("Tag: "):
            return line.split(":", 1)[1].strip()
    raise SystemExit(f"Missing Tag entry in {wheel_path}")

mlx_tag = read_wheel_tag("mlx-")
mlx_metal_tag = read_wheel_tag("mlx_metal-")

for label, tag in (("mlx", mlx_tag), ("mlx-metal", mlx_metal_tag)):
    tag_version = parse_tag_version(tag)
    if tag_version > max_version:
        raise SystemExit(
            f"{label} wheel targets macOS {tag_version[0]}.{tag_version[1]}, "
            f"which exceeds supported minimum {max_version[0]}.{max_version[1]}"
        )

core_candidates = sorted((site_packages / "mlx").glob("core.cpython-*-darwin.so"))
if not core_candidates:
    raise SystemExit("Could not locate mlx core extension for min OS validation")
core_path = core_candidates[0]
otool_output = subprocess.check_output(["otool", "-l", str(core_path)], text=True)
minos_match = re.search(r"\bminos\s+(\d+\.\d+)", otool_output)
if not minos_match:
    raise SystemExit(f"Could not extract minos from {core_path}")
mlx_core_minos = minos_match.group(1)
if parse_version(mlx_core_minos) > max_version:
    raise SystemExit(
        f"mlx core extension minos is {mlx_core_minos}, "
        f"which exceeds supported minimum {max_version[0]}.{max_version[1]}"
    )

print(f"mlx_wheel_tag={mlx_tag}")
print(f"mlx_metal_wheel_tag={mlx_metal_tag}")
print(f"mlx_core_minos={mlx_core_minos}")
PY
)
MLX_WHEEL_TAG=""
MLX_METAL_WHEEL_TAG=""
MLX_CORE_MINOS=""
while IFS='=' read -r key value; do
    case "$key" in
        mlx_wheel_tag) MLX_WHEEL_TAG="$value" ;;
        mlx_metal_wheel_tag) MLX_METAL_WHEEL_TAG="$value" ;;
        mlx_core_minos) MLX_CORE_MINOS="$value" ;;
    esac
done <<< "$COMPATIBILITY_INFO"
if [ -z "$MLX_WHEEL_TAG" ] || [ -z "$MLX_METAL_WHEEL_TAG" ] || [ -z "$MLX_CORE_MINOS" ]; then
    rm -f "$TARBALL"
    echo "Error: Failed to capture bundled MLX compatibility metadata"
    exit 1
fi
echo "    All core imports OK"
echo "    mlx: $INSTALLED_MLX_VERSION"
echo "    mlx-metal: $INSTALLED_MLX_METAL_VERSION"
echo "    mlx-lm: $INSTALLED_MLX_LM_VERSION"
echo "    mlx-audio: $INSTALLED_MLX_AUDIO_VERSION"
echo "    transformers: $INSTALLED_TRANSFORMERS_VERSION"
echo "    mlx wheel tag: $MLX_WHEEL_TAG"
echo "    mlx-metal wheel tag: $MLX_METAL_WHEEL_TAG"
echo "    mlx core minos: $MLX_CORE_MINOS"

# Step 3b: Write runtime manifest
echo "    Writing runtime manifest..."
cat > "$MANIFEST_PATH" <<EOF
{
  "python_version": "$EXTRACTED_VERSION",
  "python_short_version": "$PYTHON_SHORT_VERSION",
  "requirements_path": "$REQUIREMENTS",
  "requirements_sha256": "$REQUIREMENTS_HASH",
  "mlx_version": "$INSTALLED_MLX_VERSION",
  "mlx_metal_version": "$INSTALLED_MLX_METAL_VERSION",
  "mlx_lm_version": "$INSTALLED_MLX_LM_VERSION",
  "mlx_audio_version": "$INSTALLED_MLX_AUDIO_VERSION",
  "transformers_version": "$INSTALLED_TRANSFORMERS_VERSION",
  "mlx_wheel_tag": "$MLX_WHEEL_TAG",
  "mlx_metal_wheel_tag": "$MLX_METAL_WHEEL_TAG",
  "mlx_core_minos": "$MLX_CORE_MINOS",
  "supported_minimum_macos": "$APP_MIN_MACOS_VERSION",
  "used_vendor_wheels": true,
  "built_at_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# Step 4: Strip unnecessary files to reduce size
echo "[4/5] Stripping unnecessary files..."

# Remove __pycache__ directories
find "$PYTHON_BUNDLE" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Remove .pyc files
find "$PYTHON_BUNDLE" -name "*.pyc" -delete 2>/dev/null || true

# Remove test directories
find "$PYTHON_BUNDLE" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true
find "$PYTHON_BUNDLE" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true

# Remove documentation
find "$PYTHON_BUNDLE" -type d -name "docs" -exec rm -rf {} + 2>/dev/null || true
find "$PYTHON_BUNDLE" -type d -name "doc" -exec rm -rf {} + 2>/dev/null || true

# Remove pip/setuptools/wheel (not needed at runtime)
rm -rf "$SITE_PACKAGES/pip" 2>/dev/null || true
rm -rf "$SITE_PACKAGES/setuptools" 2>/dev/null || true
rm -rf "$SITE_PACKAGES/wheel" 2>/dev/null || true

# Remove share/man directories
rm -rf "$PYTHON_BUNDLE/share" 2>/dev/null || true

# Step 5: Report size
BUNDLE_SIZE=$(du -sh "$PYTHON_BUNDLE" | cut -f1)
echo "[5/5] Done!"
echo ""
echo "Python bundle: $PYTHON_BUNDLE"
echo "Bundle size: $BUNDLE_SIZE"
echo "Runtime manifest: $MANIFEST_PATH"
echo ""
echo "To sign for distribution:"
echo "  codesign --force --sign 'Developer ID Application: YOUR_NAME' --options runtime '$PYTHON_BUNDLE/bin/python3'"
echo "  find '$PYTHON_BUNDLE' -name '*.so' -exec codesign --force --sign 'Developer ID Application: YOUR_NAME' --options runtime {} \\;"
