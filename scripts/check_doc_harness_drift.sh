#!/usr/bin/env bash
# Fail when authoritative docs re-introduce retired UI-testing harness guidance.
#
# Usage: scripts/check_doc_harness_drift.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { printf '\033[0;31m[doc-drift]\033[0m %s\n' "$*" >&2; exit 1; }

if ! command -v rg >/dev/null 2>&1; then
  echo "warn: ripgrep not found — skipping doc harness drift check" >&2
  exit 0
fi

echo "==> doc harness drift check" >&2

EXCLUDES=(
  --glob '!build/**'
  --glob '!website/**'
  --glob '!docs/post-mortem/**'
  --glob '!docs/releases/**'
  --glob '!docs/reference/on-device-ui-testing-research-report.md'
  --glob '!docs/reference/computer-use-mcp-pilot-log.md'
  --glob '!docs/reference/ui-smoke-runbooks.md'
  --glob '!docs/reference/computer-use-mcp-alternatives-cursor.md'
  --glob '!docs/reference/ios-device-testing.md'
  --glob '!docs/reference/benchmarking-procedure.md'
  --glob '!docs/reference/mobile-mcp-ios-evaluation.md'
)

PATHS=(AGENTS.md .cursor/rules .agents docs/reference)

if out="$(rg -n -i 'Phase 3 \(in-app Speech|Phase 3.*not yet implemented' "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"; then
  [[ -z "$out" ]] || fail "Phase 3 not-yet-implemented stale claim:\n$out"
fi

if out="$(rg -n -i 'centered mirror|mirror window is kept centered|centered on the Mac display for stable Peekaboo' "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"; then
  [[ -z "$out" ]] || fail "centered mirror window policy (use calibrate-after-move):\n$out"
fi

if out="$(rg -n 'scripts/uitest\.sh' "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! echo "$line" | rg -qi 'deleted|historical|retired|replaced|removed|DEPRECATED|gone|6d1cca4|Restored'; then
      fail "scripts/uitest.sh without deleted/historical context:\n$line"
    fi
  done <<< "$out"
fi

if out="$(rg -n 'bench-ui-mirroir' "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    file="${line%%:*}"
    if ! rg -qi 'deprecated|DEPRECATED|legacy|historical|superseded|retired|archived|do not' "$file" 2>/dev/null; then
      fail "bench-ui-mirroir without deprecated context in $file:\n$line"
    fi
  done <<< "$out"
fi

if out="$(rg -n 'bench-ui-vision' "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    file="${line%%:*}"
    if ! rg -qi 'deprecated|DEPRECATED|legacy|historical|superseded|emergency|do not' "$file" 2>/dev/null; then
      fail "bench-ui-vision without deprecated context in $file:\n$line"
    fi
  done <<< "$out"
fi

if out="$(rg -n -i 'platform=iOS Simulator|build_run_sim' "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if echo "$line" | rg -qi 'never|not use|cannot|off-limits|compile-only|no XCUITest|do not|hard.?ban|is not used'; then
      continue
    fi
    fail "iOS Simulator as test destination:\n$line"
  done <<< "$out"
fi

MAC_ACTIVE=(
  AGENTS.md README.md .agents/backend-mlx.md .agents/macos-engineer.md
  .agents/release-qa-engineer.md docs/ARCHITECTURE.md docs/project-map.html
  docs/reference/macos-app-guide.md docs/reference/macos-testing.md
  docs/reference/macos-release-qa.md docs/reference/macos-permissions.md
  docs/reference/testing-runbook.md docs/reference/telemetry-and-benchmarking.md
  docs/reference/benchmarking-procedure.md
)
if out="$(rg -n -i 'VocelloMacUITests|macos_uitest_doctor|scripts/uitest_measure\.sh|macos_test\.sh journey|macos_test\.sh uitest-doctor|MacUITestSurfaceMarkers' "${MAC_ACTIVE[@]}" 2>/dev/null || true)"; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if echo "$line" | rg -qi 'removed|retired|prohibit|must not|do not|there is no|no macOS XCUITest'; then
      continue
    fi
    fail "active macOS guidance reintroduced a retired frontend driver:\n$line"
  done <<< "$out"
fi

echo "==> doc harness drift check passed" >&2
