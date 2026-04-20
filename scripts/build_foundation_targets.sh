#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-all}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOUNDATION_BUILD_ROOT="$ROOT_DIR/build/foundation/local-builds"
PROJECT_FILE="$ROOT_DIR/QwenVoice.xcodeproj"

usage() {
  cat >&2 <<'EOF'
usage: ./scripts/build_foundation_targets.sh [macos|ios|all]
EOF
}

prepare_paths() {
  mkdir -p "$FOUNDATION_BUILD_ROOT"
}

build_macos() {
  local derived_data_path="$FOUNDATION_BUILD_ROOT/macos-derived-data"
  local result_bundle_path="$FOUNDATION_BUILD_ROOT/qwenvoice-macos-build.xcresult"

  rm -rf "$derived_data_path" "$result_bundle_path"

  xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme QwenVoice \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    -resultBundlePath "$result_bundle_path" \
    -resultBundleVersion 3 \
    CODE_SIGNING_ALLOWED=NO \
    build
}

build_ios() {
  local derived_data_path="$FOUNDATION_BUILD_ROOT/ios-derived-data"
  local result_bundle_path="$FOUNDATION_BUILD_ROOT/vocello-ios-generic-build.xcresult"

  rm -rf "$derived_data_path" "$result_bundle_path"

  xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme VocelloiOS \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data_path" \
    -resultBundlePath "$result_bundle_path" \
    -resultBundleVersion 3 \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    build
}

prepare_paths

case "$MODE" in
  macos)
    build_macos
    ;;
  ios)
    build_ios
    ;;
  all)
    build_macos
    build_ios
    ;;
  *)
    usage
    exit 2
    ;;
esac
