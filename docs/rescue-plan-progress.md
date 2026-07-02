# Project rescue — progress tracker

Working state for the remediation plan (post-mortem follow-up, started 2026-07-01).
Source plan: Cursor plan "Project Rescue Overhaul Plan". Update this file as phases land;
delete it when Phase 5 (release) ships.

## Phase 0 — safety net ✅ (done 2026-07-01)

| Item | Status | Evidence |
| --- | --- | --- |
| Review baselines seeded (8 macOS + 7 iOS PNGs) | ✅ | `docs/*-review-baselines/`, commit `6586592` |
| Measurement shell restored (`scripts/uitest_measure.sh`) | ✅ | verify-generation / streaming-preview-check validated live; commits `6586592`, `b899d64` |
| JSON bench baseline + gate compare | ✅ | `benchmarks/baselines/mac-gate-bench.json`; `QWENVOICE_GATE_BENCH=1` gate ran green incl. compare (`5b96bbf`) |
| Gates hardened (crash-delta fatal, iOS generation step) | ✅ code + macOS verified | macOS gate **PASS** end-to-end 2026-07-01 19:30 (6 steps). iOS gate: implementation in place; full green run pending attended device (see below) |

## Phase 1 — UI-driven testing on the Cursor stack

| Item | Status |
| --- | --- |
| Peekaboo macOS generate loop (see → type → Cmd+Return → verify-generation) | ✅ verified (pilot log §4) |
| Runbooks regenerated (`ui-test-surface.md` catalog + `ui-smoke-runbooks.md`) | ✅ (`b899d64`) |
| mirroir iOS Studio smoke | ⏳ **blocked on Cursor restart** — French-locale fix staged in `~/.mirroir-mcp/settings.json` (`mirroringProcessName: "Recopie de l’iPhone"`); after restart run the §5 tour in the pilot log |

## Phase 2 — bench & telemetry

| Item | Status |
| --- | --- |
| Telemetry gaps P1-2 / P1-4 / P1-6 / P1-7 | ✅ closed (kvCacheEstimatedPeakMB, physFoot timeToPeak, memoryPressureBandWorst, loud merger drops); compiles green macOS + iOS foundation |
| Ledger discipline documented (like-for-like lanes) | ✅ `benchmarking-procedure.md` §7 |
| Full-matrix release-QA bench (CLI + XPC bench-ui + iOS) + HISTORY refresh + new baselines | ☐ **next up** (~1–2 h runtime; listening pass required) |

## Side quest — iOS device-state detection ✅ (done 2026-07-02)

Fail doomed on-device runs fast instead of burning tokens on timeouts:

- `scripts/ios_device.sh device-state [--json]` — visual probe (Mirroring-window
  screenshot + Vision OCR, fr+en) with verdict exit codes: MIRROR_ACTIVE 0 /
  PHONE_IN_USE 10 / CALL_ACTIVE 11 / MIRROR_CONNECTING 12 / MIRROR_DISCONNECTED 13 /
  DEVICE_UNREACHABLE 14.
- Wired into preflight (call = fatal), bench/gate sentinel polls (abort with cause;
  2-poll tolerance for a glance at the phone), ui-test retry triage, gate verdicts.
- `ensure_mirror` auto-nudges a paused session's Resume button once.
- On-device `IOSInterruptionRecorder` (CXCallObserver + lifecycle) stamps
  `interruptions` into the autorun sentinel; bench/gate print them.
- Verified live: paused-mirror state correctly classified (`MIRROR_CONNECTING`,
  exit 12); in-use/call keyword sets unit-tested; iOS foundation compile green.
- devicectl `screenIsLocked`: **not available** on this Xcode 26.6 / iOS 26.5 pairing
  (deviceProperties lacks the key) — visual probe is the authoritative signal.

## Phases 3–5 — pending

- P3: design-mode audioQC listening pass/fix · 0.6B on-device spike · thermal policy · admission-doc fix
- P4: UI P0/P1 (batch decision, ScrollView ×2, Reduce Motion routing, tab-lock) · AppModel phases 3b/5/6 · macOS Liquid Glass · a11y pass
- P5: release train

## Attended-device prerequisites (blocking iOS gate green)

1. **Unlock the iPhone** when starting `scripts/ios_device.sh gate` (XCUITest auth
   handshake; the 20:17 run failed with "lost pending connection to test runner" —
   locked-phone flake, smoke passed on its retry).
2. **Install Voice Design (Speed)** once on the phone (Settings → Model Downloads) —
   the gate's generation step uses `design:speed` because the download test uninstalls
   `pro_custom` by design. Until installed, run gates with `QVOICE_GATE_SKIP_GENERATION=1`.
3. After the next Cursor restart, finish the mirroir tour (pilot log §5) and update the log.

## Open decisions (owner)

1. iOS batch: implement streaming batch vs remove dead UI.
2. 8 GB proof: acquire 15/16 Pro hardware vs document 17-Pro-tier support claim.
3. 0.6B variant appetite if quality trade-off appears.
