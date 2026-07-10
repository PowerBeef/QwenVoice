# Testing runbook (Vocello / QwenVoice)

> **Single source of truth for how Vocello is tested.** When docs disagree, authority order is:
> **`Sources/` → `scripts/*.sh` → this file → [`AGENTS.md`](../../AGENTS.md) → other docs.**
> Historical context only: [`docs/post-mortem/`](../post-mortem/),
> [`docs/releases/`](../releases/), [`on-device-ui-testing-research-report.md`](on-device-ui-testing-research-report.md).
>
> Deterministic gates are run by checked-in scripts and CI. macOS frontend acceptance is the
> explicit semantic layer: `$vocello-macos-ui-qa` uses Codex Computer Use, while
> `scripts/macos_agent_ui.sh` makes its fresh structured attestation gate-bearing through typed
> XPC/backend probes, History, WAV, fingerprints, and cleanup. iOS remains physical-device
> XCUITest for gates and mirroir for exploratory QA. Measurement never depends only on how the UI
> was driven.
>
> Subsystem deep-dives: [`ios-device-testing.md`](ios-device-testing.md),
> [`macos-testing.md`](macos-testing.md), [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md),
> [`ui-test-surface.md`](ui-test-surface.md) (generated identifier catalog).
> Active implementation and acceptance status: [`development-progress.md`](../development-progress.md).

## 1. The model: on-device iOS + macOS smoke

All iOS UI tests run on a **paired physical iPhone** via `scripts/ios_device.sh`. The MLX
engine runs in-process on Metal and **cannot initialize on the iOS Simulator** — the Simulator
is not used for any Vocello iOS test or agent workflow.

| Platform | Backend | Where it runs | Suites |
| --- | --- | --- | --- |
| **iOS UI** | real in-process MLX engine | **paired iPhone only** | `Smoke`, `Sheet`, `OnDeviceDownload`, `ColdGeneration`, `ReviewTour` |
| **macOS frontend** | real (out-of-process XPC) | **local macOS 26 host** | Computer Use quick/full/benchmark scenarios + typed attestation |

Warm-path suites (`Smoke`, `Sheet`, `ReviewTour`) share [`VocelloUITestApp`](../../Tests/VocelloiOSUITests/VocelloUITestApp.swift) — one app session with the real engine. `ColdGeneration` and `OnDeviceDownload` self-launch fresh instances when they need cold starts or download-specific setup.

## 1b. Model fixtures (when weights are required)

Real-engine lanes need the **Custom Voice (Speed)** variant (`pro_custom_speed`, ~2.3 GB) on
the device for generation and bench paths. Download tests intentionally remove or re-fetch models.

| Lane | Models required | How to prepare |
| --- | --- | --- |
| macOS Computer Use / profile / UI benchmark | relevant Speed models in **debug** context (`QWENVOICE_DEBUG=1`) | `scripts/macos_test.sh models ensure` (canonical store + debug symlink) |
| macOS deterministic `test` | no model weights | Core, injectable XPC, vendored runtime and harness contracts |
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

### macOS deterministic + frontend acceptance (local)
```sh
scripts/macos_test.sh models ensure   # one-time Speed model + debug symlink
scripts/macos_test.sh models check    # read-only status (debug context)
scripts/macos_test.sh test            # Core + XPC transport + owned Qwen3 runtime + harness
scripts/macos_agent_ui.sh impact      # selects none / quick / full / benchmark
# Invoke $vocello-macos-ui-qa <selected-suite>, then validate its report:
scripts/macos_test.sh ui-report --suite full
scripts/macos_test.sh gate            # deterministic/crash checks + impact-selected attestation
# optional bounded engine bench + regression compare vs benchmarks/baselines/mac-gate-bench.json:
# QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate
scripts/macos_test.sh profile [spec]  # Instruments + vocello bench; fails on bench error unless --allow-bench-fail
```

### iOS UI tests (paired iPhone, attended)

**Operator guide:** [`ios-device-testing.md`](ios-device-testing.md) — one-time setup,
§ Daily workflow, § Visual reference (workflow diagrams), lane map with time budgets, model fixture policy.

```sh
scripts/ios_device.sh preflight           # device + signing + app + dSYM readiness
scripts/ios_device.sh models check        # which lanes need device models
scripts/ios_device.sh test                # default: Smoke + Sheet + ColdGeneration (all Speed models on device)
scripts/ios_device.sh ui-test --download  # OnDeviceDownload only (uninstalls pro_custom)
scripts/ios_device.sh test --cold         # ColdGeneration (needs Speed model on device)
scripts/ios_device.sh gate                # pre-merge gate (device)
```

## 3b. UI-driven benchmark lanes — step-by-step (any agent can run these)

Both platforms have a full matrix through the real UI, with different drivers: Computer Use on
macOS and physical-device XCUITest on iOS. Durable telemetry is gated afterward.

### macOS: `scripts/macos_test.sh bench-ui`

1. **Preconditions (all required):**
   - Idle machine — `pgrep -x xcodebuild` must print nothing (a concurrent build
     contaminates RTF).
   - Models: `scripts/macos_test.sh models ensure` once per machine.
   - Exact app built: `./scripts/build.sh build`.
   - Computer Use permissions: `scripts/macos_agent_ui.sh doctor --suite benchmark --json`.
2. **Run:** invoke `$vocello-macos-ui-qa benchmark`. Computer Use drives each semantic action;
   the shell harness owns the take manifest, timestamps, cold/warm labels and deterministic checks.
3. **Verdict:** `scripts/macos_test.sh bench-ui --report <run>` validates the report, typed
   app/XPC/backend rows, fingerprints, cleanup and merged matrix. Artifacts live under
   `build/macos/agent-ui/<runID>/`.
4. **Triage:** inspect `probe-verdict.json`, `events.jsonl`, generation assertions, layer JSONL,
   app/service logs, and `scripts/macos_test.sh crashes`. A coordinate fallback is an automation
   warning, never silent proof.

### iOS: `scripts/ios_device.sh bench-ui` (paired iPhone; NEVER the Simulator)

1. **Preconditions (all required):**
   - `scripts/ios_device.sh device-state` → `MIRROR_ACTIVE` (exit 0). Anything else:
     fix per the printed advice (phone locked nearby, Mirroring resumed, no call).
   - All three Speed models on the phone: `scripts/ios_device.sh models check --strict`
     (headless inventory pull — phone locked OK). See
     [`ios-device-testing.md` § Agent + MCP workflow](ios-device-testing.md#agent--mcp-workflow).
     Note: `ui-test --download` (OnDeviceDownload) UNINSTALLS Custom Voice — run it separately
     from the default gate; reinstall Custom Voice before the next default `test` / `gate`.
     benching if a gate ran since the last install. Downloads are serial (queued), ~4 min each.
   - Clone cells additionally need a **saved voice enrolled on the phone** (Voices →
     Save a new voice, attended — the mic does not work through iPhone Mirroring).
     Without one, clone cells are skipped automatically and the gate adjusts.
   - Phone unlocked for the XCUITest attach (first run of the day may show the
     passcode/automation prompt — human enters it).
2. **Run:** `scripts/ios_device.sh bench-ui --label "<why>"` (same matrix semantics and
   scoping flags as macOS; optional `--profile` for xctrace during matrix). The driver runs
   `device-state` + `uitest-doctor` preflight, builds, installs, runs
   `VocelloiOSBenchUITests/testFullMatrix`, pulls diagnostics, summarizes, and gates.
3. **Verdict:** `scripts/check_ios_ui_bench.py` prints per-cell rows + `PASS`/`FAIL`
   against the take count the test itself reported (`VOCELLO-BENCH-UI-MANIFEST ran=N`
   in the log). Artifacts: `build/ios/bench-ui-<runID>/` + `build/ios-diagnostics/`.
4. **Triage:** install/attach errors (`CoreDeviceError 3002`, `Connection interrupted`) =
   device unreachable/locked → re-check `device-state`, unlock, retry once. Take timeout =
   read `iosStudio_generationError` in the log; model missing = `textInput_installModelButton`
   assertion. Interference mid-run: the sentinel polls abort with the cause named.
   Post-run MCP playbook: [`ios-device-testing.md` § Agent + MCP workflow](ios-device-testing.md#agent--mcp-workflow).
5. **Comparing numbers:** engine rows from `bench-ui` are like-for-like with
   `ios_device.sh bench` (same `-Onone` build). Never compare against macOS or CLI lanes
   (see `benchmarking-procedure.md` §7 like-for-like table).

### Agent-driven UI QA

| Platform | Driver | Entry | Gate? |
| --- | --- | --- | --- |
| **iOS** | **mirroir native** (`describe_screen` → `tap` / `type_text`) + `measure-*` | [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix B; [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md) | **Never** |
| **macOS** | `$vocello-macos-ui-qa` Computer Use + typed harness | [`macos-testing.md`](macos-testing.md) | **Impact-selected** |

**Mirror observation (iOS):** `scripts/ios_device.sh mirror` / `shot` / `device-state` keep the
CoreDevice tunnel alive and capture evidence — **no taps**. Mirror window may sit anywhere on the
display; run `scripts/lib/ios_vision_bridge.sh calibrate` after move/resize (Peekaboo iOS fallback
only — deprecated when mirroir OCR works). iPhone mic is unavailable through Mirroring —
recording/enroll flows are attended, on the phone.

**Retired / deferred agent lanes:** iOS `bench-ui-mirroir`, `bench-ui-vision`, and `bench-ui-mcp`;
retired macOS Peekaboo, `uitest_measure.sh`, `VocelloMacUITests`, `journey`, and `uitest-doctor`.

### Harness matrix (canonical)

| Layer | iOS | macOS | Pre-merge gate? |
| --- | --- | --- | --- |
| **Gate** | `ios_device.sh gate` (XCUITest + headless generation + crashes) | `macos_test.sh gate` (deterministic tests + crashes + typed attestation) | **Yes** |
| **UI smoke** | `ios_device.sh test` / `ui-test` | `$vocello-macos-ui-qa quick\|full` + `ui-report` | Impact-selected on macOS |
| **UI matrix** | `ios_device.sh bench-ui` (XCUITest) | `$vocello-macos-ui-qa benchmark` + `macos_test.sh bench-ui` | Backend-impact/release evidence |
| **Lang verification** | `ios_device.sh lang-bench` (hint + output) | `macos_test.sh lang-bench` (hint) | No |
| **Headless engine** | `ios_device.sh bench` | `vocello bench` / `macos_test.sh profile` | Optional in gate |
| **Agent operator** | mirroir + tour doc | Computer Use + repository skill | iOS never; macOS structured reports can gate |
| **Mirror infra** | `mirror` / `shot` / `device-state` | — | Support only |

Other docs should **link here** for lane semantics instead of re-describing the matrix.

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
- **`macos-deterministic-tests`**: runs Core/XPC/runtime/harness tests, builds the exact-path app
  for fingerprinting, and validates the impact-selected committed attestation. CI does not claim
  to execute Computer Use.

**Pre-merge iOS quality gate:** run `scripts/ios_device.sh gate` locally on your paired iPhone
before merging.

## 5. Determinism rules

- iOS XCUITest waits with `waitForExistence` / `XCTNSPredicateExpectation`, never `usleep` / `Thread.sleep`
  / RunLoop polling.
- iOS permission/automation alert handling remains owned by the physical-device suite.
- Query by stable `accessibilityIdentifier` (`voicesRow_*`, `textInput_*`, `studioChip_*`, …);
  these are surface area and must survive refactors. Never let a `screen_*` container shadow its
  descendants — use the `screenPresenceMarker(_:)` leaf marker
  ([`IOSAccessibility`](../../Sources/iOS/IOSAccessibility.swift)).
- A failing assertion should explain itself (capture the error-surface text / a screenshot), so a
  single run diagnoses the cause.
- macOS Computer Use always re-observes before and after one logical action, resolves fresh element
  indices, and records screenshots/coordinates as warnings when accessibility cannot expose a control.

## 6. Perf / quality gate (real engine, mandatory pre-merge listening pass)
```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> --label "release-QA" --ledger
```
`--ledger` runs the summarizer once and appends one row to `benchmarks/HISTORY.md`. For manual
aggregation or regression checks, use `scripts/summarize_generation_telemetry.py` with
`--compare-baseline` (see [`macos-release-qa.md`](macos-release-qa.md) step 3). Committed
benchmark logs must be ≤256 KB; raw `*.jsonl` is gitignored.
