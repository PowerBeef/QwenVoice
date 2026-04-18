# Tone and Emotion in QwenVoice

This guide is a supplemental prompt-writing reference. It focuses on what QwenVoice currently exposes, then calls out where the standalone CLI or broader Qwen3-TTS ecosystem goes beyond the shipped macOS app.

For current repo truth about app structure, workflow names, or shipped behavior, trust:

1. `README.md`
2. `docs/reference/current-state.md`
3. `AGENTS.md`

## What the Shipped App Exposes

The shipped GUI controls tone and emotion through natural-language instructions, not SSML and not explicit temperature/max-token sliders.

Current app behavior:

- **Custom Voice** uses one of the shipped English speakers plus an instruction prompt
- **Voice Design** is its own main-window destination with a separate screen and prompt flow
- **Voice Cloning** clones from reference audio and can optionally use a transcript for better preparation quality, but it does not expose a separate instruction-style tone control surface
- the shipping GUI exposes live streaming preview for single generations, but not temperature or max-token controls

Useful instruction patterns in the shipped app:

- emotional delivery: `calm and reassuring`, `frustrated but controlled`, `nervous and unsure`
- pacing and cadence: `slow, deliberate pace`, `quick and energetic`, `measured and deliberate`
- character and timbre: `warm documentary narrator`, `dry late-night radio host`, `soft-spoken teacher`

## What the Standalone CLI Exposes

The CLI in `cli/` is broader than the shipped GUI in two important ways:

1. it still exposes a wider speaker map in `cli/main.py`
2. it remains a direct interactive terminal workflow rather than the app’s curated GUI flow

That means CLI examples or speaker counts should not be treated as shipped-app UI facts.

## Broader Qwen3-TTS Notes

Qwen3-TTS itself is more flexible than the current app surface. In the broader ecosystem you may see references to:

- additional speakers or languages outside the app’s shipped UI
- backend/internal streaming and batch capabilities beyond the shipped GUI
- advanced sampling controls such as `temperature`
- cloud-only or framework-specific integrations

Those are informational for power users and benchmark tooling, but they are not the current QwenVoice GUI contract unless the app docs explicitly say otherwise.

## Practical Guidance

- Be specific: combine voice character, emotional state, and pacing in one instruction.
- Keep requests concrete: `calm middle-aged narrator with steady pacing` works better than `make it better`.
- Iterate wording: instruction following is probabilistic, so small prompt changes can materially change the result.
- For consistent stylized production, use Voice Design when you want a reusable prompt-driven voice shape, then use Voice Cloning when you want a specific reference identity rather than trying to rediscover the same tone every run.

## Examples

Custom Voice:

> Speak in a calm, slightly tired voice, like someone explaining a long day.

Voice Design:

> A composed documentary narrator with a low, warm voice and deliberate pacing.

Voice Cloning support text:

> Use a clean 5–10 second reference clip and include the transcript if possible.

## Related Docs

- [`README.md`](README.md)
- [`docs/reference/current-state.md`](docs/reference/current-state.md)
- [`cli/README.md`](cli/README.md)
