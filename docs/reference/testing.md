# Testing Reference

This document describes the current automated test surface and supported commands for QwenVoice.

## Test Targets

- `QwenVoiceUITests/` — macOS XCUITests for shipped UI behavior
- `QwenVoiceTests/` — focused Swift unit tests for bridge parsing, batch coordination, manifest loading, and database migration behavior
- `backend_tests/` — Python `unittest` coverage for the JSON-RPC backend process

Current inventory:

- UI tests: 11 files / 31 test methods
- Unit tests: 4 files / 14 test methods
- Backend tests: 8 test cases

## Primary Commands

### UI runner

```bash
./scripts/run_tests.sh
./scripts/run_tests.sh --suite smoke
./scripts/run_tests.sh --suite ui
./scripts/run_tests.sh --suite integration
./scripts/run_tests.sh --suite all
./scripts/run_tests.sh --suite debug
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

`--probe generation-benchmark` delegates to `scripts/run_generation_benchmark.sh`.

## Test Runner Behavior

- `scripts/run_tests.sh` caches `xcodebuild build-for-testing` output under `build/test/`
- the cache fingerprint includes current source inputs, the resolved destination, and the scripted UI profile define
- the runner resolves the concrete host macOS destination instead of using the older ambiguous `platform=macOS` fallback
- the runner suppresses the noisy duplicate-destination warning block from `xcodebuild`

## Known Caveats

- macOS UI testing on current Xcode/macOS combinations can still intermittently fail before the control session is established. This is a runner-level failure, not the same as a product regression.
- Integration-style generation tests still depend on model/backend state and may skip when prerequisites are unavailable.
- Backend benchmark tooling still exercises internal-only streaming and sampling parameters that the shipping GUI does not expose.
