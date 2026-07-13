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

# shellcheck source=lib/build_paths.sh
. "$SCRIPT_DIR/lib/build_paths.sh"

APP_NAME="Vocello"
SCHEME_NAME="QwenVoice"
BUNDLE_ID="com.qwenvoice.app"
DESTINATION="platform=macOS,arch=arm64"

BUILD_DIR="$QVOICE_BUILD_ROOT"
DERIVED_DATA="$QVOICE_XCODE_MACOS_DERIVED"
SOURCE_PACKAGES_DIR="$QVOICE_XCODE_SOURCE_PACKAGES"
XCODEBUILD_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
export BUILD_CACHE_DIR="$SOURCE_PACKAGES_DIR/.qwenvoice-cache"

# shellcheck source=lib/build_cache.sh
. "$SCRIPT_DIR/lib/build_cache.sh"
# shellcheck source=lib/dev_signing.sh
. "$SCRIPT_DIR/lib/dev_signing.sh"

usage() {
    cat <<EOF
usage: scripts/build.sh <command> [options]

commands:
  build                 Fast local build (-Onone). No launch. (alias: debug)
  run [--logs|--telemetry|--verify|--debug]
                        Build, then launch $APP_NAME.app.
  release [args...]     Run scripts/release.sh (optimized DMG) with the shared regen/SPM cache.
  cli [args...]         Build the headless vocello CLI (build/vocello); runs it if args are given.
  clean                 Bounded cache cleanup (equivalent to --aggressive).
  clobber --yes         Remove all ignored repository-local generated state.
  help                  Show this message.

One shippable config; this builds it -Onone for speed, release.sh builds it -O.
Build ownership is defined by config/build-output-policy.json.
Set QWENVOICE_DEBUG=1 to launch with the runtime debug toggle on.
EOF
}

build_app() {
    ensure_project_regenerated
    ensure_spm_resolved "$QVOICE_SCRATCH_PACKAGE_RESOLUTION" "$SOURCE_PACKAGES_DIR" \
        dev QwenVoice Release "$DESTINATION"

    # Stable dev signing: a real Apple Development identity keeps the app's
    # designated requirement constant across rebuilds, so TCC grants
    # (mic/speech) survive the dev loop. Hardened runtime stays OFF for dev
    # builds (matching the old ad-hoc behavior, and keeping lldb attachable
    # via the injected get-task-allow); release.sh re-signs with
    # `--options runtime` for the DMG. See scripts/lib/dev_signing.sh.
    local signing_identity
    signing_identity="$(resolve_dev_signing_identity)"
    if [ "$signing_identity" = "-" ]; then
        echo "==> warning: no Apple Development identity found; signing ad-hoc — TCC grants (mic/speech) will NOT survive rebuilds" >&2
    else
        echo "==> Code signing identity: $signing_identity"
    fi
    sync_dev_signing_cache "$signing_identity" "$XCODEBUILD_APP" "$APP_BUNDLE"

    echo "==> Building $SCHEME_NAME (single config, -Onone dev build, $DESTINATION)..."
    xcb_run \
        -project "$ROOT_DIR/QwenVoice.xcodeproj" \
        -scheme "$SCHEME_NAME" \
        -configuration Release \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$signing_identity" \
        ENABLE_HARDENED_RUNTIME=NO \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        SWIFT_OPTIMIZATION_LEVEL="-Onone" \
        SWIFT_COMPILATION_MODE="incremental" \
        GCC_OPTIMIZATION_LEVEL="0" \
        build

    if [ ! -d "$XCODEBUILD_APP" ]; then
        echo "error: built app bundle not found at $XCODEBUILD_APP" >&2
        exit 1
    fi
    assert_macos_bundle_arm64_only "$XCODEBUILD_APP"
    assert_signing_identity "$XCODEBUILD_APP" "$signing_identity"
    assert_signing_identity "$XCODEBUILD_APP/Contents/XPCServices/QwenVoiceEngineService.xpc" "$signing_identity"
    if [ -e "$APP_BUNDLE" ] || [ -L "$APP_BUNDLE" ]; then
        quit_app_if_running
        rm -rf "$APP_BUNDLE"
    fi
    ln -s "${XCODEBUILD_APP#"$BUILD_DIR"/}" "$APP_BUNDLE"
    if [ ! -x "$APP_BINARY" ]; then
        echo "error: built app binary not found at $APP_BINARY" >&2
        exit 1
    fi
    assert_signing_identity "$APP_BUNDLE" "$signing_identity"
    assert_signing_identity "$APP_BUNDLE/Contents/XPCServices/QwenVoiceEngineService.xpc" "$signing_identity"
    record_dev_signing_identity "$signing_identity"
    preserve_dsyms
    local signing_class="apple-development"
    [[ "$signing_identity" != "-" ]] || signing_class="ad-hoc"
    write_build_provenance "$DERIVED_DATA/last-build.json" \
        "scripts/build.sh build" "$SCHEME_NAME" Release "$DESTINATION" arm64 \
        Onone "$signing_class" "$DERIVED_DATA" "$SOURCE_PACKAGES_DIR"
    write_build_provenance "$QVOICE_SYMBOLS_MACOS/last-build.json" \
        "scripts/build.sh build" "$SCHEME_NAME" Release "$DESTINATION" arm64 \
        Onone "$signing_class" "$DERIVED_DATA" "$SOURCE_PACKAGES_DIR"
    echo "==> Build ready: $APP_BUNDLE"
    prune_stale_builds
}

# Preserve this build's dSYMs (app + XPC service + any others) so
# scripts/macos_test.sh crashes can symbolicate .ips reports. Keyed by build version.
preserve_dsyms() {
    local dsym_dst="$QVOICE_SYMBOLS_MACOS"
    local products="$DERIVED_DATA/Build/Products/Release"
    preserve_macos_dsyms "$products" "$APP_BUNDLE" "$dsym_dst"
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

CLI_TARGET="VocelloCLI"
CLI_BINARY="$BUILD_DIR/vocello"
CLI_BUILT="$DERIVED_DATA/Build/Products/Release/vocello"

build_cli() {
    ensure_project_regenerated
    ensure_spm_resolved "$QVOICE_SCRATCH_PACKAGE_RESOLUTION" "$SOURCE_PACKAGES_DIR" \
        dev QwenVoice Release "$DESTINATION"

    # XcodeGen 2.45.4 SIGTRAPs when it directly emits a scheme for a `tool`
    # product. regenerate_project.sh renders the checked-in CLI scheme template
    # after generation, letting this lane share the canonical macOS DerivedData
    # without leaking module/index state into Xcode's global cache.
    echo "==> Building $CLI_TARGET (vocello, single config, -Onone)..."
    xcb_run \
        -project "$ROOT_DIR/QwenVoice.xcodeproj" \
        -scheme "$CLI_TARGET" \
        -configuration Release \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -onlyUsePackageVersionsFromResolvedFile \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
        -disableAutomaticPackageResolution \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        SWIFT_OPTIMIZATION_LEVEL="-Onone" \
        SWIFT_COMPILATION_MODE="incremental" \
        GCC_OPTIMIZATION_LEVEL="0" \
        build

    if [ ! -x "$CLI_BUILT" ]; then
        echo "error: vocello binary not found at $CLI_BUILT" >&2
        exit 1
    fi
    # Run IN PLACE: MLX's Metal shader bundle (mlx-swift_Cmlx.bundle, holding
    # default.metallib) and the other SPM resource bundles live next to this
    # binary — copying it elsewhere breaks metallib lookup. Expose a convenience
    # symlink at build/vocello; macOS resolves it to the real path, so the
    # bundles stay adjacent.
    rm -f "$CLI_BINARY"
    ln -s "${CLI_BUILT#"$BUILD_DIR"/}" "$CLI_BINARY"
    assert_macho_arm64_only "$CLI_BUILT" "vocello CLI"
    write_build_provenance "$DERIVED_DATA/last-build.json" \
        "scripts/build.sh cli" "$CLI_TARGET" Release "$DESTINATION" arm64 \
        Onone ad-hoc "$DERIVED_DATA" "$SOURCE_PACKAGES_DIR"
    echo "==> CLI ready: $CLI_BINARY → $CLI_BUILT"
}

cmd_cli() {
    build_cli
    # Invoke the in-place binary (bundles adjacent) — pass args straight through.
    if [ "$#" -gt 0 ]; then
        echo "==> Running: vocello $*"
        "$CLI_BUILT" "$@"
    fi
}

cmd_release() {
    exec "$SCRIPT_DIR/release.sh" "$@"
}

cmd_clean() {
    exec "$SCRIPT_DIR/clean_build_caches.sh" --aggressive
}

cmd_clobber() {
    [[ "${1:-}" == "--yes" && $# -eq 1 ]] || {
        echo "error: clobber requires the explicit confirmation: scripts/build.sh clobber --yes" >&2
        exit 2
    }
    exec "$SCRIPT_DIR/clean_build_caches.sh" --clobber --yes
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
        cli)
            cmd_cli "$@"
            ;;
        release)
            cmd_release "$@"
            ;;
        clean)
            cmd_clean
            ;;
        clobber)
            cmd_clobber "$@"
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
