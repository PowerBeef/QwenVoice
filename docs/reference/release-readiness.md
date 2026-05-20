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

- `Mac mini M2, 8 GB RAM` is the active development and bench-capture host. Perf is verified locally after material engine changes with targeted manual checks and, when appropriate, the maintained Claude Code–driven `scripts/uitest.sh` bench harness.
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

- Public homepage posture: Vocello-led for the public `v2.0.0-beta.1` macOS 26 beta, with `QwenVoice v1.2.3` retained as the stable fallback
- macOS source and packaging surfaces: maintained in-repo
- iPhone archive/export/TestFlight tooling: maintained in-repo
- Current public beta release milestone: macOS only
- iPhone owned-device proof: `iPhone 17 Pro` path is the active validation target
- iPhone official minimum-device proof: pending until `iPhone 15 Pro` evidence is recorded
- Rescue baseline: `main` commit `63a5e02` passed the historical GitHub workflows on April 26, 2026 local time. Those workflows (`Project Inputs`, `Apple Platform QA Gate` later renamed `Apple Platform Build Gate`, `Vocello macOS Release`, `Vocello iOS TestFlight`) were retired in May 2026; all proof now lives locally on Mac mini M2.
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

The current `macOS-first release track` uses three proof tiers. **All three are local-only** since the CI, XCTest, and legacy Python/automation surfaces were retired in May 2026.

1. Build and validation proof
   - `scripts/check_project_inputs.sh` (static validation)
   - `scripts/build_foundation_targets.sh macos` + `scripts/build_foundation_targets.sh ios` (compile proof)
   - Debug behavioral smoke with `./scripts/build.sh run` or `scripts/uitest.sh prep`; use manual acceptance and targeted `scripts/uitest.sh` runbooks for affected paths
2. macOS ship gate
   - local unsigned macOS packaging and verification via `scripts/release.sh` + `scripts/verify_release_bundle.sh` + `scripts/verify_packaged_dmg.sh`
   - signed/notarized DMG produced by `scripts/release.sh --preflight full` against the project owner's Apple developer credentials (local Keychain)
3. Deferred iPhone release proof
   - owned-device validation follow-through
   - local `scripts/check_ios_catalog.sh` + `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh`; TestFlight upload run locally

Only tiers 1 and 2 block the current public release milestone.

### Tier → Local Script Mapping

| Tier | Primary local commands |
|---|---|
| 1. Build and validation proof | `./scripts/check_project_inputs.sh` + `./scripts/build_foundation_targets.sh macos\|ios` + manual app smoke |
| 2. macOS ship gate | `./scripts/release.sh` + `./scripts/verify_release_bundle.sh` + `./scripts/verify_packaged_dmg.sh` |
| 3. Deferred iPhone release | `./scripts/check_ios_catalog.sh` + `./scripts/release_ios_testflight.sh` + `./scripts/verify_ios_release_archive.sh` |

Only tiers 1 and 2 block the current public release milestone. Tier 3 is maintained but deferred from public signoff until the iPhone re-entry conditions below are met. There are no CI or XCTest proof layers; local manual smoke and the maintained Claude Code harness are the behavioral regression checks.

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
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/release.sh
./scripts/verify_release_bundle.sh build/Release/Vocello.app
./scripts/verify_packaged_dmg.sh build/Release/Vocello-macos26.dmg build/Release/release-metadata.txt
```

Then launch `build/Release/Vocello.app` and exercise the affected user-facing paths by hand; each packaged repo-local Release app starts from a fresh release-id-specific app-support folder and preferences suite. For Debug behavior before release packaging, use `./scripts/build.sh run` or `scripts/uitest.sh prep` and follow the targeted `scripts/uitest.sh` smoke/bench runbooks when the change affects generation, playback, or benchmarked latency.

## CI Proof Surface

There is no CI proof surface. GitHub workflows were retired in May 2026 after harness-driven churn made them unreliable; all build, packaging, signing, notarization, and TestFlight-prep work runs locally on Mac mini M2 via the `scripts/` tooling. `scripts/release.sh` is the authoritative signed/notarized DMG producer; `scripts/release_ios_testflight.sh` is the authoritative iPhone archive/export tool.

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

With macOS 2.0.0 stable shipped, the iPhone track is being re-opened on a TestFlight-first path. The full plan lives at `~/.claude/plans/convert-agents-md-into-claude-md-parallel-hennessy.md` (6 phases, organized into 3 tracks). The two user-facing prerequisites that are not derivable from code:

### Apple entitlement request (critical-path blocker, ~1–3 weeks Apple-side)

MLX models exceed iOS's default per-process memory cap (~5–6 GB). The app already declares `com.apple.developer.kernel.increased-memory-limit` in `Sources/iOS/VocelloiOS.entitlements` and `Sources/iOSEngineExtension/VocelloEngineExtension.entitlements`, but Apple must approve the entitlement before it takes effect at runtime.

File at https://developer.apple.com/contact/ → "Programs and Enrollment" → "Request resource entitlement":

- Team ID: `FK2D8X36G2`
- App name + bundle ID: Vocello, `com.qvoice.ios`
- Entitlement: `com.apple.developer.kernel.increased-memory-limit`
- Justification: cite the on-device Qwen3-TTS / MLX workload, the iPhone 15 Pro deployment-target floor, the `iPhonePro` memory policy (`NativeMemoryPolicyResolver` tier with 128 MB cache + 30 s idle unload), the engine extension's process-isolation role, and the macOS counterpart at https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0 as proof the app exists in production. Full template in the plan file.

Pass criterion: Apple replies with a tracking case number. Re-check the App Store Connect "Capabilities" tab for `com.qvoice.ios` to confirm grant.

### App Store Connect setup (parallel to entitlement wait, ~30 min)

Manual prep that does not require the entitlement and can happen immediately:

1. **Create app record** at App Store Connect → My Apps → +. Platform iOS, name "Vocello", bundle ID `com.qvoice.ios` (must match `project.yml`), SKU `vocello-ios-2026`, primary language English (US).
2. **Set primary category**: Productivity (or Utilities). Multimedia would also fit.
3. **Confirm API key scope**: the existing `APPLE_NOTARY_KEY_ID` (used for macOS notarization) needs "App Manager" role to enable IPA upload via `xcodebuild -exportArchive ... destination upload`. Verify at Users and Access → Integrations → API. Same issuer ID works for any number of keys.
4. **Seed internal-tester list**: create a group "Maintainer & devs" in TestFlight → Internal Testing. Add `patricedery02@gmail.com` as first tester. External testers come later as a separate Apple-review process.

### Pipeline state after Phase 4

`.github/workflows/release.yml` now runs `compile-ios` in parallel with the macOS `package` job. The iOS job runs `scripts/build_foundation_targets.sh ios` (compile-safety only, no signing). A signed-IPA `archive-ios` job is intentionally NOT in the workflow yet — it requires the entitlement approval + an iOS Distribution certificate + a provisioning profile for `com.qvoice.ios` to exist, none of which are in place as of v2.0.0. Once those prereqs are met, extend the workflow with a sibling job that imports the iOS dist cert, runs `scripts/release_ios_testflight.sh --export`, and uploads the IPA + `release-metadata-ios.txt` as workflow artifacts. TestFlight `--upload` mode stays manual until the export path is proven end-to-end at least once.

### Hosted model catalog

`scripts/check_ios_catalog.sh` validates the hosted catalog at `https://downloads.qvoice.app/ios/catalog/v1/models.json` against `Sources/Resources/qwenvoice_contract.json`. That URL does not resolve as of v2.0.0; hosting the catalog (S3 / Cloudflare R2 / GitHub Pages mirror) is a Phase 5 prerequisite — without it, the iPhone app cannot complete Settings → Model Downloads on a real device. The override env var `QVOICE_IOS_MODEL_CATALOG_URL` lets local testing point at a staging mirror.
