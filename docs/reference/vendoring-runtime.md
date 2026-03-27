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

## Vendored Wheel Strategy

The app currently vendors a repacked `mlx-audio==0.4.1.post2` wheel that includes:

- a QwenVoice runtime helper module used by the backend
- repo-owned source patches applied to the unpacked upstream wheel before repacking

Relevant locations:

- `Sources/Resources/vendor/`
- `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py`
- `third_party_patches/mlx-audio/`
- `third_party_patches/mlx-audio/wheel_patches/`

`scripts/build_mlx_audio_wheel.sh` is the source of truth for rebuilding that wheel. It now:

1. downloads the upstream wheel
2. unpacks it
3. applies every patch from `third_party_patches/mlx-audio/wheel_patches/`
4. injects `third_party_patches/mlx-audio/qwenvoice_speed_patch.py`
5. syncs the backend fallback helper before repacking

If the GUI app’s `mlx-audio` version changes, the vendored wheel and vendoring notes must be updated together.

## Current Verification Surface

- `scripts/check_project_inputs.sh`
- `scripts/regenerate_project.sh`
- `scripts/verify_release_bundle.sh`
- `.github/workflows/release-dual-ui.yml`
