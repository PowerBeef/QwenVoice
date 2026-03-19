# Engineering Status

QwenVoice is currently in a strong maintenance state for a local macOS ML app: the SwiftUI frontend, long-lived Python backend, manifest-backed Swift/Python contract, and release packaging pipeline are aligned and working from the same repo truth.

## Recent Documentation-Relevant Fixes

- Debug/test builds no longer crash when a UI profile compile flag is missing.
- Model availability checks are consistent across the generation UI and model manager.
- User-facing error surfacing is consistent in Voices, Voice Cloning, and History flows.
- Static model/speaker contract data is shared between Swift and Python through `qwenvoice_contract.json`.
- Batch generation cancel now interrupts in-flight work by restarting the backend instead of only stopping between items.
- The dead `sortOrder` database column now has a real drop migration.
- Single-generation GUI flows now use streamed chunk previews and live sidebar playback backed by the Python bridge and audio player.

## Current Strengths

- Native macOS UX with no required terminal workflow for end users
- Shared manifest-driven contract between frontend and backend
- Native model downloads and local persistence
- Bundled Python + ffmpeg release pipeline

## Current Caveats

- Batch generation is still sequential and non-streaming even though the backend/runtime now supports richer streaming data and internal batch capabilities.
- Generation screens still rely on the separate Models destination for download and repair flows rather than supporting inline model installs.
- `ModelsView` still uses filesystem status through `ModelManagerViewModel` rather than backend `get_model_info`.
- On some Xcode/macOS combinations, macOS UI test sessions can still fail before a control session is established even when the app code is healthy.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `scripts/`
3. `project.yml`
4. prose docs
