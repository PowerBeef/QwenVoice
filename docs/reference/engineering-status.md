# Engineering Status

QwenVoice is now a native-only macOS ML app repository: the SwiftUI frontend, native MLX runtime, manifest-backed contract, maintained harness, and release packaging pipeline all operate without a secondary Python backend or standalone CLI surface.

## Current Strengths

- Native macOS UX with no required terminal workflow for end users
- Shared manifest-driven contract for model and speaker metadata
- Native model downloads and local persistence
- Native-only release pipeline for the shipped app bundle
- Unified harness entrypoint for validation, diagnostics, testing, and native bundle checks

## Current Caveats

- Batch generation is still sequential and non-streaming in the shipped GUI even though the native runtime supports homogeneous internal Custom, Design, and Clone batches.
- Generation screens still rely on the separate Models destination for download and repair flows rather than supporting inline installs.
- `ModelsView` still uses filesystem status through `ModelManagerViewModel` instead of a dedicated runtime query surface.
- Visual and interaction verification remains intentionally manual through Codex Computer Use rather than maintained XCUI automation.
- Some legacy benchmark categories have been retired until native replacements are implemented in the harness.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs
