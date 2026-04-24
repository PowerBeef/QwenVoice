# Release Readiness

This document tracks the current release-readiness program and the intentional split between the public macOS release posture and the broader merged repo state.

## Current Release Track

The repo is currently operating on a `macOS-first release track`.

That means:

- the next public release target is macOS only
- `Vocello-macos26.dmg` is the only public ship artifact for the current milestone and requires `macOS 26.0` as the minimum
- `macOS 15` was supported only on the already-shipped `QwenVoice v1.2.3` and is retired going forward
- iPhone remains in active development and stays compile-safe on `main`
- iPhone TestFlight and owned-device proof stay maintained, but they are deferred from public release signoff until the shared core is proven stable on macOS

## Public Homepage Posture

The public GitHub landing page currently describes `QwenVoice v1.2.3` — the shipped public build — with `Vocello` framed as the forward rebrand that lands with the next macOS release. The formal flip to a Vocello-led landing page happens when the Vocello-branded macOS release actually ships.

Public surfaces:

- `README.md`
- GitHub repo description
- GitHub homepage URL should remain blank

Public messaging rules:

- Lead with `QwenVoice` today because that is the currently shipped public brand. Frame `Vocello` as the forward rebrand, not as the current shipping name.
- Keep public claims aligned with the current macOS product reality and the active `macOS-first release track`.
- Do not imply that iPhone is already shipping publicly in this milestone. Present the iPhone app publicly as the in-development "Vocello for iPhone" — standalone, 4-bit, open source in this repo, published via the App Store once ready.
- Do not advertise a public website until one actually exists.
- Do not present the full merged Apple-platform transition as already complete and publicly shipped.

## Proof Matrix

### macOS

- Official minimum hardware: `Mac mini M1, 8 GB RAM`
- Supported default path on minimum hardware: 4-bit `Speed`
- Current local source gates: maintained
- Current hosted release path: signed and notarized DMG on GitHub Releases
- Current public release target: yes

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

- Public homepage posture: QwenVoice-led for the currently shipped `v1.2.3` build; flip to Vocello-led happens when the Vocello-branded macOS release ships
- macOS source and packaging surfaces: maintained in-repo
- iPhone archive/export/TestFlight tooling: maintained in-repo
- Current public release milestone: macOS only
- iPhone owned-device proof: `iPhone 17 Pro` path is the active validation target
- iPhone official minimum-device proof: pending until `iPhone 15 Pro` evidence is recorded

## Release Evidence Expectations

Release-facing metadata and docs should record:

- the real device used for owned-device iPhone validation
- the official minimum iPhone device
- whether minimum-device proof is `pending`, `recorded`, or `not_applicable`
- whether the TestFlight path was exported locally or uploaded to App Store Connect
- the current capability and entitlement baseline from `config/apple-platform-capability-matrix.json`
- the `.xcresult` evidence paths for maintained build and release lanes when relevant

## Current Signoff Tiers

The current `macOS-first release track` uses three proof tiers:

1. QA and build proof
   - `Project Inputs`
   - `Apple Platform QA Gate`
   - local `check_project_inputs`, `harness validate`, `contract`, `swift`, `native`, `build_foundation_targets.sh macos`, and `build_foundation_targets.sh ios`
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
| 1. QA and build proof | `.github/workflows/project-inputs.yml` | `Project Inputs` | `python3 scripts/harness.py validate` |
| 1. QA and build proof | `.github/workflows/apple-platform-validation.yml` | `Apple Platform QA Gate` | harness validate/contract/source/native/UI smoke + generic macOS and iPhone builds + unsigned release verification |
| 2. macOS ship gate (local) | — | — | `./scripts/release.sh` + `./scripts/verify_release_bundle.sh` + `./scripts/verify_packaged_dmg.sh` |
| 2. macOS ship gate (CI) | `.github/workflows/macos-release.yml` | `Vocello macOS Release` | signed + notarized `Vocello-macos26.dmg` build + `stapler validate` + post-notarization verify |
| 3. Deferred iPhone release | `.github/workflows/ios-testflight.yml` | `Vocello iOS TestFlight` | `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh` |

Only tiers 1 and 2 block the current public release milestone. Tier 3 is maintained but deferred from public signoff until the iPhone re-entry conditions below are met.

## Program Priorities

The current execution order is:

1. keep public messaging polished and aligned with the currently shipped `QwenVoice v1.2.3` build, framing `Vocello` as the forward rebrand
2. stabilize and optimize the shared core on macOS until the release candidate is deterministic
3. keep iPhone compile proof green on `main` without treating iPhone release proof as blocking for this milestone
4. maintain separate owned-device and official-minimum iPhone proof states for later re-entry
5. re-open the iPhone release track only after the macOS-first milestone ships cleanly

## Default Local macOS Signoff Loop

The default local release-readiness loop for the current milestone is:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer native
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/release.sh
./scripts/verify_release_bundle.sh build/Vocello.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

Controlled-machine UI signoff:

```sh
QWENVOICE_E2E_STRICT=1 python3 scripts/harness.py test --layer e2e
```

## CI Proof Surface

- `Apple Platform QA Gate` is the maintained gate for project inputs, harness validation, contract/source/native/UI smoke layers, generic macOS/iPhone builds, unsigned macOS release verification, and uploaded `.xcresult` artifacts.
- `Vocello macOS Release` is the only CI-owned signed/public release proof path required for the current milestone.
- `Vocello iOS TestFlight` remains maintained as the deferred iPhone archive/export/upload-prep proof path and is not required for current macOS release signoff.
- Local release scripts remain deterministic unsigned/source-validation tools; they are not the repo’s signing or notarization source of truth.

## iPhone Re-entry Conditions

Do not treat iPhone as a public release target again until all of the following are true:

- the macOS-first milestone has shipped successfully
- no critical shared-core macOS regressions remain open from the release cycle
- the QA/build gate stays green after post-release fixes
- owned-device iPhone validation is current
- official `iPhone 15 Pro` minimum-device proof is recorded before claiming full iPhone release readiness
- `Vocello iOS TestFlight` succeeds from the intended release ref

Minimum-device re-entry evidence should explicitly cover:

- iPhone 15 Pro install and first launch
- 4-bit Speed model catalog, download, resume, verification, and install
- App Group persistence for models, downloads, staging, outputs, voices, and cache
- engine-extension discovery, generation, cancellation, teardown, and replacement
- memory-pressure admission, trim, and unload behavior
- TestFlight archive/export verification and, when applicable, App Store Connect upload proof

The iPhone track remains compile-safe during the current macOS milestone, but the checklist above is not a macOS release blocker.
