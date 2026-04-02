import os
import time
import uuid
import wave


class GenerationPipeline:
    def __init__(
        self,
        state,
        transport,
        output_paths,
        audio_io,
        clone_context,
        default_speaker,
        cache_policy,
        default_streaming_interval,
        prewarm_profiles,
    ):
        self.state = state
        self.transport = transport
        self.output_paths = output_paths
        self.audio_io = audio_io
        self.clone_context = clone_context
        self.default_speaker = default_speaker
        self.cache_policy = cache_policy
        self.default_streaming_interval = default_streaming_interval
        self.prewarm_profiles = prewarm_profiles

    def has_meaningful_delivery_instruction(self, instruct):
        trimmed = (instruct or "").strip()
        return bool(trimmed) and trimmed.lower() != "normal tone"

    def prewarm_identity_key(
        self, model_key, mode, voice=None, instruct=None, ref_audio=None, ref_text=None
    ):
        components = [model_key, mode or ""]

        if mode == "clone":
            components.extend(
                [
                    os.path.realpath(ref_audio) if ref_audio else "",
                    (ref_text or "").strip(),
                ]
            )
        elif mode == "design":
            return tuple(components)
        else:
            components.extend(
                [
                    (voice or "").strip(),
                    (instruct or "").strip()
                    if self.has_meaningful_delivery_instruction(instruct)
                    else "",
                ]
            )

        return tuple(components)

    def collect_single_generation_result(self, generator):
        result, _ = self.collect_generation_result_with_timings(generator)
        return result

    def collect_generation_result_with_timings(self, generator):
        collect_start = time.perf_counter()
        first_yield_ms = None
        last_result = None

        for result in generator:
            if first_yield_ms is None:
                first_yield_ms = int((time.perf_counter() - collect_start) * 1000)
            last_result = result

        if last_result is None:
            raise RuntimeError("Generation produced no results")

        return last_result, {
            "first_generator_yield": first_yield_ms or 0,
            "collect_generation": int((time.perf_counter() - collect_start) * 1000),
        }

    def collect_batch_generation_results_with_timings(self, generator, expected_count):
        collect_start = time.perf_counter()
        first_yield_ms = None
        results = []

        for result in generator:
            if first_yield_ms is None:
                first_yield_ms = int((time.perf_counter() - collect_start) * 1000)
            results.append(result)

        if len(results) != expected_count:
            raise RuntimeError(
                f"Batch generation produced {len(results)} results; expected {expected_count}"
            )

        return results, {
            "first_generator_yield": first_yield_ms or 0,
            "collect_generation": int((time.perf_counter() - collect_start) * 1000),
        }

    def prewarm_profile(self, mode):
        profile = self.prewarm_profiles.get(mode)
        if profile is None:
            raise ValueError(f"Unknown prewarm mode: {mode}")
        return profile

    def timing_breakdown_template(self):
        return {
            "first_generator_yield": 0,
            "collect_generation": 0,
            "chunk_file_write": 0,
            "chunk_notifications": 0,
            "metadata_lookup": 0,
        }

    def apply_timing_breakdown(self, target, breakdown):
        for key, value in breakdown.items():
            target[key] = target.get(key, 0) + value

    def normalize_request_language(self, language):
        if language is None:
            return None
        normalized = str(language).strip()
        if not normalized or normalized.lower() == "auto":
            return None
        return normalized

    def with_optional_kwarg(self, kwargs, key, value):
        if value is not None:
            kwargs[key] = value
        return kwargs

    def build_generation_kwargs(
        self,
        text,
        temperature,
        max_tokens=None,
        *,
        language="auto",
        voice=None,
        instruct=None,
        stream=False,
        streaming_interval=None,
        verbose=False,
    ):
        kwargs = {
            "text": text,
            "temperature": temperature,
            "verbose": verbose,
        }
        if max_tokens is not None:
            kwargs["max_tokens"] = max_tokens
        if language is not None and language != "auto":
            kwargs["lang_code"] = language
        if voice:
            kwargs["speaker"] = voice
        if instruct:
            kwargs["instruct"] = instruct
        if stream:
            kwargs["stream"] = True
            kwargs["streaming_interval"] = (
                streaming_interval
                if streaming_interval is not None
                else self.default_streaming_interval
            )
        return kwargs

    def build_standard_generator(
        self,
        model,
        text,
        temperature,
        max_tokens=None,
        *,
        language="auto",
        voice=None,
        instruct=None,
        stream=False,
        streaming_interval=None,
    ):
        return model.generate(
            **self.build_generation_kwargs(
                text=text,
                temperature=temperature,
                max_tokens=max_tokens,
                language=language,
                voice=voice,
                instruct=instruct,
                stream=stream,
                streaming_interval=streaming_interval,
            )
        )

    def build_clone_fallback_generator(
        self,
        model,
        text,
        temperature,
        clean_ref_audio,
        resolved_ref_text,
        max_tokens=None,
        *,
        language="auto",
        stream=False,
        streaming_interval=None,
    ):
        kwargs = self.build_generation_kwargs(
            text=text,
            temperature=temperature,
            max_tokens=max_tokens,
            language=language,
            stream=stream,
            streaming_interval=streaming_interval,
            verbose=False,
        )
        kwargs["ref_audio"] = clean_ref_audio
        if resolved_ref_text:
            kwargs["ref_text"] = resolved_ref_text
        return model.generate(**kwargs)

    def stream_generator_to_output(self, generator, request_id, final_path):
        return self.consume_streaming_generator(generator, request_id, final_path)

    def stream_prepared_result_to_output(
        self, result, request_id, final_path, streaming_interval
    ):
        generator = iter([result])
        return self.consume_streaming_generator(generator, request_id, final_path)

    def finalize_generated_audio(self, result, final_path, streaming_used):
        write_start = time.perf_counter()
        self.audio_io.write_audio_file(
            final_path,
            result.audio,
            int(getattr(result, "sample_rate", self.audio_io.sample_rate)),
        )
        write_output_ms = int((time.perf_counter() - write_start) * 1000)

        metadata_start = time.perf_counter()
        output_metadata = self.audio_io.get_audio_metadata(final_path)
        metadata_lookup_ms = int((time.perf_counter() - metadata_start) * 1000)

        metrics = self.metrics_from_generation_result(result, streaming_used)
        response = {
            "audio_path": final_path,
            "duration_seconds": round(output_metadata["duration_seconds"], 2),
            "metrics": metrics,
        }
        return (
            response,
            metrics,
            output_metadata,
            write_output_ms,
            {"metadata_lookup": metadata_lookup_ms},
        )

    def stream_selected_audio(self, result, request_id, final_path, streaming_interval):
        if getattr(result, "audio", None) is None:
            raise RuntimeError("Prepared streaming result is missing audio")
        return self.stream_prepared_result_to_output(
            result, request_id, final_path, streaming_interval
        )

    def metrics_from_generation_result(self, result, streaming_used):
        if result is None:
            return {"streaming_used": streaming_used}

        return {
            "token_count": int(getattr(result, "token_count", 0) or 0),
            "processing_time_seconds": round(
                float(getattr(result, "processing_time_seconds", 0.0) or 0.0), 4
            ),
            "peak_memory_usage": round(
                float(getattr(result, "peak_memory_usage", 0.0) or 0.0), 4
            ),
            "streaming_used": streaming_used,
        }

    def make_stream_session_dir(self, request_id):
        session_id = (
            f"{int(time.time() * 1000)}_{request_id or 'stream'}_{uuid.uuid4().hex[:8]}"
        )
        session_dir = os.path.join(self.state.stream_sessions_dir, session_id)
        os.makedirs(session_dir, exist_ok=True)
        return session_dir

    def consume_streaming_generator(self, generator, request_id, final_path):
        stream_start = time.perf_counter()
        write_start = time.perf_counter()
        session_dir = self.make_stream_session_dir(request_id)
        chunk_index = 0
        cumulative_duration = 0.0
        first_chunk_ms = None
        total_token_count = 0
        peak_memory_usage = 0.0
        last_chunk = None
        wav_writer = None
        expected_sample_rate = None
        expected_channels = None
        chunk_file_write_seconds = 0.0
        chunk_notification_seconds = 0.0

        try:
            for chunk in generator:
                chunk_received_at = time.perf_counter()
                if first_chunk_ms is None:
                    first_chunk_ms = int((chunk_received_at - stream_start) * 1000)

                normalized_audio, samples_flat, nchannels = (
                    self.audio_io.flatten_audio_samples(chunk.audio)
                )
                chunk_sample_rate = int(getattr(chunk, "sample_rate", 0) or 0)
                if chunk_sample_rate <= 0:
                    raise RuntimeError(
                        "Streaming chunk is missing a valid sample rate"
                    )

                if wav_writer is None:
                    parent_dir = os.path.dirname(final_path)
                    if parent_dir:
                        os.makedirs(parent_dir, exist_ok=True)
                    wav_writer = wave.open(final_path, "wb")
                    wav_writer.setnchannels(nchannels)
                    wav_writer.setsampwidth(2)
                    wav_writer.setframerate(chunk_sample_rate)
                    expected_sample_rate = chunk_sample_rate
                    expected_channels = nchannels
                elif (
                    chunk_sample_rate != expected_sample_rate
                    or nchannels != expected_channels
                ):
                    raise RuntimeError(
                        "Streaming generation produced incompatible audio chunk formats"
                    )

                chunk_path = os.path.join(session_dir, f"chunk_{chunk_index:03d}.wav")
                chunk_write_start = time.perf_counter()
                self.state.audio_write_fn(
                    chunk_path, normalized_audio, chunk_sample_rate, format="wav"
                )
                wav_writer.writeframes(samples_flat.tobytes())
                chunk_file_write_seconds += time.perf_counter() - chunk_write_start

                sample_count = int(getattr(chunk, "samples", 0) or 0)
                if sample_count <= 0:
                    sample_count = samples_flat.size // max(nchannels, 1)

                chunk_duration_seconds = sample_count / float(chunk_sample_rate)
                cumulative_duration += chunk_duration_seconds
                total_token_count += int(getattr(chunk, "token_count", 0) or 0)
                peak_memory_usage = max(
                    peak_memory_usage,
                    float(getattr(chunk, "peak_memory_usage", 0.0) or 0.0),
                )

                notification_start = time.perf_counter()
                self.transport.send_generation_chunk(
                    request_id=request_id,
                    chunk_index=chunk_index,
                    chunk_path=chunk_path,
                    is_final=bool(getattr(chunk, "is_final_chunk", False)),
                    chunk_duration_seconds=chunk_duration_seconds,
                    cumulative_duration_seconds=cumulative_duration,
                    stream_session_dir=session_dir,
                )
                chunk_notification_seconds += time.perf_counter() - notification_start
                last_chunk = chunk
                chunk_index += 1
        finally:
            if wav_writer is not None:
                wav_writer.close()

        if last_chunk is None:
            raise RuntimeError("Generation produced no audio file")

        write_output_ms = int((time.perf_counter() - write_start) * 1000)
        metadata_start = time.perf_counter()
        output_metadata = self.audio_io.get_audio_metadata(final_path)
        metadata_lookup_ms = int((time.perf_counter() - metadata_start) * 1000)

        metrics = self.metrics_from_generation_result(last_chunk, streaming_used=True)
        metrics["token_count"] = total_token_count
        metrics["peak_memory_usage"] = round(peak_memory_usage, 4)
        metrics["processing_time_seconds"] = round(
            time.perf_counter() - stream_start, 4
        )
        metrics["first_chunk_ms"] = first_chunk_ms

        return (
            {
                "audio_path": final_path,
                "duration_seconds": round(cumulative_duration, 2),
                "stream_session_dir": session_dir,
                "metrics": metrics,
            },
            write_output_ms,
            output_metadata,
            {
                "first_generator_yield": first_chunk_ms or 0,
                "collect_generation": int(
                    (time.perf_counter() - stream_start) * 1000
                ),
                "chunk_file_write": int(chunk_file_write_seconds * 1000),
                "chunk_notifications": int(chunk_notification_seconds * 1000),
                "metadata_lookup": metadata_lookup_ms,
            },
        )

    def should_clear_cache_after_request(self, succeeded):
        if self.cache_policy == "always":
            return True
        if self.cache_policy == "adaptive":
            return not succeeded
        return False

    def clear_mlx_cache(self):
        if self.state.mx is not None:
            self.state.mx.clear_cache()

    def perform_memory_recovery(self):
        import gc

        gc.collect()
        self.clear_mlx_cache()

    def is_retryable_allocation_error(self, error):
        message = str(error).lower()
        patterns = (
            "out of memory",
            "failed to allocate",
            "resource exhausted",
            "memory allocation",
            "insufficient memory",
            "mtlheap",
        )
        return any(pattern in message for pattern in patterns) or (
            "allocate" in message and ("memory" in message or "metal" in message)
        )

    def run_model_prewarm(
        self, mode, voice=None, instruct=None, ref_audio=None, ref_text=None, language=None
    ):
        if self.state.current_model is None:
            raise RuntimeError("No model loaded. Call load_model first.")

        profile = self.prewarm_profile(mode)
        warmup_text = profile["text"]
        warmup_max_tokens = profile["max_tokens"]
        generation_start = time.perf_counter()
        normalize_reference_ms = 0
        prepare_clone_context_ms = 0
        prepared_clone_used = False
        clone_cache_hit = None
        generation_ms = 0

        if mode == "custom":
            warm_results = list(
                self.build_standard_generator(
                    self.state.current_model,
                    text=warmup_text,
                    temperature=0.6,
                    max_tokens=warmup_max_tokens,
                    language=language,
                    voice=voice or self.default_speaker,
                    instruct=instruct or "Normal tone",
                )
            )
            generation_ms = int((time.perf_counter() - generation_start) * 1000)
        elif mode == "design":
            warm_results = None
            generation_ms = int((time.perf_counter() - generation_start) * 1000)
        elif mode == "clone":
            if not ref_audio:
                raise ValueError("Mode 'clone' prewarm requires ref_audio.")

            normalize_start = time.perf_counter()
            clean_ref_audio = self.clone_context.normalize_clone_reference(ref_audio)
            normalize_reference_ms = int((time.perf_counter() - normalize_start) * 1000)
            if not clean_ref_audio:
                raise RuntimeError("Could not process reference audio file")

            resolved_ref_text = self.clone_context.resolve_clone_transcript(
                clean_ref_audio, ref_text
            )
            prepare_start = time.perf_counter()
            prepared_context, clone_cache_hit = (
                self.clone_context.get_or_prepare_clone_context(
                    clean_ref_audio, resolved_ref_text
                )
            )
            prepare_clone_context_ms = int(
                (time.perf_counter() - prepare_start) * 1000
            )
            if (
                prepared_context is not None
                and self.state.generate_prepared_icl_fn is not None
            ):
                prepared_clone_used = True
                generator = self.state.generate_prepared_icl_fn(
                    self.state.current_model,
                    warmup_text,
                    prepared_context,
                    **self.with_optional_kwarg(
                        {
                            "temperature": 0.6,
                            "top_p": 1.0,
                            "repetition_penalty": 1.5,
                            "max_tokens": warmup_max_tokens,
                        },
                        "language",
                        language,
                    ),
                )
                warm_results = list(generator)
            else:
                warm_kwargs = {
                    "text": warmup_text,
                    "ref_audio": clean_ref_audio,
                    "verbose": False,
                    "temperature": 0.6,
                    "max_tokens": warmup_max_tokens,
                }
                if language is not None:
                    warm_kwargs["lang_code"] = language
                if resolved_ref_text:
                    warm_kwargs["ref_text"] = resolved_ref_text
                warm_results = list(self.state.current_model.generate(**warm_kwargs))
            generation_ms = int((time.perf_counter() - generation_start) * 1000)
        else:
            raise ValueError(f"Unknown prewarm mode: {mode}")

        if warm_results is not None and not warm_results:
            raise RuntimeError("Prewarm produced no generation output")

        return {
            "normalize_reference": normalize_reference_ms,
            "prepare_clone_context": prepare_clone_context_ms,
            "generation": generation_ms,
            "prepared_clone_used": prepared_clone_used,
            "clone_cache_hit": clone_cache_hit,
            "prewarm_max_tokens": warmup_max_tokens,
        }

    def prime_streaming_generator(self, generator):
        generation_start = time.perf_counter()
        first_chunk_ms = None

        try:
            for _ in generator:
                first_chunk_ms = int((time.perf_counter() - generation_start) * 1000)
                break
        finally:
            close = getattr(generator, "close", None)
            if callable(close):
                try:
                    close()
                except Exception:
                    pass
            self.clone_context.reset_clone_streaming_state()

        if first_chunk_ms is None:
            raise RuntimeError("Clone priming produced no streaming chunk")

        return {
            "first_stream_chunk": first_chunk_ms,
            "generation": int((time.perf_counter() - generation_start) * 1000),
        }

    def run_clone_reference_prime(
        self, clean_ref_audio_path, resolved_ref_text, streaming_interval, language=None
    ):
        if self.state.current_model is None:
            raise RuntimeError("No model loaded. Call load_model first.")

        profile = self.prewarm_profile("clone")
        warmup_text = profile["text"]
        warmup_max_tokens = profile["max_tokens"]
        prepare_clone_context_ms = 0
        prepared_clone_used = False
        clone_cache_hit = None

        prepare_start = time.perf_counter()
        prepared_context, clone_cache_hit = (
            self.clone_context.get_or_prepare_clone_context(
                clean_ref_audio_path, resolved_ref_text
            )
        )
        prepare_clone_context_ms = int((time.perf_counter() - prepare_start) * 1000)

        if (
            prepared_context is not None
            and self.state.generate_prepared_icl_fn is not None
        ):
            prepared_clone_used = True
            generator = self.state.generate_prepared_icl_fn(
                self.state.current_model,
                warmup_text,
                prepared_context,
                **self.with_optional_kwarg(
                    {
                        "temperature": 0.6,
                        "top_p": 1.0,
                        "repetition_penalty": 1.5,
                        "max_tokens": warmup_max_tokens,
                        "stream": True,
                        "streaming_interval": streaming_interval,
                    },
                    "language",
                    language,
                ),
            )
        else:
            generator = self.build_clone_fallback_generator(
                self.state.current_model,
                text=warmup_text,
                temperature=0.6,
                clean_ref_audio=clean_ref_audio_path,
                resolved_ref_text=resolved_ref_text,
                max_tokens=warmup_max_tokens,
                stream=True,
                streaming_interval=streaming_interval,
                **({"language": language} if language is not None else {}),
            )

        streaming_timings = self.prime_streaming_generator(generator)
        return {
            "prepare_clone_context": prepare_clone_context_ms,
            "generation": streaming_timings["generation"],
            "first_stream_chunk": streaming_timings["first_stream_chunk"],
            "prepared_clone_used": prepared_clone_used,
            "clone_cache_hit": clone_cache_hit,
            "prime_max_tokens": warmup_max_tokens,
            "streaming_interval": streaming_interval,
        }
