# Contributing

Thanks for helping with QwenVoice/Vocello. This repo is in a macOS-first release track, so contributor work should keep the next public macOS release clean while keeping iPhone compile-safe.

## Source Of Truth

When facts disagree, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/` and `.github/workflows/`
4. maintained docs under `docs/reference/`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for model, speaker, variant, output, and required-file metadata.

`CLAUDE.md` is the canonical repository operating guide for coding agents working in this checkout.

Current model-selection policy:

- macOS exposes both `Speed / 4-bit` and `Quality / 8-bit` variants for Custom Voice, Voice Design, and Voice Cloning.
- 8 GB/floor Macs default to and recommend Speed; mid/high-memory Macs default to and recommend Quality.
- Mac users may select either installed variant per generation mode.
- iPhone remains Speed-only.
- Legacy base model IDs resolve to the hardware-recommended variant; variant-specific IDs own model status, download, repair, delete, and install metadata.

## Workflow

- Work on `main` unless the maintainer asks for a branch.
- Edit `project.yml` for project-structure changes, then run `./scripts/regenerate_project.sh`.
- Do not reintroduce a repo-owned Python backend, Python setup path, or standalone CLI surface.
- Keep macOS release behavior aligned with `Vocello.app` and `Vocello-macos26.dmg`.
- Keep iPhone compile-safe, but do not treat iPhone release proof as blocking for the current milestone.

## Useful Checks

Start with cheap checks:

```sh
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
./scripts/qa.sh test --layer contract
```

Then run the relevant source or build proof:

```sh
./scripts/qa.sh test --layer swift
./scripts/qa.sh test --layer native
./scripts/qa.sh test --layer ios
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

The iOS QA lane requires an available iPhone simulator and reports a structured skip when none is installed. The generic iOS foundation build remains the compile proof for machines without a simulator.

The macOS UI smoke lane is:

```sh
./scripts/qa.sh test --layer e2e
```

Hosted machines may soft-skip first-time macOS Accessibility/TCC setup. Release signoff on a controlled Mac should use:

```sh
QWENVOICE_E2E_STRICT=1 ./scripts/qa.sh test --layer e2e
```

Performance and audio-QC validation is opt-in and not a default contribution gate:

```sh
./scripts/qa.sh test --layer perf
```

qa.sh outputs live under `build/harness/{derived-data,results,source-packages,artifacts}`. Inspect `.xcresult` bundles from `build/harness/results/` when a QA-backed Xcode lane fails.

For current macOS release signoff, the maintained local loop is documented in `docs/reference/release-readiness.md`.

## Runtime Boundaries

- `Sources/QwenVoiceCore/` owns shared engine semantics.
- `Sources/QwenVoiceEngineService/` hosts the active macOS XPC runtime.
- `Sources/QwenVoiceNative/` owns the macOS app-facing engine proxy/store/client layer.
- `Sources/iOSEngineExtension/` keeps heavy iPhone generation work outside the iPhone UI process.
