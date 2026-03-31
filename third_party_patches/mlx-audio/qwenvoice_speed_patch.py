"""QwenVoice overlay for prepared Qwen3-TTS clone generation on stock mlx-audio.

This standalone helper keeps QwenVoice-specific prepared-reference reuse out of
the upstream wheel. It mirrors only the small upstream mlx-audio 0.4.2 sections
needed to:

- reuse reference-dependent ICL state across repeated clone requests
- rebuild language-specific prompt prefixes at request time
- batch multiple target texts that share the same prepared reference
"""

from __future__ import annotations

import json
import os
import time
import weakref
from dataclasses import dataclass
from pathlib import Path
from typing import Generator, List, Optional, Sequence, Union

import mlx.core as mx

from mlx_audio.tts.models.base import BatchGenerationResult, GenerationResult
from mlx_audio.tts.models.qwen3_tts.qwen3_tts import format_duration
from mlx_audio.utils import load_audio


@dataclass
class ModelStaticICL:
    """Language-independent embeddings that are stable for a loaded model."""

    tts_bos_embed: mx.array
    tts_eos_embed: mx.array
    tts_pad_embed: mx.array
    codec_pad_embed: mx.array
    codec_bos_embed: mx.array
    codec_prefix_suffix: mx.array


@dataclass
class PreparedReferenceContext:
    """Reusable reference-only state for repeated Qwen3-TTS base-model cloning."""

    ref_codes: mx.array
    ref_text_embed: mx.array
    codec_with_text_pad: mx.array
    speaker_embed: Optional[mx.array]
    clean_ref_text: str


PreparedICLContext = PreparedReferenceContext

_MODEL_STATIC_CACHE: dict[int, tuple[weakref.ReferenceType[object], ModelStaticICL]] = {}


def _get_cached_model_static_icl(model) -> Optional[ModelStaticICL]:
    cache_key = id(model)
    cached_entry = _MODEL_STATIC_CACHE.get(cache_key)
    if cached_entry is None:
        return None

    model_ref, static = cached_entry
    cached_model = model_ref()
    if cached_model is model:
        return static

    _MODEL_STATIC_CACHE.pop(cache_key, None)
    return None


def _set_cached_model_static_icl(model, static: ModelStaticICL) -> None:
    cache_key = id(model)

    def _remove_cached_static(model_ref, *, model_id=cache_key):
        cached_entry = _MODEL_STATIC_CACHE.get(model_id)
        if cached_entry is not None and cached_entry[0] is model_ref:
            _MODEL_STATIC_CACHE.pop(model_id, None)

    try:
        model_ref = weakref.ref(model, _remove_cached_static)
    except TypeError:
        return

    _MODEL_STATIC_CACHE[cache_key] = (model_ref, static)


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
    """Repair the speech tokenizer only if the upstream 0.4.2 loader still missed it."""
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
        from mlx_audio.tts.models.qwen3_tts.speech_tokenizer import (
            Qwen3TTSSpeechTokenizer,
        )
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

        if encoder_config is None:
            return False

        tokenizer_config = Qwen3TTSTokenizerConfig(
            encoder_config=encoder_config,
            decoder_config=decoder_config,
        )

        for key, value in tokenizer_config_dict.items():
            if key not in ("decoder_config", "encoder_config") and hasattr(
                tokenizer_config, key
            ):
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


def _get_model_static_icl(model) -> ModelStaticICL:
    cached = _get_cached_model_static_icl(model)
    if cached is not None:
        return cached

    tts_tokens = mx.array(
        [
            [
                model.config.tts_bos_token_id,
                model.config.tts_eos_token_id,
                model.config.tts_pad_token_id,
            ]
        ]
    )
    tts_embeds = model.talker.text_projection(
        model.talker.get_text_embeddings()(tts_tokens)
    )

    static = ModelStaticICL(
        tts_bos_embed=tts_embeds[:, 0:1, :],
        tts_eos_embed=tts_embeds[:, 1:2, :],
        tts_pad_embed=tts_embeds[:, 2:3, :],
        codec_pad_embed=model.talker.get_input_embeddings()(
            mx.array([[model.config.talker_config.codec_pad_id]])
        ),
        codec_bos_embed=model.talker.get_input_embeddings()(
            mx.array([[model.config.talker_config.codec_bos_id]])
        ),
        codec_prefix_suffix=model.talker.get_input_embeddings()(
            mx.array(
                [[
                    model.config.talker_config.codec_pad_id,
                    model.config.talker_config.codec_bos_id,
                ]]
            )
        ),
    )
    mx.eval(
        static.tts_bos_embed,
        static.tts_eos_embed,
        static.tts_pad_embed,
        static.codec_pad_embed,
        static.codec_bos_embed,
        static.codec_prefix_suffix,
    )
    _set_cached_model_static_icl(model, static)
    return static


def _prepare_reference_audio_for_encoder(ref_audio: mx.array) -> mx.array:
    if ref_audio.ndim == 1:
        return ref_audio[None, None, :]
    if ref_audio.ndim == 2:
        return ref_audio[None, :]
    return ref_audio


def _reference_text_ids(model, clean_ref_text: str) -> mx.array:
    ref_chat = f"<|im_start|>assistant\n{clean_ref_text}<|im_end|>\n"
    ref_ids = mx.array(model.tokenizer.encode(ref_chat))[None, :]
    return ref_ids[:, 3:-2]


def _target_ids(model, text: str) -> mx.array:
    target_chat = f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n"
    return mx.array(model.tokenizer.encode(target_chat))[None, :]


def _build_reference_codec_embed(model, ref_codes: mx.array) -> mx.array:
    config = model.config.talker_config
    first_cb_codes = ref_codes[:, 0, :]
    ref_codec_embed = model.talker.get_input_embeddings()(first_cb_codes)
    for index in range(config.num_code_groups - 1):
        cb_codes = ref_codes[:, index + 1, :]
        ref_codec_embed = (
            ref_codec_embed
            + model.talker.code_predictor.codec_embedding[index](cb_codes)
        )
    return ref_codec_embed


def _resolve_language_id(config, language: str) -> Optional[int]:
    normalized = (language or "auto").lower()
    if normalized != "auto" and config.codec_language_id:
        return config.codec_language_id.get(normalized)
    return None


def _build_codec_prefix_embed(
    model,
    prepared: PreparedReferenceContext,
    language: str = "auto",
) -> mx.array:
    config = model.config.talker_config
    static = _get_model_static_icl(model)
    language_id = _resolve_language_id(config, language)

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
    if prepared.speaker_embed is not None:
        codec_prefix_embed = mx.concatenate(
            [
                codec_prefix_embed,
                prepared.speaker_embed.reshape(1, 1, -1),
                static.codec_prefix_suffix,
            ],
            axis=1,
        )
    else:
        codec_prefix_embed = mx.concatenate(
            [codec_prefix_embed, static.codec_prefix_suffix],
            axis=1,
        )
    mx.eval(codec_prefix_embed)
    return codec_prefix_embed


def prepare_icl_context(
    model,
    ref_audio: Union[str, mx.array],
    ref_text: str,
    language: str = "auto",
) -> PreparedReferenceContext:
    """Pre-compute the reusable reference-only clone conditioning state."""
    if not can_prepare_icl(model):
        raise ValueError("Loaded model does not support prepared ICL contexts")
    if model.tokenizer is None:
        raise ValueError("Tokenizer not loaded. Call post_load_hook first.")

    _ = language  # Kept for backward-compatible call sites; the prepared state is reference-only.

    clean_ref_text = (ref_text or "").strip()
    if not clean_ref_text:
        raise ValueError("Prepared ICL contexts require a non-empty transcript")

    static = _get_model_static_icl(model)
    raw_ref_audio = _load_reference_audio(model, ref_audio)
    ref_audio_for_encoder = _prepare_reference_audio_for_encoder(raw_ref_audio)

    ref_codes = model.speech_tokenizer.encode(ref_audio_for_encoder)
    mx.eval(ref_codes)

    ref_text_embed = model.talker.text_projection(
        model.talker.get_text_embeddings()(_reference_text_ids(model, clean_ref_text))
    )

    ref_codec_embed = _build_reference_codec_embed(model, ref_codes)
    codec_embed_icl = mx.concatenate([static.codec_bos_embed, ref_codec_embed], axis=1)
    codec_with_text_pad = codec_embed_icl + mx.broadcast_to(
        static.tts_pad_embed, (1, codec_embed_icl.shape[1], static.tts_pad_embed.shape[-1])
    )

    speaker_embed = None
    if model.speaker_encoder is not None:
        speaker_embed = model.extract_speaker_embedding(raw_ref_audio)
        mx.eval(speaker_embed)

    mx.eval(ref_text_embed, codec_with_text_pad)

    return PreparedReferenceContext(
        ref_codes=ref_codes,
        ref_text_embed=ref_text_embed,
        codec_with_text_pad=codec_with_text_pad,
        speaker_embed=speaker_embed,
        clean_ref_text=clean_ref_text,
    )


def prepare_icl_generation_inputs_from_context(
    model,
    text: str,
    prepared: PreparedReferenceContext,
    language: str = "auto",
) -> tuple[mx.array, mx.array, mx.array]:
    """Build request-time ICL inputs from cached reference state plus target text.

    This mirrors the upstream mlx-audio 0.4.2 `_prepare_icl_generation_inputs`
    assembly, but keeps the reference-dependent pieces in `prepared`. When
    rebasing to a newer mlx-audio release, recheck the target token slicing,
    role-prefix assembly, and text/code pad layout against upstream.
    """
    static = _get_model_static_icl(model)
    target_ids = _target_ids(model, text)
    text_ids = target_ids[:, 3:-5]

    target_text_embed = model.talker.text_projection(
        model.talker.get_text_embeddings()(text_ids)
    )
    text_embed = mx.concatenate([prepared.ref_text_embed, target_text_embed], axis=1)
    text_embed = mx.concatenate([text_embed, static.tts_eos_embed], axis=1)

    text_with_codec_pad = text_embed + mx.broadcast_to(
        static.codec_pad_embed, (1, text_embed.shape[1], static.codec_pad_embed.shape[-1])
    )
    icl_input_embed = mx.concatenate(
        [text_with_codec_pad, prepared.codec_with_text_pad],
        axis=1,
    )

    codec_prefix_embed = _build_codec_prefix_embed(model, prepared, language=language)
    role_embed = model.talker.text_projection(
        model.talker.get_text_embeddings()(target_ids[:, :3])
    )

    pad_count = codec_prefix_embed.shape[1] - 2
    pad_embeds = mx.broadcast_to(
        static.tts_pad_embed, (1, pad_count, static.tts_pad_embed.shape[-1])
    )
    combined_prefix = mx.concatenate([pad_embeds, static.tts_bos_embed], axis=1)
    combined_prefix = combined_prefix + codec_prefix_embed[:, :-1, :]

    input_embeds = mx.concatenate(
        [role_embed, combined_prefix, icl_input_embed],
        axis=1,
    )
    mx.eval(input_embeds)
    return input_embeds, static.tts_pad_embed, prepared.ref_codes


build_prepared_icl_inputs = prepare_icl_generation_inputs_from_context


def _prepare_batch_prepared_icl_inputs(
    model,
    texts: Sequence[str],
    prepared: PreparedReferenceContext,
    language: str = "auto",
) -> tuple[mx.array, mx.array, mx.array, Optional[mx.array]]:
    """Mirror the upstream 0.4.2 batch padding layout for prepared references.

    Recheck the left-padding, attention-mask shape, and trailing text hidden
    state against upstream `batch_generate` whenever mlx-audio is upgraded.
    """
    per_seq_embeds = []
    shared_pad_embed = None

    for text in texts:
        embeds, pad_embed, _ = prepare_icl_generation_inputs_from_context(
            model,
            text,
            prepared,
            language=language,
        )
        per_seq_embeds.append(embeds)
        if shared_pad_embed is None:
            shared_pad_embed = pad_embed

    if shared_pad_embed is None:
        raise ValueError("Prepared batch inputs require at least one target text")

    hidden_size = per_seq_embeds[0].shape[-1]
    batch_size = len(per_seq_embeds)
    prefill_lens = [embeds.shape[1] for embeds in per_seq_embeds]
    max_prefill = max(prefill_lens)

    padded_embeds = []
    mask_rows = []
    for embeds, seq_len in zip(per_seq_embeds, prefill_lens):
        pad_len = max_prefill - seq_len
        if pad_len > 0:
            padding = mx.zeros((1, pad_len, hidden_size))
            padded = mx.concatenate([padding, embeds], axis=1)
            mask_row = mx.concatenate(
                [mx.zeros((1, pad_len)), mx.ones((1, seq_len))],
                axis=1,
            )
        else:
            padded = embeds
            mask_row = mx.ones((1, seq_len))
        padded_embeds.append(padded)
        mask_rows.append(mask_row)

    input_embeds = mx.concatenate(padded_embeds, axis=0)
    attention_mask = mx.concatenate(mask_rows, axis=0)
    trailing_text_hidden = mx.broadcast_to(
        shared_pad_embed, (batch_size, 1, hidden_size)
    )

    mx.eval(input_embeds, trailing_text_hidden, attention_mask)
    if batch_size == 1:
        attention_mask = None

    return input_embeds, trailing_text_hidden, shared_pad_embed, attention_mask


def _effective_max_tokens(model, text: str, max_tokens: int) -> int:
    target_token_count = len(model.tokenizer.encode(text))
    return min(max_tokens, max(75, target_token_count * 6))


def _icl_suppress_tokens(config, eos_token_id: int) -> list[int]:
    return [
        token_id
        for token_id in range(config.vocab_size - 1024, config.vocab_size)
        if token_id != eos_token_id
    ]


def _build_generation_result(
    audio: mx.array,
    *,
    sample_rate: int,
    token_count: int,
    elapsed_time: float,
    segment_idx: int = 0,
    is_streaming_chunk: bool = False,
    is_final_chunk: bool = False,
) -> GenerationResult:
    samples = audio.shape[0]
    duration_seconds = samples / sample_rate
    rtf = duration_seconds / elapsed_time if elapsed_time > 0 else 0
    return GenerationResult(
        audio=audio,
        samples=samples,
        sample_rate=sample_rate,
        segment_idx=segment_idx,
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
        is_streaming_chunk=is_streaming_chunk,
        is_final_chunk=is_final_chunk,
    )


def generate_with_prepared_icl(
    model,
    text: str,
    prepared: PreparedReferenceContext,
    temperature: float = 0.9,
    max_tokens: int = 4096,
    top_k: int = 50,
    top_p: float = 1.0,
    repetition_penalty: float = 1.5,
    stream: bool = False,
    streaming_interval: float = 2.0,
    language: str = "auto",
) -> Generator[GenerationResult, None, None]:
    """Run the prepared clone generation loop using request-time language assembly.

    This mirrors the upstream mlx-audio 0.4.2 `_generate_icl` loop while
    reusing a cached prepared reference context. When rebasing, recheck the
    sampling loop, code-predictor cache reset, and streaming decoder handoff
    against upstream `_generate_icl`.
    """
    start_time = time.perf_counter()
    input_embeds, tts_pad_embed, ref_codes = prepare_icl_generation_inputs_from_context(
        model,
        text,
        prepared,
        language=language,
    )

    effective_max_tokens = _effective_max_tokens(model, text, max_tokens)

    cache = model.talker.make_cache()
    code_cache = model.talker.code_predictor.make_cache()
    generated_codes: List[mx.array] = []
    generated_token_ids: List[int] = []
    config = model.config.talker_config
    eos_token_id = config.codec_eos_token_id
    suppress_tokens = _icl_suppress_tokens(config, eos_token_id)

    trailing_idx = 0
    trailing_text_hidden = tts_pad_embed

    if stream:
        streaming_chunk_size = max(1, int(streaming_interval * 12.5))
        decoded_tokens = 0
        chunk_start_time = time.perf_counter()
        model.speech_tokenizer.decoder.reset_streaming_state()

    for step in range(effective_max_tokens):
        logits, hidden = model.talker(input_embeds, cache=cache)

        next_token = model._sample_token(
            logits,
            temperature=temperature,
            top_k=top_k,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
            generated_tokens=(generated_token_ids if generated_token_ids else None),
            suppress_tokens=suppress_tokens,
            eos_token_id=eos_token_id,
        )

        is_eos = next_token[0, 0] == eos_token_id
        code_tokens = [next_token]
        code_hidden = hidden[:, -1:, :]

        for cache_entry in code_cache:
            cache_entry.keys = None
            cache_entry.values = None
            cache_entry.offset = 0

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
        mx.eval(input_embeds, is_eos)

        if is_eos.item():
            break

        generated_token_ids.append(int(next_token[0, 0]))
        generated_codes.append(all_codes)

        if step > 0 and step % 50 == 0:
            mx.clear_cache()

        if stream and len(generated_codes) - decoded_tokens >= streaming_chunk_size:
            new_tokens = len(generated_codes) - decoded_tokens
            codes_chunk = mx.stack(generated_codes[decoded_tokens:], axis=1)
            codes_for_decoder = mx.transpose(codes_chunk, (0, 2, 1))
            mx.eval(codes_for_decoder)

            wav = model.speech_tokenizer.decoder.streaming_step(codes_for_decoder)
            audio_chunk = wav.squeeze(1)[0]
            mx.eval(audio_chunk)
            decoded_tokens = len(generated_codes)

            chunk_elapsed = time.perf_counter() - chunk_start_time
            yield _build_generation_result(
                audio_chunk,
                sample_rate=model.sample_rate,
                token_count=new_tokens,
                elapsed_time=chunk_elapsed,
                is_streaming_chunk=True,
            )
            chunk_start_time = time.perf_counter()
            mx.clear_cache()

    if stream:
        if len(generated_codes) > decoded_tokens:
            codes_chunk = mx.stack(generated_codes[decoded_tokens:], axis=1)
            codes_for_decoder = mx.transpose(codes_chunk, (0, 2, 1))
            mx.eval(codes_for_decoder)

            wav = model.speech_tokenizer.decoder.streaming_step(codes_for_decoder)
            audio_chunk = wav.squeeze(1)[0]
            mx.eval(audio_chunk)

            new_tokens = len(generated_codes) - decoded_tokens
            chunk_elapsed = time.perf_counter() - chunk_start_time
            yield _build_generation_result(
                audio_chunk,
                sample_rate=model.sample_rate,
                token_count=new_tokens,
                elapsed_time=chunk_elapsed,
                is_streaming_chunk=True,
                is_final_chunk=True,
            )

        model.speech_tokenizer.decoder.reset_streaming_state()
        mx.clear_cache()
        return

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
    elapsed_time = time.perf_counter() - start_time
    yield _build_generation_result(
        audio,
        sample_rate=model.sample_rate,
        token_count=len(generated_codes),
        elapsed_time=elapsed_time,
    )
    mx.clear_cache()


def batch_generate_with_prepared_icl(
    model,
    texts: Sequence[str],
    prepared: PreparedReferenceContext,
    temperature: float = 0.9,
    max_tokens: int = 4096,
    top_k: int = 50,
    top_p: float = 1.0,
    repetition_penalty: float = 1.5,
    stream: bool = False,
    streaming_interval: float = 2.0,
    language: str = "auto",
) -> Generator[BatchGenerationResult, None, None]:
    """Generate multiple clone utterances that share one prepared reference.

    The non-streaming path mirrors the upstream mlx-audio 0.4.2 `batch_generate`
    loop, but uses request-time inputs assembled from one prepared reference.
    Recheck the batched sampling flow and `speech_tokenizer.batch_decode` usage
    against upstream `batch_generate` on every mlx-audio upgrade.
    """
    texts = [text for text in texts]
    if not texts:
        return

    if stream:
        # Shared-reference batch generation deliberately stays non-streaming-only.
        # Streaming clone requests must fall back to repeated single-item paths.
        raise ValueError("Streaming is not supported for shared-reference batch generation")

    start_time = time.time()
    batch_size = len(texts)
    config = model.config.talker_config
    eos_token_id = config.codec_eos_token_id
    input_embeds, trailing_text_hidden, tts_pad_embed, attention_mask = (
        _prepare_batch_prepared_icl_inputs(
            model,
            texts,
            prepared,
            language=language,
        )
    )

    cache = model.talker.make_cache()
    code_cache = model.talker.code_predictor.make_cache()
    generated_codes = [[] for _ in range(batch_size)]
    generated_token_ids = [[] for _ in range(batch_size)]
    finished = mx.zeros((batch_size,), dtype=mx.bool_)

    trailing_indices = mx.zeros((batch_size, 1), dtype=mx.int32)
    batch_arange = mx.arange(batch_size)
    max_trailing_len = trailing_text_hidden.shape[1]
    eos_fill = mx.full((batch_size, 1), eos_token_id, dtype=mx.int32)
    suppress_tokens = _icl_suppress_tokens(config, eos_token_id)
    effective_max_tokens = max(
        _effective_max_tokens(model, text, max_tokens) for text in texts
    )

    for step in range(effective_max_tokens):
        logits, hidden = model.talker(
            input_embeds,
            cache=cache,
            attention_mask=attention_mask,
        )
        sampled_tokens = model._sample_token_batch(
            logits,
            temperature=temperature,
            top_k=top_k,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
            generated_tokens_per_seq=generated_token_ids,
            suppress_tokens=suppress_tokens,
            eos_token_id=eos_token_id,
        )
        next_token_batch = mx.where(finished[:, None], eos_fill, sampled_tokens)
        newly_finished = next_token_batch[:, 0] == eos_token_id
        finished = finished | newly_finished

        code_tokens = [next_token_batch]
        code_hidden = hidden[:, -1:, :]
        for cache_entry in code_cache:
            cache_entry.keys = None
            cache_entry.values = None
            cache_entry.offset = 0

        for code_idx in range(config.num_code_groups - 1):
            if code_idx == 0:
                code_0_embed = model.talker.get_input_embeddings()(next_token_batch)
                code_input = mx.concatenate([code_hidden, code_0_embed], axis=1)
            else:
                code_embed = model.talker.code_predictor.codec_embedding[code_idx - 1](
                    code_tokens[-1]
                )
                code_input = code_embed

            code_logits, code_cache, _ = model.talker.code_predictor(
                code_input,
                cache=code_cache,
                generation_step=code_idx,
            )
            next_code = model._sample_token_batch(
                code_logits,
                temperature=temperature,
                top_k=top_k,
                top_p=top_p,
            )
            code_tokens.append(next_code)

        all_codes = mx.concatenate(code_tokens, axis=1)

        clamped_indices = mx.minimum(trailing_indices[:, 0], max_trailing_len - 1)
        text_embeds = trailing_text_hidden[batch_arange, clamped_indices, :][:, None, :]
        exhausted = clamped_indices >= max_trailing_len - 1
        text_embeds = mx.where(
            exhausted[:, None, None],
            mx.broadcast_to(tts_pad_embed, text_embeds.shape),
            text_embeds,
        )

        advance = (~finished).astype(mx.int32)[:, None]
        trailing_indices = trailing_indices + advance

        codec_embed = model.talker.get_input_embeddings()(next_token_batch)
        for index, code in enumerate(code_tokens[1:]):
            codec_embed = codec_embed + model.talker.code_predictor.codec_embedding[index](
                code
            )
        input_embeds = text_embeds + codec_embed

        mx.eval(all_codes, input_embeds, finished)
        finished_cpu = finished.tolist()
        if all(finished_cpu):
            break

        token_ids_cpu = next_token_batch[:, 0].tolist()
        for batch_index in range(batch_size):
            if not finished_cpu[batch_index]:
                generated_token_ids[batch_index].append(token_ids_cpu[batch_index])
                generated_codes[batch_index].append(all_codes[batch_index : batch_index + 1])

        if attention_mask is not None:
            attention_mask = mx.concatenate(
                [attention_mask, mx.ones((batch_size, 1))],
                axis=1,
            )

        if step > 0 and step % 50 == 0:
            mx.clear_cache()

    if any(not codes for codes in generated_codes):
        raise RuntimeError("Shared-reference batch generation produced no audio for one or more items")

    elapsed_time = time.time() - start_time
    ref_codes_t = mx.transpose(prepared.ref_codes, (0, 2, 1))
    ref_len = prepared.ref_codes.shape[2]
    full_codes_list = []
    total_lens = []
    token_counts = []

    for codes, token_ids in zip(generated_codes, generated_token_ids):
        sequence_codes = mx.stack(codes, axis=1)
        full_codes = mx.concatenate([ref_codes_t, sequence_codes], axis=1)
        full_codes_list.append(full_codes)
        total_lens.append(full_codes.shape[1])
        token_counts.append(len(token_ids))

    audios, _ = model.speech_tokenizer.batch_decode(full_codes_list)

    for sequence_idx, (audio, total_len, token_count) in enumerate(
        zip(audios, total_lens, token_counts)
    ):
        cut = int(ref_len / max(total_len, 1) * audio.shape[0])
        if 0 < cut < audio.shape[0]:
            audio = audio[cut:]
        mx.eval(audio)
        duration_seconds = audio.shape[0] / model.sample_rate
        yield BatchGenerationResult(
            audio=audio,
            sequence_idx=sequence_idx,
            samples=audio.shape[0],
            sample_rate=model.sample_rate,
            token_count=token_count,
            audio_duration=format_duration(duration_seconds),
            processing_time_seconds=elapsed_time,
            peak_memory_usage=mx.get_peak_memory() / 1e9,
        )

    mx.clear_cache()
