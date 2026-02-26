# Controlling tone and emotion in Qwen3-TTS

Qwen3-TTS uses **natural language instructions** — not SSML, special tokens, or numeric sliders — as its sole mechanism for controlling emotion, tone, and speech cadence. The `instruct` parameter accepts free-form text descriptions like "Speak in an incredulous tone, but with a hint of panic beginning to creep into your voice," and the model adapts its output accordingly. Only the **1.7B-parameter models** (CustomVoice and VoiceDesign) support this instruction-based control; the 0.6B variants and Base models lack it entirely.

The system builds on a discrete multi-codebook language model architecture with a proprietary 12Hz speech tokenizer that preserves paralinguistic information — breath, hesitation, and emotional intensity. This means the model can also automatically adapt prosody based on the semantics of the input text itself, even without explicit instructions. However, the instruction system's controllability is probabilistic rather than deterministic: the model treats instructions as soft guidance, and complex multi-dimensional requests may not always be followed precisely.

## Only two model variants offer style control

The Qwen3-TTS family consists of six models, but the distinction that matters most is whether a given model supports the `instruct` parameter:

| Model | Instruction control | Use case |
|---|---|---|
| **Qwen3-TTS-12Hz-1.7B-CustomVoice** | ✅ Yes | Modify emotion/tone of 9 preset voices |
| **Qwen3-TTS-12Hz-1.7B-VoiceDesign** | ✅ Yes | Create entirely new voices with specified style |
| Qwen3-TTS-12Hz-1.7B-Base | ❌ No | Voice cloning from reference audio |
| Qwen3-TTS-12Hz-0.6B-CustomVoice | ❌ No | Preset voices without style control |
| Qwen3-TTS-12Hz-0.6B-Base | ❌ No | Voice cloning only |
| qwen3-tts-instruct-flash (cloud API) | ✅ Yes | Alibaba Cloud endpoint with strongest control |

The **CustomVoice** model lets you pick from nine preset speakers (e.g., Vivian, Ryan, Serena) and then layer emotional or stylistic modifications on top. The **VoiceDesign** model creates entirely new voices from scratch based on your text description, simultaneously defining both the voice identity and the emotional delivery. The cloud-only **instruct-flash** model through Alibaba's DashScope API reportedly offers the most precise control, including adjustable speech rate, pitch, and volume parameters beyond what the open-source models expose.

## The `instruct` parameter drives all prosody control

There are no SSML tags, no `<prosody>` elements, no special tokens, and no chat template markup. The entire control surface is a single natural language string passed as the `instruct` parameter. The model's official tagline captures the philosophy: **"what you imagine is what you hear."**

For the **CustomVoice** model, the API looks like this:

```python
from qwen_tts import Qwen3TTSModel
import torch, soundfile as sf

model = Qwen3TTSModel.from_pretrained(
    "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    device_map="cuda:0",
    dtype=torch.bfloat16,
    attn_implementation="flash_attention_2",
)

# Angry delivery
wavs, sr = model.generate_custom_voice(
    text="其实我真的有发现，我是一个特别善于观察别人情绪的人。",
    language="Chinese",
    speaker="Vivian",
    instruct="用特别愤怒的语气说",  # "Say it in a particularly angry tone"
)
sf.write("angry_output.wav", wavs[0], sr)

# Happy delivery in English
wavs, sr = model.generate_custom_voice(
    text="She said she would be here by noon.",
    language="English",
    speaker="Ryan",
    instruct="Very happy.",
)
```

For the **VoiceDesign** model, the `instruct` parameter carries more weight because it simultaneously defines the voice character and the emotional style:

```python
model = Qwen3TTSModel.from_pretrained(
    "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
    device_map="cuda:0",
    dtype=torch.bfloat16,
    attn_implementation="flash_attention_2",
)

# Panicked, incredulous tone
wavs, sr = model.generate_voice_design(
    text="It's in the top drawer... wait, it's empty? No way, that's impossible!",
    language="English",
    instruct="Speak in an incredulous tone, but with a hint of panic beginning to creep into your voice.",
)

# Nervous teenager gaining confidence
wavs, sr = model.generate_voice_design(
    text="H-hey! You dropped your... uh... calculus notebook? I mean, I think it's yours? Maybe?",
    language="English",
    instruct="Male, 17 years old, tenor range, gaining confidence - deeper breath support now, though vowels still tighten when nervous",
)
```

When serving via vLLM-Omni's OpenAI-compatible `/v1/audio/speech` endpoint, the same concept maps to an `instructions` field in JSON:

```json
{
    "input": "I'm so happy to see you!",
    "voice": "vivian",
    "response_format": "wav",
    "task_type": "CustomVoice",
    "language": "Auto",
    "instructions": "Speak with excitement and enthusiasm",
    "max_new_tokens": 2048
}
```

## Writing effective instruction prompts

The Alibaba Cloud documentation provides explicit guidance on crafting instructions that the model follows well. The core principles: **be specific, be multi-dimensional, and be objective**. An instruction like "high-pitched and energetic" works far better than "nice voice." Combining multiple acoustic dimensions — pitch, speed, emotion, and timbre — in a single description outperforms single-dimension requests.

Documented instruction strings that work well span several categories. For **emotion and tone**: `"Very happy."`, `"Angry and frustrated tone"`, `"Sad and tearful voice"`, `"Calm, soothing, and reassuring"`, and `"用特别愤怒的语气说"` (angry, in Chinese). For **speaking speed and cadence**: `"Speak quickly with a rising intonation, suitable for introducing fashion products"`, `"Slow, deliberate pace with dramatic pauses"`, and `"a steady speaking speed and clear articulation"`. For **voice character descriptions** (VoiceDesign model): `"A composed middle-aged male announcer with a deep, rich and magnetic voice, a steady speaking speed and clear articulation, suitable for news broadcasting or documentary commentary"` and `"体现撒娇稚嫩的萝莉女声，音调偏高且起伏明显"` (a childish, high-pitched female voice with noticeable fluctuations).

Beyond the `instruct` parameter, standard Hugging Face generation kwargs offer indirect control. Parameters like **`temperature`** affect prosodic variability, **`top_p`** controls nucleus sampling diversity, and **`max_new_tokens`** (default 2048) limits output length. Community integrations like ComfyUI nodes also expose a **`pause_seconds`** parameter for controlling timing between dialogue segments and per-punctuation pause durations for rhythm control. Different random **seeds** produce noticeably different prosodic realizations of the same text and instruction, so iterating seeds is a practical way to find a preferred delivery.

## The Voice Design-to-Clone workflow preserves styled voices

For projects requiring consistent emotional delivery across many utterances — audiobooks, game dialogue, or radio dramas — the official documentation describes a powerful two-step workflow. First, use VoiceDesign to generate a short reference clip that embodies the desired persona and emotional style. Then, feed that clip into the Base model's `create_voice_clone_prompt()` to create a reusable voice prompt:

```python
# Step 1: Create a styled voice
ref_wavs, sr = design_model.generate_voice_design(
    text="H-hey! You dropped your... uh... calculus notebook?",
    language="English",
    instruct="Male, 17 years old, tenor range, gaining confidence",
)

# Step 2: Build a reusable clone prompt from the styled reference
voice_clone_prompt = clone_model.create_voice_clone_prompt(
    ref_audio=(ref_wavs[0], sr),
    ref_text="H-hey! You dropped your... uh... calculus notebook?",
)

# Step 3: Generate new lines with consistent voice
wavs, sr = clone_model.generate_voice_clone(
    text="Actually, I think I saw it in the library.",
    language="English",
    voice_clone_prompt=voice_clone_prompt,
)
```

This approach bakes emotional characteristics into a persistent voice identity that can be reused across any number of utterances, even though the Base model itself doesn't natively support instruction control. It effectively separates voice design (a one-time creative step) from batch production.

## Known limitations and community-reported issues

Several practical limitations shape what is achievable with Qwen3-TTS's style control system. The most significant: **instruction control is available only in the 1.7B-parameter models**, and via the cloud API, instruction control is limited to **Chinese and English only** with a maximum of **1,600 tokens**. The 0.6B models, while lighter on VRAM (roughly 4GB vs. 8GB), sacrifice instruction-following entirely.

Community users report **occasional random emotional outbursts** — unexpected laughing or moaning — during long generations, likely caused by the autoregressive model drifting in token space. A related issue is **infinite generation loops** where the model fails to emit an end-of-sequence token; the recommended workaround is reducing `max_new_tokens` to 1024 and keeping reference audio between 5–15 seconds. Multiple users also note that **some voices carry a slight Asian accent in English**, particularly the Chinese-native preset speakers.

On the InstructTTSEval benchmark, the VoiceDesign model scored **85.2 APS** (Chinese) and **82.9 APS** (English), substantially outperforming GPT-4o-mini-tts at 54.9 and 76.4 respectively. These numbers confirm strong instruction-following ability, but the model's control remains probabilistic. Complex, multi-dimensional instructions may produce inconsistent results across runs, and the model sometimes ignores specific aspects of detailed prompts. Iterating with different seeds and slightly rephrased instructions is the most practical workaround for production use.

## Conclusion

Qwen3-TTS represents a fundamentally different paradigm from SSML-based TTS systems. Rather than XML markup with numeric pitch and rate values, it leverages the language understanding capabilities of its underlying LLM to interpret natural language style descriptions. This makes it remarkably flexible — you can describe a "nervous teenager gaining confidence" or "an incredulous tone with creeping panic" — but also less deterministic than traditional parametric control. The most effective approach combines three strategies: choosing the right model variant (1.7B-CustomVoice for modifying preset voices, 1.7B-VoiceDesign for creating new ones), writing multi-dimensional instruction prompts that specify emotion, pitch, speed, and character simultaneously, and using the Voice Design-to-Clone pipeline to lock in a styled voice for consistent batch production. For applications requiring the most precise control, the DashScope cloud API's instruct-flash model adds explicit speech rate, pitch, and volume parameters beyond what the open-source models expose.