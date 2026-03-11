# Testing Reference

This document describes the current automated test surface and supported commands for QwenVoice.

## Test Targets

- `QwenVoiceUITests/` — macOS XCUITests for shipped UI behavior
- `QwenVoiceTests/` — focused Swift unit tests for bridge parsing, batch coordination, manifest loading, and database migration behavior
- `backend_tests/` — Python `unittest` coverage for the JSON-RPC backend process

Current inventory:

- UI tests: 19 files / 45 test methods
- Unit tests: 4 files / 17 test methods
- Backend tests: 16 test cases

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

`--probe generation-benchmark` delegates to `scripts/run_generation_benchmark.sh`.

## Automation Tiers

- Backend contract tests verify JSON-RPC behavior in `backend_tests/`.
- Swift unit tests verify bridge parsing, batch coordination, contract loading, and database migration behavior in `QwenVoiceTests/`.
- Real UI/integration smoke tests verify the shipping cross-process app path in `QwenVoiceUITests/`.
- Deterministic feature-matrix UI tests run the app in `QWENVOICE_UI_TEST_BACKEND_MODE=stub` and cover all shipped surfaces plus primary controls without touching real user data or requiring downloads.

## Test Runner Behavior

- `scripts/run_tests.sh` caches `xcodebuild build-for-testing` output under `build/test/`
- the cache fingerprint includes current source inputs, the resolved destination, and the scripted UI profile define
- the runner resolves the concrete host macOS destination instead of using the older ambiguous `platform=macOS` fallback
- the runner suppresses the noisy duplicate-destination warning block from `xcodebuild`
- `scripts/run_full_app_automation.sh` runs the full automation stack in order and stops on the first failing stage while printing the failing artifact path

## Known Caveats

- macOS UI testing on current Xcode/macOS combinations can still intermittently fail before the control session is established. This is a runner-level failure, not the same as a product regression.
- Integration-style generation tests still depend on model/backend state and may skip when prerequisites are unavailable.
- Deterministic feature-matrix coverage stubs external OS dialogs and backend/model work on purpose; it is the feature-coverage lane, not the truth source for real backend behavior.
- Unsigned-release behavior is still validated by release packaging checks rather than normal app-feature automation.
- Backend benchmark tooling still exercises advanced sampling and internal batch paths that the shipping GUI does not expose, even though single-generation streaming is now part of the shipped app.
