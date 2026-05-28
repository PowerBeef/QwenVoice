# Bench Runbook: Voice Design across cold/warm × variant × prompt-length

Multi-sample timing harness for Voice Design. Same structure as [`bench-custom-voice.md`](bench-custom-voice.md), passing `design` as the mode argument.

Follows the [Standard bench skeleton](ui-test-surface.md#standard-bench-skeleton). This file documents the Voice Design deltas.

## Mode-specific inputs

| Field | Value |
|---|---|
| Voice description (held constant across all samples) | `A calm, deep documentary narrator with a measured pace.` |
| smoke-check arg | `design` |

### Fixed prompts

Same as [`bench-custom-voice.md`](bench-custom-voice.md):

| Bucket | Length | Text |
|---|---|---|
| `short` | 12 chars | `Hello world.` |
| `medium` | 74 chars | `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.` |
| `long` | ~300 chars | `The MLX framework lets local language and speech models run efficiently on Apple silicon, which is exactly what Vocello uses for its native Qwen3-TTS pipeline. This longer paragraph exercises the streaming synthesis path across a larger token budget and gives the steady-state real-time factor a chance to settle.` |

## Mode-specific deltas (skeleton step 1b)

For each `variant` in `[speed, quality]`:

- **Sidebar AX id**: `sidebar_voiceDesign`
- **Screen mount check**: `scripts/uitest.sh locate screen_voiceDesign` (exit 0)
- **Variant buttons**: the Speed / Quality toggle at the top-right of the Configuration card (`voiceDesign_speedVariantButton` / `voiceDesign_qualityVariantButton` name them) — click by sight and verify the gold highlight in a follow-up screenshot.
- **Extra step**: after variant select, click `voiceDesign_voiceDescriptionField` and type the fixed description. The description persists across warm samples — **do not** clear/re-type it between samples; we want steady-state generate-path numbers.

`bench-step` invocations:

```sh
scripts/uitest.sh bench-step design "$variant" cold medium --artifacts-dir "$ART" --timeout 240
scripts/uitest.sh bench-step design "$variant" warm short  --artifacts-dir "$ART"
scripts/uitest.sh bench-step design "$variant" warm medium --artifacts-dir "$ART"
scripts/uitest.sh bench-step design "$variant" warm long   --artifacts-dir "$ART"
```

(VD/Quality cold has been seen taking >180 s on Apple M2 — use `--timeout 240` for cold.)

## Mode-specific failure handling

- **Description didn't apply** (field looks empty after typing): the `ContinuousVoiceDescriptionField` wrapper can momentarily lose focus during validation. Click the field once more and retry typing.
