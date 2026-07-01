# Testing runbook (Vocello / QwenVoice)

> **Single source of truth for how Vocello is tested.** Tests are run by the checked-in
> `scripts/*.sh` + `xcodebuild` and by `.github/workflows/ci.yml` — **never** by an agent
> driving the screen. The previous agent-driven UI harness (Anthropic "Fable" model + a
> computer-use / desktop-MCP loop) is gone; nothing here depends on it. Everything below is
> deterministic and self-driving.
>
> Subsystem deep-dives: [`ios-device-testing.md`](ios-device-testing.md),
> [`macos-testing.md`](macos-testing.md), [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md).

## 1. The model: two iOS tiers + macOS smoke

The iOS UI state depends heavily on the backend (model installed? engine ready? generating?).
To get fast, deterministic UI coverage without the 2.3 GB model or Metal, the engine is
injectable and tests split into two tiers.

| Tier | Backend | Where it runs | Suites |
| --- | --- | --- | --- |
| **A — fake backend** | [`FakeTTSEngine`](../../Sources/iOS/FakeTTSEngine.swift) + `FakeModelStatusProvider` (`QVOICE_FAKE_ENGINE=1`) | **iOS Simulator + CI** and device | `Smoke`, `Sheet`, `FakeGeneration`, `FakeGenerationError`, `ReviewTour` |
| **B — real engine** | real in-process MLX engine, real model/download | **paired iPhone only** (MLX can't init on the Simulator) | `ColdGeneration`, `OnDeviceDownload` |
| **macOS UI smoke** | real (out-of-process XPC) | **local macOS 26 host** (not CI yet) | `VocelloMacSmokeUITests` (12 tests) |

Why the split: the MLX engine initializes the Metal GPU at launch and **crashes on the iOS
Simulator** (`EXC_BAD_ACCESS` on the `GPUEnum` queue). Tier A bypasses MLX entirely, so the
backend-dependent Studio flow (idle → Generate → Generating → inline player, plus the error
surface) runs in seconds with no model. Tier B proves the real cold-launch → model-load →
generation / download path, and only runs on hardware.

## 1b. Model fixtures (when weights are required)

Real-engine lanes need the **Custom Voice (Speed)** variant (`pro_custom_speed`, ~2.3 GB).
Download/management tests are the **only** lanes that intentionally remove or re-fetch models.

| Lane | Models required | How to prepare |
| --- | --- | --- |
| macOS `test` / `gate` / `profile` | `pro_custom_speed` in **debug** context (`QWENVOICE_DEBUG=1`) | `scripts/macos_test.sh models ensure` (install once to canonical `~/Library/Application Support/QwenVoice/models`, symlink `QwenVoice-Debug/models` → canonical) |
| macOS ad-hoc `xcodebuild test` | same (tests skip if missing) | `models ensure` before running, or tolerate `XCTSkip` |
| iOS default `test` / `gate` | **none** (Tier A fake + `OnDeviceDownload` uninstalls in `setUp`) | — |
| iOS `--cold`, `bench`, `profile` | Speed model **on the device** (App Group) | Install once on iPhone: Settings → Model Downloads |
| CI Tier A (Simulator) | none | fake backend |

Shared helpers live in [`scripts/lib/test_models.sh`](../../scripts/lib/test_models.sh).

Escape hatches (macOS): `QVOICE_SKIP_MODEL_ENSURE=1` (download UX tests),
`QVOICE_TEST_MODELS_NO_NETWORK=1` (fail instead of headless `vocello models install`).

## 2. How the fake backend works

`QVOICE_FAKE_ENGINE=1` (set by the test launch environment, never in production) makes
[`IOSAppBootstrap.makeBackend`](../../Sources/iOS/IOSAppBootstrap.swift) build the fake backend
**before** the shared-container guard, so it needs neither the App Group nor a signed build.
It also:

- bypasses the on-device hardware gate in `QVoiceiOSApp` so the UI mounts on the Simulator;
- skips MLX cache configuration (`configureNativeRuntimeMemoryCacheIfNeeded`) — that
  `Memory.cacheLimit` write is the first MLX/Metal call and is what crashes the Simulator;
- bypasses the memory-admission gate + active-generation memory guard in `TTSEngineStore`
  (the Simulator reports a bogus low-headroom snapshot that would otherwise block generation
  with `insufficientMemory`).

Fake knobs (launch environment):

| Variable | Effect | Default |
| --- | --- | --- |
| `QVOICE_FAKE_ENGINE=1` | Enable the fake backend (master switch). | off |
| `QVOICE_FAKE_MODEL_STATE=notInstalled` | Report the model as **not** installed (exercises the Install CTA). | installed |
| `QVOICE_FAKE_ENGINE_SCENARIO=generateError` | `generate` throws → exercises the error surface. | normal |
| `QVOICE_IOS_SKIP_ONBOARDING=1` | Skip first-run onboarding so tests start on Studio. | (set by coordinator) |

`FakeTTSEngine.generate` writes a tiny silent WAV and returns a `GenerationResult`, so the
inline player card appears exactly as for a real take.

Tier-B suites self-launch their own `XCUIApplication` **without** the fake flag and are guarded
by `XCTSkipUnless(UITestTier.canRunRealEngine, …)` — a **compile-time** gate
(`#if targetEnvironment(simulator)`: false on Simulator, true on device). No runner-env flag is
needed.

## 3. Commands

### macOS UI smoke (local)
```sh
scripts/macos_test.sh models ensure   # one-time Speed model + debug symlink
scripts/macos_test.sh models check    # read-only status (debug context)
scripts/macos_test.sh test            # ensures models, then VocelloMacSmokeUITests
scripts/macos_test.sh gate            # pre-merge gate (includes model ensure)
# optional bounded engine bench: QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate
scripts/macos_test.sh profile [spec]  # Instruments + vocello bench; fails on bench error unless --allow-bench-fail
```

### iOS Tier A — fake backend (Simulator, local)
```sh
xcodebuild test \
  -project QwenVoice.xcodeproj -scheme VocelloiOS -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/foundation/local-builds/ios-sim-tierA-dd \
  -only-testing:VocelloiOSUITests/VocelloiOSSmokeUITests \
  -only-testing:VocelloiOSUITests/VocelloiOSSheetUITests \
  -only-testing:VocelloiOSUITests/VocelloiOSFakeGenerationUITests \
  -only-testing:VocelloiOSUITests/VocelloiOSFakeGenerationErrorUITests \
  CODE_SIGNING_ALLOWED=NO
```
(Use any installed iPhone simulator name; the suites self-skip the Tier-B classes.)

### iOS Tier B — real engine (paired iPhone, attended)
```sh
scripts/ios_device.sh preflight           # device + signing + app + dSYM readiness
scripts/ios_device.sh models check        # which tiers need device models
scripts/ios_device.sh test                # default trio: Smoke + Sheet + OnDeviceDownload
scripts/ios_device.sh test --cold         # ColdGeneration (needs Speed model on device)
scripts/ios_device.sh gate                # pre-merge gate (device)
```
On device, Smoke/Sheet run against the fake backend (fast); `OnDeviceDownload` / `--cold`
exercise the real stack. iOS is **on-device only** for real-engine work — never the Simulator.

### Compile-safety (fast, no run)
```sh
scripts/build_foundation_targets.sh macos
scripts/build_foundation_targets.sh ios
```

## 4. CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs on push to `main` and on every
PR:

- **`ios-tier-a-ui`** (always): selects an available iPhone simulator, regenerates the project,
  and runs the Tier-A suites on the iOS 26 Simulator (Xcode 26). This is the automated
  pre-merge UI signal.
- **`macos-ui-smoke`** (manual `workflow_dispatch` only): GitHub runners can't launch a
  macOS-26-targeted app yet (same reason `release.yml` sets `QWENVOICE_SKIP_LAUNCH_SMOKE=1`),
  so macOS UI smoke runs locally via `scripts/macos_test.sh test` until macOS-26 runner images
  exist. Fire the dispatch input once they do.

Tier B is **not** in CI (no physical iPhone on the runners); run it attended on device.

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
