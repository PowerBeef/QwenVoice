# Gemini Voice Review (runbook)

Reusable procedure for getting a structured, human-comparable review of a Vocello-generated audio sample through Gemini. The bench harness measures timing, RMS/peak, and memory; this procedure adds subjective dimensions such as naturalness, emotion match, pronunciation, and artifacts.

Use this when:

- Audio-path code changed and RMS/peak alone cannot prove the sample still sounds right.
- You want comparable cross-sample reviews with one fixed prompt template.
- You want Gemini to act as the multimodal/audio reviewer while Codex prepares context and records the result.

## Policy

Uploading a generated WAV to Gemini transmits local data to Google. Codex must get explicit user confirmation at action time before uploading a file through Chrome. If upload automation is flaky, stop and use the manual fallback instead of spending a long session fighting the web UI.

Do not make any repo workflow depend on a Claude subscription or a Claude-specific browser MCP. Codex may prepare the review prompt, locate the WAV, open Gemini, and save the returned review, but the upload/review step must remain explicit and reproducible.

## Prerequisites

| Requirement | How to satisfy |
|---|---|
| Chrome signed into Gemini | `https://gemini.google.com/app` opens to the prompt UI. |
| Codex Chrome control available | Use the Chrome plugin / `mcp__chrome_devtools__*` tools when browser automation is needed. |
| Vocello WAV file present on disk | Defaults under `~/Library/Application Support/QwenVoice-Debug/outputs/<Mode>/<timestamp>_<text-prefix>.wav`. |
| Sample context known | Mode, exact script text, delivery, speaker/voice description, and commit hash. |

## Recommended Flow

1. **Create a review bundle.**
   - Make `build/voice-reviews/<UTC-timestamp>-<mode>-<wav-basename>/`.
   - Copy or reference the source WAV.
   - Write `review_prompt.md` using the prompt template below.
   - Record metadata: mode, prompt text, delivery, speaker/voice context, audio duration, `git rev-parse --short HEAD`.

2. **Open Gemini in Chrome.**
   - Use `mcp__chrome_devtools__new_page(url: "https://gemini.google.com/app")` or select an existing Gemini tab.
   - Use `mcp__chrome_devtools__take_snapshot()` to find the prompt field, model selector, upload affordance, and send button.
   - Prefer a Gemini model that accepts audio and gives thoughtful multimodal review. If the product renames models, record the visible model name in the saved review.

3. **Upload the WAV only after confirmation.**
   - Ask the user to confirm the exact file path and Gemini destination immediately before upload.
   - First try `mcp__chrome_devtools__upload_file(filePath: "<absolute WAV path>", uid: "<upload control uid>")` if the snapshot exposes an upload control.
   - If Gemini uses a native picker or the upload control is not automatable, use the manual fallback: ask the user to drag the WAV from Finder onto Gemini's prompt bar, then confirm when the file chip appears.

4. **Submit the review prompt.**
   - Fill the prompt text with `mcp__chrome_devtools__fill(...)` or focus the prompt field and use `mcp__chrome_devtools__type_text(...)`.
   - Click the send button with `mcp__chrome_devtools__click(...)`.
   - Wait until the response stops changing and any thinking/progress indicator is gone.

5. **Save the review.**
   - Capture Gemini's response text.
   - Write `review.md` in the bundle directory using the storage convention below.
   - Include whether upload was automated or manual.

## Manual Upload Fallback

Use this whenever Chrome upload automation cannot see a real file input or reliable upload control:

1. Codex opens Gemini and prepares the prompt.
2. Codex prints the exact WAV path.
3. The user drags the WAV from Finder onto Gemini's prompt bar.
4. Codex waits for the visible uploaded-file chip, then fills and submits the prompt.

This is the preferred fallback. It is faster and safer than trying to force native picker automation.

## Prompt Template

Fill in `<...>` placeholders. The Markdown structure is rigid so reviews diff cleanly across runs.

```markdown
You are evaluating a text-to-speech audio sample produced by a local on-device TTS model on macOS (Vocello / Qwen3-TTS). I have attached the audio file. Listen carefully (the full clip) and provide a structured review.

Generation context:
- Mode: <Custom Voice | Voice Design | Voice Cloning>
- Text the model was asked to speak: "<EXACT TEXT VERBATIM>"
- Requested delivery: <e.g., "Neutral, Subtle" | "Excited" | "Calm and measured">
- Speaker/voice context:
  <For Custom Voice:>
  - Built-in speaker: <e.g., "Aiden — English native male">
  <For Voice Design:>
  - Voice description requested: "<DESCRIPTION>"
  <For Voice Cloning:>
  - Cloned from a saved reference clip; rate naturalness + identity coherence, NOT similarity to a specific person.

Respond in English, in this EXACT Markdown format (do not add additional sections, do not omit any):

## Voice Quality Review

**Overall score**: X/10 — <one sentence summary>

### Naturalness
- Score: X/10
- Notes: <one or two sentences>

### Intelligibility
- Score: X/10
- Notes: <one or two sentences>

### Emotion / delivery match
- Score: X/10
- Notes: <one or two sentences — does the delivery match the requested tone? For Voice Design, does it match the voice description?>

### Pronunciation
- Score: X/10
- Notes: <one or two sentences — note any specific mispronounced words>

### Pacing & prosody
- Score: X/10
- Notes: <one or two sentences>

### Artifacts
- Detected: <list clicks, pops, glitches, hiss, mid-word cuts, chunk-boundary discontinuities, background tones — OR "None">
- Severity: <None | Subtle | Noticeable | Severe>

### Strengths
- <bullet point>
- <bullet point>

### Weaknesses
- <bullet point>
- <bullet point>

### Suggested investigation
<one sentence — e.g., "Pronunciation of 'X' was unclear, worth checking the tokenizer's handling of that word." Or "None — sample is clean.">
```

## Storage Convention

Reviews land under `build/voice-reviews/` (already under ignored `build/`).

Bundle directory: `<UTC-timestamp>-<mode>-<wav-basename>/`

Files:

- `review_prompt.md` — exact prompt sent to Gemini.
- `review.md` — Gemini response plus metadata.
- `metadata.json` — source WAV path, mode, delivery, speaker/voice context, text, audio duration, commit, reviewer model, upload method, reviewed timestamp.

`review.md` body:

```markdown
# Voice review

**Source WAV**: /Users/.../QwenVoice-Debug/outputs/<Mode>/<filename>.wav
**Mode**: <Custom Voice | Voice Design | Voice Cloning>
**Speaker / voice context**: <e.g., "Aiden — English native male" | "A calm, deep documentary narrator" | "Saved voice: UITestRef">
**Requested delivery**: <e.g., "Neutral, Subtle">
**Text**: "..."
**Audio duration**: X.X s
**Vocello commit**: <git short hash at time of generation>

**Reviewer**: Gemini <visible model name>
**Upload method**: <Codex Chrome upload | manual drag-drop>
**Reviewed at**: 2026-MM-DDTHH:MM:SSZ
**Procedure version**: 2.0 (docs/reference/gemini-voice-review.md)

---

<Gemini's response verbatim — the structured Markdown from the prompt template>
```

## Caveats

- Gemini's web UI may use a native file picker or change upload markup; if upload automation fails, use manual drag/drop.
- Reviews in one Gemini conversation share context. Start a new chat between large batches.
- The prompt requests English output, which Gemini generally honors even when the UI is localized.
- Gemini model names and capabilities can change. Record the visible model name and avoid hard-coding assumptions beyond audio support.
- Scores are subjective and not deterministic. For regression detection, review at least n=3 representative samples and compare medians.

## Cross-references

- `AGENTS.md` — Vocello project root, including `shouldStream: true` enable status and bench-baseline conventions.
- `docs/reference/ui-test-surface.md` — how to know what text was generated for a given WAV, per-mode AX ids, and streaming-state signposts.
- `docs/reference/benchmark-baselines.json` — the timing/RMS/peak baselines this review pairs with.
