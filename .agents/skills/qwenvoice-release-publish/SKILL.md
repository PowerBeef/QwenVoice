---
name: qwenvoice-release-publish
description: Publish QwenVoice GitHub releases with repo-specific versioning, CI gates, dual-UI workflow inputs, and checked-in release notes. Use when asked to cut a `vX.Y` release, rebuild or download release packages, patch hosted release notes, or verify that the published GitHub release matches the intended commit and artifacts.
---

# QwenVoice Release Publish

## Overview

Use this skill for QwenVoice release work that touches versioning, checked-in release notes, remote CI gates, dual-runner GitHub Actions publishing, hosted release notes, or downloaded release artifacts. Follow the repo’s dual-UI release choreography instead of treating GitHub release publishing as a generic `gh release create` task. Local packaging scripts can still be useful for debugging, but they are not the publish path for a tagged release.

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

The workflow already supports checked-in release notes and bundled-runtime verification before upload.

### 6. Verify the hosted release, not just the workflow

After the workflow completes, verify:

- release title matches the intended version
- target commit SHA matches the release commit
- both DMGs and companion files are attached
- hosted release notes are the checked-in notes, not a placeholder

When the request includes downloads, also fetch the artifacts locally and verify checksums.

## Useful Commands

```bash
gh run list --workflow release-dual-ui.yml --limit 10
gh run view <run-id>
gh workflow run release-dual-ui.yml -f git_ref=<sha> -f artifact_label=<version-shortsha> -f release_tag=vX.Y -f release_notes_path=docs/releases/vX.Y.md
gh release view vX.Y --repo PowerBeef/QwenVoice
gh release edit vX.Y --repo PowerBeef/QwenVoice --notes-file docs/releases/vX.Y.md
```

## Failure Shields

- Do not publish from a commit whose version/build metadata still points at the old release.
- Do not skip the checked-in release notes file.
- Do not treat local green checks as a substitute for the required remote CI gates.
- Do not treat local `./scripts/release.sh` output as the final release artifact source for a tagged publish.
- Do not bypass the GitHub matrix by publishing only the locally available macOS 26 build.
- Do not patch hosted release notes by recreating the release unless the user explicitly wants that.
- Do not verify only one DMG; this repo ships dual-UI macOS artifacts.
