#!/bin/bash
set -euo pipefail

# Bundle Python 3.12 arm64 + required packages into the app's Resources/python/
# Target: QwenVoice.app/Contents/Resources/python/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/QwenVoice/Resources"
PYTHON_BUNDLE="$RESOURCES_DIR/python"
REQUIREMENTS="$SCRIPT_DIR/../../../Qwen-Voice/requirements.txt"

PYTHON_VERSION="3.12"
PYTHON_BUILD_STANDALONE_VERSION="20241219"
PYTHON_BUILD_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_BUILD_STANDALONE_VERSION}/cpython-${PYTHON_VERSION}.8+${PYTHON_BUILD_STANDALONE_VERSION}-aarch64-apple-darwin-install_only.tar.gz"

echo "=== Qwen Voice: Bundle Python ==="
echo ""

# Step 1: Download standalone Python
DOWNLOAD_DIR="/tmp/qwenvoice-python-build"
mkdir -p "$DOWNLOAD_DIR"

TARBALL="$DOWNLOAD_DIR/python-standalone.tar.gz"
if [ ! -f "$TARBALL" ]; then
    echo "[1/5] Downloading Python ${PYTHON_VERSION} (arm64 standalone)..."
    curl -L -o "$TARBALL" "$PYTHON_BUILD_STANDALONE_URL"
else
    echo "[1/5] Using cached Python download"
fi

# Step 2: Extract
echo "[2/5] Extracting Python..."
rm -rf "$PYTHON_BUNDLE"
mkdir -p "$PYTHON_BUNDLE"
tar xzf "$TARBALL" -C "$PYTHON_BUNDLE" --strip-components=1

# Step 3: Install required packages
echo "[3/5] Installing pip packages..."
"$PYTHON_BUNDLE/bin/python3" -m pip install --quiet --upgrade pip
"$PYTHON_BUNDLE/bin/python3" -m pip install --quiet -r "$REQUIREMENTS"

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
rm -rf "$PYTHON_BUNDLE/lib/python${PYTHON_VERSION}/site-packages/pip" 2>/dev/null || true
rm -rf "$PYTHON_BUNDLE/lib/python${PYTHON_VERSION}/site-packages/setuptools" 2>/dev/null || true
rm -rf "$PYTHON_BUNDLE/lib/python${PYTHON_VERSION}/site-packages/wheel" 2>/dev/null || true

# Remove share/man directories
rm -rf "$PYTHON_BUNDLE/share" 2>/dev/null || true

# Step 5: Report size
BUNDLE_SIZE=$(du -sh "$PYTHON_BUNDLE" | cut -f1)
echo "[5/5] Done!"
echo ""
echo "Python bundle: $PYTHON_BUNDLE"
echo "Bundle size: $BUNDLE_SIZE"
echo ""
echo "To sign for distribution:"
echo "  codesign --force --sign 'Developer ID Application: YOUR_NAME' --options runtime '$PYTHON_BUNDLE/bin/python3'"
echo "  find '$PYTHON_BUNDLE' -name '*.so' -exec codesign --force --sign 'Developer ID Application: YOUR_NAME' --options runtime {} \\;"
