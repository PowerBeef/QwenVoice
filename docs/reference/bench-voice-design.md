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

#### 1b. Navigate to Voice Design + select variant + fill description

- `scripts/uitest.sh window-locate sidebar_voiceDesign` → `mcp__computer_use__click`.
- Verify with `locate screen_voiceDesign` (exit 0).
- Select variant via the segmented control:
  1. Use `scripts/uitest.sh window-locate voiceDesign_speedVariantButton` and `voiceDesign_qualityVariantButton` first; these are the canonical button IDs.
  2. If direct button IDs fail, try `voiceDesign_modelVariantPicker` and `voiceDesign_modelVariantSelector` as anchors.
  3. Otherwise click visually (top-right of the configuration card) and note the coordinates.
- `scripts/uitest.sh window-locate voiceDesign_voiceDescriptionField` → `mcp__computer_use__click`, then `mcp__computer_use__type_text(app: "Vocello", text: "<fixed description>")`.

**Verify variant first** via screenshot (see `bench-custom-voice.md`).

**Initial T0.** Before the first generation in a `(mode, variant)` pass:

```sh
python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0
```

#### 1c. Cold sample (medium prompt)

In order: click `textInput_textEditor` → type medium prompt → `super+Return`.

```sh
scripts/uitest.sh bench-step design "$variant" cold medium --artifacts-dir "$ART" --timeout 240
```

VD/Quality cold has been seen taking >180 s on Apple M2 — the 240 s timeout gives headroom.

#### 1d. Warm samples

For each `bucket` in `[short, medium, long]`, repeat 3 times:

In order: click `textInput_textEditor` → `super+a` → `BackSpace` → type bucket prompt → `super+Return`. **Do not** clear or re-type the voice description; it persists between samples and we want to bench the steady-state generate path.

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
