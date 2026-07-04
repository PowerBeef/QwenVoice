# Testing runbook (Vocello / QwenVoice)

> **Single source of truth for how Vocello is tested.** Regression gates are run by the
> checked-in `scripts/*.sh` + `xcodebuild` and by `.github/workflows/ci.yml` — never by an
> agent driving the screen. Separate from the gates, **exploratory agent-driven UI QA**
> exists again (Jul 2026): Peekaboo/mirroir MCPs drive the UI while the deterministic
> measurement shell [`scripts/uitest_measure.sh`](../../scripts/uitest_measure.sh) verifies
> results from OSSignposts + `history.sqlite` + the WAV on disk — see
> [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md). Measurement never depends on how the UI
> was driven.
>
> Subsystem deep-dives: [`ios-device-testing.md`](ios-device-testing.md),
> [`macos-testing.md`](macos-testing.md), [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md),
> [`ui-test-surface.md`](ui-test-surface.md) (generated identifier catalog).

## 1. The model: on-device iOS + macOS smoke

All iOS UI tests run on a **paired physical iPhone** via `scripts/ios_device.sh`. The MLX
engine runs in-process on Metal and **cannot initialize on the iOS Simulator** — the Simulator
is not used for any Vocello iOS test or agent workflow.

| Platform | Backend | Where it runs | Suites |
| --- | --- | --- | --- |
| **iOS UI** | real in-process MLX engine | **paired iPhone only** | `Smoke`, `Sheet`, `OnDeviceDownload`, `ColdGeneration`, `ReviewTour` |
| **macOS UI smoke** | real (out-of-process XPC) | **local macOS 26 host** (not CI yet) | `VocelloMacSmokeUITests` (12 tests) |

Warm-path suites (`Smoke`, `Sheet`, `ReviewTour`) share [`VocelloUITestApp`](../../Tests/VocelloiOSUITests/VocelloUITestApp.swift) — one app session with the real engine. `ColdGeneration` and `OnDeviceDownload` self-launch fresh instances when they need cold starts or download-specific setup.

## 1b. Model fixtures (when weights are required)

Real-engine lanes need the **Custom Voice (Speed)** variant (`pro_custom_speed`, ~2.3 GB) on
the device for generation and bench paths. Download tests intentionally remove or re-fetch models.

| Lane | Models required | How to prepare |
| --- | --- | --- |
| macOS `test` / `gate` / `profile` | `pro_custom_speed` in **debug** context (`QWENVOICE_DEBUG=1`) | `scripts/macos_test.sh models ensure` (install once to canonical `~/Library/Application Support/QwenVoice/models`, symlink `QwenVoice-Debug/models` → canonical) |
| macOS ad-hoc `xcodebuild test` | same (tests skip if missing) | `models ensure` before running, or tolerate `XCTSkip` |
| iOS default `test` / `gate` | Smoke + Sheet + ColdGeneration + Custom Voice headless generation | Install **all three Speed models** on iPhone once: Settings → Model Downloads (~6.9 GB). `QVOICE_GATE_SKIP_GENERATION=1` to skip generation step. |
| iOS `--cold`, `bench`, `profile` | Speed model **on the device** (App Group) | Install once on iPhone: Settings → Model Downloads |
| CI (GitHub) | none (compile-only) | `build-for-testing` with `generic/platform=iOS` |

Shared helpers live in [`scripts/lib/test_models.sh`](../../scripts/lib/test_models.sh).

Escape hatches (macOS): `QVOICE_SKIP_MODEL_ENSURE=1` (download UX tests),
`QVOICE_TEST_MODELS_NO_NETWORK=1` (fail instead of headless `vocello models install`).

## 2. iOS UI test launch environment

| Variable | Effect | Used by |
| --- | --- | --- |
| `QVOICE_IOS_SKIP_ONBOARDING=1` | Skip first-run onboarding so tests start on Studio. | warm coordinator + download/cold suites |
| `QWENVOICE_DEBUG=1` | Durable engine telemetry JSONL on device. | `ColdGeneration` |

Pin a specific phone with `QVOICE_IOS_DEVICE_ID` (CoreDevice identifier). When multiple devices
are paired, `scripts/ios_device.sh` prefers **iPhone 17 Pro**.

## 3. Commands

### macOS UI smoke (local)
```sh
scripts/macos_test.sh models ensure   # one-time Speed model + debug symlink
scripts/macos_test.sh models check    # read-only status (debug context)
scripts/macos_test.sh test            # ensures models, then VocelloMacSmokeUITests
scripts/macos_test.sh gate            # pre-merge gate (includes model ensure; new .ips during the run are gate-fatal)
# optional bounded engine bench + regression compare vs benchmarks/baselines/mac-gate-bench.json:
# QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate
scripts/macos_test.sh profile [spec]  # Instruments + vocello bench; fails on bench error unless --allow-bench-fail
```

### iOS UI tests (paired iPhone, attended)
```sh
scripts/ios_device.sh preflight           # device + signing + app + dSYM readiness
scripts/ios_device.sh models check        # which lanes need device models
scripts/ios_device.sh test                # default: Smoke + Sheet + ColdGeneration (all Speed models on device)
scripts/ios_device.sh ui-test --download  # OnDeviceDownload only (uninstalls pro_custom)
scripts/ios_device.sh test --cold         # ColdGeneration (needs Speed model on device)
scripts/ios_device.sh gate                # pre-merge gate (device)
```

## 3b. UI-driven benchmark lanes — step-by-step (any agent can run these)

Both platforms have a **full-matrix benchmark driven through the real UI** (XCUITest taps
the actual mode segments, composer, and Generate button; the engine's durable telemetry is
gated afterwards). Follow these procedures literally.

### macOS: `scripts/macos_test.sh bench-ui`

1. **Preconditions (all required):**
   - Idle machine — `pgrep -x xcodebuild` must print nothing (a concurrent build
     contaminates RTF).
   - Models: `scripts/macos_test.sh models ensure` once per machine.
   - Unattended automation ready: `scripts/macos_test.sh uitest-doctor` reports Gates 1–3 OK.
2. **Run:** `scripts/macos_test.sh bench-ui --label "<why-you-are-running>"`
   (default 29-take matrix: custom/design/clone × short/medium/long, 1 cold + 3 warm;
   scope down with `--modes custom --lengths medium --warm 1` for a smoke).
   Duration ≈ 20 min full matrix. Do NOT touch the machine while it runs.
3. **Verdict:** printed XPC gate — `expected=N engine=N service=N app=N merged=N` then
   `PASS`/`FAIL`. Artifacts: `build/macos/bench-ui-<runID>/` (log, summary, verdict).
4. **Triage:** missing service/app rows = audit J1 family (see
   `docs/rescue-plan-progress.md` §3b) — **closed 2026-07-02** (length-aware flush
   timeouts; was 12 s warm vs long takes still generating after player bar). Frozen
   markers (`did not advance` in the log) = `MacUITestSurfaceMarkers` observability. A take stuck on generate = check
   `sidebar_backendStatus_error`/`_crashed` in the log, then `scripts/macos_test.sh crashes`.

### iOS: `scripts/ios_device.sh bench-ui` (paired iPhone; NEVER the Simulator)

1. **Preconditions (all required):**
   - `scripts/ios_device.sh device-state` → `MIRROR_ACTIVE` (exit 0). Anything else:
     fix per the printed advice (phone locked nearby, Mirroring resumed, no call).
   - All three Speed models installed on the phone (Settings → Model Downloads):
     Custom Voice, Voice Design, Voice Cloning. `scripts/ios_device.sh models check`.
     Note: `ui-test --download` (OnDeviceDownload) UNINSTALLS Custom Voice — run it separately
     from the default gate; reinstall Custom Voice before the next default `test` / `gate`.
     benching if a gate ran since the last install. Downloads are serial (queued), ~4 min each.
   - Clone cells additionally need a **saved voice enrolled on the phone** (Voices →
     Save a new voice, attended — the mic does not work through iPhone Mirroring).
     Without one, clone cells are skipped automatically and the gate adjusts.
   - Phone unlocked for the XCUITest attach (first run of the day may show the
     passcode/automation prompt — human enters it).
2. **Run:** `scripts/ios_device.sh bench-ui --label "<why>"` (same matrix semantics and
   scoping flags as macOS). The driver builds, installs, runs
   `VocelloiOSBenchUITests/testFullMatrix`, pulls diagnostics, summarizes, and gates.
3. **Verdict:** `scripts/check_ios_ui_bench.py` prints per-cell rows + `PASS`/`FAIL`
   against the take count the test itself reported (`VOCELLO-BENCH-UI-MANIFEST ran=N`
   in the log). Artifacts: `build/ios/bench-ui-<runID>/` + `build/ios-diagnostics/`.
4. **Triage:** install/attach errors (`CoreDeviceError 3002`, `Connection interrupted`) =
   device unreachable/locked → re-check `device-state`, unlock, retry once. Take timeout =
   read `iosStudio_generationError` in the log; model missing = `textInput_installModelButton`
   assertion. Interference mid-run: the sentinel polls abort with the cause named.
5. **Comparing numbers:** engine rows from `bench-ui` are like-for-like with
   `ios_device.sh bench` (same `-Onone` build). Never compare against macOS or CLI lanes
   (see `benchmarking-procedure.md` §7 like-for-like table).

### Agent-driven exploratory UI QA (not a gate)

Peekaboo (macOS app) and the Mirroring window recipes (iOS) remain for exploratory QA
only — procedures in [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md); measurement always
goes through `scripts/uitest_measure.sh`, never through screenshots alone. The iPhone
mic is unavailable through Mirroring — recording/enroll flows are attended, on the phone.

### Compile-safety (fast, no run)
```sh
scripts/build_foundation_targets.sh macos
scripts/build_foundation_targets.sh ios
```

## 4. CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs on push to `main` and on every
PR:

- **`ios-compile-check`** (always): regenerates the project and runs `build-for-testing` for
  `VocelloiOS` + `VocelloiOSUITests` against `generic/platform=iOS` (compile/link only — no
  Simulator, no XCUITest). This catches Swift/SPM/XcodeGen regressions without a physical device.
- **`macos-ui-smoke`** (manual `workflow_dispatch` only): GitHub runners can't launch a
  macOS-26-targeted app yet (same reason `release.yml` sets `QWENVOICE_SKIP_LAUNCH_SMOKE=1`),
  so macOS UI smoke runs locally via `scripts/macos_test.sh test`. Fire the dispatch input once
  they do.

**Pre-merge iOS quality gate:** run `scripts/ios_device.sh gate` locally on your paired iPhone
before merging.

## 5. Determinism rules (keep tests un-flaky)

- Wait with `waitForExistence` / `XCTNSPredicateExpectation`, **never** `usleep` / `Thread.sleep`
  / RunLoop polling.
- Register `installSystemAlertMonitor()` in `setUp` so permission/automation dialogs can't stall
  a run.
- Query by stable `accessibilityIdentifier` (`voicesRow_*`, `textInput_*`, `studioChip_*`, …);
  these are surface area and must survive refactors. Never let a `screen_*` container shadow its
  descendants — use the `screenPresenceMarker(_:)` leaf marker
  ([`IOSAccessibility`](../../Sources/iOS/IOSAccessibility.swift)).
- A failing assertion should explain itself (capture the error-surface text / a screenshot), so a
  single run diagnoses the cause.

## 6. Perf / quality gate (real engine, mandatory pre-merge listening pass)
```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> --label "release-QA" --ledger
```
`--ledger` runs the summarizer once and appends one row to `benchmarks/HISTORY.md`. For manual
aggregation or regression checks, use `scripts/summarize_generation_telemetry.py` with
`--compare-baseline` (see [`macos-release-qa.md`](macos-release-qa.md) step 3). Committed
benchmark logs must be ≤256 KB; raw `*.jsonl` is gitignored.
