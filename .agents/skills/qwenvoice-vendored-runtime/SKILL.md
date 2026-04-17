---
name: qwenvoice-vendored-runtime
description: Update QwenVoice source/debug Python compatibility assets, `mlx-audio` wheel patches, `mlx-audio-swift`, and packaged dependency flows safely. Use when work touches `build_mlx_audio_wheel.sh`, `third_party_patches/mlx-audio`, `third_party_patches/mlx-audio-swift`, Python compatibility assets, backend runtime experiments, or release-bundle verification for packaged apps.
---

# QwenVoice Vendored Runtime

## Overview

Use this skill for runtime and packaging changes where QwenVoice relies on generated or vendored assets. The main rule is simple: change the repo-owned vendoring flow, then regenerate the relevant source/debug runtime or project artifacts from that source of truth. Local packaging remains useful for macOS 26 debug/runtime investigation on this machine, but shipped release proof for either UI variant must come from the GitHub `Release Dual UI` workflow outputs.

On this machine, keep runtime verification deliberately low-RAM: run the cheapest relevant source gates first, do not overlap heavy validation commands, and treat wheel rebuilds, rebundling, local packaging, and release-style validation as later steps once the lighter checks are already green.

Current runtime policy:

- both shipped release variants intentionally ship a native-only app bundle with no bundled Python backend, Python runtime, or bundled `ffmpeg`
- the dual-release split is for app/UI build profile and SDK differences, not for two separate bundled MLX runtimes
- moving the macOS 26 artifact to a macOS 26-specific MLX/Metal runtime would be a product/runtime decision, not a packaging optimization
- normal app launches now default the app-facing engine to `NativeMLXMacEngine`; `QWENVOICE_APP_ENGINE=python` remains the source/debug compatibility path
- stub UI harness mode now uses `UITestStubMacEngine`, which keeps deterministic preview behavior without routing through the Python adapter

## Workflow

### 1. Respect the safe edit boundaries

Treat these as generated or vendored outputs, not hand-edit targets:

- `Sources/Resources/python/`
- `Sources/Resources/ffmpeg/`
- most of `Sources/Resources/vendor/`

Prefer editing:

- `scripts/build_mlx_audio_wheel.sh`
- `scripts/bundle_python.sh`
- `scripts/bundle_ffmpeg.sh`
- `third_party_patches/mlx-audio/`
- `third_party_patches/mlx-audio-swift/`
- `project.yml`
- repo-owned backend helper patches

### 2. For `mlx-audio`, choose the right vendoring flow

When the work touches Qwen3-TTS, cache strategies, streaming fixes, or vendored Python behavior:

- update the repo-owned patch sources under `third_party_patches/mlx-audio/`
- keep any helper modules and wheel patches aligned
- rebuild the wheel through `scripts/build_mlx_audio_wheel.sh`
- rebundle Python compatibility assets from the rebuilt wheel when the source/debug path is part of the request

Do not hand-edit installed files under `Sources/Resources/python/` as the primary implementation path.

When the work touches the native backend package graph or Swift MLXAudio integration:

- update the repo-owned source under `third_party_patches/mlx-audio-swift/`
- keep `project.yml` and `Package.resolved` aligned with the package graph QwenVoice actually builds
- regenerate the Xcode project
- validate the app build and the targeted native tests before claiming the native runtime is healthy
- use `QWENVOICE_ENABLE_NATIVE_ENGINE_LIVE_TESTS=1 ... NativeMLXMacEngineLiveTests ...` as the opt-in proof of real native synthesis when an installed model is available
- if the change also affects app-engine selection, run the stub UI harness lane too, but remember that stub mode proves deterministic app-shell compatibility through `UITestStubMacEngine`, not live model synthesis

### 3. Keep the app/backend boundary in sync

If the runtime change affects backend behavior rather than just packaging, review the coupled app/backend surfaces together:

- `Sources/Resources/backend/server.py`
- `Sources/Services/PythonBridge.swift`
- `Sources/Models/RPCMessage.swift`
- `Sources/Resources/qwenvoice_contract.json` when model or speaker metadata changes

Keep CLI-only assumptions out of the shipped GUI runtime.

### 4. Rebuild and verify the packaged runtime

For vendored runtime changes, run the packaging sequence instead of stopping at unit tests:

```bash
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer server
python3 scripts/harness.py test --layer pipeline
./scripts/build_mlx_audio_wheel.sh
./scripts/bundle_python.sh
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
```

Add more targeted harness layers when the change touches UI-visible behavior.
If the request is about shipped release behavior, validate against downloaded final notarized workflow artifacts after the local macOS 26 debug checks pass.
If the user’s question can still be answered by the source gates or a narrower targeted test, stop there instead of eagerly jumping to wheel rebuilds, rebundling, `./scripts/release.sh`, or release-style validation.

### 5. Keep release-facing docs aligned

When vendoring or packaged dependency behavior changes, update the docs that maintainers rely on:

- `docs/reference/vendoring-runtime.md`
- `docs/reference/current-state.md`
- `AGENTS.md` if the workflow expectations changed materially
- `.agents/skills/qwenvoice-vendored-runtime/SKILL.md` if the maintained vendoring workflow changed materially

## Special Cases

### KV-cache or TurboQuant-style experiments

Treat performance/runtime spikes as internal until measurements prove otherwise:

- keep the default shipped runtime conservative
- wire experiments behind internal-only parameters
- compare against the dense baseline and any existing control arm
- do not declare success from memory savings alone if latency or output fidelity regresses

### Bundled dependency questions

When asked whether a packaged app still uses bundled Python or `ffmpeg`, rely on runtime diagnostics and `verify_release_bundle.sh`, not inference from file presence.

## Failure Shields

- Do not patch generated runtime assets directly when a repo-owned vendoring path exists.
- Do not forget to rebuild the wheel after changing `third_party_patches/mlx-audio/`.
- Do not change `third_party_patches/mlx-audio-swift/` without keeping `project.yml` and `Package.resolved` aligned.
- Do not overlap heavy rebuild, bundling, packaging, or release-validation commands on this machine.
- Do not jump to `./scripts/release.sh` or packaged/release validation before the cheaper source gates are already green.
- Do not let a broad cold native or MLX rebuild continue if it is not strictly necessary to answer the user’s question.
- Do not stop at source tests when packaged runtime behavior is part of the request.
- Do not treat local macOS 26 packaging as authoritative release proof for either shipped variant.
- Do not let `__pycache__` or `.pyc` files leak into tracked changes.
- Do not copy CLI speaker maps or cwd-based assumptions into the GUI runtime.
