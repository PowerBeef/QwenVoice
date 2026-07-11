#!/usr/bin/env bash
# scripts/clean_build_caches.sh — free disk space by removing regenerable
# build/cache artifacts (and, opt-in, the dev model cache). Doubles as a
# disk-doctor: it always prints a reclaimable inventory first.
#
# Tiers (additive):
#   default        Always-safe items: release outputs/logs, the legacy
#                  build/Debug+build/Release split, retired-harness leftovers,
#                  and the throwaway iOS build sidecars (build/ios-uitest,
#                  build/ios-diagnostics, build/ios-diag-check, legacy build/ios-device).
#   --aggressive   Also build/DerivedData, build/foundation, the consolidated
#                  build/ios tree, and the vendored mlx-audio-swift/.build
#                  (next build is slower while those rebuild).
#   --models       Also ~/Library/Application Support/QwenVoice-Debug/models — the
#                  dev model cache (re-downloads from Hugging Face on the next
#                  debug/bench run). Usually the single biggest reclaim (~15 GB).
#   --prune-ui-results
#                  Remove failed/older build/ui-tests runs while retaining the
#                  newest passed smoke and benchmark for each platform.
#   --ui-keep N    With --prune-ui-results, retain N passed results per lane
#                  (default 1; at least one verified result is always retained).
#   --all          == --aggressive --models
#   --dry-run, -n  Print the inventory + what would be removed; remove nothing.
#
# Always preserved by default (no flags): build/DerivedData + build/foundation +
# build/ios (incremental caches) and build/Vocello.app (the live build). The
# shipped app's ~/Library/Application Support/QwenVoice/models is reported but
# NEVER removed by this script.
#
# The repo's .gitignore excludes build/, .build/, DerivedData/ — nothing removed
# here is version-controlled. See .agents/release-qa-engineer.md "Storage hygiene".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
VENDORED_BUILD="$REPO_ROOT/third_party_patches/mlx-audio-swift/.build"
DEBUG_MODELS="$HOME/Library/Application Support/QwenVoice-Debug/models"
SHIPPED_MODELS="$HOME/Library/Application Support/QwenVoice/models"

aggressive=false
models=false
dry_run=false
prune_ui_results=false
ui_keep=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --aggressive) aggressive=true; shift ;;
        --models) models=true; shift ;;
        --prune-ui-results) prune_ui_results=true; shift ;;
        --ui-keep) ui_keep="${2:-}"; shift 2 ;;
        --ui-keep=*) ui_keep="${1#*=}"; shift ;;
        --all) aggressive=true; models=true; shift ;;
        --dry-run|-n) dry_run=true; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: clean_build_caches.sh [--aggressive] [--models] [--prune-ui-results] [--ui-keep N] [--all] [--dry-run|-n]

  (default)     Remove always-safe artifacts: release outputs/logs, the legacy
                build/Debug+Release split, retired-harness leftovers, and the
                throwaway iOS sidecars (ios-uitest, ios-diagnostics,
                ios-diag-check, legacy ios-device).
  --aggressive  Also build/DerivedData, build/foundation, build/ios, and the
                vendored mlx-audio-swift/.build (slower next build).
  --models      Also ~/Library/Application Support/QwenVoice-Debug/models — the
                dev model cache (~15 GB; re-downloads on next debug/bench run).
  --prune-ui-results
                Remove failed and superseded build/ui-tests runs. Retains the
                newest passed result for every platform/lane by default.
  --ui-keep N   Retain N passed results per platform/lane while pruning
                (default 1; N must be at least 1).
  --all         == --aggressive --models
  --dry-run, -n Print the inventory + what would be removed; remove nothing.
  -h, --help    Show this help.

Always reported but never removed: the shipped app's QwenVoice/models.
See the header in scripts/clean_build_caches.sh for the exact retention policy.
EOF
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ "$ui_keep" =~ ^[0-9]+$ && "$ui_keep" -ge 1 ]] \
    || { echo "--ui-keep must be an integer of at least 1" >&2; exit 2; }

# Human-readable size of an existing path (empty if absent/unreadable). Uses the
# `read` builtin to parse `du -sh` (no awk/cut dependency).
human() { local sz _r; read -r sz _r < <(du -sh "$1" 2>/dev/null) || true; printf '%s' "${sz:-}"; }

remove_path() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    local size; size="$(human "$target")"
    if $dry_run; then
        printf 'would-remove: %-8s %s\n' "${size:-?}" "$target"
    else
        rm -rf "$target"
        printf 'removed:      %-8s %s\n' "${size:-?}" "$target"
    fi
}

cd "$REPO_ROOT"

# --- Inventory (report-only) ----------------------------------------------
echo "==> Reclaimable inventory:"
report() { [[ -e "$1" ]] && printf '    %-8s %s  [%s]\n' "$(human "$1")" "$1" "$2" || true; }
report "$BUILD_DIR" "build/ total"
report "$BUILD_DIR/DerivedData" "--aggressive"
report "$BUILD_DIR/ios" "--aggressive"
report "$BUILD_DIR/ui-tests" "--prune-ui-results (keeps ${ui_keep} passed result(s) per platform/lane)"
report "$VENDORED_BUILD" "--aggressive"
report "$DEBUG_MODELS" "--models"
report "$SHIPPED_MODELS" "report-only (never removed)"
echo

# --- always-safe ----------------------------------------------------------
echo "==> Cleaning always-safe build artifacts ..."
# Release outputs (regenerated by release.sh).
remove_path "$BUILD_DIR/Vocello-macos26.dmg"
remove_path "$BUILD_DIR/release-build-settings.log"
remove_path "$BUILD_DIR/release-metadata.txt"
remove_path "$BUILD_DIR/xcodebuild-release.log"
# Legacy dual-folder split + retired harness leftovers.
remove_path "$BUILD_DIR/Debug"
remove_path "$BUILD_DIR/Release"
remove_path "$BUILD_DIR/uitest"
remove_path "$BUILD_DIR/audio-qc"
remove_path "$BUILD_DIR/instruments-traces"
remove_path "$BUILD_DIR/ui-bench"
remove_path "$BUILD_DIR/harness"
# Retired Computer Use, mirror, coordinate/vision, review, and pre-XCUITest
# evidence. These paths are never produced by the current native XCUITest stack.
remove_path "$BUILD_DIR/computer-use-routing-openai-issue.md"
remove_path "$BUILD_DIR/cache/mirror_state_ocr"
remove_path "$BUILD_DIR/pilot-mirror-shot.png"
remove_path "$BUILD_DIR/macos/agent-ui"
remove_path "$BUILD_DIR/macos/review-shots"
remove_path "$BUILD_DIR/macos/uitest-artifacts"
remove_path "$BUILD_DIR/macos/uitest-measure"
remove_path "$BUILD_DIR/macos/uitest-screenshots"
for target in "$BUILD_DIR"/macos/gate-*/ui-attestation.log; do
    [[ -e "$target" ]] && remove_path "$target"
done
for target in "$BUILD_DIR"/macos/bench-ui-xpc-*; do
    [[ -e "$target" ]] && remove_path "$target"
done
remove_path "$BUILD_DIR/ios/agent-ui"
remove_path "$BUILD_DIR/ios/agent-test-mirror.png"
remove_path "$BUILD_DIR/ios/mobile-mcp-spike"
remove_path "$BUILD_DIR/ios/review-shots"
remove_path "$BUILD_DIR/ios/uitest-artifacts"
for target in \
    "$BUILD_DIR"/ios/bench-ui-* \
    "$BUILD_DIR"/ios/bench-pilot-* \
    "$BUILD_DIR"/ios/bench-ui-mirroir-* \
    "$BUILD_DIR"/ios/bench-ui-vision-* \
    "$BUILD_DIR"/ios/*mirror*.png \
    "$BUILD_DIR"/ios/post-setup-mirror.png \
    "$BUILD_DIR"/ios/vision-*; do
    [[ -e "$target" ]] && remove_path "$target"
done
# Throwaway iOS build sidecars (hybrid on-device test method, scripts/ios_device.sh).
remove_path "$BUILD_DIR/ios-uitest"
remove_path "$BUILD_DIR/ios-diagnostics"
remove_path "$BUILD_DIR/ios-diag-check"
remove_path "$BUILD_DIR/ios-device"

if $prune_ui_results && [[ -d "$BUILD_DIR/ui-tests" ]]; then
    echo "==> --prune-ui-results: removing failed and superseded XCUITest runs (keeping $ui_keep passed per platform/lane) ..."
    prune_list="$(mktemp)"
    python3 - "$BUILD_DIR/ui-tests" "$ui_keep" >"$prune_list" <<'PY'
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
keep_count = int(sys.argv[2])
passed = {}
all_runs = []
for platform in ("macos", "ios"):
    platform_root = root / platform
    if not platform_root.is_dir():
        continue
    for run in platform_root.iterdir():
        if not run.is_dir():
            continue
        all_runs.append(run)
        try:
            payload = json.loads((run / "run.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        lane = payload.get("lane")
        if payload.get("status") == "passed" and lane in {"smoke", "benchmark"}:
            passed.setdefault((platform, lane), []).append(run)

retained = set()
for runs in passed.values():
    retained.update(sorted(runs, key=lambda path: (path.stat().st_mtime_ns, path.name), reverse=True)[:keep_count])
for run in sorted(set(all_runs) - retained):
    sys.stdout.buffer.write(os.fsencode(run) + b"\0")
PY
    while IFS= read -r -d '' target; do
        remove_path "$target"
    done <"$prune_list"
    rm -f "$prune_list"
fi

if $aggressive; then
    echo "==> --aggressive: also wiping DerivedData + foundation + build/ios + vendored .build (slower next build) ..."
    remove_path "$BUILD_DIR/DerivedData"
    remove_path "$BUILD_DIR/foundation"
    remove_path "$BUILD_DIR/ios"
    remove_path "$VENDORED_BUILD"
fi

if $models; then
    echo "==> --models: also wiping the dev model cache (re-downloads on next debug/bench run) ..."
    remove_path "$DEBUG_MODELS"
fi

echo "==> Done."
if $dry_run; then
    echo "    (dry-run; no files removed)"
fi
if [[ -e "$SHIPPED_MODELS" ]]; then
    echo "==> Note: shipped-app models KEPT ($(human "$SHIPPED_MODELS")) at: $SHIPPED_MODELS"
fi
if [[ -d "$BUILD_DIR" ]]; then
    echo "==> build/ size after cleanup:"
    du -sh "$BUILD_DIR" 2>/dev/null || true
fi
