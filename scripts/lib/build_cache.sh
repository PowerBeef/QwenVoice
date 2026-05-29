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
# SIGKILL fallback. Mirrors the kill pattern in build.sh and
# build_and_run.sh so behavior is consistent across entrypoints.
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

    local keep_app="$ROOT_DIR/build/Vocello.app"
    local killed=false
    while IFS= read -r -d '' candidate; do
        if [ "$candidate" = "$keep_app" ]; then
            continue
        fi
        if [[ "$candidate" == "$ROOT_DIR/build/DerivedData/"* ]]; then
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
