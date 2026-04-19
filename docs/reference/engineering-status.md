# Engineering Status

QwenVoice is now a merged Apple-platform repository for Vocello. The repo carries a shared engine core, a macOS XPC-isolated runtime path, and an iPhone engine-extension path without reintroducing a secondary Python backend or standalone CLI surface.

## Current Strengths

- One shared Apple-platform codebase with explicit separation between UI orchestration and isolated engine execution
- Shared manifest-driven contract for model, speaker, and platform-variant metadata
- Process isolation preserved on both platforms during generation and prewarm work
- Explicit low-RAM policy surfaces for the iPhone path, including guarded and critical memory bands
- Restored repo workflows for project inputs, Apple-platform validation, macOS release packaging/notarization, and iPhone TestFlight packaging
- Maintained release scripts for signed/notarized macOS DMGs and iPhone archive/export flows

## Current Caveats

- The iPhone target is Vocello-branded, but the macOS target graph still keeps several internal `QwenVoice` names and bundle paths for continuity.
- The supported macOS minimum-hardware path is the 4-bit `Speed` lane on `Mac mini M1, 8 GB RAM`; `Quality` remains opt-in and must stay admission-guarded.
- The repo compiles the iPhone app and engine extension, but final floor-device proof still depends on real `iPhone 15 Pro` validation under load.
- The restored iPhone TestFlight workflow still depends on real Apple signing materials, provisioning, and App Store Connect credentials.
- Visual and interaction verification remains intentionally partly manual through local Computer Use rather than full maintained XCUI parity across both platforms.

## Source Of Truth

When documentation and code drift, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs
