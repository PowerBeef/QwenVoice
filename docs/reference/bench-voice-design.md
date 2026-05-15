# Bench Runbook: Voice Design across cold/warm × variant × prompt-length

Multi-sample timing harness for Voice Design generations. Same structure as [`bench-custom-voice.md`](bench-custom-voice.md), passing `design` as the mode argument to `bench-record`.

Companion docs: [`ui-test-surface.md`](ui-test-surface.md), [`smoke-voice-design.md`](smoke-voice-design.md).

## Run plan

```
for variant in [speed, quality]:
    3 × cold sample   (medium prompt, fresh-launch between each)
    3 × warm short
    3 × warm medium
    3 × warm long
```

24 samples total (12 per variant). See `bench-custom-voice.md`'s "Cold sample count" note for why cold is now n=3 instead of n=1.

## Prerequisites

- Debug build present.
- `scripts/uitest.sh smoke-check design` exits 0.
- macOS Accessibility granted.
- 5–10 minutes of uninterrupted Vocello time.

## Fixed inputs

Voice description (held constant across all samples in a run):

```
A calm, deep documentary narrator with a measured pace.
```

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
mcp__computer-use__request_access(applications: ["Vocello"])
read SW SH < <(scripts/uitest.sh screen-size)
```

### 1. Variant loop

For each `variant` in `[speed, quality]`:

#### 1a. Fresh launch

```sh
scripts/uitest.sh reset
scripts/uitest.sh prep
scripts/uitest.sh activate
```

#### 1b. Navigate to Voice Design + select variant + fill description

- Locate + click `sidebar_voiceDesign` (scale coords).
- Verify with `locate screen_voiceDesign` (exit 0).
- Select variant via the segmented control. First contact:
  1. Try `scripts/uitest.sh locate voiceDesign_variant_speed` and `voiceDesign_variant_quality`. Record what works in `ui-test-surface.md`.
  2. Otherwise click visually (top-right of the configuration card) and note the coordinates.
- Locate + click `voiceDesign_voiceDescriptionField`, then `mcp__computer-use__type` the fixed description.

**Verify variant first** via screenshot (see `bench-custom-voice.md` — same caveat applies; `GenerationVariantSelector` button-level AX ids aren't queryable).

**Initial T0.** Before the first generation in a `(mode, variant)` pass:

```sh
python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0
```

#### 1c. Cold sample (medium prompt)

`computer_batch`: click `textInput_textEditor` → type medium prompt → `cmd+return`.

```sh
scripts/uitest.sh bench-step design "$variant" cold medium --artifacts-dir "$ART" --timeout 240
```

VD/Quality cold has been seen taking >180 s on Apple M2 — the 240 s timeout gives headroom.

#### 1d. Warm samples

For each `bucket` in `[short, medium, long]`, repeat 3 times:

`computer_batch`: click `textInput_textEditor` → `cmd+a` → `delete` → type bucket prompt → `cmd+return`. **Do not** clear or re-type the voice description; it persists between samples and we want to bench the steady-state generate path.

```sh
scripts/uitest.sh bench-step design "$variant" warm "$bucket" --artifacts-dir "$ART"
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

The combined baselines file is keyed by mode at the top level (`results.design.<variant>...`), so Voice Design baselines coexist with Custom Voice and Voice Cloning without collision.

## Failure handling

- **Description didn't apply** (the field looks empty after typing): click the field once more and retry typing. Voice Design uses a `ContinuousVoiceDescriptionField` wrapper that can momentarily lose focus during validation.
- Everything else is identical to `bench-custom-voice.md` — see there for `bench-wait` timeouts, missing `Final File Ready`, DB row lag, and the rest.
