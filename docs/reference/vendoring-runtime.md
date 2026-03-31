# Vendoring and Runtime Packaging

QwenVoice has two distinct Python/runtime stories:

1. **Source builds / development mode**
2. **Packaged release builds**

## Development Mode

In a clean source checkout, `Sources/Resources/python/` is usually absent. The app then:

- finds a local Python 3.11–3.14 install
- creates a venv under `~/Library/Application Support/QwenVoice/python/`
- installs dependencies from `Sources/Resources/requirements.txt`
- records the requirements hash in `.setup-complete`

## Release Packaging

`./scripts/release.sh` bundles:

- standalone Python into `Sources/Resources/python/`
- `ffmpeg` into `Sources/Resources/ffmpeg/`

Those directories are generated build assets, not hand-edited source files.

The release pipeline also:

- regenerates the Xcode project safely
- builds the app
- injects the bundled runtime resources into the final `.app`
- removes vendored wheels and compiled Python artifacts from the packaged Resources directory
- verifies the final bundle
- creates the DMG

## Qwen3-TTS Overlay Strategy

The app now installs stock `mlx-audio==0.4.2` and keeps the QwenVoice-specific Qwen3-TTS clone-speedup logic as a standalone backend helper overlay.

Relevant locations:

- `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py`
- `third_party_patches/mlx-audio/`

`scripts/build_mlx_audio_wheel.sh` is now just the source of truth for syncing the backend helper from `third_party_patches/mlx-audio/qwenvoice_speed_patch.py`.

If the GUI app’s `mlx-audio` version changes, the standalone overlay and vendoring notes must be reviewed together.

## Current Verification Surface

- `scripts/check_project_inputs.sh`
- `scripts/regenerate_project.sh`
- `scripts/verify_release_bundle.sh`
- `.github/workflows/release-dual-ui.yml`
