# Tone and Emotion in QwenVoice

This guide is a supplemental prompt-writing reference for the shipped macOS app.

For current repo truth about app structure, workflows, or supported behavior, trust:

1. `README.md`
2. `docs/reference/current-state.md`
3. `AGENTS.md`

## What the App Exposes

QwenVoice controls tone and emotion through natural-language instructions, not SSML and not explicit sampling sliders.

Current app behavior:

- **Custom Voice** uses one of the shipped English speakers plus an instruction prompt
- **Voice Design** has its own generation screen and prompt flow
- **Voice Cloning** uses reference audio and can optionally use a transcript for better preparation quality, but it does not expose a separate instruction-only tone surface
- single generations stream live preview, but the app does not expose temperature or max-token controls

Useful instruction patterns:

- emotional delivery: `calm and reassuring`, `frustrated but controlled`, `nervous and unsure`
- pacing and cadence: `slow, deliberate pace`, `quick and energetic`, `measured and deliberate`
- character and timbre: `warm documentary narrator`, `dry late-night radio host`, `soft-spoken teacher`

## Practical Guidance

- Be specific: combine voice character, emotional state, and pacing in one instruction.
- Keep requests concrete: `calm middle-aged narrator with steady pacing` works better than `make it better`.
- Iterate wording: instruction following is probabilistic, so small prompt changes can materially change the result.
- Use Voice Design when you want a reusable prompt-driven voice shape, and use Voice Cloning when you want a specific reference identity from audio.

## Examples

Custom Voice:

> Speak in a calm, slightly tired voice, like someone explaining a long day.

Voice Design:

> A composed documentary narrator with a low, warm voice and deliberate pacing.

Voice Cloning support text:

> Use a clean 5–10 second reference clip and include the transcript if possible.

## Related Docs

- [`../README.md`](../README.md)
- [`reference/current-state.md`](reference/current-state.md)
