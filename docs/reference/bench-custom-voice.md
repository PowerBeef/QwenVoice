# Bench Runbook: Custom Voice across cold/warm × variant × prompt-length

Multi-sample timing harness on the Custom Voice generation flow. Produces a structured `bench-result.json` and can be diffed against the committed baseline at `docs/reference/benchmark-baselines.json` to detect regressions.

Companion docs: [`ui-test-surface.md`](ui-test-surface.md), [`smoke-custom-voice.md`](smoke-custom-voice.md).

## Run plan

20 samples total, generated in this order within one session:

```
for variant in [speed, quality]:
    cold sample       (medium prompt, after a fresh launch)
    3 × warm short
    3 × warm medium
    3 × warm long
```

Cold runs capture model-load + first-generation latency. Warm runs hit the steady-state model-in-memory path.

## Prerequisites

- Debug build present (`scripts/build.sh debug` if missing).
- `scripts/uitest.sh smoke-check` exits 0 (Custom Voice model variants installed).
- macOS Accessibility permission granted to Claude.
- 5–10 minutes of uninterrupted Vocello time.

## Fixed prompts

| Bucket | Length | Text |
|---|---|---|
| `short` | 12 chars | `Hello world.` |
| `medium` | 74 chars | `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.` |
| `long` | ~300 chars | `The MLX framework lets local language and speech models run efficiently on Apple silicon, which is exactly what Vocello uses for its native Qwen3-TTS pipeline. This longer paragraph exercises the streaming synthesis path across a larger token budget and gives the steady-state real-time factor a chance to settle.` |

Speaker stays at the app default (Aiden); Delivery stays `Neutral` / `Subtle`. Don't change these — comparability across runs depends on it.

## Steps

### 0. Setup

```sh
ART=$(scripts/uitest.sh artifacts-dir)
echo "$ART"
mcp__computer-use__request_access(applications: ["Vocello"])
read SW SH < <(scripts/uitest.sh screen-size)
```

Record `$ART`, `$SW`, `$SH` — you'll reuse them throughout.

### 1. Variant loop

For each `variant` in `[speed, quality]`:

#### 1a. Fresh launch

```sh
scripts/uitest.sh reset            # quit Vocello, wipe generations + outputs
scripts/uitest.sh prep             # relaunch into a fresh state
scripts/uitest.sh activate         # ensure frontmost
```

#### 1b. Navigate to Custom Voice + select variant

- `scripts/uitest.sh locate sidebar_customVoice` → click center (after scaling by `IW/SW, IH/SH`).
- Verify with `scripts/uitest.sh locate screen_customVoice` (exit 0 = on the right screen).
- Select the variant via the segmented control at the top-right of the Configuration card. It does **not** have a catalogued accessibility identifier yet — first time you do this, try:
  1. `scripts/uitest.sh locate customVoice_variantSpeed` and `customVoice_variantQuality`. If either succeeds, record both in `ui-test-surface.md` and reuse.
  2. Otherwise screenshot, find the Speed / Quality buttons visually (top-right of the Configuration card), and click. Note the coordinates in the run's `result.json` notes so a future calibration step can codify them.

#### 1c. Cold sample (medium prompt)

The first generation after launch hits the model-load path. Treat it as one cold sample.

```sh
# Capture the moment we start the generation
T0=$(date +"%Y-%m-%d %H:%M:%S.%3N")
```

Then issue ONE `computer_batch` containing: click into the script field (visual click — also not in the AX vocabulary), type the medium prompt, send `cmd+return`.

```sh
scripts/uitest.sh bench-wait --since "$T0" --timeout 180   # cold includes model load; first live run saw ~8.7-9.5 s
scripts/uitest.sh bench-record custom "$variant" cold medium --artifacts-dir "$ART"
```

`bench-record` prints the recorded sample as JSON to stdout (for the agent to inspect) and appends to `$ART/bench-samples.jsonl`.

#### 1d. Warm samples

For each `bucket` in `[short, medium, long]`, repeat 3 times:

```sh
T0=$(date +"%Y-%m-%d %H:%M:%S.%3N")
```

Then `computer_batch`: click script field → `cmd+a` → `delete` → type bucket prompt → `cmd+return`.

```sh
scripts/uitest.sh bench-wait --since "$T0" --timeout 90
scripts/uitest.sh bench-record custom "$variant" warm "$bucket" --artifacts-dir "$ART"
```

### 2. Summarize + compare

After the loop completes (10 samples per variant × 2 = 20 in `bench-samples.jsonl`):

```sh
scripts/uitest.sh bench-summarize "$ART"          # writes $ART/bench-result.json
scripts/uitest.sh bench-compare "$ART"            # Markdown table; exit 1 if any breach
```

`bench-compare` highlights any (variant, phase, bucket, metric) that drifted more than ±15 % vs the committed baseline. First-ever run: baseline is empty; compare exits 0 with a "no baseline yet" message.

### 3. Promote to baseline (only when deliberate)

```sh
scripts/uitest.sh bench-update-baselines           # overwrites docs/reference/benchmark-baselines.json
git diff docs/reference/benchmark-baselines.json   # review
git commit -m "Update bench baselines: <reason>"   # only if intentional
```

The baseline file is committed source-of-truth. Update it only when the new numbers are intentional (faster path, expected regression with a known cause, etc.).

## Output shape

`$ART/bench-result.json`:

```json
{
  "schema_version": 2,
  "generated_at_utc": "...",
  "sample_count": 20,
  "results": {
    "custom": {
      "speed": {
        "cold": { "medium": { "ms_engine_start_to_final": {"n":1, "mean":..., ...}, "rtf": {...}, ... } },
        "warm": {
          "short":  { "ms_engine_start_to_final": {"n":3, ...}, ... },
          "medium": { ... },
          "long":   { ... }
        }
      },
      "quality": { ... }
    }
  }
}
```

Other generation modes (`design`, `clone`) populate sibling top-level keys when their own runbooks run.

Per-bucket metrics: `ms_engine_start_to_first_chunk`, `ms_engine_start_to_final`, `ms_engine_start_to_autoplay`, `audio_duration_s`, `rtf` (real-time factor = audio_seconds / generation_seconds — higher is better, >1 means faster than real-time).

## Failure handling

- **`bench-wait` times out**: the generation never completed. Take a screenshot, check `$ART/log.txt` for clues, and either retry the current sample (don't record it) or abort the run. Likely causes: app crashed, modal dialog blocked it, model not loaded for the selected variant.
- **`bench-record` reports "no Final File Ready"**: the signpost capture window expired. Re-trigger the generation and try again — but note that `bench-record` reads `log show --last 3m`, so don't wait too long between `bench-wait` and `bench-record`.
- **DB row missing**: race between the signpost (synchronous, before the detached save Task) and the DB write. `bench-record` already polls the DB for up to 2 s. If it still misses, the sample lands with `db_id: null` and `audio_duration_s: null` — analyze cause manually.
- **Variant toggle didn't switch the model**: the cold sample for the second variant will look suspiciously fast (model still warm). Verify by checking the Engine status line transitioned through "Starting engine…" before the cold sample.

## Notes

- This is the first benchmark scenario. Element 3 of the rollout will add Voice Design and Voice Cloning runbooks at the same depth.
- 3 warm samples per bucket gives noisy statistics (p95 is barely meaningful at n=3). It's enough to detect order-of-magnitude regressions. Future work can raise the sample count via flags.
- The cold sample is intentionally a single measurement per variant — repeating cold is expensive (each cold sample requires a fresh launch) and not currently in scope.
