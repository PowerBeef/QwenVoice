#!/usr/bin/env bash
# Agent-driven iOS UI bench loop — retained stub for deferred mobile-mcp (WDA) only.
# mirroir and vision agent matrix lanes removed 2026-07 — use XCUITest bench-ui.
# Sourced by scripts/ios_device.sh — do not execute directly.

# _ios_agent_bench_ui <driver> [flags...]
# driver: mcp (deferred) | mirroir | vision (both retired)
_ios_agent_bench_ui() {
  local driver="${1:?driver required}"; shift

  case "$driver" in
    mirroir|vision)
      die "bench-ui-$driver is deprecated (2026-07) — use scripts/ios_device.sh bench-ui for the UI matrix. Exploratory smokes: mirroir + measure-* (docs/reference/ui-smoke-runbooks.md). Historical: docs/reference/computer-use-mcp-pilot-log.md §Archived agent bench."
      ;;
    mcp)
      die "bench-ui-mcp is deferred — WDA signing blocked. See docs/reference/mobile-mcp-ios-evaluation.md. Matrix: scripts/ios_device.sh bench-ui."
      ;;
    *)
      die "unknown agent bench driver '$driver' (mcp deferred; mirroir/vision retired)"
      ;;
  esac
}
