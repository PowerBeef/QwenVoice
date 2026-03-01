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

# --- How to update the Python standalone URL ---
# The URL above points to a specific release from astral-sh/python-build-standalone.
# If this release is removed or you want a newer Python patch version:
#   1. Visit https://github.com/astral-sh/python-build-standalone/releases
#   2. Find the latest release tag (e.g. 20260301)
#   3. Look for the asset named: cpython-3.13.X+YYYYMMDD-aarch64-apple-darwin-install_only.tar.gz
#   4. Update PYTHON_BUILD_STANDALONE_VERSION and the minor version in the URL above
# The "install_only" variant is a pre-built, relocatable Python — no compilation needed.

echo "=== Qwen Voice: Bundle Python ==="
echo ""

EXPECTED_MLX_AUDIO_VERSION="$(grep -E '^mlx-audio==' "$REQUIREMENTS" | head -n 1 | sed 's/^mlx-audio==//')"
if [ -z "$EXPECTED_MLX_AUDIO_VERSION" ]; then
    echo "Error: Could not determine pinned mlx-audio version from $REQUIREMENTS"
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

# Validate core imports
echo "    Validating core imports..."
if ! "$PYTHON_BUNDLE/bin/python3" -c "import mlx; import mlx_audio; import transformers; import numpy; import soundfile" 2>&1; then
    rm -f "$TARBALL"
    echo "Error: Core import validation failed — one or more packages did not install correctly"
    exit 1
fi
if ! "$PYTHON_BUNDLE/bin/python3" -c "import huggingface_hub" 2>&1; then
    rm -f "$TARBALL"
    echo "Error: huggingface_hub import validation failed"
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
echo "    All core imports OK"
echo "    mlx-audio: $INSTALLED_MLX_AUDIO_VERSION"

# Step 3b: Write runtime manifest
echo "    Writing runtime manifest..."
cat > "$MANIFEST_PATH" <<EOF
{
  "python_version": "$EXTRACTED_VERSION",
  "python_short_version": "$PYTHON_SHORT_VERSION",
  "requirements_path": "$REQUIREMENTS",
  "requirements_sha256": "$REQUIREMENTS_HASH",
  "mlx_audio_version": "$INSTALLED_MLX_AUDIO_VERSION",
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
