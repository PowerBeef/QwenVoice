---
name: operating-guide-replacement-update
description: Workflow command scaffold for operating-guide-replacement-update in QwenVoice.
allowed_tools: ["Bash", "Read", "Write", "Grep", "Glob"]
---

# /operating-guide-replacement-update

Use this workflow when working on **operating-guide-replacement-update** in `QwenVoice`.

## Goal

Transitioning the primary operating guide from one file to another, updating all references and related enforcement scripts.

## Common Files

- `CLAUDE.md`
- `AGENTS.md`
- `docs/README.md`
- `docs/qwen_tone.md`
- `docs/reference/current-state.md`
- `docs/reference/backend-freeze-gate.md`

## Suggested Sequence

1. Understand the current state and failure mode before editing.
2. Make the smallest coherent change that satisfies the workflow goal.
3. Run the most relevant verification for touched files.
4. Summarize what changed and what still needs review.

## Typical Commit Signals

- Create or expand the new operating guide file (e.g., CLAUDE.md) with updated or merged content.
- Delete or deprecate the old operating guide file (e.g., AGENTS.md).
- Update all documentation files that reference the old guide to point to the new guide.
- Update enforcement scripts (e.g., scripts/check_project_inputs.sh) to allow or disallow references to the new/old guide as appropriate.

## Notes

- Treat this as a scaffold, not a hard-coded script.
- Update the command if the workflow evolves materially.