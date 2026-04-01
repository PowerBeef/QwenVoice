---
name: qwenvoice-vendored-runtime
description: Update QwenVoice vendored Python runtime, `mlx-audio` wheel patches, and packaged dependency flows safely. Use when work touches `build_mlx_audio_wheel.sh`, `third_party_patches/mlx-audio`, bundled Python or ffmpeg assets, backend runtime experiments, or release-bundle verification for packaged apps.
---

# QwenVoice Vendored Runtime

## Overview

Use this skill for runtime and packaging changes where QwenVoice relies on generated or vendored assets. The main rule is simple: change the repo-owned vendoring flow, then regenerate the bundled runtime from that source of truth. Local packaging remains useful for macOS 26 debug/runtime investigation on this machine, but shipped release proof for either UI variant must come from the GitHub `Release Dual UI` workflow outputs.

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
- repo-owned backend helper patches

### 2. For `mlx-audio`, patch the wheel flow

When the work touches Qwen3-TTS, cache strategies, streaming fixes, or vendored Python behavior:

- update the repo-owned patch sources under `third_party_patches/mlx-audio/`
- keep any helper modules and wheel patches aligned
- rebuild the wheel through `scripts/build_mlx_audio_wheel.sh`
- rebundle Python from the rebuilt wheel

Do not hand-edit installed files under `Sources/Resources/python/` as the primary implementation path.

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

### 5. Keep release-facing docs aligned

When vendoring or packaged dependency behavior changes, update the docs that maintainers rely on:

- `docs/reference/vendoring-runtime.md`
- `docs/reference/current-state.md`
- `AGENTS.md` if the workflow expectations changed materially

## Special Cases

### KV-cache or TurboQuant-style experiments

Treat performance/runtime spikes as internal until measurements prove otherwise:

- keep the default shipped runtime conservative
- wire experiments behind internal-only parameters
- compare against the dense baseline and any existing control arm
- do not declare success from memory savings alone if latency or output fidelity regresses

### Bundled dependency questions

When asked whether a packaged app uses bundled Python or ffmpeg, rely on runtime diagnostics and `verify_release_bundle.sh`, not inference from file presence.

## Failure Shields

- Do not patch generated runtime assets directly when a repo-owned vendoring path exists.
- Do not forget to rebuild the wheel after changing `third_party_patches/mlx-audio/`.
- Do not stop at source tests when packaged runtime behavior is part of the request.
- Do not treat local macOS 26 packaging as authoritative release proof for either shipped variant.
- Do not let `__pycache__` or `.pyc` files leak into tracked changes.
- Do not copy CLI speaker maps or cwd-based assumptions into the GUI runtime.
