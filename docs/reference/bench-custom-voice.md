# Bench Runbook: Custom Voice across cold/warm × variant × prompt-length

Multi-sample timing harness for Custom Voice. Produces `bench-result.json`; diffable against [`benchmark-baselines.json`](benchmark-baselines.json) via `bench-compare` (±15 % gate on `ms_engine_start_to_final` + `rtf`).

Follows the [Standard bench skeleton](ui-test-surface.md#standard-bench-skeleton). This file documents the Custom Voice deltas. For when to run this vs. the smoke, see [`testing-overview.md`](testing-overview.md). For the matrix-budget rationale (why n=3 cold, ~3 min per cold sample, ~12 min for the full mode matrix), see the skeleton.

## Mode-specific inputs

| Field | Value |
|---|---|
| Speaker | the app default (Aiden) — do not change |
| Delivery | `Neutral` / `Subtle` — do not change |
| smoke-check arg | `custom` |

### Fixed prompts (held constant across all bench runs for baseline comparability)

| Bucket | Length | Text |
|---|---|---|
| `short` | 12 chars | `Hello world.` |
| `medium` | 74 chars | `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.` |
| `long` | ~300 chars | `The MLX framework lets local language and speech models run efficiently on Apple silicon, which is exactly what Vocello uses for its native Qwen3-TTS pipeline. This longer paragraph exercises the streaming synthesis path across a larger token budget and gives the steady-state real-time factor a chance to settle.` |

## Mode-specific deltas (skeleton step 1b)

For each `variant` in `[speed, quality]`:

- **Sidebar AX id**: `sidebar_customVoice`
- **Screen mount check**: `scripts/uitest.sh locate screen_customVoice` (exit 0)
- **Variant buttons**: the Speed / Quality toggle at the top-right of the Configuration card (`customVoice_speedVariantButton` / `customVoice_qualityVariantButton` name them) — click by sight and verify the gold highlight in a follow-up screenshot.
- **No saved-voice bind needed** (that's only Voice Cloning).

`bench-step` invocations:

```sh
scripts/uitest.sh bench-step custom "$variant" cold medium --artifacts-dir "$ART" --timeout 180
scripts/uitest.sh bench-step custom "$variant" warm short  --artifacts-dir "$ART"
scripts/uitest.sh bench-step custom "$variant" warm medium --artifacts-dir "$ART"
scripts/uitest.sh bench-step custom "$variant" warm long   --artifacts-dir "$ART"
```

(Three repetitions each per the skeleton.)

## Mode-specific failure handling

- **Variant toggle didn't switch the model**: the cold sample for the second variant will look suspiciously fast (model still warm). Verify by checking the Engine status line transitioned through "Starting engine…" before the cold sample.
- Other failure modes (timeout on `bench-wait`, missing `Final File Ready`, DB row lag) are covered in the skeleton.
