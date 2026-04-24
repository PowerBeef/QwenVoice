#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Vocello"
PROJECT_NAME="QwenVoice"
PROJECT_FILE="QwenVoice.xcodeproj"
SCHEME_NAME="QwenVoice"
CONFIGURATION="Debug"
DESTINATION="platform=macOS,arch=arm64"
BUNDLE_ID="com.qwenvoice.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

kill_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
}

build_app() {
  cd "$ROOT_DIR"
  xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
    build

  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: built app bundle not found at $APP_BUNDLE" >&2
    exit 1
  fi

  if [[ ! -x "$APP_BINARY" ]]; then
    echo "error: built app binary not found at $APP_BINARY" >&2
    exit 1
  fi
}

open_app() {
  /usr/bin/open -na "$APP_BUNDLE"
}

verify_launch() {
  sleep 1
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "error: $APP_NAME did not appear in the process list after launch" >&2
    exit 1
  fi
  echo "$APP_NAME launched successfully"
}

stream_logs() {
  local predicate="$1"
  echo "Streaming logs for predicate: $predicate"
  /usr/bin/log stream --info --style compact --predicate "$predicate"
}

kill_running_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    exec lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    verify_launch
    stream_logs "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    verify_launch
    stream_logs "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_launch
    ;;
  *)
    usage
    exit 2
    ;;
esac
