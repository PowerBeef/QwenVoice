# Rescue plan — continuation guide

> **Read this first if you are picking up the rescue work.** It is written to be self-contained: current state, exact remaining steps with commands and expected outputs, and the guardrails that previous sessions learned the hard way. Follow it literally; when this doc disagrees with the code, the code wins. Delete this file when Phase 5 (release) ships.
>
> Context: [post-mortem](post-mortem/2026-06-post-fable-development-hell.md) → four
> audits (2026-07-01) → phased remediation. Onboarding: `[AGENTS.md](../AGENTS.md)`.
>
> **HANDOFF (2026-07-07):** iOS UI testing harness **simplified** — agent matrix
> (`bench-ui-mirroir`) retired; full matrix = XCUITest `bench-ui` only; agent smokes =
> mirroir 1-clip + `measure-*`. Lang Phase 4 UI tests **de-scoped** (headless lang-bench
> covers semantics). Re-run lang-bench full output gate when Speech assets finish on Wi‑Fi.
> Start at **§2 Step 4** (human design listening) or **§2 Step A** (manual clone record verify),
> then **§2 Step 5b** (release).

## 1. Current state (2026-07-07, `main`)

### Session update (2026-07-07) — iOS UI testing simplification

| Step | Status | Notes |
| --- | --- | --- |
| Agent matrix retired | **LANDED** | `bench-ui-mirroir` / `bench-ui-vision` hard-fail; Playbooks collapsed to 3 |
| iOS measure shell | **LANDED** | `measure-prep`, `measure-now`, `measure-wait`, `measure-verify` on `ios_device.sh` |
| Lang Phase 4 UI tests | **DE-SCOPED** | Picker→telemetry covered by headless `lang-bench`; no new XCUITest lane pre-release |
| Lang full output gate | **BLOCKED** | `ios-lang-bench-20260706-135146`: 7/18 — DE/ES/ZH/JA Speech assets pending Wi‑Fi |

### Session update (2026-07-06) — language-path verification

| Step | Status | Notes |
| --- | --- | --- |
| Phase 1 — `VocelloCoreTests` | **LANDED** | 20 macOS unit tests: `qwenLanguageHint`, `PromptLanguageDetector`, `LanguageSelectionPresentation`; `scripts/macos_test.sh core-test`; gate step 3 |
| Phase 2 — lang-bench + hint gate | **LANDED + quick PASS** | Device `ios-lang-bench-20260706-110143` 7/7 hints; `check_language_hints.py` accepts `finishReason=eos` |
| Phase 2 — device validation (full) | **hint PASS / output BLOCKED** | `ios-lang-bench-20260706-135146`: hint 19/19; output 7/18 — DE/ES/ZH/JA need Speech Wi‑Fi assets |
| Phase 3 — Speech round-trip | **LANDED + quick PASS** | Locale-locked ASR (`transcribeForVerification`), stored `pass` in sentinel; device `ios-lang-bench-20260706-112319` output 6/6; negative control `skipOutputVerification` |
| Phase 4 — UI integration tests | **DE-SCOPED** | Headless lang-bench covers picker semantics; no pre-release XCUITest lane |

Runbook: [`language-bench.md`](reference/language-bench.md). Semantics reference: [`qwen3-tts-guide.md`](reference/qwen3-tts-guide.md) §7.

### Session update (2026-07-05 evening)

| Step | Status | Notes |
| --- | --- | --- |
| Device-state probe overhaul | **LANDED** | Layered CoreDevice JSON + bundle-ID mirror + Swift OCR classify + `--json-v2` / `watch`; offline fixtures; [`ios-device-probe.md`](reference/ios-device-probe.md) |
| iOS bench-ui composer fix | **LANDED** | `VocelloiOSBenchUITests.typeScript()` uses `editor.typeText` + `textInput_lengthCount` (not macOS `textInput_charCount`); bench-ui calls `ensure_mirror` before guard; transient XCUITest retry |
| iOS full matrix re-run | **PASS** | `ios-bench-ui-20260705-200615` → 29/29 engine gate (~605 s XCUITest); warm RTF medians custom 1.74 / design 1.84 / clone 1.58 |
| 4 design listening | **OWED (human)** | QC `warn:dropout` on some warm short/medium cells — ears on History design takes |
| 5a gates | **PASS (2026-07-03)** | Re-gate optional before release |
| 5b release train | **PENDING** | After Step 4 + Step A |
| Clone reference recording | **COMMITTED** (`a250ec1`+) | Manual Studio → Clone → Record → Save still owed on phone (mic not via Mirroring) |

### Session update (2026-07-03 afternoon)

| Step | Status | Notes |
| --- | --- | --- |
| 1–3 macOS J1 + iOS bench | **PASS** | iOS latest: `ios-bench-ui-20260705-200615` (29/29); macOS J1 unchanged |
| 4 design listening | **OWED (human)** | Maintainer listens to History design takes on phone |
| 5a gates + macOS review | **PASS** | `gate-mac-gate-20260702-163644`; `mac-review-20260702-164903` |
| 5b release train | **PENDING** | Version bump / tag / DMG — after Step 4 + clone manual verify |
| Clone reference recording | **COMMITTED** | `IOSRecordVoiceSheet` enroll flow on both entry points (`a250ec1`+) |
| Clone fix verification | **PARTIAL** | `ios_device.sh test` PASS; maintainer manual Studio → Clone → Record → Save still owed |

### Session update (2026-07-03 ~00:30) — bench + gate closure

| Step | Status | Artifact |
| --- | --- | --- |
| 1 macOS J1 verify | **PASS** | `build/macos/bench-ui-xpc-bench-20260702-155134/` → 29/29/29/29 |
| 2 iOS bench-ui shakeout | **PASS** | `build/ios/bench-ui-ios-bench-ui-20260703-000049/` (telemetry mirror fix) |
| 3 iOS full matrix | **PASS** | `build/ios/bench-ui-ios-bench-ui-20260703-001546/` → 29/29 engine gate; HISTORY rows appended |
| 4 design listening | **OWED (human)** | maintainer listens to History design takes on phone |
| 5 macOS gate+review | **PASS** | `gate-mac-gate-20260702-163644`; review `mac-review-20260702-164903` |
| 5 iOS gate | **PASS** | `gate-ios-gate-20260703-003025` |

**iOS bench fixes (`004800d`):** mirror App Group diagnostics into devicectl-pullable Caches after each generation; `ensure_mirror` auto-nudges Reprendre/Resume when mirroring paused; bench-ui unlock retry; warm-take inline player dismiss between takes; voice-brief starter path skips Confirm.

**J1 root cause (final):** warm flush timeout (12 s) << long-take generation time after player bar.
Fix: `VocelloMacBenchUITests.telemetryFlushTimeout` + hard XCTFail; inline `await` app JSONL when hooks on.

### Session update (2026-07-02 afternoon) — superseded

Phone was `unavailable` in devicectl (Steps 2–3 and iOS gate BLOCKED). Resolved when phone reconnected; see ~00:30 table above for PASS artifacts.

### Done and verified


| Area                    | What landed                                                                                                                                                                                                        | Key commits          |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------- |
| Visual regression net   | 8 macOS + 7 iOS review-baseline PNGs seeded (`docs/*-review-baselines/`); xcresult-attachment fallback in both review lanes                                                                                        | `6586592`            |
| Measurement shell       | `scripts/uitest_measure.sh` (prep/finish, reset, smoke-check, bench-wait, verify-generation, streaming-preview-check, bench-compare) — validated live end-to-end                            | `6586592`, `b899d64` |
| Bench regression gating | `benchmarks/baselines/mac-gate-bench.json` + `benchmarks/baselines/full-matrix-speed.json`; `QWENVOICE_GATE_BENCH=1 macos_test.sh gate` compares and fails on >5% regression; summarizer RTF direction fixed       | `5b96bbf`, `846721f` |
| Hardened gates          | New crashes during a gate run are gate-fatal (both platforms); iOS gate gained a headless generation step (design:speed — the download test uninstalls pro_custom BY DESIGN)                                       | `5b96bbf`            |
| Agent-driven UI loop    | Peekaboo macOS generate loop verified (see pilot log §4); runbooks regenerated (`ui-test-surface.md` generated catalog + `ui-smoke-runbooks.md`)                                                                   | `b899d64`            |
| Device-state detection  | Layered probe: CoreDevice JSON + bundle-ID mirror + Swift OCR; `--json-v2`, `watch`, offline fixtures; [`ios-device-probe.md`](reference/ios-device-probe.md) | this commit |
| Telemetry gaps          | P1-2 kvCacheEstimatedPeakMB, P1-4 physFoot timeToPeak, P1-6 notes.memoryPressureBandWorst, P1-7 loud merger drops                                                                                                  | `7986c00`            |
| P2 bench refresh        | Full-matrix Speed CLI bench (idle-machine reference: `benchmarks/baseline-2026-07-02-rescue-p2-speed.md`); HISTORY rows appended                                                                                   | `846721f`            |
| Thermal policy          | `TTSEngineStore.startThermalObservation` — proactive warm blocked at serious/critical; generation never thermally blocked; `QVOICE_IOS_THERMAL_GATE=off`                                                           | `846721f`            |
| UI P0/P1                | iOS batch REMOVED (decision) · tab lock RELAXED (decision) · ScrollView + Reduce Motion routing (iOS + macOS live re-read) · player scrubber/transcript VoiceOver ids · dead uiProfile fork removed                | `8b78470`, `e396b94` |
| Decisions on record     | **1.7B variants only** (0.6B ruled out — Voice Design needs 1.7B) · iOS batch removed · tab lock relaxed · cold launch lands Studio→Custom                                                                         | `42aa64e`, `8f70f68` |
| iOS UI-driven bench     | Full matrix 29/29; pullable telemetry mirror; gate lane closed                                                                                                                                    | `004800d`            |


### Also done: AppModel migration Phases 3b/5/6 (landed in `0df766b` + `411ce84`)

All migration phase comments in `Sources/iOS/App/AppModel.swift` now read
"complete-as-designed" — that is the final architecture, not a TODO:

- **3b:** engine calls deliberately stay in the per-mode views (they need four
environment-owned stores that predate `AppModel`); shared cancel lives in
`IOSStudioGenerationActions`.
- **5:** no `presentedSheet` enum (surfaces have different payloads/hosting);
the real fix was pairing the delete-model sheet with the focus backdrop via
`AppModel.presentDeleteModelSheet/dismissDeleteModelSheet`. System modals
(fileImporter/alerts/dialogs) intentionally remain local `@State`.
- **6:** `HistoryScreen`/`SettingsScreen` own their bodies; `IOSLibraryViews.swift`
and `IOSSettingsContainerView` deleted (the Voices-library branch was dead code —
live Voices tab is `IOSVoicesView`). All protected identifiers survive verbatim
(`docs/reference/ui-test-surface.md` regenerated); the only removed ids were the
dead branch's `savedVoiceMenu_*`/`savedVoiceDeleteConfirm_*`, unreferenced by tests.

Compile-verified (`build_foundation_targets.sh ios` BUILD SUCCEEDED). On-device
coverage via `gate-ios-gate-20260703-003025` PASS (includes default UI tests).

### Current performance reference (like-for-like lanes — NEVER mix)


| Lane                    | Headline (custom/speed/warm/medium)       | Reference artifact                                  |
| ----------------------- | ----------------------------------------- | --------------------------------------------------- |
| CLI `-Onone` in-process | RTF ≈ 1.05                                | `benchmarks/baseline-2026-07-02-rescue-p2-speed.md` |
| Local release `-O` CLI  | RTF ≈ 1.7                                 | HISTORY 2026-06-29 rows                             |
| macOS XPC bench-ui      | RTF ≈ 0.9–1.0 + TTFC ≈ 0.9 s warm         | `build/macos/bench-ui-*/summary.log`                |
| iPhone 17 Pro on-device | RTF 1.6–1.9, physFoot 2.4–3.3 GB, 0 trims | `docs/reference/ios-engine-optimization.md` §6      |


## 2. NEXT ACTIONS — do these IN ORDER (handout for the continuing model)

> Updated 2026-07-05. Steps 1–3 and 5a are **COMPLETE** — do not re-run unless
> regressing. Remaining: Step 4 (human), Step A (clone manual verify on phone),
> Step 5b (release train). If a step fails twice the same way, STOP and report —
> do not improvise new tools.

### Step 1 — J1 verification (macOS) — COMPLETE

**Status: VERIFIED PASS (2026-07-02).** `expected=29 engine=29 service=29 app=29 merged=29` +
PASS (`build/macos/bench-ui-xpc-bench-20260702-155134/`).

Root cause was **not** row-loss from async writes alone — the bench driver's
`waitForTelemetryFlush` used a 12 s warm timeout while `tapGenerateAndWaitForPlayer`
returns at first-chunk (player bar). Warm **long** takes were still generating when the
soft-failed flush let relaunch/terminate kill the app before `recordCompleted`. Fix:
length-aware flush timeouts (60/120/300 s) + hard XCTFail on flush timeout; inline
`await` app JSONL write when UI-test hooks are on.

**If rerunning** and the gate fails, use this triage tree (historical — do not revert fixes):

The `j1-verify-round3` run FAILED EARLY (log: `/tmp/bench-ui-j5.log`, artifacts
`build/macos/bench-ui-xpc-bench-20260702-142137/`) with a composer flake signature
(`textInput_charCount` never appeared). Rerun once on an idle machine (`pgrep -x xcodebuild`).
If rows still missing after a normal run, filter JSONL by `recordedAt` and inspect
svc/app gaps (see §3b J1 notes).

### Step 2 — iOS bench-ui shakeout — COMPLETE

**Status: PASS (2026-07-05).** Latest full matrix:
`build/ios/bench-ui-ios-bench-ui-20260705-200615/` (29/29).

### Step 3 — Full iOS UI-driven matrix — COMPLETE

**Status: PASS (2026-07-05).** `ios-bench-ui-20260705-200615` → 29/29 engine gate.
Prior PASS (2026-07-03): `ios-bench-ui-20260703-001546`.

### Step 4 — Design-mode listening pass (HUMAN ears; cannot be automated) — OWED

Takes live in the app's History on the phone. Ask the user to listen to the design
takes for dropouts/clicks. If audible: file the defect with the chunkTimeline row
(v5 telemetry localizes the silence window) BEFORE touching engine code.

### Step A — Clone reference recording (before release) — COMMITTED; manual verify owed

Studio → Clone → Record uses the same `IOSRecordVoiceSheet` enroll flow as the Voices tab
(landed `a250ec1`+). Verify on the **physical phone** — mic is unavailable through Mirroring.

```sh
# Manual: Studio → Clone → Reference → Record → Stop → Save → Generate
scripts/ios_device.sh test    # retry if device auth flake (error 12)
```

### Step 5 — Release train (Phase 5)

#### 5a Pre-release gates — COMPLETE

| Lane | Status | Artifact |
| --- | --- | --- |
| macOS gate | **PASS** | `gate-mac-gate-20260702-163644` |
| macOS review | **PASS** | `mac-review-20260702-164903` (8 PNG diffs — visual pass) |
| iOS gate | **PASS** | `gate-ios-gate-20260703-003025` |

Optional re-gate after Step A lands (2026-07-07 attempt):

| Lane | Status | Artifact / notes |
| --- | --- | --- |
| macOS gate | **FAIL (flake)** | `gate-mac-gate-20260707-134920` — 6/12 XCUITest failures (element not ready / event timeout); unrelated to harness simplification (docs/scripts only) |
| iOS gate | **BLOCKED** | `device-state` exit 12 `MIRROR_CONNECTING` — resume iPhone Mirroring on phone, then re-run |
| iOS lang-bench full | **BLOCKED** | Same mirror blocker; prior full run `ios-lang-bench-20260706-135146` output 7/18 pending Speech assets |

```sh
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # retry when Mac UI tests idle
scripts/ios_device.sh gate                          # after mirror active + unlock once
scripts/ios_device.sh lang-bench --subset full --label "lang-full-output-v3"
scripts/macos_test.sh review && scripts/ios_device.sh review
```

#### 5b Release train — PENDING (after Step 4 + Step A)

Follow `docs/reference/macos-release-qa.md` (version bump in `project.yml` →
`regenerate_project.sh` → tag → GitHub release triggers the DMG workflow). iOS
TestFlight lane is optional (`archive-ios` manual dispatch).

## 3. Guardrails (learned the hard way — do not violate)

From the post-mortem (repo-fatal):

- **Never** build simulator/fake-engine test tiers for iOS. On-device only.
- **Never** rewrite agent guides per harness/model. AGENTS.md is the single guide.
- **Never** land multi-hundred-line features without `macos_test.sh gate` /
`ios_device.sh gate` first. Reverts = planning failure.
- **Never** float `mlx-swift`/`mlx-swift-lm` pins independently or without a
benchmark-gated throwaway branch.

From this rescue (operational traps that WILL bite again):

- **LaunchServices double-instance trap:** never `tell application "Vocello" to activate` / `open -na` while a measured debug session runs — it can spawn a second
instance WITHOUT debug mode whose takes land in the user's real library.
`uitest_measure.sh prep/activate/finish` handle this correctly (persisted DebugMode
flag + PID-based activation + single-instance guard).
- **logd flush lag:** `log show` exposes fresh os_signpost events minutes late. Wait
on the history.sqlite row (what `bench-wait` does), never poll `log show --last Nm`.
- `log show --start` **rejects fractional seconds** — trim to whole seconds.
- **xcodebuild env:** plain env vars do NOT reach the test runner; use the
`TEST_RUNNER_` prefix (review lanes do), and expect on-device runners to be unable
to write Mac paths (use the xcresult-attachment fallback).
- **Engine JSONL auto-prunes oldest-first** — never isolate a run's rows by line
count; filter by `recordedAt` (gate bench) or the run label.
- **bash 3.2 +** `set -u`**:** expanding an empty array errors; use
`${arr[@]+"${arr[@]}"}`.
- **New/deleted Swift files require** `./scripts/regenerate_project.sh` before the
Xcode build sees them.
- **MIRROR_ACTIVE ≠ XCUITest ready:** `device-state` exit 0 means mirroring is up, not that
  the phone is unlocked for the first XCUITest attach. Unlock once + approve automation prompt;
  `bench-ui` prints an attended-handshake banner. If mirroring shows « Connexion en pause »,
  run `scripts/ios_device.sh mirror` (auto-nudges Reprendre).
- **iOS bench composer typing:** validate with `textInput_lengthCount` (`"42 / 150"`), not
  macOS `textInput_charCount`. See `VocelloiOSBenchUITests.typeScript()`.
- **French macOS localization:** Mirroring process is "Recopie de l'iPhone" — shell probe uses
  bundle ID `com.apple.ScreenContinuity`; osascript/mirroir need `mirroringProcessName` in
  `~/.mirroir-mcp/settings.json`. OCR keyword sets are fr+en (`mirror_state_ocr.swift`).
- **RTF = audioSeconds/wallSeconds — HIGHER is better.** A drop is the regression.
- **Benches need an idle machine** — a concurrent xcodebuild contaminated a full
matrix (design/long 0.57 vs 1.11 idle). Check `pgrep -x xcodebuild` first.
- **devicectl lock state:** use `devicectl device info lockState --device <id>` when available
  (returns `unlockedSinceBoot`, `passcodeRequired`). The old `screenIsLocked` field does **not**
  exist on Xcode 26.6/iOS 26.5. Layered probe docs: [`docs/reference/ios-device-probe.md`](docs/reference/ios-device-probe.md).
- **iOS model downloads are SERIAL (concurrent disabled — maintainer, 2026-07-02):**
tapping Install on a second model while one downloads queues it; it starts after the
first completes. Not a stuck download. The maintainer rates the iOS download process
"in poor shape" — treat download-UX polish as a backlog item; do not enable
concurrency as a quick fix.
- **Driving the mirrored phone from the Mac (attended installs):** peekaboo `see`
cannot map elements inside the Mirroring window (video stream, no AX tree). See via
`screencapture -x -o -l $(swift scripts/lib/mirror_state_ocr.swift window-id)`, then
peekaboo `click` with screen coords (window origin/size from peekaboo `see PID:<mirroring-pid>`; screenshot px = 2× window points). Focus the app first
(`app focus`); a paused mirror shows "Connexion en pause" — click Reprendre to resume.
- **The iPhone MICROPHONE is unavailable through iPhone Mirroring** ("Le micro de
l'iPhone n'est pas disponible à partir du Mac", verified 2026-07-02). Voice
recording/enrollment is NOT broken in the app — it works when operated directly on the
phone (maintainer-confirmed same day). Never triage recording as an app defect from a
mirror session, and never drive record/enroll flows via the mirror; that step is
attended, on the physical phone.
- **Reference clip handoff:** `ReferenceClipRecordingStash` + `didHandOffClip` guard temp WAV deletion in `IOSRecordingOverlay`. **Studio Clone record presents `IOSRecordVoiceSheet` from `RootView`** via `AppModel.requestCloneReferenceRecording` (after bottom-panel dismiss) — same enroll flow as Voices tab; result via `pendingVoiceCloningHandoff`. Do not nest recorders under `IOSGenerateContainerView` while the bottom panel is active.

## 3b. Active work (2026-07-03)

- **iOS UI-driven bench — CLOSED (`004800d`).** Full matrix 29/29 engine gate;
  pullable telemetry mirror into devicectl Caches; shakeout + baseline runs PASS.
  Parts: `VocelloiOSBenchUITests`, `IOSStudioBenchHooks`, `ios_device.sh bench-ui`,
  `scripts/check_ios_ui_bench.py`.
- **macOS XPC bench-ui J1 — CLOSED (2026-07-02).** `bench-ui-xpc-bench-20260702-155134`
  → 29/29/29/29 PASS. Length-aware flush timeout + inline app JSONL when hooks on.
- **iOS gate — PASS.** `gate-ios-gate-20260703-003025`. Design dropout did NOT
  reproduce in benches; perceptual listening pass still owed (Step 4).
- **Clone reference recording — COMMITTED (`a250ec1`+; manual verify owed).** Studio Clone
  record uses `IOSRecordVoiceSheet` (identical to Voices tab). Present from `RootView` via
  `AppModel.requestCloneReferenceRecording`. Automated: `gate-ios-gate-20260703-003025` PASS.
  Maintainer: Studio → Clone → Record on the **physical phone** — confirm naming sheet after Stop.
- **"Recording broken through mirror" — RESOLVED (not an app defect).** Mic unavailable
  via Mirroring; physical-phone operation confirmed separately.
- **iOS agent UI driving — mirroir native (2026-07-04, simplified 2026-07-07).** Exploratory
  smokes only (`describe_screen` → `tap` / `type_text` + `measure-*`). Full matrix = XCUITest
  `bench-ui` only. See [`ios-agent-ui-tour.md`](reference/ios-agent-ui-tour.md) Appendix B.5–B.8 and
  [`computer-use-mcp-pilot-log.md`](reference/computer-use-mcp-pilot-log.md) §10.2–§10.3.
  **mobile-mcp** (WDA) remains **deferred** — see
  [`docs/reference/mobile-mcp-ios-evaluation.md`](reference/mobile-mcp-ios-evaluation.md).

## 4. Where everything lives (quick index)


| Need                                  | Location                                                                            |
| ------------------------------------- | ----------------------------------------------------------------------------------- |
| Build/test commands                   | `AGENTS.md` (Workflows + Commands)                                                  |
| Testing lanes + gates                 | `docs/reference/testing-runbook.md`, `macos-testing.md`, `ios-device-testing.md`    |
| Deterministic measurement (macOS) | `scripts/uitest_measure.sh` (header = manual) |
| Deterministic measurement (iOS smokes) | `scripts/ios_device.sh measure-*` |
| Device interference probe             | `scripts/ios_device.sh device-state`; libs `ios_device_state.sh`, `ios_coredevice_probe.py`, `mirror_state_ocr.swift` |
| Agent-driven UI smoke procedure       | `docs/reference/ui-smoke-runbooks.md`                                               |
| Identifier catalog (generated)        | `docs/reference/ui-test-surface.md` (`python3 scripts/generate_ui_test_surface.py`) |
| Bench procedure + like-for-like rules | `docs/reference/benchmarking-procedure.md` §7                                       |
| Bench baselines                       | `benchmarks/baselines/*.json` (machine) + `benchmarks/baseline-*.md` (human)        |
| iOS engine posture + records          | `docs/reference/ios-engine-optimization.md`                                         |
| iOS app map + clone flow              | `docs/reference/ios-app-guide.md`                                                   |
| MCP pilot state                       | `docs/reference/computer-use-mcp-pilot-log.md`                                      |

