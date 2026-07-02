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
| Full-matrix release-QA bench + HISTORY refresh + new baselines | ✅ CLI matrix ×2 (idle run is reference: `baseline-2026-07-02-rescue-p2-speed.md` + `baselines/full-matrix-speed.json`; custom warm 0.94–1.06 RTF, 0 trims, QC pass). XPC `bench-ui` ×2: all 29 ENGINE rows complete both runs (KPIs valid), but the merged-row gate FAILS — app/engine-service layers lose 1–2 rows across the bench's cold relaunches (audit J1 family: rows pending flush die with the process). **Follow-up:** make app/service row flush synchronous with the per-take `mainWindow_lastTelemetryFlushed` ack, or fail-soft the checker on relaunch-adjacent takes. iOS bench: blocked on Speed model install (attended). **Listening pass: pending (operator).** |

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

## Phases 3–5 — status

- P3 done: thermal gate (proactive-warm blocked at serious/critical, QVOICE_IOS_THERMAL_GATE=off) ·
  admission-doc fix. **Remaining P3 (attended):** design-mode audioQC listening pass on device ·
  0.6B on-device spike.
- **0.6B spike prep (desk half done 2026-07-02):** checkpoints confirmed on the Hub —
  `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice` (official, bf16 ≈1.2 GB) and
  `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit` (MLX 4-bit of the BASE only; no 4-bit
  CustomVoice conversion published). Spike plan: throwaway branch, add a contract entry
  for 0.6B CustomVoice (bf16 first; 4-bit via mlx-audio convert if promising), then
  `ios_device.sh bench` matrix + listening pass vs the 1.7B reference.
- P4 done: batch removed (maintainer decision) · tab lock relaxed (maintainer decision) ·
  ScrollView + Reduce Motion routing (iOS + macOS live re-read) · a11y (scrubber/transcript) ·
  Liquid Glass audit resolved · AppModel phases 3b/5/6 (see commit for scope).
- P5 (release): blocked on the attended items below + listening pass.

## Attended checklist (everything left needs you)

1. **Unlock iPhone + install Voice Design (Speed)** on the phone → run `scripts/ios_device.sh gate`
   (should now go green end-to-end incl. the generation step).
2. **Install Custom Voice (Speed)** on device → `scripts/ios_device.sh bench` per mode → listening
   pass (incl. the design dropout/clicks investigation on the pulled WAVs).
3. **Restart Cursor** → run the mirroir Studio tour (pilot log §5).
4. Decide on the 0.6B spike branch when you have the device time.
5. XPC bench-ui merged-row follow-up (row loss across cold relaunches — J1 family).

## Phase 4 findings — Liquid Glass audit item resolved as mostly false-positive (2026-07-02)

The UI audit flagged CustomVoice/VoiceDesign/VoiceCloning/Settings as "no glass" from a
grep for `#if QW_UI_LIQUID` in those files. Code review shows the generate surfaces ARE
glassed — they feed `modeGlassTint`/`modeCanvasBackdrop` into the shared
`GenerationWorkflowView`/`profileGroupBoxStyle` chrome where the glass lives.
`StartupDiagnosticsView` uses `profileGroupBoxStyle` (glassed). `SettingsView` is an
intentionally NATIVE grouped Form ("modeled on macOS System Settings") — adding custom
glass there would fight the system idiom; left native by design. `EmotionPickerView` has
no chrome of its own (hosted inside glassed panels). Only real cleanup: the dead
`AppTheme.uiProfile` fallback (both #if branches returned .liquid) simplified with a
documented seam comment.

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
