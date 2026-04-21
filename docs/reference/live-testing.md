# Live Native Engine Testing

This doc covers the opt-in live smoke tests that exercise the real MLX-backed macOS engine against an installed Qwen3 model. They are intentionally gated — the default harness layers run against mocked engine surfaces so CI stays deterministic and cheap.

Use live testing when:

- You just rebased `third_party_patches/mlx-audio-swift/` or bumped an MLX pin.
- You changed `NativeMLXMacEngine`, `MLXTTSEngine`, `MLXModelLoadCoordinator`, `NativeStreamingSynthesisSession`, or the engine-service host.
- You want to verify end-to-end clone-prompt handling against a real voice reference before shipping a release.

## The Env Flag

```bash
QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1
```

When this env var is unset or `0`, the live tests under `QwenVoiceTests/NativeMLXMacEngineLiveTests.swift` are skipped via `XCTSkipUnless`. When it's `1`, they run against whatever model is installed at the paths below.

## Prerequisites

1. **Apple Silicon Mac**, macOS 26+, running on the development machine (not in CI).
2. **Installed Qwen3 TTS model.** Vocello's normal first-run model installer is the easiest path — launch the app, let it download the default model, then quit. The model lives under:
   ```
   ~/Library/Application Support/QwenVoice/models/<model-folder>
   ```
   Or, if you set `QWENVOICE_APP_SUPPORT_DIR`, under that override root.
3. **Package resolution already done.** Run a regular `./scripts/build_foundation_targets.sh macos` once first so the SwiftPM dependencies are cached. Without this the first live-test run will take 10–15 extra minutes just resolving packages.
4. **No overlapping harness / xcodebuild / packaging runs.** The harness now holds an advisory `build/harness/.harness.lock` to enforce this; the live tests share the same machine resources and should be serialized too.

## Running Them

Primary entry point:

```bash
QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 \
  xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice \
  -destination 'platform=macOS' \
  -only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests test
```

To run an individual test case, append its name:

```bash
-only-testing:QwenVoiceTests/NativeMLXMacEngineLiveTests/testNativeCustomSmokeWithInstalledModel
```

## What Gets Exercised

The live test suite covers the unhappy-path-adjacent shapes the mocked tests can't hit:

- **Cold model load** against a real on-disk Qwen3 manifest and required files.
- **Custom voice streaming** end-to-end: stream build → chunk file writes → final WAV assembly.
- **Clone preparation** against a real reference audio file (provided under `tests/fixtures/`).
- **Memory/telemetry sampling** producing a non-empty `BenchmarkSample` with real `firstChunkMs`, `residentPeakMB`, and `timingsMS` values.
- **Cancellation cleanup** against the real streaming session — session directory + output file must not leak on cancel.

Expect runtimes in the tens of seconds per test on a Mac mini M1; faster on Pro/Max hardware. A full live-test pass is typically 2–5 minutes.

## CI Status

The live tests are **not** run in any `.github/workflows/*.yml`. They require an installed model, which CI runners do not carry. The backend-freeze gate does build live-test symbols (they must compile), but does not execute them.

Re-enabling live tests in CI would require staging a model under the runner's app-support directory — tracked as out-of-scope until the iPhone release track re-opens.

## Troubleshooting

- **`XCTSkipUnless` hit without running anything** → the env var isn't exported. `export QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1` in the same shell and retry.
- **`Model 'pro_custom' is unavailable or incomplete`** → the manifest's required files aren't present under `~/Library/Application Support/QwenVoice/models/`. Launch Vocello, wait for first-run model installation, quit, and re-run.
- **Swift package resolution errors** → run `./scripts/build_foundation_targets.sh macos` first so packages are resolved under `build/foundation/source-packages/`.
- **Hang or very long runtime** → the live tests will time out if the model cannot finish generation. Look in Console.app for `OSLog` messages under the `com.qwenvoice.app` subsystem.
- **"another heavy run holds … lock"** → the harness flock is preventing an overlap. Wait for the other run to finish, or remove `build/harness/.harness.lock` if it's stale.

See also:

- `AGENTS.md` — "Never overlap heavy `xcodebuild`, `scripts/harness.py`, release packaging, live app validation, or native smoke processes."
- [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md) — live-test checklist after a vendor rebase.
- [`release-readiness.md`](release-readiness.md) — how live tests fit into the signoff tiers.
