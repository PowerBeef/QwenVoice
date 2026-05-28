# Smoke Runbook: Voice Cloning generate → verify

One-shot functional check: launch the Debug build, drive Voice Cloning with the `UITestRef` saved-voice fixture + a fixed script via [native computer-use](computer-use-mcp.md), confirm completion via signpost + WAV + DB row.

Follows the [Standard smoke skeleton](ui-test-surface.md#standard-smoke-skeleton). This file only documents the Voice Cloning deltas. For when to run this vs. the bench, see [`testing-overview.md`](testing-overview.md).

## Prerequisite

Voice Cloning requires the **`UITestRef`** saved-voice fixture. If `scripts/uitest.sh smoke-check clone` fails because the fixture is missing, run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md) first — it takes ~1 minute and produces `voices/UITestRef.wav` autonomously via Voice Design (no file-picker dialog).

## Mode-specific inputs

| Field | Value |
|---|---|
| Saved voice | `UITestRef` (created by the bootstrap runbook) |
| Transcript | fixture-dependent; transcript-backed fixtures are preferred, audio-only remains valid |
| Script text | `Voice Cloning smoke test. This is a one-sentence sample to verify the path.` |
| Variant | app default |
| smoke-check arg | `clone` |

## Mode-specific deltas

- **Sidebar AX id**: `sidebar_voiceCloning`
- **Screen mount check**: `scripts/uitest.sh locate screen_voiceCloning` (exit 0)
- **Output subfolder**: `outputs/Clones/` (PascalCase, NOT `VoiceCloning/`)
- **`verify-generation` timeout**: defaults to 120 s for `clone` (vs 90 s for custom/design) because clone priming adds latency to the first generation.
- **Extra step before generate**:
  1. Click `voiceCloning_savedVoicePicker` to open the dropdown.
  2. Screenshot to see the open menu; click the menu item labeled `UITestRef` visually (menu items don't have stable AX ids).
  3. Confirm reference is bound: `scripts/uitest.sh locate voiceCloning_activeReference` (exit 0).
  
  Then proceed to `textInput_textEditor` + script + `cmd+Return`.

## Notes

- `Final File Ready` signpost is emitted identically to the other modes. The `VoiceCloningCoordinator` adds a clone-priming step (`ensureCloneReferencePrimed`) which slightly increases latency on the first generation after a reference change — the smoke's first generation will reflect that.
- If the saved-voice dropdown shows a quality-warning badge (`voiceCloning_referenceWarning`), the saved voice may produce a degraded take but generation still succeeds. Record the badge presence in any custom notes you keep alongside `result.json`.
- DB `mode` column reads `clone` (not `cloning` or `voiceCloning`); `verify-generation` already handles that.
