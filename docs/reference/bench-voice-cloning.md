# Bench Runbook: Voice Cloning across cold/warm × variant × prompt-length

Multi-sample timing harness for Voice Cloning. Same structure as the other two bench runbooks, passing `clone` as the mode argument.

Companion docs: [`ui-test-surface.md`](ui-test-surface.md), [`smoke-voice-cloning.md`](smoke-voice-cloning.md), [`bench-custom-voice.md`](bench-custom-voice.md).

## Prerequisites

Requires the **`UITestRef`** saved-voice fixture. If `scripts/uitest.sh smoke-check clone` fails because the fixture is missing, run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md) first.

Voice Cloning has an extra subtlety for benchmarking: when the **reference clip changes**, the engine re-primes (`VoiceCloningCoordinator.ensureCloneReferencePrimed`). The cold sample for each variant captures this priming cost; warm samples reuse the primed reference. **Do not change the saved-voice selection between warm samples** — that would make every warm sample look cold.

## Run plan

```
for variant in [speed, quality]:
    3 × cold sample   (medium prompt, fresh-launch + re-prime between each)
    3 × warm short
    3 × warm medium
    3 × warm long
```

24 samples total (12 per variant). See `bench-custom-voice.md`'s "Cold sample count" note for the n=1 → n=3 rationale. For cloning specifically, each cold sample requires re-priming the reference clip, so the cold-cohort budget is closer to ~4 minutes per sample.

## Fixed inputs

| Field | Value |
|---|---|
| Saved voice | `UITestRef` (created by the bootstrap runbook). |
| Transcript | leave empty |

Prompts:

| Bucket | Length | Text |
|---|---|---|
| `short` | 12 chars | `Hello world.` |
| `medium` | 74 chars | `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.` |
| `long` | ~300 chars | `The MLX framework lets local language and speech models run efficiently on Apple silicon, which is exactly what Vocello uses for its native Qwen3-TTS pipeline. This longer paragraph exercises the streaming synthesis path across a larger token budget and gives the steady-state real-time factor a chance to settle.` |

## Steps

### 0. Setup

```sh
ART=$(scripts/uitest.sh artifacts-dir)
mcp__computer_use__get_app_state(app: "Vocello")
```

### 1. Variant loop

For each `variant` in `[speed, quality]`:

#### 1a. Fresh launch

```sh
scripts/uitest.sh reset
scripts/uitest.sh prep
scripts/uitest.sh activate
```

#### 1b. Navigate, select variant, bind saved voice

- `scripts/uitest.sh window-locate sidebar_voiceCloning` → `mcp__computer_use__click`.
- Verify with `locate screen_voiceCloning`.
- Select variant via the segmented control. First contact:
  1. Try `scripts/uitest.sh window-locate voiceCloning_speedVariantButton` / `voiceCloning_qualityVariantButton`.
  2. If direct button IDs fail, try `voiceCloning_modelVariantPicker` and `voiceCloning_modelVariantSelector` as anchors.
  3. Otherwise click visually.
- `scripts/uitest.sh window-locate voiceCloning_savedVoicePicker` → `mcp__computer_use__click`, screenshot to see the open menu, click the `UITestRef` menu item.
- Verify with `locate voiceCloning_activeReference` (exit 0 means a reference is bound).

**Verify variant first** via screenshot (see `bench-custom-voice.md` — same caveat).

**Initial T0.** Before the first generation in a `(mode, variant)` pass:

```sh
python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0
```

#### 1c. Cold sample (medium prompt)

In order: click `textInput_textEditor` → type medium prompt → `super+Return`.

```sh
scripts/uitest.sh bench-step clone "$variant" cold medium --artifacts-dir "$ART" --timeout 180
```

#### 1d. Warm samples

For each `bucket` in `[short, medium, long]`, repeat 3 times:

In order: click `textInput_textEditor` → `super+a` → `BackSpace` → type bucket prompt → `super+Return`. **Don't touch the saved-voice picker** between warm samples.

```sh
scripts/uitest.sh bench-step clone "$variant" warm "$bucket" --artifacts-dir "$ART"
```

**Warm-short variance**: ≥10 samples recommended if you need to distinguish noise from real regression in the warm/short bucket.

### 2. Summarize + compare

```sh
scripts/uitest.sh bench-summarize "$ART"
scripts/uitest.sh bench-compare "$ART"
```

### 3. Promote to baseline (only when deliberate)

```sh
scripts/uitest.sh bench-update-baselines
git diff docs/reference/benchmark-baselines.json
git commit -m "Update bench baselines: <reason>"
```

## Failure handling

- **Saved-voice picker had no `UITestRef` entry**: `smoke-check clone` should have caught this. If it slipped through, abort the run and run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md).
- **Warm sample looks unexpectedly slow**: the saved-voice selection may have been re-touched (re-primes the reference). Don't click the picker between warm samples.
- **Quality warning badge on the active reference**: degraded audio possible but doesn't affect bench timings. Note in `result.json` for awareness.
- Everything else is identical to `bench-custom-voice.md` — see there for `bench-wait` timeouts, missing `Final File Ready`, DB row lag.
