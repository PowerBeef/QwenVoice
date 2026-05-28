# Release Readiness

This document tracks the current release-readiness program and the intentional split between the public macOS release posture and the broader merged repo state.

## Current Release Track

The repo is currently operating on a `macOS-first release track`.

That means:

- the current public release target is macOS only
- `Vocello-macos26.dmg` is the only public ship artifact for the current milestone and requires `macOS 26.0` as the minimum
- `macOS 15` was supported only on the already-shipped `QwenVoice v1.2.3` and is retired going forward
- iPhone remains in active development and stays compile-safe on `main`
- iPhone TestFlight and owned-device proof stay maintained, but they are deferred from public release signoff until the shared core is proven stable on macOS

## Public Homepage Posture

The public GitHub landing page leads with `Vocello 2.0.0` (stable) for macOS 26+ users. `QwenVoice v1.2.3` remains the legacy fallback for macOS 15 users.

Public surfaces:

- `README.md`
- GitHub repo description
- GitHub homepage URL should remain blank

Public messaging rules:

- Lead with `Vocello 2.0.0` as the current public macOS 26+ release.
- Keep `QwenVoice v1.2.3` visible as the legacy fallback, especially for macOS 15 users.
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

- `Mac mini M2, 8 GB RAM` is the active development and bench-capture host. Perf is verified locally after material engine changes with targeted manual checks and, when appropriate, the maintained Codex–driven `scripts/uitest.sh` bench harness.
- `Mac mini M1, 8 GB RAM` remains the documented official minimum, but engine-level findings captured on M1 have not been re-verified on M2. The M1-saturation conclusion (Step Eval Flush ≈62 % of generation, irreducible without quantization or hardware change) was reached on M1; M2's wider memory bandwidth and more capable GPU cores mean the saturation profile may differ. Re-verify via manual Instruments capture on M2 before citing the finding as M2-bound.
- Do not claim the M1 floor is fully verified as of the dual-variant catalog (`d5b3c61`, 2026-05-05). Re-verify the floor-device finding before citing it for current M2 behavior.

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

- Public homepage posture: Vocello-led for the public `v2.0.0` (stable) macOS 26+ release, with `QwenVoice v1.2.3` retained as the legacy macOS 15 fallback
- macOS source and packaging surfaces: maintained in-repo
- iPhone archive/export/TestFlight tooling: maintained in-repo
- Current public release milestone: macOS only
- iPhone owned-device proof: `iPhone 17 Pro` path is the active validation target
- iPhone official minimum-device proof: pending until `iPhone 15 Pro` evidence is recorded
- Rescue baseline: `main` commit `63a5e02` passed the historical GitHub workflows on April 26, 2026 local time. Those broad workflows (`Project Inputs`, `Apple Platform QA Gate` later renamed `Apple Platform Build Gate`, `Vocello macOS Release`, `Vocello iOS TestFlight`) were retired in May 2026. The current workflow is only `.github/workflows/release.yml`, scoped to macOS DMG packaging plus iOS compile-safety; behavioral and signed-iPhone proof stays local/manual on Mac mini M2.
- Latest local release proof: unsigned `Vocello.app` and `Vocello-macos26.dmg` built and verified from `c6beacd`; GitHub re-proved the unsigned macOS release-artifact lane for `63a5e02`
- Latest local manual macOS smoke: launched the local Release app, switched generation modes, generated and played a short Custom Voice preview, and confirmed the output was written to that release app's app-support outputs folder

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

The current `macOS-first release track` uses three proof tiers. The authoritative proof commands are local, while CI is intentionally limited to macOS release packaging and unsigned iOS compile-safety. XCTest and the legacy Python/automation surfaces were retired in May 2026.

1. Build and validation proof
   - `scripts/check_project_inputs.sh` (static validation)
   - `scripts/build_foundation_targets.sh macos` + `scripts/build_foundation_targets.sh ios` (compile proof)
   - Debug behavioral smoke with `./scripts/build.sh run` or `scripts/uitest.sh prep`; use manual acceptance and targeted `scripts/uitest.sh` runbooks for affected paths
2. macOS ship gate
   - local unsigned macOS packaging and verification via `scripts/release.sh` + `scripts/verify_release_bundle.sh` + `scripts/verify_packaged_dmg.sh`
   - signed/notarized DMG produced by `scripts/release.sh --preflight full` against the project owner's Apple developer credentials (local Keychain)
3. Deferred iPhone release proof
   - owned-device validation follow-through
   - direct Debug hardware validation through `scripts/ios_device.sh` on the owned iPhone 17 Pro
   - local `scripts/check_ios_catalog.sh` + `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh`; TestFlight upload run locally

Only tiers 1 and 2 block the current public release milestone.

### Tier → Local Script Mapping

| Tier | Primary local commands |
|---|---|
| 1. Build and validation proof | `./scripts/check_project_inputs.sh` + `./scripts/build_foundation_targets.sh macos\|ios` + manual app smoke |
| 2. macOS ship gate | `./scripts/release.sh` + `./scripts/verify_release_bundle.sh` + `./scripts/verify_packaged_dmg.sh` |
| 3. Deferred iPhone release | `./scripts/ios_device.sh start` + `./scripts/ios_device.sh pull` + `./scripts/check_ios_catalog.sh` + `./scripts/release_ios_testflight.sh` + `./scripts/verify_ios_release_archive.sh` |

Only tiers 1 and 2 block the current public release milestone. Tier 3 is maintained but deferred from public signoff until the iPhone re-entry conditions below are met. There are no CI smoke, benchmark, or XCTest proof layers; local manual smoke, the maintained Codex macOS harness, and real-device iPhone screen-mirror runs are the behavioral regression checks.

## Program Priorities

The current execution order is:

1. keep public messaging polished and aligned with `Vocello 2.0.0` (stable) as the macOS 26+ release and `QwenVoice v1.2.3` as the legacy macOS 15 fallback
2. stabilize the shared core on macOS through follow-up patch releases
3. keep iPhone compile proof green on `main` without treating iPhone release proof as blocking for this milestone
4. maintain separate owned-device and official-minimum iPhone proof states for later re-entry
5. re-open the iPhone release track only after the macOS-first stable milestone is clean

## Default Local macOS Signoff Loop

The default local release-readiness loop for the current milestone is:

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/release.sh
./scripts/verify_release_bundle.sh build/Release/Vocello.app
./scripts/verify_packaged_dmg.sh build/Release/Vocello-macos26.dmg build/Release/release-metadata.txt
```

Then launch `build/Release/Vocello.app` and exercise the affected user-facing paths by hand; each packaged repo-local Release app starts from a fresh release-id-specific app-support folder and preferences suite. For Debug behavior before release packaging, use `./scripts/build.sh run` or `scripts/uitest.sh prep` and follow the targeted `scripts/uitest.sh` smoke/bench runbooks when the change affects generation, playback, or benchmarked latency.

## CI Proof Surface

The current CI proof surface is intentionally narrow: `.github/workflows/release.yml` packages the macOS DMG and runs unsigned iOS compile-safety. It does not run XCTest, smoke tests, benchmarks, signed iOS archive/export, or TestFlight upload. The broad historical GitHub workflows were retired in May 2026 after harness-driven churn made them unreliable. `scripts/release.sh` remains the authoritative signed/notarized DMG producer, `scripts/release_ios_testflight.sh` remains the authoritative iPhone archive/export tool, and `scripts/ios_device.sh` is the real-device Debug validation entrypoint.

Historical CI evidence (kept for the audit trail; not a current gate):

- GitHub `Project Inputs`: passed for `63a5e02`, run `24973916220` (workflow retired)
- GitHub `Apple Platform QA Gate` later renamed `Apple Platform Build Gate`: passed for `63a5e02`, run `24973916195` (workflow retired)
- Local unsigned release proof: `./scripts/release.sh`, `./scripts/verify_release_bundle.sh build/Release/Vocello.app`, and `./scripts/verify_packaged_dmg.sh build/Release/Vocello-macos26.dmg build/Release/release-metadata.txt`

## iPhone Re-entry Conditions

Do not treat iPhone as a public release target again until all of the following are true:

- the macOS-first milestone has shipped successfully
- no critical shared-core macOS regressions remain open from the release cycle
- the build gate stays green after post-release fixes
- owned-device iPhone validation is current
- real-device screen-mirror evidence from `scripts/ios_device.sh` is current for affected Custom / Design / Clone paths
- official `iPhone 15 Pro` minimum-device proof is recorded before claiming full iPhone release readiness
- `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh` succeed from the intended release ref (local on Mac mini M2)

Minimum-device re-entry evidence should explicitly cover:

- iPhone 15 Pro install and first launch
- Speed-only model catalog, download, resume, verification, and install
- App Group persistence for models, downloads, staging, outputs, voices, and cache
- engine-extension discovery, generation, cancellation, teardown, and replacement
- memory-pressure admission, trim, and unload behavior
- TestFlight archive/export verification and, when applicable, App Store Connect upload proof

The iPhone track remains compile-safe during the current macOS milestone, but the checklist above is not a macOS release blocker.

## iPhone Shipping Plan (post-2.0.0)

With macOS 2.0.0 stable shipped, the iPhone track is being re-opened on a TestFlight-first path. The current source of truth is the checklist in this section plus the repo-level guidance in `AGENTS.md`. The two user-facing prerequisites that are not derivable from code:

### Apple entitlement request (critical-path blocker)

MLX generation currently hits the iOS engine-extension process memory limit before real model admission. The app already declares `com.apple.developer.kernel.increased-memory-limit` in `Sources/iOS/VocelloiOS.entitlements` and `Sources/iOSEngineExtension/VocelloEngineExtension.entitlements`, but Apple must approve the managed capability before it can be enabled in provisioning profiles.

Maintained doc set (start at [`ios-shipping.md`](ios-shipping.md)):

- [`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md) — Apple request packet
- [`ios-increased-memory-entitlement-tracker.md`](ios-increased-memory-entitlement-tracker.md) — submission status
- [`ios-mlx-jetsam-feasibility.md`](ios-mlx-jetsam-feasibility.md) — feasibility and Jetsam posture
- [`ios-memory-admission-policy.md`](ios-memory-admission-policy.md) — Release vs Debug admission
- [`ios-device-proof-matrix.md`](ios-device-proof-matrix.md) — device validation (`scripts/ios_device_proof_matrix.sh`)

The request must be submitted from Apple Developer → Certificates, Identifiers & Profiles → Identifiers → each App ID → Capability Requests:

- Team ID: your Apple Developer team (`APPLE_TEAM_ID` / `QWENVOICE_DEVELOPMENT_TEAM` — do not commit literals)
- App name + bundle IDs: Vocello, `com.patricedery.vocello` and engine extension `com.patricedery.vocello.engine-extension`
- App Group: `group.com.patricedery.vocello.shared`
- Entitlement: `com.apple.developer.kernel.increased-memory-limit`
- Justification: cite private on-device Qwen3-TTS / MLX generation, the engine extension's process-isolation role, `os_proc_available_memory()` evidence showing extension process headroom is critically low before model load, app + extension memory-context diagnostics from `scripts/ios_device.sh pull`, and the implemented guardrails: admission blocking, streaming-first iOS generation, no inline PCM preview by default, cache clearing, critical cancellation, and full unload.

Pass criterion: Apple replies with a tracking case number, then the App ID Capabilities tab shows Increased Memory Limit for both `com.patricedery.vocello.engine-extension` and `com.patricedery.vocello`. Regenerate profiles and run `scripts/ios_device.sh verify-entitlements --enable-increased-memory-limit` to confirm both signed products contain the entitlement.

### App Store Connect setup (parallel to entitlement wait, ~30 min)

Manual prep that does not require the entitlement and can happen immediately:

1. **Create app record** at App Store Connect → My Apps → +. Platform iOS, name "Vocello", bundle ID `com.patricedery.vocello` (must match `project.yml`), SKU `vocello-ios-2026`, primary language English (US). In Apple Developer, also create `com.patricedery.vocello.engine-extension` and attach both IDs to `group.com.patricedery.vocello.shared`.
2. **Set primary category**: Productivity (or Utilities). Multimedia would also fit.
3. **Confirm API key scope**: the existing `APPLE_NOTARY_KEY_ID` (used for macOS notarization) needs "App Manager" role to enable IPA upload via `xcodebuild -exportArchive ... destination upload`. Verify at Users and Access → Integrations → API. Same issuer ID works for any number of keys.
4. **Seed internal-tester list**: create a group "Maintainer & devs" in TestFlight → Internal Testing. Add the maintainer Apple ID email as the first internal tester. External testers come later as a separate Apple-review process.

### Pipeline state after Phase 4

`.github/workflows/release.yml` now runs `compile-ios` in parallel with the macOS `package` job. The iOS job runs `scripts/build_foundation_targets.sh ios` (compile-safety only, no signing). A signed-IPA `archive-ios` job is intentionally NOT in the workflow yet — it requires the entitlement approval, an iOS Distribution certificate, and provisioning profiles for `com.patricedery.vocello` plus `com.patricedery.vocello.engine-extension` that include the increased-memory entitlement. Once those prereqs are met, extend the workflow with a sibling job that imports the iOS dist cert, runs `scripts/release_ios_testflight.sh --export`, and uploads the IPA + `release-metadata-ios.txt` as workflow artifacts. TestFlight `--upload` mode stays manual until the export path is proven end-to-end at least once.

### iPhone model catalog

`scripts/check_ios_catalog.sh` validates the bundled production iPhone catalog at `Sources/Resources/qwenvoice_ios_model_catalog.json` against `Sources/Resources/qwenvoice_contract.json`. The app default is `bundle://vocello/ios/catalog/v1/models.json`; model files download from pinned Hugging Face revisions with per-file SHA-256 verification. The override env var `QVOICE_IOS_MODEL_CATALOG_URL` still lets local testing or TestFlight prep point at a staging hosted catalog.

The May 2026 iOS identity rename is a clean pre-release reset. Existing hardware data under the old `group.com.qvoice.shared` App Group is not migrated.
