# Release Readiness

This document tracks the current release-readiness program and the intentional split between the public macOS release posture and the broader merged repo state.

## Current Release Track

The repo is currently operating on a `macOS-first release track`.

That means:

- the current public beta release target is macOS only
- `Vocello-macos26.dmg` is the only public beta ship artifact for the current milestone and requires `macOS 26.0` as the minimum
- `macOS 15` was supported only on the already-shipped `QwenVoice v1.2.3` and is retired going forward
- iPhone remains in active development and stays compile-safe on `main`
- iPhone TestFlight and owned-device proof stay maintained, but they are deferred from public release signoff until the shared core is proven stable on macOS

## Public Homepage Posture

The public GitHub landing page now leads with `Vocello 2.0.0 beta 1` for macOS 26 testers. `QwenVoice v1.2.3` remains the stable fallback for macOS 15 users and people who do not want beta software.

Public surfaces:

- `README.md`
- GitHub repo description
- GitHub homepage URL should remain blank

Public messaging rules:

- Lead with `Vocello 2.0.0 beta 1` as the current public macOS 26 beta.
- Keep `QwenVoice v1.2.3` visible as the stable fallback, especially for macOS 15 users.
- Keep public claims aligned with the current macOS product reality and the active `macOS-first release track`.
- Do not imply that iPhone is already shipping publicly in this milestone. Present the iPhone app publicly as the in-development "Vocello for iPhone" — standalone, 4-bit, open source in this repo, published via the App Store once ready.
- Do not advertise a public website until one actually exists.
- Do not present the full merged Apple-platform transition as already complete and publicly shipped.

## Proof Matrix

### macOS

- Official minimum hardware: `Mac mini M1, 8 GB RAM`
- Currently used testing machine: `Mac mini M2, 8 GB RAM` (project owner)
- Supported default path on minimum hardware: 4-bit `Speed`
- Model catalog proof: six macOS rows, covering `Speed / 4-bit` and `Quality / 8-bit` for Custom Voice, Voice Design, and Voice Cloning
- Active/recommended behavior: floor Macs default to and recommend Speed; mid/high-memory Macs default to and recommend Quality
- Current local source gates: maintained
- Current hosted release path: signed and notarized DMG on GitHub Releases
- Current public release target: yes

Two-track macOS hardware proof:

- `Mac mini M2, 8 GB RAM` is the active development and bench-capture host. Wall-clock perf baselines (`scripts/perf-baseline-manifest.json`, `scripts/perf-baseline-manifest-quality.json`) are captured on this hardware and regression tracking is **local-only** via `./scripts/qa.sh test --layer perf` + `./scripts/compare_perf_manifest.sh`. There is no CI mirror for the perf lane.
- `Mac mini M1, 8 GB RAM` remains the documented official minimum, but engine-level findings captured on M1 have not been re-verified on M2. The M1-saturation conclusion in `docs/reference/instruments-profiling.md` (Step Eval Flush ≈62 % of generation, irreducible without quantization or hardware change) was reached on M1; M2's wider memory bandwidth and more capable GPU cores mean the saturation profile may differ. Re-verify via Instruments on M2 before citing the finding as M2-bound.
- Do not claim the M1 floor is fully verified as of the dual-variant catalog (`d5b3c61`, 2026-05-05); the current bench evidence reflects M2 8 GB. See [`CLAUDE.md`'s Performance Findings section](../../CLAUDE.md#performance-findings) for the agent-discoverable form.

### iPhone

- Official minimum hardware: `iPhone 15 Pro`
- Currently available owned validation device: `iPhone 17 Pro`
- Supported iPhone install path: App Store / TestFlight
- Current public release target: deferred

Two-track proof policy:

- owned-device proof on `iPhone 17 Pro` is valid for active development and release-path hardening
- official minimum-device proof on `iPhone 15 Pro` remains a separate requirement
- do not claim the iPhone minimum hardware is fully proven until `iPhone 15 Pro` evidence is recorded

## Current Status

- Public homepage posture: Vocello-led for the public `v2.0.0-beta.1` macOS 26 beta, with `QwenVoice v1.2.3` retained as the stable fallback
- macOS source and packaging surfaces: maintained in-repo
- iPhone archive/export/TestFlight tooling: maintained in-repo
- Current public beta release milestone: macOS only
- iPhone owned-device proof: `iPhone 17 Pro` path is the active validation target
- iPhone official minimum-device proof: pending until `iPhone 15 Pro` evidence is recorded
- Rescue baseline: `main` commit `63a5e02` passed GitHub `Project Inputs` and `Apple Platform QA Gate` (since renamed to `Apple Platform Build Gate`) on April 26, 2026 local time
- Latest local release proof: unsigned `Vocello.app` and `Vocello-macos26.dmg` built and verified from `c6beacd`; GitHub re-proved the unsigned macOS release-artifact lane for `63a5e02`
- Latest local manual macOS smoke: launched `build/Vocello.app`, switched generation modes, generated and played a short Custom Voice preview, and confirmed the output was written to the app-support outputs folder

## Release Evidence Expectations

Release-facing metadata and docs should record:

- the real device used for owned-device iPhone validation
- the official minimum iPhone device
- whether minimum-device proof is `pending`, `recorded`, or `not_applicable`
- whether the TestFlight path was exported locally or uploaded to App Store Connect
- the current capability and entitlement baseline from `config/apple-platform-capability-matrix.json`
- macOS model-catalog proof for dual Speed/Quality rows, Active and Recommended states, per-mode active selection, and folder coexistence
- the `.xcresult` evidence paths for maintained build and release lanes when relevant

## Current Signoff Tiers

The current `macOS-first release track` uses three proof tiers:

1. Build and validation proof
   - `Project Inputs` (CI — runs `qa.sh validate`)
   - `Apple Platform Build Gate` (CI — project regen + `qa.sh validate` + generic macOS/iPhone builds + unsigned release verify)
   - local `check_project_inputs`, `qa.sh validate`, `contract`, `swift`, `native`, `build_foundation_targets.sh macos`, and `build_foundation_targets.sh ios` (behavioral test layers are local-only — CI does not run them)
2. macOS ship gate
   - local unsigned macOS packaging and verification
   - `Vocello macOS Release` for the signed/notarized public artifact
3. Deferred iPhone release proof
   - owned-device validation follow-through
   - `Vocello iOS TestFlight`

Only tiers 1 and 2 block the current public release milestone.

### Tier → Workflow Mapping

Each tier is owned by concrete CI workflow files. Update this table whenever a
workflow is renamed, split, or retired so prose and YAML do not drift.

| Tier | Workflow file | Workflow display name | Primary validation step |
|---|---|---|---|
| 1. Build and validation proof | `.github/workflows/project-inputs.yml` | `Project Inputs` | `./scripts/qa.sh validate` |
| 1. Build and validation proof | `.github/workflows/apple-platform-validation.yml` | `Apple Platform Build Gate` | project regen + `qa.sh validate` + generic macOS and iPhone builds + unsigned macOS release verification |
| 2. macOS ship gate (local) | — | — | `./scripts/release.sh` + `./scripts/verify_release_bundle.sh` + `./scripts/verify_packaged_dmg.sh` |
| 2. macOS ship gate (CI) | `.github/workflows/macos-release.yml` | `Vocello macOS Release` | signed + notarized `Vocello-macos26.dmg` build + `stapler validate` + post-notarization verify |
| 3. Deferred iPhone release | `.github/workflows/ios-testflight.yml` | `Vocello iOS TestFlight` | `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh` |

Only tiers 1 and 2 block the current public release milestone. Tier 3 is maintained but deferred from public signoff until the iPhone re-entry conditions below are met. Behavioral test layers (`contract`, `swift`, `native`, `e2e`, `perf-static`, `perf`) and UI benches (`bench_ui_generation.sh`) run **locally on Mac mini M2** — they are not gated by CI. See the "Default Local macOS Signoff Loop" section below for the local matrix.

## Program Priorities

The current execution order is:

1. keep public messaging polished and aligned with `Vocello 2.0.0 beta 1` as the macOS 26 beta and `QwenVoice v1.2.3` as the stable fallback
2. stabilize the shared core on macOS through beta feedback and follow-up release candidates
3. keep iPhone compile proof green on `main` without treating iPhone release proof as blocking for this milestone
4. maintain separate owned-device and official-minimum iPhone proof states for later re-entry
5. re-open the iPhone release track only after the macOS-first beta/stable milestone is clean

## Default Local macOS Signoff Loop

The default local release-readiness loop for the current milestone is:

```sh
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
./scripts/qa.sh test --layer contract
./scripts/qa.sh test --layer swift
./scripts/qa.sh test --layer native
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/release.sh
./scripts/verify_release_bundle.sh build/Vocello.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

Controlled-machine UI signoff:

```sh
QWENVOICE_E2E_STRICT=1 ./scripts/qa.sh test --layer e2e
```

## CI Proof Surface

- `Apple Platform Build Gate` is the maintained CI gate for project regeneration, `qa.sh validate` (static project-input check), generic macOS/iPhone builds, unsigned macOS release verification, and uploaded `.xcresult` artifacts. It does **not** run behavioral test layers — those are local-only on Mac mini M2.
- `Vocello macOS Release` is the only CI-owned signed/public release proof path required for the current milestone.
- `Vocello iOS TestFlight` remains maintained as the deferred iPhone archive/export/upload-prep proof path and is not required for current macOS release signoff.
- Local release scripts remain deterministic unsigned/source-validation tools; they are not the repo’s signing or notarization source of truth.

Current automated rescue evidence:

- GitHub `Project Inputs`: passed for `63a5e02`, run `24973916220`
- GitHub `Apple Platform QA Gate` (now `Apple Platform Build Gate`): passed for `63a5e02`, run `24973916195`
- Local unsigned release proof: `./scripts/release.sh`, `./scripts/verify_release_bundle.sh build/Vocello.app`, and `./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt`

## iPhone Re-entry Conditions

Do not treat iPhone as a public release target again until all of the following are true:

- the macOS-first milestone has shipped successfully
- no critical shared-core macOS regressions remain open from the release cycle
- the build gate stays green after post-release fixes
- owned-device iPhone validation is current
- official `iPhone 15 Pro` minimum-device proof is recorded before claiming full iPhone release readiness
- `Vocello iOS TestFlight` succeeds from the intended release ref

Minimum-device re-entry evidence should explicitly cover:

- iPhone 15 Pro install and first launch
- Speed-only model catalog, download, resume, verification, and install
- App Group persistence for models, downloads, staging, outputs, voices, and cache
- engine-extension discovery, generation, cancellation, teardown, and replacement
- memory-pressure admission, trim, and unload behavior
- TestFlight archive/export verification and, when applicable, App Store Connect upload proof

The iPhone track remains compile-safe during the current macOS milestone, but the checklist above is not a macOS release blocker.
