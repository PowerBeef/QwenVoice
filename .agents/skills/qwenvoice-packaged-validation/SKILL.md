---
name: qwenvoice-packaged-validation
description: Validate QwenVoice dev builds, packaged apps, and downloaded release artifacts with the repo harness and bundle checks. Use when asked to run automated testing, verify both macOS variants, check UI smoothness, confirm bundled Python or ffmpeg usage, investigate screenshot-capture prompts, or explain why a packaged validation lane failed.
---

# QwenVoice Packaged Validation

## Overview

Use this skill for QwenVoice validation requests that go beyond a plain local build. Favor the repo harness, packaged-app flows, and bundled-runtime checks over one-off manual app launches.

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

Add only the layers that match the requested scope:

```bash
python3 scripts/harness.py test --layer swift
python3 scripts/harness.py test --layer server
python3 scripts/harness.py test --layer contract
python3 scripts/harness.py test --layer ui
python3 scripts/harness.py test --layer design
python3 scripts/harness.py test --layer perf
```

Remember that `test --layer all` excludes `ui`, `design`, and `perf`.

### 3. Prefer the packaged-release lane for shipped-artifact checks

When the request is about the actual release packages, prefer the packaged flow:

```bash
python3 scripts/harness.py test --layer release --artifacts-root <dir> --ui-backend-mode live --ui-data-root fixture
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
- if you run bundled Python directly inside the copied app for inspection, set `PYTHONDONTWRITEBYTECODE=1` or avoid ad hoc interpreter runs that would create `__pycache__` noise in the audit copy

### 4. Keep UI screenshot capture permissionless by default

For `ui` and `design` lanes, default to:

```bash
QWENVOICE_UITEST_CAPTURE_MODE=content
```

Use `system` mode only when the user explicitly wants real system capture fidelity. If `system` mode fails because Screen Recording permission is missing, report that as an expected TCC limitation instead of treating it as a general app failure.

### 5. Prove bundled dependencies, not just startup

When validating packaged apps, run the bundle verifier:

```bash
./scripts/verify_release_bundle.sh <path-to-app-or-build/QwenVoice.app>
```

Treat the following as the packaged-runtime acceptance checks:

- `runtimeSource == bundled`
- bundled Python path resolves under `QwenVoice.app/Contents/Resources/python`
- bundled ffmpeg path resolves under `QwenVoice.app/Contents/Resources/ffmpeg`
- packaged backend smoke passes

If the request is about “using bundled dependencies,” do not stop at launch success.
When the request is about downloaded signed/notarized DMGs, treat trust checks plus copied-app bundle verification as the acceptance gate.

### 6. Handle live-model blockers explicitly

The `ui`, `design`, `perf`, and `release` lanes default to live backend mode with a fixture data root. If installed models are missing under `~/Library/Application Support/QwenVoice/models`, say so directly and separate:

- what passed with stub or packaged structural checks
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
python3 scripts/harness.py test --layer ui --dmg <path-to-dmg> --ui-backend-mode live --ui-data-root fixture
python3 scripts/harness.py test --layer perf --app-bundle <path-to-app> --ui-backend-mode live --ui-data-root fixture
python3 scripts/harness.py test --layer design --ui-backend-mode stub
```

## Failure Shields

- Do not hand-roll alternate test flows when the harness already has a lane.
- Do not build or validate macOS 15 release packages locally on this machine.
- Do not use local `./scripts/release.sh` output as the authoritative proof for shipped macOS 26 or macOS 15 release artifacts.
- Do not treat the intermediate `qwenvoice-dual-ui-build-*` artifacts as the final shipped release packages.
- Do not assume the mounted DMG app is the real test target.
- Do not treat missing live models as a code regression.
- Do not default screenshot tests to `QWENVOICE_UITEST_CAPTURE_MODE=system`.
- Do not claim success on bundled dependencies unless `verify_release_bundle.sh` or equivalent runtime diagnostics prove it.
