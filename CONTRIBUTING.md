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
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer contract
```

Then run the relevant source or build proof:

```sh
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer native
python3 scripts/harness.py test --layer ios
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

The iOS harness lane requires an available iPhone simulator and reports a structured skip when none is installed. The generic iOS foundation build remains the compile proof for machines without a simulator.

The macOS UI smoke lane is:

```sh
python3 scripts/harness.py test --layer e2e
```

Hosted machines may soft-skip first-time macOS Accessibility/TCC setup. Release signoff on a controlled Mac should use:

```sh
QWENVOICE_E2E_STRICT=1 python3 scripts/harness.py test --layer e2e
```

Benchmarks are opt-in release-investigation tools, not default contribution gates:

```sh
python3 scripts/harness.py bench --category latency --runs 3
python3 scripts/harness.py bench --category load --runs 3
```

Harness outputs live under `build/harness/{derived-data,results,source-packages,artifacts}`. Inspect `.xcresult` bundles from `build/harness/results/` when a harness-backed Xcode lane fails.

For current macOS release signoff, the maintained local loop is documented in `docs/reference/release-readiness.md`.

## Runtime Boundaries

- `Sources/QwenVoiceCore/` owns shared engine semantics.
- `Sources/QwenVoiceEngineService/` hosts the active macOS XPC runtime.
- `Sources/QwenVoiceNative/` owns the macOS app-facing engine proxy/store/client layer.
- `Sources/QwenVoiceNativeRuntime/` is retained compatibility and regression coverage, not the active policy owner.
- `Sources/iOSEngineExtension/` keeps heavy iPhone generation work outside the iPhone UI process.

When fixing streaming/session behavior that still exists in both active and retained runtime copies, update both copies in the same change.
