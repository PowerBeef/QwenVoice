# Live Testing

This document describes the rebuilt QA orchestrator for local and CI validation.

## Entrypoint

Use `scripts/qa.sh` as the portable orchestrator. Xcode remains the build and test authority; qa.sh supplies deterministic roots, fixture setup, locking, and `.xcresult` parsing for the wrapped `xcodebuild` invocations.

```sh
./scripts/qa.sh validate
./scripts/qa.sh test --layer contract
./scripts/qa.sh test --layer swift
./scripts/qa.sh test --layer native
./scripts/qa.sh test --layer ios
./scripts/qa.sh test --layer e2e
./scripts/qa.sh test --layer perf      # opt-in audio-QC; not part of --layer all
```

qa.sh output roots:

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

Hosted macOS runners can fail first-time UI automation because Accessibility/TCC permission has not been granted or because the app window is not frontmost in the accessibility tree. By default, qa.sh demotes those two environment failures into clear skipped results.

Release signoff on a controlled machine must use strict mode:

```sh
QWENVOICE_E2E_STRICT=1 ./scripts/qa.sh test --layer e2e
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

Every Xcode-backed QA lane writes build and test result bundles under `build/harness/results/<lane>/`.

Useful commands:

```sh
xcrun xcresulttool get build-results --path build/harness/results/swift_source_tests/build.xcresult
xcrun xcresulttool get test-results summary --path build/harness/results/swift_source_tests/test.xcresult
```

Treat the `.xcresult` bundle as authoritative when stdout only reports a generic `** TEST BUILD FAILED **`.

## Performance Lane

Performance and audio-QC validation runs through the opt-in `perf` layer. It is not part of `--layer all` and requires installed models under `QWENVOICE_AUDIO_QC_MODELS_ROOT` (default `~/Library/Application Support/QwenVoice/models`).

```sh
./scripts/qa.sh test --layer perf
```

The lane drives `GenerationQualityAuditLiveTests`, which manages the cold/warm/exhaustive matrix internally and consumes these diagnostics-only controls:

- `QWENVOICE_QWEN3_GENERATION_SPEED_PROFILE` (`current` | `legacy123-memory` | `adaptive-failure-only` | `balanced-all-modes`)
- `QWENVOICE_QWEN3_MEMORY_CLEAR_CADENCE` (`0` disables per-step MLX cache clears)
- `QWENVOICE_QWEN3_POST_REQUEST_CACHE_POLICY` (`current` | `always` | `failure-only` | `never`)
- `QWENVOICE_AUDIO_QC_OUTPUT_DIR`, `QWENVOICE_AUDIO_QC_MODES`, `QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE`, `QWENVOICE_AUDIO_QC_REPEAT_COUNT`, `QWENVOICE_AUDIO_QC_COLD_RUNS`, `QWENVOICE_AUDIO_QC_WARM_RUNS`

The app launches as a headless `.accessory` host (`QWENVOICE_AUDIO_QC_HEADLESS_APP_HOST=1` is forced by the lane), keeping the embedded XPC service alive without rendering UI on screen. A `vm.swapusage` preflight refuses to start when swap-used ≥ `QWENVOICE_PERF_SWAP_HARD_STOP_MB` (default 8 GB) or swap-free ≤ `QWENVOICE_PERF_SWAP_MIN_FREE_MB` (default 512 MB).
