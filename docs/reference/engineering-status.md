# Engineering Status

QwenVoice is a native-only macOS ML app repository. The SwiftUI frontend, XPC-isolated native runtime, manifest-backed contract, and maintained local harness all operate without a secondary Python backend or standalone CLI surface.

## Current Strengths

- Native macOS app architecture with app-side/UI and service-side/runtime responsibilities split cleanly
- Shared manifest-driven contract for model and speaker metadata
- Native model downloads and local persistence
- Unified local harness entrypoint for validation, diagnostics, testing, and benchmark stubs
- Source-build-only repo story that matches the current checkout instead of promising hosted artifact flows

## Current Caveats

- Batch generation is still sequential and non-streaming in the shipped GUI even though the native runtime supports homogeneous internal Custom, Design, and Clone batches.
- Generation screens still rely on the separate Models destination for download and repair flows rather than supporting inline installs.
- `ModelsView` still uses filesystem status through `ModelManagerViewModel` instead of a dedicated runtime query surface.
- Visual and interaction verification remains intentionally manual through Codex Computer Use rather than maintained XCUI automation.
- There are no maintained GitHub Actions workflows or hosted release artifacts in this checkout; source builds are the supported path described by current docs.
- Some benchmark categories remain retired until native replacements are implemented in the harness.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs
