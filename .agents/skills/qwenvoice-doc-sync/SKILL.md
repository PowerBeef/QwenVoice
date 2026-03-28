---
name: qwenvoice-doc-sync
description: Sync QwenVoice docs with repo truth after workflow, packaging, version, or behavior changes. Use when asked to update `README.md`, `AGENTS.md`, `docs/reference/current-state.md`, checked-in release notes, or other contributor docs and you need to verify commands, links, artifact names, and version claims against the actual source and scripts.
---

# QwenVoice Doc Sync

## Overview

Use this skill when QwenVoice documentation needs to be refreshed against the actual code, manifests, and scripts. Favor factual consistency over marketing rewrites.

## Source of Truth Order

Resolve documentation questions in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/`
4. `docs/reference/current-state.md` and `docs/reference/engineering-status.md`
5. other prose docs

If prose disagrees with code or scripts, fix the prose.

## Workflow

### 1. Map the changed behavior

Before editing docs, identify which subsystem changed:

- app behavior or UI surface
- backend contract or model metadata
- harness and validation commands
- packaged runtime or vendoring
- release/version metadata

Pull facts from the smallest reliable source instead of relying on older docs.

### 2. Update the right docs together

Use these pairings as defaults:

- **Workflow or contributor guidance**: `AGENTS.md`, `README.md`, `docs/README.md`
- **Current repo facts**: `docs/reference/current-state.md`
- **Runtime or vendoring behavior**: `docs/reference/vendoring-runtime.md`
- **Versioned release messaging**: `docs/releases/vX.Y.md`

If a doc is intentionally user-facing, keep the wording concise and benefit-led. If it is maintainer-facing, keep the wording factual and operational.

### 3. Verify commands, links, and artifact names

For every doc edit, check that:

- script names exist
- linked files exist
- workflow names and artifact filenames match the current repo
- version/build claims match `project.yml`

Use repo inspection commands instead of assuming previous docs were right.

### 4. Keep scope boundaries intact

When documenting app behavior:

- treat the GUI app as the primary product surface
- do not import CLI-only assumptions into app docs
- keep Preferences in the Settings scene
- keep Voice Cloning limitations and dual-UI build constraints accurate

### 5. Release notes are a special case

Checked-in release notes should be concise and user-facing. Avoid changelog-style file inventories. If a GitHub release already exists, update the hosted body from the checked-in notes file rather than maintaining two sources of truth manually.

## Useful Checks

```bash
rg -n "run_tests.sh|run_backend_tests.sh|docs/reference/testing.md" README.md docs AGENTS.md
rg -n "MARKETING_VERSION|CURRENT_PROJECT_VERSION" project.yml
find docs -maxdepth 3 -type f | sort
python3 scripts/harness.py validate
```

## Failure Shields

- Do not treat stale docs as evidence when code and scripts disagree.
- Do not duplicate the same repo fact in multiple places without updating the maintained reference docs too.
- Do not let release notes fall back to placeholder text.
- Do not broaden a factual doc refresh into an unnecessary copy rewrite.
