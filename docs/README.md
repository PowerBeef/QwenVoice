# QwenVoice Documentation

This folder contains the current, repo-authored documentation for QwenVoice.

## Public Docs

- [`../README.md`](../README.md) — GitHub landing page and end-user overview
- [`../qwen_tone.md`](../qwen_tone.md) — practical guide to tone, emotion, and instruction writing in the shipped app and CLI

## Contributor And Agent Docs

- [`../AGENTS.md`](../AGENTS.md) — primary repository operating guide for coding agents and maintainers
- [`reference/current-state.md`](reference/current-state.md) — shared current repo facts reused by the other docs
- [`reference/engineering-status.md`](reference/engineering-status.md) — current engineering status, cleanup outcomes, and live caveats
- [`reference/vendoring-runtime.md`](reference/vendoring-runtime.md) — bundled Python, backend helper overlay, and runtime packaging notes

## CLI Docs

- [`../cli/README.md`](../cli/README.md) — standalone CLI usage and setup

## Repo-Local Skills

- [`../.agents/skills/`](../.agents/skills/) — repo-tracked QwenVoice skills for doc sync, packaged validation, release publishing, and vendored-runtime work

## Notes

- Maintained contributor guidance in this checkout lives in the files listed above. Do not assume missing supplementary docs still exist.
- Generated and vendor documentation under `Sources/Resources/python/`, `cli/.venv/`, and dependency package directories is intentionally out of scope for the repo docs.
- Historical notes may still appear in git history or external references, but the maintained repo docs live in the files listed above.
