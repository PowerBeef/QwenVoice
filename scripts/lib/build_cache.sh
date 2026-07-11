# Shared build-cache helpers for QwenVoice / Vocello.
#
# Sourced by scripts/build.sh (debug/run path) and scripts/release.sh
# (release path) so that XcodeGen regeneration and SwiftPM resolution
# only run when their inputs have actually changed.
#
# Usage:
#
#   ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   . "$ROOT_DIR/scripts/lib/build_cache.sh"
#
#   ensure_project_regenerated
#   ensure_spm_resolved "<derived-data-path>" "<source-packages-dir-or-empty>" "<context-tag>"
#   xcb_run <xcodebuild args...>
#
# Callers must have set ROOT_DIR before sourcing or pass it explicitly.

# shellcheck shell=bash

if [ -z "${ROOT_DIR:-}" ]; then
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

BUILD_CACHE_DIR="${BUILD_CACHE_DIR:-$ROOT_DIR/build/.cache}"
PROJECT_YML="$ROOT_DIR/project.yml"
PROJECT_FILE="$ROOT_DIR/QwenVoice.xcodeproj"
PROJECT_RESOLVED="$PROJECT_FILE/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Print sha256 of a file, or empty string if the file is missing.
sha256_of() {
    local path="$1"
    if [ -f "$path" ]; then
        /usr/bin/shasum -a 256 "$path" | awk '{print $1}'
    fi
}

# Skip the XcodeGen regeneration step when project.yml hasn't changed
# since the project was last generated. On cache miss, run
# regenerate_project.sh (which also runs check_project_inputs.sh).
ensure_project_regenerated() {
    mkdir -p "$BUILD_CACHE_DIR"
    local cache_file="$BUILD_CACHE_DIR/project.yml.sha256"
    local current
    current="$(sha256_of "$PROJECT_YML")"
    if [ -z "$current" ]; then
        echo "error: project.yml not found at $PROJECT_YML" >&2
        return 1
    fi

    local cached=""
    if [ -f "$cache_file" ]; then
        cached="$(cat "$cache_file" 2>/dev/null || true)"
    fi

    if [ -d "$PROJECT_FILE" ] && [ "$current" = "$cached" ]; then
        echo "==> project.yml unchanged; skipping XcodeGen"
        return 0
    fi

    echo "==> Regenerating Xcode project (project.yml changed or project missing)..."
    bash "$ROOT_DIR/scripts/regenerate_project.sh"
    printf '%s\n' "$current" > "$cache_file"
}

# Skip `xcodebuild -resolvePackageDependencies` when Package.resolved
# hasn't changed since the last resolve for this <context_tag>.
#
# Args:
#   $1 = derived-data path (required)
#   $2 = cloned-source-packages dir, or empty to use the in-project default
#   $3 = context tag used to namespace the cache file (e.g. "debug", "release")
ensure_spm_resolved() {
    local derived_data="$1"
    local source_packages="$2"
    local context="$3"

    if [ -z "$derived_data" ] || [ -z "$context" ]; then
        echo "error: ensure_spm_resolved requires <derived-data> and <context>" >&2
        return 1
    fi

    mkdir -p "$BUILD_CACHE_DIR"
    local cache_file="$BUILD_CACHE_DIR/Package.resolved.sha256.$context"
    local current=""
    if [ -f "$PROJECT_RESOLVED" ]; then
        current="$(sha256_of "$PROJECT_RESOLVED")"
    fi

    local cached=""
    if [ -f "$cache_file" ]; then
        cached="$(cat "$cache_file" 2>/dev/null || true)"
    fi

    if [ -n "$current" ] && [ "$current" = "$cached" ]; then
        echo "==> Package.resolved unchanged for '$context'; skipping SPM resolve"
        return 0
    fi

    echo "==> Resolving Swift packages for '$context'..."
    local args=(
        -project "$PROJECT_FILE"
        -scheme QwenVoice
        -destination 'platform=macOS,arch=arm64'
        -derivedDataPath "$derived_data"
    )
    if [ -n "$source_packages" ]; then
        args+=(-clonedSourcePackagesDirPath "$source_packages")
    fi
    args+=(-resolvePackageDependencies)
    xcodebuild "${args[@]}"

    if [ -f "$PROJECT_RESOLVED" ]; then
        sha256_of "$PROJECT_RESOLVED" > "$cache_file"
    fi
}

# Gracefully terminate Vocello if it's running. SIGTERM, poll ~10s, then
# SIGKILL fallback. This helper is used only by build-cache maintenance;
# explicit UI acceptance owns its exact test-host process separately.
quit_app_if_running() {
    if ! pgrep -x Vocello >/dev/null 2>&1; then
        return 0
    fi
    echo "==> Quitting running Vocello before cleanup"
    pkill -x Vocello >/dev/null 2>&1 || true
    for _ in {1..40}; do
        if ! pgrep -x Vocello >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    pkill -9 -x Vocello >/dev/null 2>&1 || true
    sleep 0.5
}

# Remove the now-legacy dual-folder split (build/Debug + build/Release) and the
# retired uitest dir. The single-package layout lives directly under build/.
prune_legacy_build_layout() {
    local killed=false
    local path
    for path in \
        "$ROOT_DIR/build/Debug" \
        "$ROOT_DIR/build/Release" \
        "$ROOT_DIR/build/uitest"; do
        if [ -e "$path" ]; then
            if ! $killed; then
                quit_app_if_running
                killed=true
            fi
            echo "==> Removing legacy build layout item: $path"
            rm -rf "$path"
        fi
    done
}

# Single-resident policy for the one build/ folder. Keeps build/Vocello.app
# (staged by both build.sh and release.sh) and, when an output name is given
# (release), build/<output_name>.dmg; removes any other Vocello.app (outside
# DerivedData) or stray *.dmg. Leaves DerivedData intact for incremental builds.
prune_stale_builds() {
    local output_name="${1:-}"
    prune_legacy_build_layout

    # Reclaim a leftover foundation compile-safety DerivedData tree (1-2 GB each).
    # The foundation script removes these on exit, but a normal build also prunes
    # them here in case a prior run was interrupted before its trap fired — so only
    # the single active build/DerivedData tree ever persists.
    local foundation_root="$ROOT_DIR/build/foundation/local-builds"
    for stale in "$foundation_root/macos-derived-data" "$foundation_root/ios-derived-data"; do
        if [ -d "$stale" ]; then
            echo "==> Removing stale foundation build tree: $stale"
            rm -rf "$stale"
        fi
    done

    # Reclaim throwaway iOS build sidecars from the hybrid on-device test method
    # (scripts/ios_device.sh): the disposable build-for-testing sim tree, the pulled
    # diagnostics dirs (already copied off-device), and the legacy build/ios-device
    # tree (superseded by the single shared build/ios). The active build/ios and the
    # macOS build/DerivedData are KEPT as incremental caches.
    for stale in \
        "$ROOT_DIR/build/ios-uitest" \
        "$ROOT_DIR/build/ios-diagnostics" \
        "$ROOT_DIR/build/ios-diag-check" \
        "$ROOT_DIR/build/ios-device"; do
        if [ -e "$stale" ]; then
            echo "==> Removing throwaway iOS build sidecar: $stale"
            rm -rf "$stale"
        fi
    done

    local keep_app="$ROOT_DIR/build/Vocello.app"
    local killed=false
    while IFS= read -r -d '' candidate; do
        if [ "$candidate" = "$keep_app" ]; then
            continue
        fi
        if [[ "$candidate" == "$ROOT_DIR/build/DerivedData/"* ]]; then
            continue
        fi
        # Preserve the iOS app bundle in the shared iOS tree: a macOS build must not
        # clobber an in-progress iOS device/sim build (build/ios is its own
        # incremental tree, like build/DerivedData).
        if [[ "$candidate" == "$ROOT_DIR/build/ios/"* ]]; then
            continue
        fi
        if ! $killed; then
            quit_app_if_running
            killed=true
        fi
        echo "==> Removing stale build: $candidate"
        rm -rf "$candidate"
    done < <(find "$ROOT_DIR/build" -type d -name "Vocello.app" -prune -print0 2>/dev/null)

    if [ -n "$output_name" ]; then
        local keep_dmg="$ROOT_DIR/build/${output_name}.dmg"
        while IFS= read -r -d '' candidate; do
            if [ "$candidate" = "$keep_dmg" ]; then
                continue
            fi
            echo "==> Removing stale DMG: $candidate"
            rm -f "$candidate"
        done < <(find "$ROOT_DIR/build" -maxdepth 1 -type f -name '*.dmg' -print0 2>/dev/null)
    fi

    warn_if_storage_bloated
}

# Print a one-line reclaim hint if <dir> exceeds <limit_gb>. Advisory only; uses
# stat-based `du -sk` (fast) and is a no-op when the dir is absent.
_storage_warn_dir() {
    local path="$1" limit_gb="$2" label="$3" flag="${4:-}"
    [ -d "$path" ] || return 0
    # Parse `du -sk` with the `read` builtin (no awk/cut dependency on the hot path).
    local kb _rest limit_kb gb
    read -r kb _rest < <(du -sk "$path" 2>/dev/null) || true
    [ -n "${kb:-}" ] || return 0
    case "$kb" in ''|*[!0-9]*) return 0 ;; esac
    limit_kb=$(( limit_gb * 1024 * 1024 ))
    if [ "$kb" -gt "$limit_kb" ]; then
        gb=$(( kb / 1048576 ))
        echo "==> [storage] ${label} is ~${gb} GB (>${limit_gb} GB) — reclaim with: scripts/clean_build_caches.sh ${flag}" >&2
    fi
}

# Non-fatal advisory called after every build: warn when reclaimable storage crosses
# a soft threshold (the project build/ tree, or the dev model cache). NEVER deletes,
# NEVER blocks. Thresholds (GB) overridable via env: QWENVOICE_BUILD_WARN_GB,
# QWENVOICE_MODELS_WARN_GB.
warn_if_storage_bloated() {
    _storage_warn_dir "$ROOT_DIR/build" "${QWENVOICE_BUILD_WARN_GB:-12}" "build/" "--aggressive"
    _storage_warn_dir "$HOME/Library/Application Support/QwenVoice-Debug/models" \
        "${QWENVOICE_MODELS_WARN_GB:-10}" "QwenVoice-Debug/models" "--models"
}

# Run xcodebuild, piping output through xcbeautify when it's on PATH and
# stdout is a terminal. Preserves xcodebuild's exit code in both cases.
xcb_run() {
    if command -v xcbeautify >/dev/null 2>&1 && [ -t 1 ]; then
        set -o pipefail
        xcodebuild "$@" | xcbeautify --renderer terminal
        local status=${PIPESTATUS[0]}
        set +o pipefail
        return "$status"
    fi
    xcodebuild "$@"
}
