# Live Testing

This document describes the rebuilt repo-owned QA harness for local and CI validation.

## Entrypoint

Use `scripts/harness.py` as the portable orchestrator. Xcode remains the build and test authority; the Python harness supplies deterministic roots, fixture setup, locking, `.xcresult` parsing, and JSON envelopes.

```sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer native
python3 scripts/harness.py test --layer ios
python3 scripts/harness.py test --layer e2e
python3 scripts/harness.py diagnose
python3 scripts/harness.py bench --category latency --runs 3
```

Harness output roots:

- `build/harness/derived-data/`
- `build/harness/results/`
- `build/harness/source-packages/`
- `build/harness/artifacts/`
- `build/harness/.lock`

## Layers

| Layer | Purpose | Backing tool |
|---|---|---|
| `validate` | static guards, project-input checks, contract sanity, stale-reference checks | shell + Python |
| `contract` | fast contract schema and metadata checks | Python |
| `swift` | macOS unit/integration foundation tests | `xcodebuild` + `QwenVoice Foundation` |
| `native` | macOS runtime/XPC/native compatibility subset | `xcodebuild` + `QwenVoiceRuntime` plan |
| `ios` | iPhone foundation tests when an iPhone simulator is available | `xcodebuild` + `VocelloiOS Foundation` |
| `e2e` | macOS XCUITest smoke over the stub engine/live-preview flow | `xcodebuild` + `Vocello UI` |

The iOS lane returns a structured skip when no iPhone simulator destination is installed. Generic iPhone compile proof is still maintained by `./scripts/build_foundation_targets.sh ios`.

## Strict E2E

Hosted macOS runners can fail first-time UI automation because Accessibility/TCC permission has not been granted or because the app window is not frontmost in the accessibility tree. By default, the harness demotes those two environment failures into clear skipped results.

Release signoff on a controlled machine must use strict mode:

```sh
QWENVOICE_E2E_STRICT=1 python3 scripts/harness.py test --layer e2e
```

In strict mode, TCC and window-registration failures fail the lane instead of being treated as skipped passes.

## Test Support Code

`QW_TEST_SUPPORT` is defined only for Debug/test builds. It gates:

- stub engine selection
- UI launch arguments and isolated defaults/app-support fixtures
- fault injection
- test-only XPC invalidation hooks
- opt-in benchmark runners

Release builds must not rely on `QW_TEST_SUPPORT` behavior.

## Result Triage

Every Xcode-backed harness lane writes build and test result bundles under `build/harness/results/<lane>/`.

Useful commands:

```sh
xcrun xcresulttool get build-results --path build/harness/results/swift_source_tests/build.xcresult
xcrun xcresulttool get test-results summary --path build/harness/results/swift_source_tests/test.xcresult
```

Treat the `.xcresult` bundle as authoritative when stdout only reports a generic `** TEST BUILD FAILED **`.

## Benchmarks

Benchmarks are opt-in release-investigation tools, not default PR gates:

```sh
python3 scripts/harness.py bench --category latency --runs 3
python3 scripts/harness.py bench --category load --runs 3
python3 scripts/harness.py bench --category quality --runs 3
python3 scripts/harness.py bench --category tts_roundtrip --runs 3
```

`latency` and `load` currently use portable command-backed measurements. `quality` and `tts_roundtrip` are preserved as explicit lanes but skip until native model/audio evaluation is wired without the retired Python backend path.
