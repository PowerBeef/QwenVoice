import json
import os
import re
import shutil
import time
import traceback
from importlib import metadata as importlib_metadata


class BackendRPCHandlers:
    def __init__(
        self,
        *,
        state,
        transport,
        output_paths,
        audio_io,
        clone_context,
        generation_pipeline,
        models,
        models_by_mode,
        speaker_map,
        default_speaker,
        cache_policy,
        original_stderr,
    ):
        self.state = state
        self.transport = transport
        self.output_paths = output_paths
        self.audio_io = audio_io
        self.clone_context = clone_context
        self.generation_pipeline = generation_pipeline
        self.models = models
        self.models_by_mode = models_by_mode
        self.speaker_map = speaker_map
        self.default_speaker = default_speaker
        self.cache_policy = cache_policy
        self.original_stderr = original_stderr

    def ensure_mlx(self):
        if self.state.load_model_fn is None:
            import numpy as np
            from mlx_audio.tts.utils import load_model
            from mlx_audio.tts.generate import generate_audio
            from mlx_audio.audio_io import write as audio_write
            import mlx.core as mx

            try:
                from mlx_audio_qwen_speed_patch import (
                    can_prepare_icl,
                    batch_generate_with_prepared_icl,
                    generate_with_prepared_icl,
                    prepare_icl_context,
                    try_enable_speech_tokenizer_encoder,
                )
            except ImportError:
                try:
                    from mlx_audio.qwenvoice_speed_patch import (
                        can_prepare_icl,
                        batch_generate_with_prepared_icl,
                        generate_with_prepared_icl,
                        prepare_icl_context,
                        try_enable_speech_tokenizer_encoder,
                    )
                except ImportError:
                    can_prepare_icl = None
                    batch_generate_with_prepared_icl = None
                    generate_with_prepared_icl = None
                    prepare_icl_context = None
                    try_enable_speech_tokenizer_encoder = None

            self.state.load_model_fn = load_model
            self.state.generate_audio_fn = generate_audio
            self.state.audio_write_fn = audio_write
            self.state.mx = mx
            self.state.np = np
            self.state.can_prepare_icl_fn = can_prepare_icl
            self.state.prepare_icl_context_fn = prepare_icl_context
            self.state.generate_prepared_icl_fn = generate_with_prepared_icl
            self.state.batch_generate_prepared_icl_fn = batch_generate_with_prepared_icl
            self.state.enable_speech_tokenizer_encoder_fn = (
                try_enable_speech_tokenizer_encoder
            )
            try:
                self.state.mlx_audio_version = importlib_metadata.version("mlx-audio")
            except importlib_metadata.PackageNotFoundError:
                self.state.mlx_audio_version = "unknown"

    def base_model_capabilities(self, model_def):
        version = self.state.mlx_audio_version
        if version is None:
            try:
                version = importlib_metadata.version("mlx-audio")
            except importlib_metadata.PackageNotFoundError:
                version = "unknown"
        is_clone = model_def["mode"] == "clone"
        return {
            "mlx_audio_version": version,
            "supports_streaming": True,
            "supports_prepared_clone": is_clone,
            "supports_clone_streaming": is_clone,
            "supports_batch": True,
        }

    def resolved_model_capabilities(self, model_def):
        capabilities = dict(self.base_model_capabilities(model_def))

        if (
            self.state.current_model is None
            or self.state.current_model_id != model_def["id"]
        ):
            return capabilities

        capabilities["supports_streaming"] = hasattr(
            self.state.current_model, "generate"
        )
        capabilities["supports_batch"] = bool(
            hasattr(self.state.current_model, "batch_generate")
            or hasattr(self.state.current_model, "generate_batch")
        )

        if model_def["mode"] == "clone":
            supports_prepared_clone = bool(
                self.state.can_prepare_icl_fn
                and self.state.can_prepare_icl_fn(self.state.current_model)
            )
            capabilities["supports_prepared_clone"] = supports_prepared_clone
            capabilities["supports_clone_streaming"] = bool(
                capabilities["supports_streaming"] and supports_prepared_clone
            )

        return capabilities

    def handle_ping(self, params):
        return {"status": "ok"}

    def handle_init(self, params):
        if "app_support_dir" in params:
            self.state.configure_app_support_dir(params["app_support_dir"])

        self.state.ensure_directories()
        self.clone_context.prune_normalized_clone_reference_cache()

        return {
            "status": "ok",
            "models_dir": self.state.models_dir,
            "outputs_dir": self.state.outputs_dir,
        }

    def clear_mlx_cache(self):
        self.generation_pipeline.clear_mlx_cache()

    def perform_memory_recovery(self):
        self.generation_pipeline.perform_memory_recovery()

    def discard_loaded_model(self):
        self.state.current_model = None
        self.state.current_model_path = None
        self.state.current_model_id = None
        self.clone_context.clear_clone_context_cache()
        self.state.primed_clone_reference_keys.clear()
        self.perform_memory_recovery()

    def maybe_send_progress(self, percent, message, request_id=None):
        if request_id is not None:
            self.transport.send_progress(percent, message, request_id=request_id)

    def load_model_request(
        self, model_id=None, model_path=None, benchmark=False, request_id=None
    ):
        load_start = time.perf_counter()
        model_path, resolved_model_id = self.output_paths.resolve_model_request(
            model_id=model_id, model_path=model_path
        )
        was_same_model_loaded = (
            self.state.current_model is not None
            and self.state.current_model_path == model_path
        )

        if was_same_model_loaded:
            result = {
                "success": True,
                "model_path": model_path,
                "cached": True,
                "model_id": resolved_model_id,
            }
            if resolved_model_id:
                self.state.current_model_id = resolved_model_id
                result.update(
                    self.resolved_model_capabilities(self.models[resolved_model_id])
                )
            if benchmark:
                result["benchmark"] = {
                    "timings_ms": {
                        "load_model_total": int(
                            (time.perf_counter() - load_start) * 1000
                        ),
                    }
                }
            return result, resolved_model_id, model_path, False

        if self.state.current_model is not None:
            self.discard_loaded_model()

        self.ensure_mlx()
        self.maybe_send_progress(5, "Preparing model...", request_id=request_id)
        self.maybe_send_progress(25, "Loading model...", request_id=request_id)

        self.state.current_model = self.state.load_model_fn(model_path)
        if self.state.enable_speech_tokenizer_encoder_fn is not None:
            self.state.enable_speech_tokenizer_encoder_fn(
                self.state.current_model, model_path
            )
        self.state.current_model_path = model_path
        self.state.current_model_id = resolved_model_id

        self.maybe_send_progress(100, "Model ready", request_id=request_id)

        result = {
            "success": True,
            "model_path": model_path,
            "model_id": resolved_model_id,
        }
        if resolved_model_id:
            result.update(self.resolved_model_capabilities(self.models[resolved_model_id]))
        if benchmark:
            result["benchmark"] = {
                "timings_ms": {
                    "load_model_total": int(
                        (time.perf_counter() - load_start) * 1000
                    ),
                }
            }
        return result, resolved_model_id, model_path, True

    def handle_load_model(self, params, request_id=None):
        result, _, _, _ = self.load_model_request(
            model_id=params.get("model_id"),
            model_path=params.get("model_path"),
            benchmark=bool(params.get("benchmark", False)),
            request_id=request_id,
        )
        return result

    def handle_prewarm_model(self, params, request_id=None):
        benchmark = bool(params.get("benchmark", False))
        model_id = params.get("model_id")
        model_path = params.get("model_path")
        requested_mode = params.get("mode")
        voice = params.get("voice")
        instruct = params.get("instruct")
        ref_audio = params.get("ref_audio")
        ref_text = params.get("ref_text")
        language = self.generation_pipeline.normalize_request_language(
            params.get("language")
        )

        overall_start = time.perf_counter()
        model_path, resolved_model_id = self.output_paths.resolve_model_request(
            model_id=model_id, model_path=model_path
        )
        model_key = self.output_paths.model_identity_key(resolved_model_id, model_path)
        loaded_model_changed = self.state.current_model_path != model_path

        load_result, resolved_model_id, model_path, _ = self.load_model_request(
            model_id=model_id,
            model_path=model_path,
            benchmark=benchmark,
            request_id=None,
        )
        load_timings = load_result.get("benchmark", {}).get("timings_ms", {})
        warm_mode = requested_mode or (
            self.models.get(resolved_model_id, {}).get("mode")
            if resolved_model_id
            else None
        )
        if not warm_mode:
            current_model_contract = self.output_paths.current_model_contract()
            warm_mode = current_model_contract["mode"] if current_model_contract else None
        if not warm_mode:
            raise RuntimeError("Could not determine which generation mode to prewarm")

        prewarm_key = self.generation_pipeline.prewarm_identity_key(
            model_key,
            warm_mode,
            voice=voice,
            instruct=instruct,
            ref_audio=ref_audio,
            ref_text=ref_text,
        )

        already_prewarmed = prewarm_key in self.state.prewarmed_model_keys
        prewarm_timings = {
            "normalize_reference": 0,
            "prepare_clone_context": 0,
            "generation": 0,
            "prewarm_max_tokens": 0,
        }
        prepared_clone_used = False
        clone_cache_hit = None

        if not already_prewarmed:
            prewarm_timings = self.generation_pipeline.run_model_prewarm(
                warm_mode,
                voice=voice,
                instruct=instruct,
                ref_audio=ref_audio,
                ref_text=ref_text,
                language=language,
            )
            prepared_clone_used = prewarm_timings["prepared_clone_used"]
            clone_cache_hit = prewarm_timings["clone_cache_hit"]
            self.state.prewarmed_model_keys.add(prewarm_key)

        result = {
            "success": True,
            "model_id": resolved_model_id,
            "model_path": model_path,
            "loaded_model_changed": loaded_model_changed,
            "already_prewarmed": already_prewarmed,
            "prewarm_applied": not already_prewarmed,
        }
        if benchmark:
            result["benchmark"] = {
                "mode": warm_mode,
                "prepared_clone_used": prepared_clone_used,
                "clone_cache_hit": clone_cache_hit,
                "prewarm_max_tokens": prewarm_timings.get("prewarm_max_tokens", 0),
                "timings_ms": {
                    "load_model_total": load_timings.get("load_model_total", 0),
                    "normalize_reference": prewarm_timings["normalize_reference"],
                    "prepare_clone_context": prewarm_timings[
                        "prepare_clone_context"
                    ],
                    "generation": prewarm_timings["generation"],
                    "total_backend": int((time.perf_counter() - overall_start) * 1000),
                },
            }
        return result

    def handle_prepare_clone_reference(self, params, request_id=None):
        benchmark = bool(params.get("benchmark", False))
        model_id = params.get("model_id")
        model_path = params.get("model_path")
        ref_audio = params.get("ref_audio")
        ref_text = params.get("ref_text")

        if not ref_audio:
            raise ValueError("prepare_clone_reference requires ref_audio")

        overall_start = time.perf_counter()
        model_path, resolved_model_id = self.output_paths.resolve_model_request(
            model_id=model_id, model_path=model_path
        )
        loaded_model_changed = self.state.current_model_path != model_path

        load_result, resolved_model_id, model_path, _ = self.load_model_request(
            model_id=model_id,
            model_path=model_path,
            benchmark=benchmark,
            request_id=request_id,
        )
        load_timings = load_result.get("benchmark", {}).get("timings_ms", {})

        normalize_start = time.perf_counter()
        clean_ref_audio = self.clone_context.normalize_clone_reference(ref_audio)
        normalize_reference_ms = int((time.perf_counter() - normalize_start) * 1000)
        if not clean_ref_audio:
            raise RuntimeError("Could not process reference audio file")

        resolved_ref_text = self.clone_context.resolve_clone_transcript(
            clean_ref_audio, ref_text
        )
        self.transport.send_progress(20, "Preparing voice context...", request_id=request_id)
        prepare_start = time.perf_counter()
        prepared_context, clone_cache_hit = self.clone_context.get_or_prepare_clone_context(
            clean_ref_audio,
            resolved_ref_text,
        )
        prepare_clone_context_ms = int((time.perf_counter() - prepare_start) * 1000)
        prepared_clone_used = (
            prepared_context is not None
            and self.state.generate_prepared_icl_fn is not None
        )

        result = {
            "success": True,
            "model_id": resolved_model_id,
            "model_path": model_path,
            "loaded_model_changed": loaded_model_changed,
            "prepared_clone_used": prepared_clone_used,
            "clone_cache_hit": clone_cache_hit,
            "reference_prepared": prepared_context is not None,
        }
        if benchmark:
            result["benchmark"] = {
                "prepared_clone_used": prepared_clone_used,
                "clone_cache_hit": clone_cache_hit,
                "timings_ms": {
                    "load_model_total": load_timings.get("load_model_total", 0),
                    "normalize_reference": normalize_reference_ms,
                    "prepare_clone_context": prepare_clone_context_ms,
                    "total_backend": int((time.perf_counter() - overall_start) * 1000),
                },
            }
        return result

    def handle_prime_clone_reference(self, params, request_id=None):
        benchmark = bool(params.get("benchmark", False))
        model_id = params.get("model_id")
        model_path = params.get("model_path")
        ref_audio = params.get("ref_audio")
        ref_text = params.get("ref_text")
        language = self.generation_pipeline.normalize_request_language(
            params.get("language")
        )
        streaming_interval = float(
            params.get(
                "streaming_interval", self.generation_pipeline.default_streaming_interval
            )
        )

        if not ref_audio:
            raise ValueError("prime_clone_reference requires ref_audio")

        overall_start = time.perf_counter()
        model_path, resolved_model_id = self.output_paths.resolve_model_request(
            model_id=model_id, model_path=model_path
        )
        loaded_model_changed = self.state.current_model_path != model_path

        load_result, resolved_model_id, model_path, _ = self.load_model_request(
            model_id=model_id,
            model_path=model_path,
            benchmark=benchmark,
            request_id=request_id,
        )
        load_timings = load_result.get("benchmark", {}).get("timings_ms", {})

        normalize_start = time.perf_counter()
        clean_ref_audio = self.clone_context.normalize_clone_reference(ref_audio)
        normalize_reference_ms = int((time.perf_counter() - normalize_start) * 1000)
        if not clean_ref_audio:
            raise RuntimeError("Could not process reference audio file")

        resolved_ref_text = self.clone_context.resolve_clone_transcript(
            clean_ref_audio, ref_text
        )
        prime_key = self.clone_context.clone_prime_identity_key(
            clean_ref_audio, resolved_ref_text
        )
        already_primed = prime_key in self.state.primed_clone_reference_keys

        prime_timings = {
            "normalize_reference": normalize_reference_ms,
            "prepare_clone_context": 0,
            "generation": 0,
            "first_stream_chunk": 0,
            "prime_max_tokens": 0,
            "streaming_interval": streaming_interval,
        }
        prepared_clone_used = False
        clone_cache_hit = None

        if not already_primed:
            self.transport.send_progress(
                20, "Preparing voice context...", request_id=request_id
            )
            prime_timings = self.generation_pipeline.run_clone_reference_prime(
                clean_ref_audio,
                resolved_ref_text,
                streaming_interval=streaming_interval,
                language=language,
            )
            prime_timings["normalize_reference"] = normalize_reference_ms
            prepared_clone_used = prime_timings["prepared_clone_used"]
            clone_cache_hit = prime_timings["clone_cache_hit"]
            self.state.primed_clone_reference_keys.add(prime_key)

        result = {
            "success": True,
            "model_id": resolved_model_id,
            "model_path": model_path,
            "loaded_model_changed": loaded_model_changed,
            "already_primed": already_primed,
            "prime_applied": not already_primed,
            "prepared_clone_used": prepared_clone_used,
            "clone_cache_hit": clone_cache_hit,
        }
        if benchmark:
            result["benchmark"] = {
                "prepared_clone_used": prepared_clone_used,
                "clone_cache_hit": clone_cache_hit,
                "prime_max_tokens": prime_timings.get("prime_max_tokens", 0),
                "streaming_interval": prime_timings.get(
                    "streaming_interval", streaming_interval
                ),
                "timings_ms": {
                    "load_model_total": load_timings.get("load_model_total", 0),
                    "normalize_reference": prime_timings["normalize_reference"],
                    "prepare_clone_context": prime_timings[
                        "prepare_clone_context"
                    ],
                    "first_stream_chunk": prime_timings["first_stream_chunk"],
                    "generation": prime_timings["generation"],
                    "total_backend": int((time.perf_counter() - overall_start) * 1000),
                },
            }
        return result

    def handle_unload_model(self, params):
        self.discard_loaded_model()
        return {"success": True}

    def handle_generate(self, params, request_id=None):
        if self.state.current_model is None:
            raise RuntimeError("No model loaded. Call load_model first.")

        self.ensure_mlx()

        text = (params.get("text") or "").strip()
        if not text:
            raise ValueError("Missing required param: text")

        output_path = params.get("output_path")
        requested_mode = params.get("mode")
        model_id = params.get("model_id")
        voice = params.get("voice")
        instruct = params.get("instruct")
        ref_audio = params.get("ref_audio")
        ref_text = params.get("ref_text")
        language = self.generation_pipeline.normalize_request_language(
            params.get("language")
        )
        temperature_value = float(params.get("temperature", 0.6))
        max_tokens = params.get("max_tokens")
        stream = bool(params.get("stream", False))
        streaming_interval = float(
            params.get(
                "streaming_interval", self.generation_pipeline.default_streaming_interval
            )
        )
        benchmark = bool(params.get("benchmark", False))
        benchmark_label = params.get("benchmark_label")
        benchmark_mode = self.output_paths.resolve_generation_mode(
            requested_mode, voice=voice, ref_audio=ref_audio
        )
        current_model_contract = self.output_paths.current_model_contract()

        if requested_mode and requested_mode not in self.models_by_mode:
            raise ValueError(f"Unknown generation mode: {requested_mode}")

        if (
            requested_mode
            and current_model_contract
            and current_model_contract["mode"] != requested_mode
        ):
            if model_id:
                self.load_model_request(model_id=model_id, benchmark=False, request_id=None)
                current_model_contract = self.output_paths.current_model_contract()
            else:
                raise ValueError(
                    f"Requested mode '{requested_mode}' does not match loaded model '{self.state.current_model_id}' ({current_model_contract['mode']})."
                )

        if benchmark_mode == "custom" and not voice:
            raise ValueError("Mode 'custom' requires a voice.")
        if benchmark_mode == "design" and not instruct:
            raise ValueError("Mode 'design' requires instruct.")
        if benchmark_mode == "clone" and not ref_audio:
            raise ValueError("Mode 'clone' requires ref_audio.")

        effective_max_tokens = int(max_tokens) if max_tokens is not None else None
        model_was_loaded = self.state.current_model is not None
        benchmark_flags_base = {
            "label": benchmark_label or benchmark_mode,
            "mode": benchmark_mode,
            "prepared_clone_used": False,
            "clone_cache_hit": None,
            "streaming_used": bool(stream and request_id is not None),
            "used_temp_reference": False,
            "request_temperature": temperature_value,
            "request_max_tokens": effective_max_tokens,
            "model_path": self.state.current_model_path,
            "model_already_loaded": bool(model_was_loaded),
            "post_request_cache_clear_enabled": self.cache_policy == "always",
            "cache_policy": self.cache_policy,
            "allocation_retry_attempted": False,
            "allocation_retry_succeeded": False,
        }
        overall_start = time.perf_counter()
        final_path = self.output_paths.resolve_final_output_path(
            output_path, text, mode=benchmark_mode, voice=voice, ref_audio=ref_audio
        )
        target_dir, target_stem, generated_path = self.output_paths.derive_generation_paths(
            final_path
        )
        stream_session_dirs = []

        if ref_audio:
            self.transport.send_progress(
                10, "Normalizing reference...", request_id=request_id
            )
        else:
            self.transport.send_progress(15, "Preparing request...", request_id=request_id)

        def cleanup_partial_outputs():
            paths_to_remove = {final_path}
            if generated_path != final_path:
                paths_to_remove.add(generated_path)

            for path in paths_to_remove:
                if os.path.exists(path):
                    try:
                        os.remove(path)
                    except OSError:
                        pass

            chunk_prefix = f"{target_stem}__chunk_"
            if os.path.isdir(target_dir):
                for name in os.listdir(target_dir):
                    if name.startswith(chunk_prefix) and name.endswith(".wav"):
                        try:
                            os.remove(os.path.join(target_dir, name))
                        except OSError:
                            pass

            for session_dir in stream_session_dirs:
                if os.path.isdir(session_dir):
                    shutil.rmtree(session_dir, ignore_errors=True)

        def generate_once():
            nonlocal effective_max_tokens

            benchmark_flags = dict(benchmark_flags_base)
            benchmark_timings = {
                "normalize_reference": 0,
                "prepare_clone_context": 0,
                "generation": 0,
                "write_output": 0,
            }
            benchmark_timings.update(
                self.generation_pipeline.timing_breakdown_template()
            )
            metrics = None

            if ref_audio:
                normalize_start = time.perf_counter()
                clean_ref_audio = self.clone_context.normalize_clone_reference(ref_audio)
                benchmark_timings["normalize_reference"] = int(
                    (time.perf_counter() - normalize_start) * 1000
                )
                if not clean_ref_audio:
                    raise RuntimeError("Could not process reference audio file")
                benchmark_flags["used_temp_reference"] = clean_ref_audio != ref_audio

                resolved_ref_text = self.clone_context.resolve_clone_transcript(
                    clean_ref_audio, ref_text
                )
                prepare_start = time.perf_counter()
                prepared_context, clone_cache_hit = (
                    self.clone_context.get_or_prepare_clone_context(
                        clean_ref_audio, resolved_ref_text
                    )
                )
                benchmark_timings["prepare_clone_context"] = int(
                    (time.perf_counter() - prepare_start) * 1000
                )
                benchmark_flags["clone_cache_hit"] = clone_cache_hit

                self.transport.send_progress(
                    30, "Preparing voice context...", request_id=request_id
                )
                if (
                    prepared_context is not None
                    and self.state.generate_prepared_icl_fn is not None
                ):
                    benchmark_flags["prepared_clone_used"] = True
                    if effective_max_tokens is None:
                        effective_max_tokens = 4096
                        benchmark_flags["request_max_tokens"] = effective_max_tokens
                    generator = self.state.generate_prepared_icl_fn(
                        self.state.current_model,
                        text,
                        prepared_context,
                        **self.generation_pipeline.with_optional_kwarg(
                            {
                                "temperature": temperature_value,
                                "max_tokens": effective_max_tokens,
                                "stream": bool(stream and request_id is not None),
                                "streaming_interval": streaming_interval,
                            },
                            "language",
                            language,
                        ),
                    )
                    if stream and request_id is not None:
                        self.transport.send_progress(
                            55, "Streaming audio...", request_id=request_id
                        )
                        generation_start = time.perf_counter()
                        (
                            result,
                            benchmark_timings["write_output"],
                            output_metadata,
                            stream_breakdown,
                        ) = self.generation_pipeline.stream_generator_to_output(
                            generator,
                            request_id=request_id,
                            final_path=final_path,
                        )
                        benchmark_timings["generation"] = int(
                            (time.perf_counter() - generation_start) * 1000
                        )
                        self.generation_pipeline.apply_timing_breakdown(
                            benchmark_timings, stream_breakdown
                        )
                        stream_session_dirs.append(result["stream_session_dir"])
                        metrics = dict(result.get("metrics") or {})
                    else:
                        self.transport.send_progress(
                            60, "Generating audio...", request_id=request_id
                        )
                        generation_start = time.perf_counter()
                        prepared_result, collection_breakdown = (
                            self.generation_pipeline.collect_generation_result_with_timings(
                                generator
                            )
                        )
                        benchmark_timings["generation"] = int(
                            (time.perf_counter() - generation_start) * 1000
                        )
                        self.generation_pipeline.apply_timing_breakdown(
                            benchmark_timings, collection_breakdown
                        )
                        self.transport.send_progress(
                            90, "Saving audio...", request_id=request_id
                        )
                        (
                            result,
                            metrics,
                            output_metadata,
                            benchmark_timings["write_output"],
                            finalize_breakdown,
                        ) = self.generation_pipeline.finalize_generated_audio(
                            prepared_result,
                            final_path=final_path,
                            streaming_used=False,
                        )
                        self.generation_pipeline.apply_timing_breakdown(
                            benchmark_timings, finalize_breakdown
                        )
                else:
                    generation_start = time.perf_counter()
                    generator = self.generation_pipeline.build_clone_fallback_generator(
                        self.state.current_model,
                        text=text,
                        temperature=temperature_value,
                        clean_ref_audio=clean_ref_audio,
                        resolved_ref_text=resolved_ref_text,
                        max_tokens=max_tokens,
                        stream=bool(stream and request_id is not None),
                        streaming_interval=streaming_interval,
                        **({"language": language} if language is not None else {}),
                    )
                    if stream and request_id is not None:
                        self.transport.send_progress(
                            55, "Streaming audio...", request_id=request_id
                        )
                        (
                            result,
                            benchmark_timings["write_output"],
                            output_metadata,
                            stream_breakdown,
                        ) = self.generation_pipeline.stream_generator_to_output(
                            generator,
                            request_id=request_id,
                            final_path=final_path,
                        )
                        benchmark_timings["generation"] = int(
                            (time.perf_counter() - generation_start) * 1000
                        )
                        self.generation_pipeline.apply_timing_breakdown(
                            benchmark_timings, stream_breakdown
                        )
                        stream_session_dirs.append(result["stream_session_dir"])
                        metrics = dict(result.get("metrics") or {})
                    else:
                        self.transport.send_progress(
                            60, "Generating audio...", request_id=request_id
                        )
                        fallback_result, collection_breakdown = (
                            self.generation_pipeline.collect_generation_result_with_timings(
                                generator
                            )
                        )
                        benchmark_timings["generation"] = int(
                            (time.perf_counter() - generation_start) * 1000
                        )
                        self.generation_pipeline.apply_timing_breakdown(
                            benchmark_timings, collection_breakdown
                        )
                        self.transport.send_progress(
                            90, "Saving audio...", request_id=request_id
                        )
                        (
                            result,
                            metrics,
                            output_metadata,
                            benchmark_timings["write_output"],
                            finalize_breakdown,
                        ) = self.generation_pipeline.finalize_generated_audio(
                            fallback_result,
                            final_path=final_path,
                            streaming_used=False,
                        )
                        self.generation_pipeline.apply_timing_breakdown(
                            benchmark_timings, finalize_breakdown
                        )
            elif stream and request_id is not None:
                generator = self.generation_pipeline.build_standard_generator(
                    self.state.current_model,
                    text=text,
                    temperature=temperature_value,
                    max_tokens=max_tokens,
                    language=language,
                    voice=voice,
                    instruct=instruct,
                    stream=True,
                    streaming_interval=streaming_interval,
                )
                self.transport.send_progress(35, "Streaming audio...", request_id=request_id)
                generation_start = time.perf_counter()
                (
                    result,
                    benchmark_timings["write_output"],
                    output_metadata,
                    stream_breakdown,
                ) = self.generation_pipeline.stream_generator_to_output(
                    generator,
                    request_id=request_id,
                    final_path=final_path,
                )
                benchmark_timings["generation"] = int(
                    (time.perf_counter() - generation_start) * 1000
                )
                self.generation_pipeline.apply_timing_breakdown(
                    benchmark_timings, stream_breakdown
                )
                stream_session_dirs.append(result["stream_session_dir"])
                metrics = dict(result.get("metrics") or {})
                self.transport.send_progress(85, "Saving audio...", request_id=request_id)
            else:
                generator = self.generation_pipeline.build_standard_generator(
                    self.state.current_model,
                    text=text,
                    temperature=temperature_value,
                    max_tokens=max_tokens,
                    language=language,
                    voice=voice,
                    instruct=instruct,
                )
                generation_start = time.perf_counter()
                self.transport.send_progress(45, "Generating audio...", request_id=request_id)
                collected_result, collection_breakdown = (
                    self.generation_pipeline.collect_generation_result_with_timings(
                        generator
                    )
                )
                benchmark_timings["generation"] = int(
                    (time.perf_counter() - generation_start) * 1000
                )
                self.generation_pipeline.apply_timing_breakdown(
                    benchmark_timings, collection_breakdown
                )
                self.transport.send_progress(85, "Saving audio...", request_id=request_id)
                (
                    result,
                    metrics,
                    output_metadata,
                    benchmark_timings["write_output"],
                    finalize_breakdown,
                ) = self.generation_pipeline.finalize_generated_audio(
                    collected_result,
                    final_path=final_path,
                    streaming_used=False,
                )
                self.generation_pipeline.apply_timing_breakdown(
                    benchmark_timings, finalize_breakdown
                )

            metrics = dict(metrics or {})
            metrics.setdefault("streaming_used", bool(stream and request_id is not None))
            metrics["prepared_clone_used"] = benchmark_flags["prepared_clone_used"]
            metrics["clone_cache_hit"] = benchmark_flags["clone_cache_hit"]
            result["metrics"] = metrics
            return result, benchmark_flags, benchmark_timings, output_metadata

        request_succeeded = False
        retried_after_allocation_failure = False

        try:
            try:
                (
                    result,
                    benchmark_flags,
                    benchmark_timings,
                    output_metadata,
                ) = generate_once()
            except Exception as error:
                if not self.generation_pipeline.is_retryable_allocation_error(error):
                    raise

                retried_after_allocation_failure = True
                cleanup_partial_outputs()
                self.generation_pipeline.perform_memory_recovery()
                (
                    result,
                    benchmark_flags,
                    benchmark_timings,
                    output_metadata,
                ) = generate_once()

            request_succeeded = True
            benchmark_timings["total_backend"] = int(
                (time.perf_counter() - overall_start) * 1000
            )
            benchmark_flags["allocation_retry_attempted"] = (
                retried_after_allocation_failure
            )
            benchmark_flags["allocation_retry_succeeded"] = (
                retried_after_allocation_failure
            )
            self.transport.send_progress(100, "Done", request_id=request_id)

            if benchmark:
                result["benchmark"] = {
                    **benchmark_flags,
                    "output_duration_seconds": round(
                        output_metadata["duration_seconds"], 4
                    ),
                    "output_frames": output_metadata["frames"],
                    "timings_ms": benchmark_timings,
                }
            return result

        finally:
            if self.generation_pipeline.should_clear_cache_after_request(
                request_succeeded
            ):
                self.generation_pipeline.clear_mlx_cache()

    def handle_generate_clone_batch(self, params, request_id=None):
        if self.state.current_model is None:
            raise RuntimeError("No model loaded. Call load_model first.")

        self.ensure_mlx()

        model_id = params.get("model_id")
        if model_id and self.state.current_model_id != model_id:
            self.load_model_request(model_id=model_id, benchmark=False, request_id=None)

        current_model_contract = self.output_paths.current_model_contract()
        if current_model_contract and current_model_contract["mode"] != "clone":
            raise ValueError(
                f"generate_clone_batch requires a clone model, but '{current_model_contract['id']}' is {current_model_contract['mode']}"
            )

        raw_texts = params.get("texts") or []
        if not isinstance(raw_texts, list) or not raw_texts:
            raise ValueError("Missing required param: texts")

        texts = [str(item).strip() for item in raw_texts]
        if any(not text for text in texts):
            raise ValueError(
                "Clone batch generation requires every text item to be non-empty"
            )

        raw_output_paths = params.get("output_paths") or []
        if not isinstance(raw_output_paths, list) or len(raw_output_paths) != len(texts):
            raise ValueError("output_paths must be a list matching texts")

        ref_audio = params.get("ref_audio")
        ref_text = params.get("ref_text")
        if not ref_audio:
            raise ValueError("generate_clone_batch requires ref_audio")

        language = self.generation_pipeline.normalize_request_language(
            params.get("language")
        )
        temperature_value = float(params.get("temperature", 0.6))
        max_tokens = params.get("max_tokens")
        effective_max_tokens = int(max_tokens) if max_tokens is not None else 4096
        requested_stream = bool(params.get("stream", False))

        final_paths = [
            self.output_paths.resolve_final_output_path(
                path, text, mode="clone", ref_audio=ref_audio
            )
            for text, path in zip(texts, raw_output_paths)
        ]

        def cleanup_partial_outputs():
            for path in final_paths:
                if path and os.path.exists(path):
                    try:
                        os.remove(path)
                    except OSError:
                        pass

        def generate_once():
            self.maybe_send_progress(
                10, "Normalizing reference...", request_id=request_id
            )
            clean_ref_audio = self.clone_context.normalize_clone_reference(ref_audio)
            if not clean_ref_audio:
                raise RuntimeError("Could not process reference audio file")

            resolved_ref_text = self.clone_context.resolve_clone_transcript(
                clean_ref_audio, ref_text
            )
            self.maybe_send_progress(
                30, "Preparing voice context...", request_id=request_id
            )
            prepared_context, clone_cache_hit = (
                self.clone_context.get_or_prepare_clone_context(
                    clean_ref_audio, resolved_ref_text
                )
            )
            can_use_prepared = (
                prepared_context is not None
                and self.state.generate_prepared_icl_fn is not None
            )
            can_use_batch_fast_path = len(texts) > 1 and self.clone_context.can_use_shared_reference_clone_batch_fast_path(
                can_use_prepared=can_use_prepared,
                requested_stream=requested_stream,
            )

            if can_use_batch_fast_path:
                self.maybe_send_progress(
                    60, "Generating audio batch...", request_id=request_id
                )
                collected_results, _ = (
                    self.generation_pipeline.collect_batch_generation_results_with_timings(
                        self.state.batch_generate_prepared_icl_fn(
                            self.state.current_model,
                            texts,
                            prepared_context,
                            **self.generation_pipeline.with_optional_kwarg(
                                {
                                    "temperature": temperature_value,
                                    "max_tokens": effective_max_tokens,
                                    "stream": False,
                                },
                                "language",
                                language,
                            ),
                        ),
                        len(texts),
                    )
                )
            else:
                collected_results = []
                total = len(texts)
                for index, text in enumerate(texts):
                    percent = 45 + int((index / max(total, 1)) * 30)
                    self.maybe_send_progress(
                        percent,
                        f"Generating item {index + 1}/{total}...",
                        request_id=request_id,
                    )
                    if can_use_prepared:
                        generator = self.state.generate_prepared_icl_fn(
                            self.state.current_model,
                            text,
                            prepared_context,
                            **self.generation_pipeline.with_optional_kwarg(
                                {
                                    "temperature": temperature_value,
                                    "max_tokens": effective_max_tokens,
                                    "stream": False,
                                },
                                "language",
                                language,
                            ),
                        )
                    else:
                        generator = self.generation_pipeline.build_clone_fallback_generator(
                            self.state.current_model,
                            text=text,
                            temperature=temperature_value,
                            clean_ref_audio=clean_ref_audio,
                            resolved_ref_text=resolved_ref_text,
                            max_tokens=effective_max_tokens,
                            stream=False,
                            **({"language": language} if language is not None else {}),
                        )
                    item_result, _ = (
                        self.generation_pipeline.collect_generation_result_with_timings(
                            generator
                        )
                    )
                    collected_results.append(item_result)

            responses = []
            total = len(collected_results)
            for index, (result, final_path) in enumerate(
                zip(collected_results, final_paths)
            ):
                percent = 80 + int((index / max(total, 1)) * 15)
                self.maybe_send_progress(
                    percent, f"Saving item {index + 1}/{total}...", request_id=request_id
                )
                response_item, metrics, _, _, _ = (
                    self.generation_pipeline.finalize_generated_audio(
                        result,
                        final_path=final_path,
                        streaming_used=False,
                    )
                )
                metrics = dict(metrics or {})
                metrics["prepared_clone_used"] = can_use_prepared
                metrics["clone_cache_hit"] = clone_cache_hit
                metrics["batch_generation_used"] = can_use_batch_fast_path
                response_item["metrics"] = metrics
                responses.append(response_item)

            return responses

        request_succeeded = False

        try:
            try:
                results = generate_once()
            except Exception as error:
                if not self.generation_pipeline.is_retryable_allocation_error(error):
                    raise
                cleanup_partial_outputs()
                self.generation_pipeline.perform_memory_recovery()
                results = generate_once()

            request_succeeded = True
            self.maybe_send_progress(100, "Done", request_id=request_id)
            return results
        finally:
            if self.generation_pipeline.should_clear_cache_after_request(
                request_succeeded
            ):
                self.generation_pipeline.clear_mlx_cache()

    def handle_convert_audio(self, params):
        input_path = params.get("input_path")
        if not input_path:
            raise ValueError("Missing required param: input_path")

        output_path = params.get("output_path")
        wav_path = self.audio_io.convert_audio_if_needed(input_path)

        if output_path and wav_path and wav_path != input_path:
            parent = os.path.dirname(output_path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            try:
                shutil.move(wav_path, output_path)
            except Exception:
                try:
                    os.remove(wav_path)
                except OSError:
                    pass
                raise
            wav_path = output_path

        return {"wav_path": wav_path}

    def handle_list_voices(self, params):
        if not os.path.exists(self.state.voices_dir):
            return []

        voices = []
        for filename in sorted(os.listdir(self.state.voices_dir)):
            if filename.endswith(".wav"):
                name = filename[:-4]
                txt_path = os.path.join(self.state.voices_dir, f"{name}.txt")
                voices.append(
                    {
                        "name": name,
                        "has_transcript": os.path.exists(txt_path),
                        "wav_path": os.path.join(self.state.voices_dir, filename),
                    }
                )

        return voices

    def handle_enroll_voice(self, params):
        name = params.get("name")
        audio_path = params.get("audio_path")

        if not name or not audio_path:
            raise ValueError("Missing required params: name, audio_path")

        safe_name = re.sub(r"[^\w\s-]", "", name).strip().replace(" ", "_")
        if not safe_name:
            raise ValueError("Invalid voice name")

        os.makedirs(self.state.voices_dir, exist_ok=True)

        clean_wav = self.clone_context.normalize_clone_reference(audio_path)
        if not clean_wav:
            raise RuntimeError("Could not process audio file")

        target_wav = os.path.join(self.state.voices_dir, f"{safe_name}.wav")
        target_txt = os.path.join(self.state.voices_dir, f"{safe_name}.txt")

        if os.path.exists(target_wav) or os.path.exists(target_txt):
            raise ValueError(
                f'A saved voice named "{safe_name}" already exists. Choose a different name.'
            )

        shutil.copy(clean_wav, target_wav)

        transcript = params.get("transcript", "")
        if transcript:
            with open(target_txt, "w", encoding="utf-8") as handle:
                handle.write(transcript)

        return {"success": True, "name": safe_name, "wav_path": target_wav}

    def handle_delete_voice(self, params):
        name = params.get("name")
        if not name:
            raise ValueError("Missing required param: name")

        safe_name = re.sub(r"[^\w\s-]", "", name).strip().replace(" ", "_")
        if not safe_name:
            raise ValueError("Invalid voice name")

        wav_path = os.path.join(self.state.voices_dir, f"{safe_name}.wav")
        txt_path = os.path.join(self.state.voices_dir, f"{safe_name}.txt")

        deleted = False
        if os.path.exists(wav_path):
            os.remove(wav_path)
            deleted = True
        if os.path.exists(txt_path):
            os.remove(txt_path)

        return {"success": deleted}

    def handle_get_model_info(self, params):
        models_info = []
        for model_id, model_def in self.models.items():
            path = self.output_paths.get_smart_path(model_def["folder"])
            size_bytes = 0
            if path:
                for root, _, files in os.walk(path):
                    for filename in files:
                        size_bytes += os.path.getsize(os.path.join(root, filename))

            models_info.append(
                {
                    "id": model_id,
                    "name": model_def["name"],
                    "folder": model_def["folder"],
                    "mode": model_def["mode"],
                    "tier": model_def["tier"],
                    "output_subfolder": model_def["outputSubfolder"],
                    "hugging_face_repo": model_def["huggingFaceRepo"],
                    "required_relative_paths": model_def["requiredRelativePaths"],
                    "downloaded": path is not None,
                    "size_bytes": size_bytes,
                    **self.resolved_model_capabilities(model_def),
                }
            )

        return models_info

    def handle_get_speakers(self, params):
        return self.speaker_map

    def methods(self):
        return {
            "ping": self.handle_ping,
            "init": self.handle_init,
            "load_model": self.handle_load_model,
            "prewarm_model": self.handle_prewarm_model,
            "prepare_clone_reference": self.handle_prepare_clone_reference,
            "prime_clone_reference": self.handle_prime_clone_reference,
            "unload_model": self.handle_unload_model,
            "generate": self.handle_generate,
            "generate_clone_batch": self.handle_generate_clone_batch,
            "convert_audio": self.handle_convert_audio,
            "list_voices": self.handle_list_voices,
            "enroll_voice": self.handle_enroll_voice,
            "delete_voice": self.handle_delete_voice,
            "get_model_info": self.handle_get_model_info,
            "get_speakers": self.handle_get_speakers,
        }

    def process_request(self, line):
        methods = self.methods()
        try:
            req = json.loads(line)
        except json.JSONDecodeError as error:
            self.transport.send_error(None, -32700, f"Parse error: {error}")
            return

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params", {})

        if method not in methods:
            self.transport.send_error(req_id, -32601, f"Method not found: {method}")
            return

        try:
            if method in {
                "generate",
                "generate_clone_batch",
                "load_model",
                "prewarm_model",
                "prepare_clone_reference",
                "prime_clone_reference",
            }:
                result = methods[method](params, request_id=req_id)
            else:
                result = methods[method](params)
            self.transport.send_response(req_id, result)
        except Exception as error:
            tb = traceback.format_exc()
            print(tb, file=self.original_stderr)
            self.transport.send_error(req_id, -32000, str(error))
