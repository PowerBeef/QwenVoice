You are evaluating whether Voice Cloning tone guidance changed the delivery of a generated speech clip while keeping the same speaker identity.

Files in the current working directory:
- `scenario.json`
- `neutral.wav`
- `guided.wav`
- `response_schema.json`

Instructions:
1. Read `scenario.json` to get the scenario metadata and requested tone.
2. Inspect `neutral.wav` and `guided.wav` as audio files.
3. Compare `guided.wav` against `neutral.wav` for the same script and reference speaker.
4. Judge only delivery and speaker identity:
   - Did `guided.wav` express the requested tone more strongly than `neutral.wav`?
   - Did both clips still sound like the same speaker?
5. Ignore lexical content because both clips use the same script.
6. Ignore small loudness or mastering differences unless they materially affect perceived emotion.
7. Return exactly one JSON object that matches `response_schema.json`.

Decision guidance:
- `relative_contrast` should be:
  - `stronger` when the requested tone is clearly more noticeable in `guided.wav`
  - `slightly_stronger` when the effect is present but modest
  - `no_clear_difference` when the clips are effectively the same emotionally
  - `weaker` when `guided.wav` is less aligned with the requested tone than `neutral.wav`
- `target_match` should be:
  - `clear` when the requested tone is obvious
  - `partial` when it is somewhat present
  - `poor` when it is not meaningfully present
- `speaker_consistency` should be:
  - `preserved` when both clips clearly sound like the same speaker
  - `slightly_shifted` when the speaker still sounds mostly the same but with some drift
  - `changed` when the speaker identity no longer sounds meaningfully the same

Output rules:
- Return JSON only.
- Do not use Markdown fences.
- Do not add any extra prose before or after the JSON object.
