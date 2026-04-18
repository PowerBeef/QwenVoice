# QwenVoice Documentation

This folder contains the current, repo-authored documentation for QwenVoice.

## Maintained Reference Docs

- [`../AGENTS.md`](../AGENTS.md) — primary repository operating guide for coding agents and maintainers
- [`reference/current-state.md`](reference/current-state.md) — shared current repo facts reused by the other docs
- [`reference/engineering-status.md`](reference/engineering-status.md) — current engineering status, cleanup outcomes, and live caveats
- [`reference/vendoring-runtime.md`](reference/vendoring-runtime.md) — native runtime, vendoring, and packaging notes

These are the maintained source-of-truth documents for contributor and repository behavior. When prose disagrees, trust the repo code, manifests, scripts, and then these reference docs in that order.

## Product And Public Docs

- [`../README.md`](../README.md) — GitHub landing page and end-user overview

## Supplemental Guides

- [`../qwen_tone.md`](../qwen_tone.md) — supplemental tone and prompt-writing guidance

Supplemental guides are useful, but they are not the primary source of truth for current repo structure or shipped-product behavior.

## Historical Docs

- [`releases/`](releases/) — checked-in release notes for past published versions

## Repo-Local Skills

- [`../.agents/skills/`](../.agents/skills/) — repo-tracked QwenVoice skills for doc sync, packaged validation, release publishing, and native runtime vendoring work

## Notes

- Maintained contributor guidance in this checkout lives in the maintained reference docs listed above.
- Generated or vendored dependency documentation is intentionally out of scope for the repo docs.
- Historical notes may still appear in git history or external references, but the maintained repo facts live in the reference docs listed above.
