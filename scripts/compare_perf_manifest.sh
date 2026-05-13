#!/usr/bin/env bash
# Compare a fresh perf-lane generation-manifest.json against the
# committed baseline at scripts/perf-baseline-manifest.json. Prints
# regressions in wall-clock time, real-time factor, headline timing
# keys, and boolean flags.
#
# Designed for local use after running `./scripts/qa.sh test --layer perf`.
# Hosted CI does not run the perf lane (no installed models), so this is
# a developer-facing tool, not a CI gate.
#
# Usage: ./scripts/compare_perf_manifest.sh [<fresh-manifest>]
#   <fresh-manifest>: defaults to build/audio-qc/qa-perf/generation-manifest.json
#
# Tolerances (override via env):
#   QWENVOICE_PERF_WALL_TOLERANCE_PCT     default 15  (wallClockMS / realTimeFactor)
#   QWENVOICE_PERF_TIMING_TOLERANCE_PCT   default 25  (per-key timingsMS values)
#
# Exit codes:
#   0  — every comparison within tolerance + boolean flags identical
#   1  — at least one comparison drifted beyond tolerance OR flags diverged
#   2  — usage error / missing files / malformed JSON
#
# Note: piping this script's output through `tee`, `head`, etc. swallows
# the non-zero exit code unless your shell has `set -o pipefail` (or
# you read `${PIPESTATUS[0]}` instead of `$?`). See CLAUDE.md →
# "Shell pipeline exit codes" for the full discipline note.
#
# Headline metrics compared (top-level per artifact):
#   wallClockMS, realTimeFactor, durationSeconds
# Headline timingsMS keys compared (subset; full set is ~70 noisy keys):
#   load_model, first_audio_ready, generation, request_wall_ms,
#   prewarm_model, custom_prewarm_eval_ms, mlx_model_load
# Boolean-flag drift: ALL booleanFlags compared exactly.

set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly BASELINE_PATH="$PROJECT_DIR/scripts/perf-baseline-manifest.json"
readonly DEFAULT_FRESH_PATH="$PROJECT_DIR/build/audio-qc/qa-perf/generation-manifest.json"

readonly WALL_TOLERANCE_PCT="${QWENVOICE_PERF_WALL_TOLERANCE_PCT:-15}"
readonly TIMING_TOLERANCE_PCT="${QWENVOICE_PERF_TIMING_TOLERANCE_PCT:-25}"

# Headline timingsMS keys we surface with tolerance checks. Other timingsMS
# keys are diff'd for presence only (added/removed) — too noisy to
# threshold individually.
readonly HEADLINE_TIMING_KEYS=(
  "load_model"
  "first_audio_ready"
  "generation"
  "request_wall_ms"
  "prewarm_model"
  "custom_prewarm_eval_ms"
  "mlx_model_load"
)

usage() {
  cat <<EOF
Usage: ${0##*/} [<fresh-manifest>]

Compare <fresh-manifest> against the committed baseline at
$BASELINE_PATH and print regressions.

If <fresh-manifest> is omitted, defaults to:
  $DEFAULT_FRESH_PATH

Tolerances (env overrides):
  QWENVOICE_PERF_WALL_TOLERANCE_PCT    default $WALL_TOLERANCE_PCT  (wallClockMS, realTimeFactor)
  QWENVOICE_PERF_TIMING_TOLERANCE_PCT  default $TIMING_TOLERANCE_PCT  (timingsMS values)

Exit codes:
  0 - within tolerance, no flag drift
  1 - regression detected
  2 - usage / missing files / malformed JSON
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

FRESH_PATH="${1:-$DEFAULT_FRESH_PATH}"

if [[ ! -f "$BASELINE_PATH" ]]; then
  echo "error: baseline manifest not found at $BASELINE_PATH" >&2
  echo "       run scripts/capture_perf_baseline.sh to refresh it" >&2
  exit 2
fi
if [[ ! -f "$FRESH_PATH" ]]; then
  echo "error: fresh manifest not found at $FRESH_PATH" >&2
  echo "       run ./scripts/qa.sh test --layer perf first" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (install via mise: \`mise install ubi:jqlang/jq\`)" >&2
  exit 2
fi

# Validate both files parse as JSON.
if ! jq -e . "$BASELINE_PATH" >/dev/null 2>&1; then
  echo "error: baseline at $BASELINE_PATH is not valid JSON" >&2
  exit 2
fi
if ! jq -e . "$FRESH_PATH" >/dev/null 2>&1; then
  echo "error: fresh manifest at $FRESH_PATH is not valid JSON" >&2
  exit 2
fi

# Returns 0 if |a-b|/b > tolerance_pct, else 1. Both args numeric strings.
exceeds_tolerance() {
  local fresh="$1"
  local base="$2"
  local tolerance_pct="$3"
  awk -v f="$fresh" -v b="$base" -v t="$tolerance_pct" 'BEGIN {
    if (b == 0) { exit (f == 0 ? 1 : 0) }
    delta = (f - b) / b * 100
    if (delta < 0) delta = -delta
    exit (delta > t ? 0 : 1)
  }'
}

# Format a percent delta for display.
format_pct_delta() {
  local fresh="$1"
  local base="$2"
  awk -v f="$fresh" -v b="$base" 'BEGIN {
    if (b == 0) {
      print (f == 0 ? "  0.0%" : " +inf%")
      exit
    }
    delta = (f - b) / b * 100
    printf "%+.1f%%", delta
  }'
}

# Build artifact identity key from (mode, phase, runIndex, iteration).
# We compare artifacts pairwise on this key.
artifact_keys() {
  jq -r '.artifacts[] | "\(.mode)|\(.phase)|\(.runIndex)|\(.iteration)"' "$1"
}

BASELINE_KEYS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && BASELINE_KEYS+=("$line")
done < <(artifact_keys "$BASELINE_PATH")
FRESH_KEYS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && FRESH_KEYS+=("$line")
done < <(artifact_keys "$FRESH_PATH")

regressions=0
warnings=0

# Detect added / removed artifacts.
for key in "${FRESH_KEYS[@]}"; do
  if ! printf '%s\n' "${BASELINE_KEYS[@]}" | grep -qxF "$key"; then
    echo "ADDED:    $key (present in fresh, missing from baseline)"
    warnings=$((warnings + 1))
  fi
done
for key in "${BASELINE_KEYS[@]}"; do
  if ! printf '%s\n' "${FRESH_KEYS[@]}" | grep -qxF "$key"; then
    echo "REMOVED:  $key (present in baseline, missing from fresh)"
    warnings=$((warnings + 1))
  fi
done

# Compare each artifact pair (intersection of keys).
for key in "${BASELINE_KEYS[@]}"; do
  if ! printf '%s\n' "${FRESH_KEYS[@]}" | grep -qxF "$key"; then
    continue
  fi
  IFS='|' read -r mode phase runIndex iteration <<<"$key"

  jq_filter='.artifacts[] | select(.mode == "'"$mode"'" and .phase == "'"$phase"'" and .runIndex == '"$runIndex"' and .iteration == '"$iteration"')'

  base_artifact="$(jq -c "$jq_filter" "$BASELINE_PATH")"
  fresh_artifact="$(jq -c "$jq_filter" "$FRESH_PATH")"

  base_wall="$(jq -r '.wallClockMS // 0' <<<"$base_artifact")"
  fresh_wall="$(jq -r '.wallClockMS // 0' <<<"$fresh_artifact")"
  base_rtf="$(jq -r '.realTimeFactor // 0' <<<"$base_artifact")"
  fresh_rtf="$(jq -r '.realTimeFactor // 0' <<<"$fresh_artifact")"

  artifact_label="$mode/$phase/run$runIndex/iter$iteration"

  if exceeds_tolerance "$fresh_wall" "$base_wall" "$WALL_TOLERANCE_PCT"; then
    pct="$(format_pct_delta "$fresh_wall" "$base_wall")"
    echo "REGRESSION: $artifact_label  wallClockMS  baseline=$base_wall  fresh=$fresh_wall  $pct  (>${WALL_TOLERANCE_PCT}%)"
    regressions=$((regressions + 1))
  fi

  if exceeds_tolerance "$fresh_rtf" "$base_rtf" "$WALL_TOLERANCE_PCT"; then
    pct="$(format_pct_delta "$fresh_rtf" "$base_rtf")"
    echo "REGRESSION: $artifact_label  realTimeFactor  baseline=$base_rtf  fresh=$fresh_rtf  $pct  (>${WALL_TOLERANCE_PCT}%)"
    regressions=$((regressions + 1))
  fi

  # Headline timingsMS keys.
  for tkey in "${HEADLINE_TIMING_KEYS[@]}"; do
    base_t="$(jq -r ".timingsMS.\"$tkey\" // null" <<<"$base_artifact")"
    fresh_t="$(jq -r ".timingsMS.\"$tkey\" // null" <<<"$fresh_artifact")"

    if [[ "$base_t" == "null" && "$fresh_t" == "null" ]]; then continue; fi
    if [[ "$base_t" == "null" ]]; then
      echo "ADDED:    $artifact_label  timingsMS.$tkey  fresh=$fresh_t  (not in baseline)"
      warnings=$((warnings + 1))
      continue
    fi
    if [[ "$fresh_t" == "null" ]]; then
      echo "REMOVED:  $artifact_label  timingsMS.$tkey  baseline=$base_t  (missing from fresh)"
      warnings=$((warnings + 1))
      continue
    fi

    if exceeds_tolerance "$fresh_t" "$base_t" "$TIMING_TOLERANCE_PCT"; then
      pct="$(format_pct_delta "$fresh_t" "$base_t")"
      echo "REGRESSION: $artifact_label  timingsMS.$tkey  baseline=$base_t  fresh=$fresh_t  $pct  (>${TIMING_TOLERANCE_PCT}%)"
      regressions=$((regressions + 1))
    fi
  done

  # Boolean flag drift (every flag compared exactly).
  # jq's `//` operator treats `false` like `null` for the alternative
  # branch, which would mis-render `false` as `<missing>` in the display.
  # Use explicit `has` + ternary to distinguish missing keys from false
  # values.
  flag_diff="$(jq -nr --argjson b "$base_artifact" --argjson f "$fresh_artifact" '
    ($b.booleanFlags // {}) as $bb |
    ($f.booleanFlags // {}) as $ff |
    ($bb | keys_unsorted) + ($ff | keys_unsorted) | unique | .[] | . as $k |
    (if $bb | has($k) then ($bb[$k] | tostring) else "<missing>" end) as $bv |
    (if $ff | has($k) then ($ff[$k] | tostring) else "<missing>" end) as $fv |
    if $bv != $fv then "  \($k): baseline=\($bv)  fresh=\($fv)" else empty end
  ')"
  if [[ -n "$flag_diff" ]]; then
    echo "FLAG-DRIFT: $artifact_label"
    while IFS= read -r line; do
      echo "  $line"
    done <<<"$flag_diff"
    regressions=$((regressions + 1))
  fi
done

echo
echo "==> baseline:  $BASELINE_PATH"
echo "==> fresh:     $FRESH_PATH"
echo "==> tolerances: wall=±${WALL_TOLERANCE_PCT}%  timing=±${TIMING_TOLERANCE_PCT}%"
echo "==> regressions: $regressions"
echo "==> warnings:    $warnings  (added/removed artifacts or timingsMS keys)"

if (( regressions > 0 )); then
  exit 1
fi
exit 0
