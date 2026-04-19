# QwenVoice Documentation

This folder contains the current repo-authored documentation for QwenVoice.

## Maintained Reference Docs

- [`../AGENTS.md`](../AGENTS.md) — primary repository operating guide for coding agents and maintainers
- [`reference/current-state.md`](reference/current-state.md) — shared current repo facts
- [`reference/engineering-status.md`](reference/engineering-status.md) — current strengths, caveats, and validation posture
- [`reference/release-readiness.md`](reference/release-readiness.md) — release-readiness matrix, proof status, and public-homepage freeze rules
- [`reference/vendoring-runtime.md`](reference/vendoring-runtime.md) — runtime, vendoring, and packaging boundaries

These are the maintained source-of-truth docs for contributor and repository behavior. When prose disagrees, trust the repo code, manifests, scripts, and workflows first, then these reference docs.

## Product And Public Docs

- [`../README.md`](../README.md) — public GitHub landing page and end-user overview

The public landing page is intentionally conservative right now. It stays aligned with the currently shipped macOS product reality until the repo owner explicitly approves a broader homepage update.

## Supplemental Guides

- [`qwen_tone.md`](qwen_tone.md) — supplemental tone and prompt-writing guidance

Supplemental guides are useful, but they are not the primary source of truth for current repo structure or shipped-product behavior.

## Historical Docs

- [`releases/`](releases/) — checked-in release notes for past published versions

## Notes

- Maintained contributor guidance in this checkout lives in the maintained reference docs listed above.
- This repo does not maintain project-scoped QwenVoice skills; contributor guidance lives in the maintained docs above.
- Current automation surfaces live in `scripts/` and `.github/workflows/`, including macOS release packaging and iPhone TestFlight workflows.
- Generated or vendored dependency documentation is intentionally out of scope for the repo docs.
