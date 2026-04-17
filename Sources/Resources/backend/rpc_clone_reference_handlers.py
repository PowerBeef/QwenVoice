import time


class CloneReferenceRPCMixin:
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
            clean_ref_audio, ref_audio, ref_text
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
                "reference_preprocessing": dict(
                    self.state.last_clone_reference_metrics or {}
                ),
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
            clean_ref_audio, ref_audio, ref_text
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
            self.transport.send_progress(20, "Preparing voice context...", request_id=request_id)
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
                "reference_preprocessing": dict(
                    self.state.last_clone_reference_metrics or {}
                ),
                "prime_max_tokens": prime_timings.get("prime_max_tokens", 0),
                "streaming_interval": prime_timings.get(
                    "streaming_interval", streaming_interval
                ),
                "timings_ms": {
                    "load_model_total": load_timings.get("load_model_total", 0),
                    "normalize_reference": prime_timings["normalize_reference"],
                    "prepare_clone_context": prime_timings["prepare_clone_context"],
                    "first_stream_chunk": prime_timings["first_stream_chunk"],
                    "generation": prime_timings["generation"],
                    "total_backend": int((time.perf_counter() - overall_start) * 1000),
                },
            }
        return result
