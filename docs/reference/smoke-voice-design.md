# Smoke Runbook: Voice Design generate → verify

One-shot functional check: launch the Debug build, drive Voice Design with a fixed description + script via [native computer-use](computer-use-mcp.md), confirm completion via signpost + WAV + DB row.

Follows the [Standard smoke skeleton](ui-test-surface.md#standard-smoke-skeleton). This file only documents the Voice Design deltas. For when to run this vs. the bench, see [`testing-overview.md`](testing-overview.md).

## Mode-specific inputs

| Field | Value |
|---|---|
| Voice description | `A calm, deep documentary narrator with a measured pace.` |
| Script text | `Voice Design smoke test. This is a one-sentence sample to verify the path.` |
| Variant | app default |
| smoke-check arg | `design` |

## Mode-specific deltas

- **Sidebar AX id**: `sidebar_voiceDesign`
- **Screen mount check**: `scripts/uitest.sh locate screen_voiceDesign` (exit 0)
- **Output subfolder**: `outputs/VoiceDesign/`
- **Extra step before generate**: click `voiceDesign_voiceDescriptionField`, type the fixed description, **then** proceed to `textInput_textEditor` + script + `cmd+Return`.

## Notes

- `Final File Ready` signpost is emitted by the shared `GenerationPersistence.persistAndAutoplay()` path, identical to Custom Voice — completion detection is unchanged.
- The variant toggle has accessibility-id prefix `voiceDesign` per `GenerationVariantSelector`; the smoke test leaves it at the app default, so we don't need to click it.
- The voice-description field is implemented as `ContinuousVoiceDescriptionField` and can momentarily lose focus during validation — if the field looks empty after typing, click it once more and retry typing.
