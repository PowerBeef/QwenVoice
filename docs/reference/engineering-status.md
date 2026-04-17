# Engineering Status

QwenVoice is currently in a strong maintenance state for a local macOS ML app: the SwiftUI frontend, long-lived Python backend, manifest-backed Swift/Python contract, harness, and release packaging pipeline are aligned and working from the same repo truth.

## Recent Documentation-Relevant Fixes

- Debug and test builds no longer crash when a UI profile compile flag is missing.
- Model availability checks are consistent across the generation UI and model manager.
- User-facing error surfacing is consistent in Voices, Voice Cloning, and History flows.
- Static model and speaker contract data is shared between Swift and Python through `qwenvoice_contract.json`.
- Batch generation cancel now interrupts in-flight work by restarting the backend instead of only stopping between items.
- The dead `sortOrder` database column now has a real drop migration.
- Single-generation GUI flows now use streamed chunk previews and live sidebar playback backed by the Python bridge and audio player.
- The native engine now supports Custom Voice, Voice Design, and Voice Cloning generation behind the stable `MacTTSEngine` boundary, including truthful clone priming and clone-conditioning reuse.
- Native batch generation now supports homogeneous Custom, Design, and Clone runs with explicit mixed-mode rejection instead of the old custom-only restriction.
- The app now selects its generation engine through `QWENVOICE_APP_ENGINE`, defaulting to native while keeping `python` as a rollback path.

## Current Strengths

- Native macOS UX with no required terminal workflow for end users
- Shared manifest-driven contract between frontend and backend
- Native model downloads and local persistence
- Bundled Python and ffmpeg release pipeline
- Unified harness entrypoint for validation, diagnostics, testing, and benchmarks

## Current Caveats

- Batch generation is still sequential and non-streaming in the shipped GUI even though the native runtime now supports homogeneous internal Custom, Design, and Clone batches; mixed-mode native batches are still rejected.
- Generation screens still rely on the separate Models destination for download and repair flows rather than supporting inline model installs.
- `ModelsView` still uses filesystem status through `ModelManagerViewModel` rather than backend `get_model_info`.
- The app still launches the Python backend for runtime coordination, Models screen truth, and sidebar/backend activity even when generation itself uses the native engine by default.
- On some Xcode and macOS combinations, macOS UI test sessions can still fail before a control session is established even when the app code is healthy.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs
