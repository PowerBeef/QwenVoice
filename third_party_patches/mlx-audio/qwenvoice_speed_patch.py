"""QwenVoice-specific helpers for faster repeated Qwen3-TTS clone generation.

This module stays local to the backend so the app can use the optimization
immediately, even before the vendored mlx-audio wheel is rebuilt.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Generator, List, Optional, Union

import mlx.core as mx

from mlx_audio.tts.models.base import GenerationResult
from mlx_audio.tts.models.qwen3_tts.qwen3_tts import format_duration
from mlx_audio.utils import load_audio


@dataclass
class PreparedICLContext:
    """Reusable reference-dependent state for repeated clone generation."""

    ref_codes: mx.array
    ref_text_embed: mx.array
    tts_bos_embed: mx.array
    tts_eos_embed: mx.array
    tts_pad_embed: mx.array
    codec_pad_embed: mx.array
    codec_with_text_pad: mx.array
    codec_prefix_embed: mx.array


def can_prepare_icl(model) -> bool:
    """Return True when the loaded model exposes the expected Qwen3 internals."""
    has_shape = all(
        hasattr(model, attr)
        for attr in (
            "tokenizer",
            "talker",
            "config",
            "speech_tokenizer",
            "_sample_token",
            "extract_speaker_embedding",
        )
    )
    if not has_shape:
        return False
    speech_tokenizer = getattr(model, "speech_tokenizer", None)
    return bool(getattr(speech_tokenizer, "has_encoder", False))


def try_enable_speech_tokenizer_encoder(
    model,
    model_path: Union[str, os.PathLike[str], None],
) -> bool:
    """Repair the speech tokenizer when the upstream loader skipped encoder_config.

    Current mlx-audio builds can load the speech tokenizer decoder while silently
    discarding the encoder_config, which leaves `has_encoder == False` even when
    the model bundle includes the full encoder weights. Rebuild the speech
    tokenizer from the on-disk config so prepared ICL can actually activate.
    """
    speech_tokenizer = getattr(model, "speech_tokenizer", None)
    if speech_tokenizer is None:
        return False
    if bool(getattr(speech_tokenizer, "has_encoder", False)):
        return True
    if not model_path or not hasattr(model, "load_speech_tokenizer"):
        return False

    try:
        from mlx_audio.tts.models.qwen3_tts.config import (
            Qwen3TTSTokenizerConfig,
            Qwen3TTSTokenizerDecoderConfig,
            Qwen3TTSTokenizerEncoderConfig,
            filter_dict_for_dataclass,
        )
        from mlx_audio.tts.models.qwen3_tts.speech_tokenizer import Qwen3TTSSpeechTokenizer
    except ImportError:
        return False

    tokenizer_dir = Path(model_path) / "speech_tokenizer"
    config_path = tokenizer_dir / "config.json"
    if not config_path.exists():
        return False

    try:
        tokenizer_config_dict = json.loads(config_path.read_text(encoding="utf-8"))

        decoder_config = None
        encoder_config = None

        if "decoder_config" in tokenizer_config_dict:
            filtered = filter_dict_for_dataclass(
                Qwen3TTSTokenizerDecoderConfig,
                tokenizer_config_dict["decoder_config"],
            )
            decoder_config = Qwen3TTSTokenizerDecoderConfig(**filtered)

        if "encoder_config" in tokenizer_config_dict:
            filtered = filter_dict_for_dataclass(
                Qwen3TTSTokenizerEncoderConfig,
                tokenizer_config_dict["encoder_config"],
            )
            encoder_config = Qwen3TTSTokenizerEncoderConfig(**filtered)

        tokenizer_config = Qwen3TTSTokenizerConfig(
            encoder_config=encoder_config,
            decoder_config=decoder_config,
        )

        for key, value in tokenizer_config_dict.items():
            if key not in ("decoder_config", "encoder_config") and hasattr(tokenizer_config, key):
                setattr(tokenizer_config, key, value)

        repaired = Qwen3TTSSpeechTokenizer(tokenizer_config)

        tokenizer_weights = {}
        for weight_file in tokenizer_dir.glob("*.safetensors"):
            tokenizer_weights.update(mx.load(str(weight_file)))

        if not tokenizer_weights:
            return False

        tokenizer_weights = Qwen3TTSSpeechTokenizer.sanitize(tokenizer_weights)
        repaired.load_weights(list(tokenizer_weights.items()), strict=False)
        mx.eval(repaired.parameters())
        repaired.eval()

        if repaired.encoder_model is not None:
            quantizer = repaired.encoder_model.quantizer
            for layer in quantizer.rvq_first.vq.layers:
                layer.codebook.update_in_place()
            for layer in quantizer.rvq_rest.vq.layers:
                layer.codebook.update_in_place()

        model.load_speech_tokenizer(repaired)
    except Exception:
        return False

    repaired_tokenizer = getattr(model, "speech_tokenizer", None)
    return bool(getattr(repaired_tokenizer, "has_encoder", False))


def _load_reference_audio(model, ref_audio: Union[str, mx.array]) -> mx.array:
    if isinstance(ref_audio, (str, os.PathLike)):
        return load_audio(os.fspath(ref_audio), sample_rate=model.sample_rate)
    return ref_audio


def prepare_icl_context(
    model,
    ref_audio: Union[str, mx.array],
    ref_text: str,
    language: str = "auto",
) -> PreparedICLContext:
    """Pre-compute the reference-dependent clone conditioning state."""
    if not can_prepare_icl(model):
        raise ValueError("Loaded model does not support prepared ICL contexts")
    if model.tokenizer is None:
        raise ValueError("Tokenizer not loaded. Call post_load_hook first.")

    clean_ref_text = (ref_text or "").strip()
    if not clean_ref_text:
        raise ValueError("Prepared ICL contexts require a non-empty transcript")

    config = model.config.talker_config
    ref_audio = _load_reference_audio(model, ref_audio)
    audio_for_spk = ref_audio

    if ref_audio.ndim == 1:
        ref_audio = ref_audio[None, None, :]
    elif ref_audio.ndim == 2:
        ref_audio = ref_audio[None, :]

    ref_codes = model.speech_tokenizer.encode(ref_audio)
    mx.eval(ref_codes)

    ref_chat = f"<|im_start|>assistant\n{clean_ref_text}<|im_end|>\n"
    ref_ids = mx.array(model.tokenizer.encode(ref_chat))[None, :]
    ref_text_ids = ref_ids[:, 3:-2]

    tts_tokens = mx.array(
        [[model.config.tts_bos_token_id, model.config.tts_eos_token_id, model.config.tts_pad_token_id]]
    )
    tts_embeds = model.talker.text_projection(model.talker.get_text_embeddings()(tts_tokens))
    tts_bos_embed = tts_embeds[:, 0:1, :]
    tts_eos_embed = tts_embeds[:, 1:2, :]
    tts_pad_embed = tts_embeds[:, 2:3, :]

    ref_text_embed = model.talker.text_projection(
        model.talker.get_text_embeddings()(ref_text_ids)
    )

    first_cb_codes = ref_codes[:, 0, :]
    ref_codec_embed = model.talker.get_input_embeddings()(first_cb_codes)
    for index in range(config.num_code_groups - 1):
        cb_codes = ref_codes[:, index + 1, :]
        ref_codec_embed = (
            ref_codec_embed
            + model.talker.code_predictor.codec_embedding[index](cb_codes)
        )

    codec_bos_embed = model.talker.get_input_embeddings()(mx.array([[config.codec_bos_id]]))
    codec_embed_icl = mx.concatenate([codec_bos_embed, ref_codec_embed], axis=1)
    codec_lens = codec_embed_icl.shape[1]

    codec_pad_embed = model.talker.get_input_embeddings()(mx.array([[config.codec_pad_id]]))
    codec_with_text_pad = codec_embed_icl + mx.broadcast_to(
        tts_pad_embed, (1, codec_lens, tts_pad_embed.shape[-1])
    )

    language_id = None
    if language.lower() != "auto" and config.codec_language_id:
        language_id = config.codec_language_id.get(language.lower())

    speaker_embed = None
    if model.speaker_encoder is not None:
        speaker_embed = model.extract_speaker_embedding(audio_for_spk)

    if language_id is None:
        codec_prefill = [
            config.codec_nothink_id,
            config.codec_think_bos_id,
            config.codec_think_eos_id,
        ]
    else:
        codec_prefill = [
            config.codec_think_id,
            config.codec_think_bos_id,
            language_id,
            config.codec_think_eos_id,
        ]

    codec_prefix_embed = model.talker.get_input_embeddings()(mx.array([codec_prefill]))
    codec_prefix_suffix = model.talker.get_input_embeddings()(
        mx.array([[config.codec_pad_id, config.codec_bos_id]])
    )

    if speaker_embed is not None:
        codec_prefix_embed = mx.concatenate(
            [codec_prefix_embed, speaker_embed.reshape(1, 1, -1), codec_prefix_suffix],
            axis=1,
        )
    else:
        codec_prefix_embed = mx.concatenate(
            [codec_prefix_embed, codec_prefix_suffix],
            axis=1,
        )

    mx.eval(codec_with_text_pad)
    mx.eval(codec_prefix_embed)

    return PreparedICLContext(
        ref_codes=ref_codes,
        ref_text_embed=ref_text_embed,
        tts_bos_embed=tts_bos_embed,
        tts_eos_embed=tts_eos_embed,
        tts_pad_embed=tts_pad_embed,
        codec_pad_embed=codec_pad_embed,
        codec_with_text_pad=codec_with_text_pad,
        codec_prefix_embed=codec_prefix_embed,
    )


def prepare_icl_generation_inputs_from_context(
    model,
    text: str,
    prepared: PreparedICLContext,
) -> tuple[mx.array, mx.array, mx.array]:
    """Combine cached reference state with per-request target text state."""
    target_chat = (
        f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n"
    )
    target_ids = mx.array(model.tokenizer.encode(target_chat))[None, :]
    text_ids = target_ids[:, 3:-5]

    target_text_embed = model.talker.text_projection(
        model.talker.get_text_embeddings()(text_ids)
    )
    text_embed = mx.concatenate([prepared.ref_text_embed, target_text_embed], axis=1)
    text_embed = mx.concatenate([text_embed, prepared.tts_eos_embed], axis=1)
    text_lens = text_embed.shape[1]

    text_with_codec_pad = text_embed + mx.broadcast_to(
        prepared.codec_pad_embed,
        (1, text_lens, prepared.codec_pad_embed.shape[-1]),
    )
    icl_input_embed = mx.concatenate(
        [text_with_codec_pad, prepared.codec_with_text_pad],
        axis=1,
    )

    role_embed = model.talker.text_projection(
        model.talker.get_text_embeddings()(target_ids[:, :3])
    )

    pad_count = prepared.codec_prefix_embed.shape[1] - 2
    pad_embeds = mx.broadcast_to(
        prepared.tts_pad_embed, (1, pad_count, prepared.tts_pad_embed.shape[-1])
    )
    combined_prefix = mx.concatenate([pad_embeds, prepared.tts_bos_embed], axis=1)
    combined_prefix = combined_prefix + prepared.codec_prefix_embed[:, :-1, :]

    input_embeds = mx.concatenate([role_embed, combined_prefix, icl_input_embed], axis=1)
    mx.eval(input_embeds)

    return input_embeds, prepared.tts_pad_embed, prepared.ref_codes


def generate_with_prepared_icl(
    model,
    text: str,
    prepared: PreparedICLContext,
    temperature: float = 0.9,
    max_tokens: int = 4096,
    top_k: int = 50,
    top_p: float = 1.0,
    repetition_penalty: float = 1.5,
) -> Generator[GenerationResult, None, None]:
    """Run the clone generation loop using a prepared ICL context."""
    start_time = time.time()
    input_embeds, tts_pad_embed, ref_codes = prepare_icl_generation_inputs_from_context(
        model, text, prepared
    )

    target_token_count = len(model.tokenizer.encode(text))
    effective_max_tokens = min(max_tokens, max(75, target_token_count * 6))

    cache = model.talker.make_cache()
    generated_codes: List[mx.array] = []
    config = model.config.talker_config
    eos_token_id = config.codec_eos_token_id
    suppress_tokens = [
        token_id
        for token_id in range(config.vocab_size - 1024, config.vocab_size)
        if token_id != eos_token_id
    ]

    trailing_idx = 0
    trailing_text_hidden = tts_pad_embed

    for step in range(effective_max_tokens):
        logits, hidden = model.talker(input_embeds, cache=cache)

        next_token = model._sample_token(
            logits,
            temperature=temperature,
            top_k=top_k,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
            generated_tokens=(
                [int(code[0, 0]) for code in generated_codes]
                if generated_codes
                else None
            ),
            suppress_tokens=suppress_tokens,
            eos_token_id=eos_token_id,
        )

        if int(next_token[0, 0]) == eos_token_id:
            break

        code_tokens = [next_token]
        code_hidden = hidden[:, -1:, :]
        code_cache = model.talker.code_predictor.make_cache()

        for code_index in range(config.num_code_groups - 1):
            if code_index == 0:
                code_0_embed = model.talker.get_input_embeddings()(next_token)
                code_input = mx.concatenate([code_hidden, code_0_embed], axis=1)
            else:
                code_embed = model.talker.code_predictor.codec_embedding[code_index - 1](
                    code_tokens[-1]
                )
                code_input = code_embed

            code_logits, code_cache, _ = model.talker.code_predictor(
                code_input,
                cache=code_cache,
                generation_step=code_index,
            )

            next_code = model._sample_token(
                code_logits,
                temperature=temperature,
                top_k=top_k,
                top_p=top_p,
            )
            code_tokens.append(next_code)

        all_codes = mx.concatenate(code_tokens, axis=1)
        generated_codes.append(all_codes)

        del code_cache
        mx.clear_cache()

        if trailing_idx < trailing_text_hidden.shape[1]:
            text_embed = trailing_text_hidden[:, trailing_idx : trailing_idx + 1, :]
            trailing_idx += 1
        else:
            text_embed = tts_pad_embed

        codec_embed = model.talker.get_input_embeddings()(next_token)
        for index, code in enumerate(code_tokens[1:]):
            codec_embed = codec_embed + model.talker.code_predictor.codec_embedding[index](
                code
            )

        input_embeds = text_embed + codec_embed
        mx.eval(input_embeds)

        if step > 0 and step % 50 == 0:
            mx.clear_cache()

    if not generated_codes:
        return

    gen_codes = mx.stack(generated_codes, axis=1)
    ref_codes_t = mx.transpose(ref_codes, (0, 2, 1))
    full_codes = mx.concatenate([ref_codes_t, gen_codes], axis=1)

    ref_len = ref_codes.shape[2]
    total_len = full_codes.shape[1]

    audio, audio_lengths = model.speech_tokenizer.decode(full_codes)
    audio = audio[0]

    valid_len = int(audio_lengths[0])
    if valid_len > 0 and valid_len < audio.shape[0]:
        audio = audio[:valid_len]

    cut = int(ref_len / max(total_len, 1) * audio.shape[0])
    if 0 < cut < audio.shape[0]:
        audio = audio[cut:]

    mx.eval(audio)

    elapsed_time = time.time() - start_time
    samples = audio.shape[0]
    token_count = len(generated_codes)
    duration_seconds = samples / model.sample_rate
    rtf = duration_seconds / elapsed_time if elapsed_time > 0 else 0

    yield GenerationResult(
        audio=audio,
        samples=samples,
        sample_rate=model.sample_rate,
        segment_idx=0,
        token_count=token_count,
        audio_duration=format_duration(duration_seconds),
        real_time_factor=rtf,
        prompt={
            "tokens": token_count,
            "tokens-per-sec": (token_count / elapsed_time if elapsed_time > 0 else 0),
        },
        audio_samples={
            "samples": samples,
            "samples-per-sec": (samples / elapsed_time if elapsed_time > 0 else 0),
        },
        processing_time_seconds=elapsed_time,
        peak_memory_usage=mx.get_peak_memory() / 1e9,
    )

    mx.clear_cache()
