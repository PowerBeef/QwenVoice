# Release Readiness

This document tracks the current release-readiness program and the intentional split between the public macOS release posture and the broader merged repo state.

## Current Release Track

The repo is currently operating on a `macOS-first release track`.

That means:

- the next public release target is macOS only
- `Vocello-macos26.dmg` is the only public ship artifact for the current milestone
- iPhone remains in active development and stays compile-safe on `main`
- iPhone TestFlight and owned-device proof stay maintained, but they are deferred from public release signoff until the shared core is proven stable on macOS

## Public Homepage Posture

The public GitHub landing-page surfaces have been refreshed to the current `Vocello` brand posture for this milestone.

Public surfaces:

- `README.md`
- GitHub repo description
- GitHub homepage URL should remain blank

Public messaging rules:

- Lead with `Vocello` as the shipped product brand.
- Keep public claims aligned with the current macOS product reality and the active `macOS-first release track`.
- Do not imply that iPhone is already shipping publicly in this milestone.
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

- Public homepage posture: refreshed and Vocello-first
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
- the `.xcresult` evidence paths for maintained source/runtime lanes and maintained archive/release lanes when relevant

## Current Signoff Tiers

The current `macOS-first release track` uses three proof tiers:

1. Shared-core regression proof
   - `Project Inputs`
   - `Backend Freeze Gate`
   - local `check_project_inputs`, `validate`, `swift`, `contract`, `native`, `build_foundation_targets.sh macos`, and `build_foundation_targets.sh ios`
2. macOS ship gate
   - local unsigned macOS packaging and verification
   - `Vocello macOS Release` for the signed/notarized public artifact
3. Deferred iPhone release proof
   - `python3 scripts/harness.py test --layer ios`
   - owned-device validation follow-through
   - `Vocello iOS TestFlight`

Only tiers 1 and 2 block the current public release milestone.

### Tier → Workflow Mapping

Each tier is owned by concrete CI workflow files. Update this table whenever a
workflow is renamed, split, or retired so prose and YAML do not drift.

| Tier | Workflow file | Workflow display name | Primary validation step |
|---|---|---|---|
| 1. Shared-core regression | `.github/workflows/project-inputs.yml` | `Project Inputs` | `./scripts/check_project_inputs.sh` |
| 1. Shared-core regression | `.github/workflows/apple-platform-validation.yml` | `Backend Freeze Gate` | `python3 scripts/harness.py test --layer swift` + `--layer native` + `--layer contract` + generic macOS and iPhone builds + unsigned release verification |
| 2. macOS ship gate (local) | — | — | `./scripts/release.sh` + `./scripts/verify_release_bundle.sh` + `./scripts/verify_packaged_dmg.sh` |
| 2. macOS ship gate (CI) | `.github/workflows/macos-release.yml` | `Vocello macOS Release` | signed + notarized `Vocello-macos26.dmg` build + `stapler validate` + post-notarization verify |
| 3. Deferred iPhone release | `.github/workflows/ios-testflight.yml` | `Vocello iOS TestFlight` | `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh` |

Only tiers 1 and 2 block the current public release milestone. Tier 3 is maintained but deferred from public signoff until the iPhone re-entry conditions below are met.

## Program Priorities

The current execution order is:

1. keep public messaging polished, Vocello-first, and aligned with shipped macOS reality
2. stabilize and optimize the shared core on macOS until the release candidate is deterministic
3. keep iPhone compile proof green on `main` without treating iPhone release proof as blocking for this milestone
4. maintain separate owned-device and official-minimum iPhone proof states for later re-entry
5. re-open the iPhone release track only after the macOS-first milestone ships cleanly

## Default Local macOS Signoff Loop

The default local release-readiness loop for the current milestone is:

```sh
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer native
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/release.sh
./scripts/verify_release_bundle.sh build/QwenVoice.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

Run `python3 scripts/harness.py test --layer ios` in addition to that loop when the change directly touches iPhone app, extension, model-delivery, or memory-policy behavior, or when preparing to re-open the iPhone release track.

## CI Proof Surface

- `Backend Freeze Gate` is the maintained shared-core regression gate for project inputs, shared Swift/runtime test plans, generic macOS/iPhone builds, unsigned macOS release verification, and uploaded `.xcresult` artifacts.
- `Vocello macOS Release` is the only CI-owned signed/public release proof path required for the current milestone.
- `Vocello iOS TestFlight` remains maintained as the deferred iPhone archive/export/upload-prep proof path and is not required for current macOS release signoff.
- Local release scripts remain deterministic unsigned/source-validation tools; they are not the repo’s signing or notarization source of truth.

## iPhone Re-entry Conditions

Do not treat iPhone as a public release target again until all of the following are true:

- the macOS-first milestone has shipped successfully
- no critical shared-core macOS regressions remain open from the release cycle
- the shared-core regression gate stays green after post-release fixes
- `python3 scripts/harness.py test --layer ios` is restored to maintained blocking proof for the re-entry milestone
- owned-device iPhone validation is current
- official `iPhone 15 Pro` minimum-device proof is recorded before claiming full iPhone release readiness
- `Vocello iOS TestFlight` succeeds from the intended release ref
