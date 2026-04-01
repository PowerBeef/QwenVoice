---
name: qwenvoice-release-publish
description: Publish QwenVoice GitHub releases with repo-specific versioning, CI gates, dual-UI workflow inputs, and checked-in release notes. Use when asked to cut a `vX.Y` release, rebuild or download release packages, patch hosted release notes, or verify that the published GitHub release matches the intended commit and artifacts.
---

# QwenVoice Release Publish

## Overview

Use this skill for QwenVoice release work that touches versioning, checked-in release notes, remote CI gates, dual-runner GitHub Actions publishing, hosted release notes, or downloaded release artifacts. Follow the repo’s dual-UI release choreography instead of treating GitHub release publishing as a generic `gh release create` task. Local packaging scripts can still be useful for macOS 26 debug work, but they are not the publish path or the source of truth for shipped release artifacts.

## Workflow

### 1. Align the shipped version first

Before publishing a new release, confirm the app metadata matches the intended tag:

- update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`
- regenerate the Xcode project only if manifest-backed project structure changed
- update release-facing docs that intentionally state the current shipped version or build

Do not cut a release tag against stale `1.x` metadata.

### 2. Create checked-in release notes

Every tagged publish needs a checked-in notes file such as:

```text
docs/releases/v1.2.md
```

Keep release notes user-facing and concise. Do not rely on placeholder text in the workflow. If the hosted release already exists, update it in place instead of recreating it.

### 3. Run the local preflight gates

Run the minimum local validation expected for a ship candidate:

```bash
./scripts/check_project_inputs.sh
python3 scripts/harness.py validate
python3 scripts/harness.py test --layer swift
```

Do not treat local `./scripts/release.sh` output as the tagged release artifact source. For tagged publishes, packaged dependency proof comes from the `build-release` matrix in `.github/workflows/release-dual-ui.yml`, which already runs `./scripts/verify_release_bundle.sh "$APP_PATH"` on each runner before upload. If the request includes downloaded artifact verification, do that after the hosted release artifacts exist.

### 4. Wait for GitHub CI on the exact release SHA

Do not dispatch the publish workflow until the intended release commit is green remotely.

Required checks on the exact target SHA:

- `Project Inputs`
- `Test Suite`

If either is red or still running, wait. Do not publish from a newer or different SHA without saying so explicitly.

### 5. Dispatch the dual-UI release workflow

The publish source of truth is `.github/workflows/release-dual-ui.yml`. This workflow is not just the publish step; it is the required build step for both shipped artifacts.

The workflow currently has three stages:

- `build-release`: builds and Developer ID-signs `QwenVoice-macos15.dmg` on `macos-15` and `QwenVoice-macos26.dmg` on `macos-26`
- `notarize-release`: runs on `macos-26`, downloads the intermediate DMGs, notarizes and staples both, then uploads the final notarized artifact bundle
- `publish-release`: runs only when `release_tag` is non-empty and uploads the final notarized assets to the GitHub release

Provide all release-specific inputs:

- `git_ref=<exact release sha>`
- `artifact_label=<version-shortsha>`
- `release_tag=vX.Y`
- `release_notes_path=docs/releases/vX.Y.md`

Do not build one artifact locally and the other on GitHub. Do not publish a tagged release unless both matrix variants complete on their intended runners:

- `QwenVoice-macos15.dmg`
- built on `macos-15`
- `QwenVoice-macos26.dmg`
- built on `macos-26`
- checksum files
- release metadata files for both UI profiles

The workflow should also be the signing/notarization source of truth: import the Developer ID Application certificate from GitHub secrets, sign each runner's app, notarize and staple each DMG, and only then upload the artifacts. Prefer App Store Connect API key auth for notarization; include `issuer` for Team keys and omit it for Individual keys.

### 6. Use non-release smoke runs for build-only artifact requests

When the user wants the official artifacts produced without publishing a GitHub release:

- dispatch `release-dual-ui.yml` with `git_ref=<sha-or-branch>` and `artifact_label=<label>`
- omit both `release_tag` and `release_notes_path`
- wait for `build-release` and `notarize-release` to finish green
- download the final notarized artifact bundle with `gh run download`
- verify the downloaded DMGs before treating them as deliverables

Do not download the intermediate `qwenvoice-dual-ui-build-*` artifacts when the user wants the final signed/notarized packages. The final `qwenvoice-dual-ui-*-final*` artifact bundle is the source of truth.

### 7. Verify the hosted release, not just the workflow

After the workflow completes, verify:

- release title matches the intended version
- target commit SHA matches the release commit
- both DMGs and companion files are attached
- hosted release notes are the checked-in notes, not a placeholder

When the request includes downloads, also fetch the final artifact bundle locally and verify checksums plus DMG trust state.

## Useful Commands

```bash
gh run list --workflow release-dual-ui.yml --limit 10
gh run view <run-id>
gh workflow run release-dual-ui.yml -f git_ref=<sha> -f artifact_label=<version-shortsha> -f release_tag=vX.Y -f release_notes_path=docs/releases/vX.Y.md
gh workflow run release-dual-ui.yml -f git_ref=<sha> -f artifact_label=<label>
gh run download <run-id> -n qwenvoice-dual-ui-<run-number>-final[-label] -D <dir>
gh release view vX.Y --repo PowerBeef/QwenVoice
gh release edit vX.Y --repo PowerBeef/QwenVoice --notes-file docs/releases/vX.Y.md
```

## Failure Shields

- Do not publish from a commit whose version/build metadata still points at the old release.
- Do not skip the checked-in release notes file.
- Do not treat local green checks as a substitute for the required remote CI gates.
- Do not treat local `./scripts/release.sh` output as the final release artifact source for a tagged publish.
- Do not bypass the GitHub matrix by publishing only the locally available macOS 26 build.
- Do not verify or hand off intermediate `qwenvoice-dual-ui-build-*` artifacts when the request is for final signed/notarized packages.
- Do not patch hosted release notes by recreating the release unless the user explicitly wants that.
- Do not verify only one DMG; this repo ships dual-UI macOS artifacts.
