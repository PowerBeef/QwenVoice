---
name: qwenvoice-packaged-validation
description: Validate QwenVoice dev builds, packaged apps, and downloaded release artifacts with the repo harness and bundle checks. Use when asked to run automated testing, verify both macOS variants, check UI smoothness, confirm native-only bundle behavior, investigate screenshot-capture prompts, or explain why a packaged validation lane failed.
---

# QwenVoice Packaged Validation

## Overview

Use this skill for QwenVoice validation requests that go beyond a plain local build. Favor the repo harness, packaged-app flows, and native-bundle checks over one-off manual app launches.

Treat local and release surfaces differently:

- local builds on this machine are for macOS 26 dev/testing only
- official macOS 26 and macOS 15 release packages must come from the GitHub `Release Dual UI` workflow
- official release signing and notarization must also come from that workflow, not from local packaging runs
- notarization should prefer App Store Connect API key auth; `issuer` is present for Team keys and omitted for Individual keys
- the final notarized workflow artifact bundle is the preferred source for downloaded release validation, not the intermediate build artifacts

## Workflow

### 1. Confirm the target surface

Classify the request before running anything:

- **Source sanity**: repo inputs, Swift tests, pure Python tests.
- **Dev app validation**: local app built from the checkout for the macOS 26 dev surface.
- **Packaged app validation**: `.app` bundle copied from a build artifact.
- **Release artifact validation**: downloaded dual-UI DMGs or a release-artifact root.

Prefer the most specific surface that matches the request. Do not treat a source build as proof that the packaged app is healthy.
Do not treat a local packaged build as proof of a shipped release artifact for either macOS variant.

### 2. Start with repo truth

Run the fast gates first unless the user explicitly wants only one narrow lane:

```bash
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
```

Keep packaged validation deliberately low-RAM on this machine:

- prefer the narrowest lane that answers the question
- do not overlap heavy `xcodebuild`, `scripts/harness.py`, `./scripts/release.sh`, or live app validation runs
- do not jump to `release`, local packaging, or live `ui` / `design` / `perf` proof until the source gates are already green
- if a command starts a broad cold native/MLX rebuild that is not required for the user’s question, stop and re-scope to a cheaper lane

Add only the layers that match the requested scope:

```bash
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer server
python3 scripts/harness.py test --layer contract
```

Remember that `test --layer all` excludes `release`.

### 3. Prefer the packaged-release lane for shipped-artifact checks

When the request is about the actual release packages, prefer the packaged flow:

```bash
python3 scripts/harness.py test --layer release --artifacts-root <dir>
```

For this repo, both `QwenVoice-macos26.dmg` and `QwenVoice-macos15.dmg` should come from the GitHub `Release Dual UI` workflow. Validate the final downloaded or uploaded notarized workflow artifact bundle rather than rebuilding release packages locally or relying on the intermediate `qwenvoice-dual-ui-build-*` artifacts.

For deeper hosted-release analysis, prefer a local audit workspace under:

```bash
build/downloads/<release-or-label>/audit/
```

Keep copied-out apps, raw inspection output, and any written audit report there so release investigations stay local and do not pollute tracked docs.

When the request is about signed or notarized releases, include trust checks in addition to bundle checks:

- `spctl -a -vvv --type open --context context:primary-signature <dmg>`
- `xcrun stapler validate <dmg>`

Use `--dmg` or `--app-bundle` only for narrow spot checks. Treat DMG targets as install-and-test flows:

- mount the DMG
- copy `QwenVoice.app` into a disposable temp install root
- clear quarantine on the temp copy only if the spot-check flow requires it
- test the copied app, not the mounted app
### 4. Use Computer Use for visual truth

This checkout no longer keeps maintained automated XCUI `ui`, `design`, or `perf` lanes.

For visual or interaction proof:

- run `./scripts/check_project_inputs.sh`
- run `python3 scripts/harness.py validate`
- run the narrowest relevant source lane
- then use local Codex Computer Use for the actual visual pass

Do not try to recreate the removed XCUI or screenshot-diff path.

### 5. Prove native bundle boundaries, not just startup

When validating packaged apps, run the bundle verifier:

```bash
./scripts/verify_release_bundle.sh <path-to-app-or-build/QwenVoice.app>
```

Treat the following as the packaged-runtime acceptance checks:

- `runtimeSource == native`
- `activePythonPath == ""`
- `activeFFmpegPath == ""`
- packaged app startup smoke passes

If the request is about proving native-only packaging, do not stop at launch success.
When the request is about downloaded signed/notarized DMGs, treat trust checks plus copied-app bundle verification as the acceptance gate.

### 6. Handle live-model blockers explicitly

If installed models are missing under `~/Library/Application Support/QwenVoice/models`, say so directly and separate:

- what passed with packaged structural checks
- what could not be proven live because the machine lacks models

Do not blur “packaged app launches” into “full live generation works.”

### 7. Report with acceptance gates

When summarizing results, group findings by:

- source sanity
- packaged startup and bundle verification
- UI and screenshot behavior
- live generation coverage
- blockers or missing prerequisites

Call out the exact lane that failed and the first concrete blocker.

## Common Commands

```bash
python3 scripts/harness.py diagnose
python3 scripts/harness.py test --layer release --artifacts-root <dir>
./scripts/verify_release_bundle.sh <path-to-app-or-build/QwenVoice.app>
```

## Failure Shields

- Do not hand-roll alternate test flows when the harness already has a lane.
- Do not stack heavy validation commands or launch a second heavy run while the first is still active.
- Do not build or validate macOS 15 release packages locally on this machine.
- Do not use local `./scripts/release.sh` output as the authoritative proof for shipped macOS 26 or macOS 15 release artifacts.
- Do not jump straight to `test --layer release`, local packaging, or a manual Computer Use pass when a cheaper source lane can answer the question first.
- Do not treat the intermediate `qwenvoice-dual-ui-build-*` artifacts as the final shipped release packages.
- Do not assume the mounted DMG app is the real test target.
- Do not treat missing live models as a code regression.
- Do not recreate removed XCUI or screenshot-diff automation in an ad hoc way.
- Do not claim success on native-only bundle boundaries unless `verify_release_bundle.sh` or equivalent runtime diagnostics prove it.
