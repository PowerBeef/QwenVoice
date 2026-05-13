# Tone and Emotion in QwenVoice

_Last reviewed: 2026-05-08._

This guide is a supplemental prompt-writing reference for the shipped macOS app. It is supplemental and may lag shipped behavior — when in doubt, trust the sources listed below before this guide.

For current repo truth about app structure, workflows, or supported behavior, trust:

1. `README.md`
2. `docs/reference/current-state.md`
3. `CLAUDE.md` for repository and agent workflow rules

## What the App Exposes

QwenVoice controls tone and emotion through natural-language instructions, not SSML and not explicit sampling sliders.

Current app behavior:

- **Custom Voice** uses one of the shipped speakers plus an optional delivery instruction prompt
- **Voice Design** has its own generation screen and prompt flow using a natural-language voice/design instruction
- **Voice Cloning** uses reference audio and can optionally use a transcript for better preparation quality, but it does not expose a separate instruction-only tone surface
- single generations produce a complete final take, and the app does not expose temperature or max-token controls
- **Neutral** delivery is intentionally treated as no meaningful style instruction. Custom Voice and Voice Design prompts use direct natural language rather than `Delivery style:` fields.

Useful instruction patterns:

- emotional delivery: `calm and reassuring`, `frustrated but controlled`, `nervous and unsure`
- vocal behavior: `gentle smile in the voice`, `sharp emphasis without shouting`, `breathy but clear`
- pacing and cadence: `slow, deliberate pace`, `quick but clear`, `measured pauses`
- character and timbre: `warm documentary narrator`, `dry late-night radio host`, `soft-spoken teacher`

## Practical Guidance

- Be specific: combine voice character, emotional state, pacing, and clarity in one instruction.
- Keep requests concrete: `calm middle-aged narrator with steady pacing` works better than `make it better`.
- Prefer short, direct performance direction over one-word labels; Qwen3-TTS follows natural-language delivery instructions.
- Keep strong emotions intelligible: add constraints like `while keeping words clear`, `without shouting`, or `still understandable`.
- For whisper delivery, say `whisper` explicitly. Generic `soft and quiet` wording can produce soft-spoken delivery instead of an actual whisper.
- Iterate wording: instruction following is probabilistic, so small prompt changes can materially change the result.
- Use Voice Design when you want a reusable prompt-driven voice shape, and use Voice Cloning when you want a specific reference identity from audio.

## Pauses in the Spoken Text

Qwen3-TTS does not parse SSML or explicit pause markers. Pauses come from the natural punctuation and line structure of the input:

- **Period** — sentence-end pause (longest within a paragraph).
- **Comma / semicolon / colon** — short pause.
- **Blank line** between paragraphs — paragraph-level pause.
- **Question mark / exclamation mark** — sentence-end pause with the matching prosody.

Things that are **not** reliable pause cues:

- Ellipsis (`...`) — read as text, not as a long pause.
- Hyphens or dashes — usually treated as continuation, not pause.
- Repeated commas or extra spaces — collapsed; they don't lengthen the pause.

If you need a longer beat, end the sentence with a period and start a new one. For an explicit paragraph break, add a blank line.

## Examples

Custom Voice:

> Calm, soothing, and reassuring, with smooth pacing and gentle confidence.

Custom Voice, strong emotion:

> Very excited and animated, energetic and anticipatory, with lively emphasis, controlled pacing, and clear pronunciation.

Custom Voice, whisper:

> Subtle audible whisper, close-mic and quiet, with gentle breath, hushed tone, and clear words.

Voice Design:

> A composed documentary narrator with a low, warm voice, deliberate pacing, crisp diction, and gentle emphasis on key phrases.

Voice Cloning support text:

> Use a clean 5–10 second reference clip and include the transcript if possible.

## Source References

- [Qwen3-TTS README](https://github.com/QwenLM/Qwen3-TTS/blob/main/README.md)
- [Qwen3-TTS Hugging Face model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)
- [Qwen3-TTS Technical Report](https://arxiv.org/abs/2601.15621)

## Related Docs

- [`../README.md`](../README.md)
- [`reference/current-state.md`](reference/current-state.md)
