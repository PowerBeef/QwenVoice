# Emotion / delivery accuracy — May 2026 improvements

Working notes for the round of fixes that landed in the same change as this file. Records *why* each fix was made so a later session can decide whether to revert, extend, or rewrite.

## Architecture, end to end

For both Custom Voice and Voice Design, the delivery instruction the user picks in the UI becomes part of the **chat-format prompt** the Qwen3-TTS model decodes. It is **not** a separate conditioning embedding — it's literally tokenized text in the model's prompt prefix.

```
UI (EmotionPickerView)
   └─→ DeliveryProfile   (Sources/Models/EmotionPreset.swift)
        └─→ Coordinator  (Custom or VoiceDesign)
             └─→ GenerationSemantics.{customInstruction,designInstruction}
                  └─→ englishDictionReinforcedInstruction  (optional English-only append)
                       └─→ Qwen3TTS.buildConditioningPrefix(instruct:)
                            └─→ "<|im_start|>user\n{instruct}<|im_end|>\n"  → tokenize → embed → prefix the audio decoder
```

Two consequences:

1. **Phrasing matters.** The model parses the instruction as natural-language performance direction (per `docs/qwen_tone.md`), so wording, word order, and the presence/absence of cross-preset terms ("dramatic", "intense") materially shape the output.
2. **Concatenation matters.** Voice Design combines `voiceDescription + emotion` in one string; any conflict between the two halves is the user's problem. Custom Voice keeps the speaker separate (it's a token embedding) and only the emotion is text.

## The two real bugs

### Bug 1 — Voice Design instruction concat was brief-dominated

`Sources/QwenVoiceCore/GenerationSemantics.swift:38-49` used:

```swift
return "\(trimmedEmotion) \(trimmedDescription)"
```

For the bench-standard voice brief `"A calm, deep documentary narrator with a measured pace."`, picking the **Happy** preset produced:

> Happy and upbeat, with bright energy, clear articulation, and natural conversational pacing. A calm, deep documentary narrator with a measured pace.

The two halves directly contradict. May 18's salvaged-cell data confirmed empirically: VD Happy/Subtle scored **4/10** on emotion-match vs. CV Happy/Subtle at **8/10**, with the same preset text fed into both modes. The voice brief was winning.

**Fix:** restructure as labeled framing.

```swift
return "Voice character: \(trimmedDescription) Delivery: \(trimmedEmotion)"
```

- Description first establishes the persistent voice identity.
- `Voice character:` / `Delivery:` labels match the chat-format conventions the model was trained on.
- The dominant performance direction (Delivery) follows, which is where the model expects per-take guidance.

Bench timings are unaffected — `normalizedDesignConditioningIdentity` (lines 55-72) keys off the full instruction text, so cache identity just shifts to a new value.

### Bug 2 — `englishDictionReinforcement` appended unconditionally

`Sources/QwenVoiceCore/GenerationSemantics.swift:108-130` appended `"Native English pronunciation with clear English diction and natural stress."` to every English-language instruction. The existing dedup check only skipped when that exact substring was already present.

Several preset strings already say "clear articulation" (Happy), "clear words" (Fearful), "clear pronunciation" (Whisper, Excited). After append, the model received instructions like:

> Happy and upbeat, with bright energy, clear articulation, and natural conversational pacing. Native English pronunciation with clear English diction and natural stress.

Three "clear" tokens, two "diction"/"articulation" tokens — the diction half drowns out the emotion half.

**Fix:** expand the dedup guard to skip the append when the base instruction already contains any of: `clear`, `clearly`, `diction`, `articulation`, `pronunciation`, `clarity`, `intelligible`, `understandable`. Lowercased substring check; preserves base-string case in the output.

## The 27-string preset rewrite

`Sources/Models/EmotionPreset.swift` (and its byte-identical mirror at `Sources/iOSSupport/Models/EmotionPreset.swift`) hand-wrote each of the 8 non-Neutral presets × 3 intensity levels = 24 instruction strings (Neutral is just `"Neutral"`). These predate `docs/qwen_tone.md`'s guidance and didn't consistently follow its phrasing patterns.

### Pattern applied

From `docs/qwen_tone.md`:

> Combine voice character, emotional state, pacing, and clarity in one instruction. Prefer short, direct performance direction over one-word labels; Qwen3-TTS follows natural-language delivery instructions.

Concrete rules used in the rewrite:

1. **Lead with the dominant emotion verb in present tense.** "Speaks happily" not "Happy and upbeat".
2. **Action verbs over adjective lists.** Performance direction beats trait labels.
3. **Combine emotion + pacing + clarity hint in one sentence.**
4. **Use the word "whisper" literally for the Whisper preset** at all intensities. `qwen_tone.md` calls this out: generic "soft and quiet" produces soft-spoken, not true whisper.
5. **For Strong intensity, lead with the intensifier word.** "Speaks furiously", "Whispers urgently", "Speaks in trembling panic".
6. **Drop "natural pacing" / "clear articulation" boilerplate** — the diction reinforcement (when it survives the new guard from Bug 2) covers clarity. Preset strings can focus on emotional shape.
7. **Avoid words that name other presets.** "Intense" and "dramatic" trigger the Dramatic conditioning even when used in a Whisper string. Use synonyms: "fervent", "animated", "urgent".

### Old → new table

| Preset / Intensity | Old | New |
|---|---|---|
| Happy / Subtle | Slightly cheerful and warm, with a gentle smile in the voice and natural pacing. | Speaks with a hint of warmth and a faint smile in the voice. |
| Happy / Normal | Happy and upbeat, with bright energy, clear articulation, and natural conversational pacing. | Speaks happily and upbeat, smiling through the words with bright energy. |
| Happy / Strong | Very happy and joyful, energetic and expressive, with lively stress while keeping words clear. | Speaks joyfully and exuberantly, lighting up every word with bouncy, beaming enthusiasm. |
| Sad / Subtle | Slightly sad and reflective, subdued but clear, with slower natural pacing. | Speaks with quiet, reflective sadness, slower and a little subdued. |
| Sad / Normal | Sad and somber, with a restrained heavy tone and gentle pauses. | Speaks sadly and somberly, with a heavy, restrained tone and small gentle pauses. |
| Sad / Strong | Deeply sad and tearful, with fragile emotion, slow pacing, and soft intensity while staying intelligible. | Speaks through deep sorrow, fragile and tearful, words slow and weighted with grief. |
| Angry / Subtle | Slightly irritated and tense, controlled and clipped without shouting. | Speaks with quiet irritation, controlled and clipped, holding back the bigger feeling. |
| Angry / Normal | Angry and frustrated, with firm stress, sharper consonants, and controlled intensity. | Speaks angrily and frustrated, firm and pushed, with sharp consonants and tight stress. |
| Angry / Strong | Furious but intelligible, forceful and tense, with sharp emphasis and no screaming. | Speaks furiously, biting every word with forceful tension, never breaking into a scream. |
| Fearful / Subtle | Slightly nervous and uneasy, cautious and quiet with natural hesitation. | Speaks with quiet unease, cautious and hesitant, voice a little smaller than usual. |
| Fearful / Normal | Fearful and anxious, with tense breath, uncertain pacing, and clear words. | Speaks fearfully and anxiously, breath caught, pacing uncertain, words pushed out shakily. |
| Fearful / Strong | Terrified and urgent, trembling and panicked but still understandable. | Speaks in trembling panic, voice quavering and urgent, but still keeps every word audible. |
| Whisper / Subtle | Subtle audible whisper, close-mic and quiet, with gentle breath, hushed tone, and clear words. | Whispers gently, close-mic and quiet, with soft breath and easy pacing. |
| Whisper / Normal | Hushed whisper, intimate and quiet, with breathy texture, clear articulation, and soft pacing. | Whispers throughout, hushed and breathy, every word voiced just above breath, close and confidential. |
| Whisper / Strong | Very soft and breathy whisper, intimate and intense, with clear pronunciation and enough audibility to understand every word. | Whispers urgently and barely voiced, secretive close-mic breath, audible but never lifted into normal speech. |
| Dramatic / Subtle | Slightly theatrical, with measured emphasis and tasteful pauses. | Speaks with measured theatrical weight, leaning into key beats without overdoing it. |
| Dramatic / Normal | Dramatic and expressive, with heightened intonation, deliberate pacing, and clear emphasis. | Speaks dramatically and expressively, lifting key phrases with heightened inflection and deliberate pacing. |
| Dramatic / Strong | Highly dramatic and theatrical, with bold emphasis, sweeping intensity, and well-timed pauses. | Speaks with sweeping theatrical grandeur, bold stress on key words, generous well-timed pauses that command attention. |
| Calm / Subtle | Relaxed and easy-going, steady and warm with unhurried pacing. | Speaks easily and unhurriedly, relaxed and warm throughout. |
| Calm / Normal | Calm, soothing, and reassuring, with smooth pacing and gentle confidence. | Speaks calmly and soothingly, smooth pacing with reassuring warmth and gentle confidence. |
| Calm / Strong | Deeply serene and meditative, slow and deliberate, with soft warmth and long steady phrasing. | Speaks with serene, meditative stillness, slow and softly grounded, each phrase fully landed. |
| Excited / Subtle | Slightly energetic and engaged, with a touch of enthusiasm and natural pace. | Speaks with a touch of enthusiasm, slightly energized and engaged. |
| Excited / Normal | Excited and energetic, enthusiastic and bright, with quick but clear delivery. | Speaks energetically and enthusiastically, bright and animated, picking up the pace just slightly. |
| Excited / Strong | Very excited and animated, energetic and anticipatory, with lively emphasis, controlled pacing, and clear pronunciation. | Speaks with bursting, lively excitement, animated and bright, can hardly contain the eager energy. |

Notable removals during the rewrite, by rule:

- "intense" stripped from Whisper/Strong (rule 7 — was triggering Dramatic conditioning).
- "clear" / "clearly" / "clear pronunciation" stripped from most strings (rule 6 — diction reinforcement now covers it when not already present).
- "natural pacing" stripped (rule 6 — verb already implies natural pacing unless modified).
- "controlled intensity" / "well-timed pauses" / "sweeping intensity" trimmed from non-Dramatic presets (rule 7).

## The picker-driving lesson (test-side fix)

May 18's 53-cell test driving the delivery picker via fixed click coordinates produced 45 mis-labeled cells. Root cause: SwiftUI `Picker` menus open **anchored to the currently-selected item**, so fixed menu-item y-coordinates only work for the first selection.

The fix is in `docs/reference/ui-test-surface.md`'s "Driving SwiftUI `Picker` menus" subsection: click the picker → `key("down")` N times → `key("return")`, tracking the current selection in shell state to compute N. Cross-link from this doc.

A note also lands in `CLAUDE.md`'s "Conventions to preserve" so the next session driving a Picker doesn't repeat the mistake.

## Expected Gemini score deltas (verification gates)

Re-run criteria after the fix lands (per the plan's verification section):

- **C1** — Every non-Neutral preset clears ≥7 on emotion-match in at least one intensity per mode. (Today's salvaged data: CV passed for every preset that got a sample; VD failed on Happy at 4/10 best.)
- **C2** — VD Neutral ≥8/10. (Was 7/10.)
- **C3** — Whisper/Strong described by Gemini as a whisper, not as dramatic. (Today's review for the actual Whisper/Strong cell that ran called it "flat, nervous, and hesitant" — the "intimate and intense" wording was misleading the model.)
- **C4** — Strong − Subtle delta positive for ≥6 of 8 presets per mode.
- **C5** — Cross-mode |Δ|>2 cell count drops below 5 (was 12).
- **C6** — Custom-tone cells produce 3 clearly-distinct deliveries with Gemini's perceived emotion matching the request.

## Deferred to future sessions

- **Per-preset sampling parameters.** Qwen3TTS exposes `temperature`, `topP`, `topK`, `repetitionPenalty`, `minP`. All are hardcoded today (temp 0.9, topK 50, topP 1.0). A future plan can map each preset to a tuned tuple — e.g., Whisper tighter (lower topP) for less surprise, Excited looser (higher temp) for more variation. Lives in `Qwen3GenerationConfiguration` + the preset table.
- **Voice Design UI redesign.** A1's labeled-framing fix is structural at the prompt level; the UI still mixes voice brief and emotion into one input box. A future revision could expose them as separate fields with clearer names (e.g., "Voice character" and "Performance").
- **Voice Cloning delivery surface.** Cloning has no emotion controls today (the engine path doesn't accept them). A future feature could add minimal delivery hints — at minimum a Subtle/Normal/Strong intensifier without a preset.

## Cross-references

- `docs/qwen_tone.md` — phrasing guidance the rewrite follows.
- `docs/reference/ui-test-surface.md` § "Driving SwiftUI `Picker` menus" — keyboard-navigation pattern for tests.
- `docs/reference/gemini-voice-review.md` — the perceptual review tool used for the verification matrix.
- `Sources/QwenVoiceCore/GenerationSemantics.swift` — instruction-assembly layer (the only Swift file that changed for the two fixes).
- `Sources/Models/EmotionPreset.swift` + `Sources/iOSSupport/Models/EmotionPreset.swift` — preset string library (kept byte-identical between macOS and iOS targets).
