---
name: enforcement-script-reference-update
description: Workflow command scaffold for enforcement-script-reference-update in QwenVoice.
allowed_tools: ["Bash", "Read", "Write", "Grep", "Glob"]
---

# /enforcement-script-reference-update

Use this workflow when working on **enforcement-script-reference-update** in `QwenVoice`.

## Goal

Updating enforcement scripts to allow or ban references to specific files or patterns in the project.

## Common Files

- `scripts/check_project_inputs.sh`

## Suggested Sequence

1. Understand the current state and failure mode before editing.
2. Make the smallest coherent change that satisfies the workflow goal.
3. Run the most relevant verification for touched files.
4. Summarize what changed and what still needs review.

## Typical Commit Signals

- Modify scripts/check_project_inputs.sh to update PROHIBITED_REFERENCE_PATTERNS or similar logic.
- Test that the new references are correctly allowed or banned as intended.

## Notes

- Treat this as a scaffold, not a hard-coded script.
- Update the command if the workflow evolves materially.