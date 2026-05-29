# Contributing

Thanks for helping with QwenVoice/Vocello. This repo is in a macOS-first release track, so contributor work should keep the next public macOS release clean while keeping iPhone compile-safe.

## Agent Guide

`CLAUDE.md` at the repo root is the single source of truth for repo conventions, build commands, generation-flow architecture, performance + memory adaptation, known traps, and the "no tests on CI" stance. Read it first; this file is the contributor-facing summary, `CLAUDE.md` has the depth.

## Source Of Truth

When facts disagree, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/`
4. maintained docs under `docs/reference/`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for model, speaker, variant, output, Hugging Face revision, and required-file metadata.

Model-selection policy (Mac exposes Speed/4-bit + Quality/8-bit per mode, hardware-default Speed on 8 GB / Quality on larger; iPhone Speed-only) is owned by `qwenvoice_contract.json` and described in `CLAUDE.md` § Architecture — don't restate it here.

## Workflow

- Work on `main` unless the maintainer asks for a branch.
- Edit `project.yml` for project-structure changes, then run `./scripts/regenerate_project.sh`.
- Do not reintroduce a repo-owned Python backend, Python setup path, or standalone CLI surface.
- Keep macOS release behavior aligned with `Vocello.app` and `Vocello-macos26.dmg`.
- Keep iPhone compile-safe, but do not treat iPhone release proof as blocking for the current milestone.
- iPhone on-device MLX, memory admission, and Apple increased-memory entitlement work: start at [`docs/reference/ios-shipping.md`](docs/reference/ios-shipping.md).

## Useful Checks

Start with the static validator:

```sh
./scripts/check_project_inputs.sh
```

Then run the relevant build proof:

```sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

Behavioral testing is local-only; CI (`.github/workflows/release.yml`) is scoped to the macOS DMG (`package`) plus iOS compile-safety (`compile-ios`) — no tests, benches, or smoke runs. Behavioral validation is **manual local app acceptance**: there is no automated UI-driving, smoke, or benchmark harness — build and launch the Debug app and exercise the affected paths by hand. The full CI boundary, the Debug vs repo-local-Release vs installed data-store rules, and the "don't reintroduce a test framework, extra CI workflow, or UI-driving / bench harness without a scoped decision" stance are documented in `CLAUDE.md` § "Testing policy" and § "Runtime data folders".

The `scripts/build.sh` script is the canonical local entrypoint (`debug`, `run`, `release`, `clean`); the lower-level scripts remain available but route through it. At most one Debug `.app` and one Release `.app/.dmg` live under `build/` at a time — the build script prunes stale products automatically.

For current macOS release signoff, the maintained local loop is documented in `docs/reference/release-readiness.md`.

### Runtime Data Folders

Three non-overlapping, configuration-aware tiers — **Debug** (`QwenVoice-Debug/`, persistent across rebuilds), **repo-local Release** (`QwenVoice-Release-Local/<release-data-id>/`, fresh per `scripts/release.sh` packaging), and **installed Release** (`QwenVoice/`, end-user). `QWENVOICE_APP_SUPPORT_DIR` overrides the root. Full paths + selection logic: `CLAUDE.md` § "Runtime data folders".

## Runtime Boundaries

- `Sources/QwenVoiceCore/` owns shared engine semantics.
- `Sources/QwenVoiceEngineService/` hosts the active macOS XPC runtime.
- `Sources/QwenVoiceNative/` owns the macOS app-facing engine proxy/store/client layer.
- `Sources/iOSEngineExtension/` keeps heavy iPhone generation work outside the iPhone UI process.
