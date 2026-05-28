# Smoke Runbook: Custom Voice generate → verify

One-shot functional check: launch the Debug build, drive Custom Voice through one short generation via [native computer-use](computer-use-mcp.md), confirm completion via signpost + WAV + DB row.

Follows the [Standard smoke skeleton](ui-test-surface.md#standard-smoke-skeleton). This file only documents the Custom Voice deltas. For when to run this vs. the bench, see [`testing-overview.md`](testing-overview.md).

## Mode-specific inputs

| Field | Value |
|---|---|
| Speaker | the app default (Aiden) — do not change |
| Script text | `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.` |
| Variant | whichever variant is the app default for this Mac |
| smoke-check arg | `custom` (or no arg — defaults to `custom`) |

## Mode-specific deltas

- **Sidebar AX id**: `sidebar_customVoice`
- **Screen mount check**: `scripts/uitest.sh locate screen_customVoice` (exit 0)
- **Output subfolder**: `outputs/CustomVoice/`
- **Extra steps before generate**: none — the default speaker and delivery are correct. Just click `textInput_textEditor`, type the fixed script, fire `cmd+Return`.

## Notes

- This runbook is the contract for "the smoke test works." When AX-id values, completion signals, or the standard skeleton change, update [`ui-test-surface.md`](ui-test-surface.md) first; per-mode runbooks (this file) only need updates when the mode-specific deltas above change.
- The runbook deliberately doesn't navigate Settings or download models — `smoke-check custom` enforces that prerequisite so the smoke stays focused on the generate path.
