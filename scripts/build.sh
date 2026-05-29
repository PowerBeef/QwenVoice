#!/usr/bin/env bash
# Unified local build entrypoint for QwenVoice / Vocello.
#
# Single shippable config: there is no separate Debug config. This builds the
# Release config UNOPTIMIZED (-Onone) for a fast local loop; scripts/release.sh
# builds the same config OPTIMIZED for the DMG. Debug capabilities are gated at
# runtime via DebugMode (env QWENVOICE_DEBUG=1 or the hidden version-tap toggle),
# not by a compile-time symbol.
#
# Skips XcodeGen regen when project.yml hasn't changed and SwiftPM resolve when
# Package.resolved hasn't changed, so back-to-back builds drop into xcodebuild.
#
# usage:
#   scripts/build.sh build            # fast local build, no launch (alias: debug)
#   scripts/build.sh run [--logs|--telemetry|--verify|--debug]
#   scripts/build.sh release [release.sh args...]
#   scripts/build.sh clean
#   scripts/build.sh help

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

APP_NAME="Vocello"
SCHEME_NAME="QwenVoice"
BUNDLE_ID="com.qwenvoice.app"
DESTINATION="platform=macOS,arch=arm64"

BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
XCODEBUILD_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUILD_CACHE_DIR="$BUILD_DIR/.cache"

# shellcheck source=lib/build_cache.sh
. "$SCRIPT_DIR/lib/build_cache.sh"

usage() {
    cat <<EOF
usage: scripts/build.sh <command> [options]

commands:
  build                 Fast local build (-Onone). No launch. (alias: debug)
  run [--logs|--telemetry|--verify|--debug]
                        Build, then launch $APP_NAME.app.
  release [args...]     Run scripts/release.sh (optimized DMG) with the shared regen/SPM cache.
  clean                 Remove build/.
  help                  Show this message.

One shippable config; this builds it -Onone for speed, release.sh builds it -O.
Cache lives under build/.cache/ and self-heals — delete build/ to force a full rebuild.
Set QWENVOICE_DEBUG=1 to launch with the runtime debug toggle on.
EOF
}

build_app() {
    ensure_project_regenerated
    ensure_spm_resolved "$DERIVED_DATA" "" dev

    echo "==> Building $SCHEME_NAME (single config, -Onone dev build, $DESTINATION)..."
    xcb_run \
        -project "$ROOT_DIR/QwenVoice.xcodeproj" \
        -scheme "$SCHEME_NAME" \
        -configuration Release \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -onlyUsePackageVersionsFromResolvedFile \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        SWIFT_OPTIMIZATION_LEVEL="-Onone" \
        SWIFT_COMPILATION_MODE="incremental" \
        GCC_OPTIMIZATION_LEVEL="0" \
        build

    if [ ! -d "$XCODEBUILD_APP" ]; then
        echo "error: built app bundle not found at $XCODEBUILD_APP" >&2
        exit 1
    fi
    if [ -d "$APP_BUNDLE" ]; then
        quit_app_if_running
        rm -rf "$APP_BUNDLE"
    fi
    cp -a "$XCODEBUILD_APP" "$APP_BUNDLE"
    if [ ! -x "$APP_BINARY" ]; then
        echo "error: built app binary not found at $APP_BINARY" >&2
        exit 1
    fi
    echo "==> Build ready: $APP_BUNDLE"
    prune_stale_builds
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

verify_launch() {
    sleep 1
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "error: $APP_NAME did not appear in the process list after launch" >&2
        exit 1
    fi
    echo "==> $APP_NAME launched"
}

stream_logs() {
    local predicate="$1"
    echo "==> Streaming logs for predicate: $predicate"
    /usr/bin/log stream --info --style compact --predicate "$predicate"
}

cmd_run() {
    local mode="${1:-run}"
    kill_running_app
    build_app
    case "$mode" in
        run|"")
            /usr/bin/open -na "$APP_BUNDLE"
            ;;
        --debug|debug)
            exec lldb -- "$APP_BINARY"
            ;;
        --logs|logs)
            /usr/bin/open -na "$APP_BUNDLE"
            verify_launch
            stream_logs "process == \"$APP_NAME\""
            ;;
        --telemetry|telemetry)
            /usr/bin/open -na "$APP_BUNDLE"
            verify_launch
            stream_logs "subsystem == \"$BUNDLE_ID\""
            ;;
        --verify|verify)
            /usr/bin/open -na "$APP_BUNDLE"
            verify_launch
            ;;
        *)
            echo "error: unknown run mode '$mode'" >&2
            usage
            exit 2
            ;;
    esac
}

cmd_release() {
    exec "$SCRIPT_DIR/release.sh" "$@"
}

cmd_clean() {
    if [ -d "$ROOT_DIR/build" ]; then
        echo "==> Removing $ROOT_DIR/build"
        rm -rf "$ROOT_DIR/build"
    else
        echo "==> Nothing to clean ($ROOT_DIR/build does not exist)"
    fi
}

main() {
    local command="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$command" in
        build|debug)
            build_app
            ;;
        run)
            cmd_run "$@"
            ;;
        release)
            cmd_release "$@"
            ;;
        clean)
            cmd_clean
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "error: unknown command '$command'" >&2
            usage
            exit 2
            ;;
    esac
}

main "$@"
