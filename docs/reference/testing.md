# Testing Reference

This document describes the current automated test surface and supported commands for QwenVoice.

## Test Targets

- `QwenVoiceUITests/` — macOS XCUITests for shipped UI behavior
- `QwenVoiceTests/` — focused Swift unit tests for bridge parsing, batch coordination, manifest loading, and database migration behavior
- `backend_tests/` — Python `unittest` coverage for the JSON-RPC backend process

Current inventory:

- UI tests: 19 files / 58 test methods
- Unit tests: 4 files / 23 test methods
- Backend tests: 35 test cases

## Primary Commands

### Full automation

```bash
./scripts/run_full_app_automation.sh
```

### UI runner

```bash
./scripts/run_tests.sh
./scripts/run_tests.sh --suite smoke
./scripts/run_tests.sh --suite ui
./scripts/run_tests.sh --suite integration
./scripts/run_tests.sh --suite all
./scripts/run_tests.sh --suite debug
./scripts/run_tests.sh --suite feature-matrix
./scripts/run_tests.sh --list
./scripts/run_tests.sh --class SidebarNavigation
./scripts/run_tests.sh --test CustomVoiceViewTests/testCustomVoiceScreenCoreLayout
./scripts/run_tests.sh --probe clone-tone
```

### Backend tests

```bash
./scripts/run_backend_tests.sh
```

## UI Suite Boundaries

- `smoke` — one representative test per major UI class
- `ui` — non-generation UI coverage
- `integration` — `GenerationFlowTests`
- `all` — `ui` + `integration`
- `debug` — debug hierarchy and accessibility checks
- `feature-matrix` — deterministic fixture-driven coverage for all shipped surfaces and primary UI controls

Probe commands:

- `--probe generation-benchmark` delegates to `scripts/run_generation_benchmark.sh`
- `--probe clone-tone` delegates to `scripts/evaluate_clone_tone.py`

## Automation Tiers

- Backend contract tests verify JSON-RPC behavior in `backend_tests/`.
- Swift unit tests verify bridge parsing, batch coordination, contract loading, and database migration behavior in `QwenVoiceTests/`.
- Smoke/layout/navigation/availability UI tests now default to isolated stub-backed launches through `StubbedQwenVoiceUITestBase`, so they can validate shell behavior without paying live backend/bootstrap cost.
- `QwenVoiceUITestBase` defaults to `freshPerTest` launches, and state isolation now really injects isolated app-support/defaults state instead of being descriptive-only.
- Live backend UI coverage is intentionally narrower and focused on explicit integration/generation paths such as `GenerationFlowTests`.
- Deterministic feature-matrix UI tests also run in `QWENVOICE_UI_TEST_BACKEND_MODE=stub`, but they remain the full fixture-driven coverage lane rather than the lighter smoke lane.

## Test Runner Behavior

- `scripts/run_tests.sh` caches `xcodebuild build-for-testing` output under `build/test/`
- the cache fingerprint includes current source inputs, the resolved destination, and the scripted UI profile define
- the runner resolves the concrete host macOS destination instead of using the older ambiguous `platform=macOS` fallback
- the runner suppresses the noisy duplicate-destination warning block from `xcodebuild`
- the runner performs repo-process cleanup and a short cooldown before macOS UI automation runs
- launch readiness now waits for test-only main-window or Settings sentinels instead of treating the first visible window as success
- smoke now runs sequentially, retries the current filter once on XCTest infrastructure failures, and stops early if the same infrastructure failure repeats
- targeted `--test` and `--class` invocations also retry once after automation bootstrap failures such as `Timed out while enabling automation mode`
- infrastructure failures are recorded separately from assertion failures via `progress.txt`, `latest-progress.txt`, `infrastructure-failure.txt`, and per-filter status files under `build/test/results/`
- `scripts/run_full_app_automation.sh` runs the full automation stack in order and stops on the first failing stage while printing the failing artifact path

## Known Caveats

- macOS UI testing on current Xcode/macOS combinations can still intermittently fail before the control session is established. This is a runner-level failure, not the same as a product regression.
- Integration-style generation tests still depend on model/backend state and may skip when prerequisites are unavailable.
- The clone-tone probe is opt-in and requires a locally installed/authenticated Homebrew Gemini CLI plus the clone model installed in the normal app-support models directory.
- On this machine the probe defaults to `/opt/homebrew/bin/gemini`, injects `/opt/homebrew/bin` into `PATH` so the Homebrew `node` launcher resolves correctly, and pins explicit Gemini judge models instead of using the CLI default model selection.
- Judge-model fallback for the probe is capacity-aware: prefer `gemini-3.1-pro-preview`, then fall back to `gemini-2.5-pro`, `gemini-2.5-flash`, and `gemini-2.5-flash-lite`.
- Deterministic feature-matrix coverage stubs external OS dialogs and backend/model work on purpose; it is the feature-coverage lane, not the truth source for real backend behavior.
- Unsigned-release behavior is still validated by release packaging checks rather than normal app-feature automation.
- Backend benchmark tooling still exercises advanced sampling and internal batch paths that the shipping GUI does not expose, even though single-generation streaming is now part of the shipped app.
