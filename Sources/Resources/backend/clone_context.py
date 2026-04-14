import hashlib
import os
import re
import time
import wave

MIN_TRIMMED_CLONE_REFERENCE_SECONDS = 0.75


class CloneContextManager:
    def __init__(
        self,
        state,
        audio_io,
        clone_context_cache_capacity,
        normalized_clone_ref_cache_limit,
        normalized_clone_ref_max_age_seconds,
        experimental_trim_enabled=False,
    ):
        self.state = state
        self.audio_io = audio_io
        self.clone_context_cache_capacity = clone_context_cache_capacity
        self.normalized_clone_ref_cache_limit = normalized_clone_ref_cache_limit
        self.normalized_clone_ref_max_age_seconds = normalized_clone_ref_max_age_seconds
        self.experimental_trim_enabled = experimental_trim_enabled

    def clear_clone_context_cache(self):
        self.state.clone_context_cache.clear()

    def clone_reference_cache_path(self, input_path):
        stem, fingerprint = self._clone_reference_cache_components(input_path)
        return os.path.join(self.state.clone_ref_cache_dir, f"{stem}_{fingerprint}.wav")

    def clone_reference_trimmed_cache_path(self, input_path):
        stem, fingerprint = self._clone_reference_cache_components(input_path)
        return os.path.join(
            self.state.clone_ref_cache_dir, f"{stem}_{fingerprint}_trimmed.wav"
        )

    def _clone_reference_cache_components(self, input_path):
        stat_result = os.stat(input_path)
        fingerprint = hashlib.sha256(
            f"{os.path.realpath(input_path)}:{stat_result.st_size}:{stat_result.st_mtime_ns}".encode(
                "utf-8"
            )
        ).hexdigest()[:16]
        stem = (
            re.sub(r"[^\w\s-]", "", os.path.splitext(os.path.basename(input_path))[0])
            .strip()
            .replace(" ", "_")
        )
        stem = stem or "reference"
        return stem, fingerprint

    def _record_clone_reference_metrics(
        self,
        *,
        original_path,
        normalized_path,
        returned_path,
        trim_attempted,
        trim_applied,
        trim_status,
        duration_before_seconds,
        duration_after_seconds,
        trim_error=None,
    ):
        metrics = {
            "original_path": original_path,
            "normalized_path": normalized_path,
            "returned_path": returned_path,
            "trim_attempted": trim_attempted,
            "trim_applied": trim_applied,
            "trim_status": trim_status,
            "duration_before_seconds": round(duration_before_seconds, 4),
            "duration_after_seconds": round(duration_after_seconds, 4),
        }
        if trim_error:
            metrics["trim_error"] = trim_error
        self.state.last_clone_reference_metrics = metrics
        return metrics

    def _trim_normalized_clone_reference(self, original_path, normalized_path):
        trimmed_path = self.clone_reference_trimmed_cache_path(original_path)
        source_duration = (
            self.audio_io.get_audio_metadata(normalized_path).get("duration_seconds")
            or 0.0
        )

        if os.path.exists(trimmed_path):
            try:
                os.utime(trimmed_path, None)
            except OSError:
                pass
            trimmed_duration = (
                self.audio_io.get_audio_metadata(trimmed_path).get("duration_seconds")
                or source_duration
            )
            self._record_clone_reference_metrics(
                original_path=original_path,
                normalized_path=normalized_path,
                returned_path=trimmed_path,
                trim_attempted=True,
                trim_applied=True,
                trim_status="cached_trimmed_reference",
                duration_before_seconds=source_duration,
                duration_after_seconds=trimmed_duration,
            )
            return trimmed_path

        try:
            trimmed_candidate = self.audio_io.trim_clone_reference_silence(
                normalized_path, trimmed_path
            )
        except Exception as exc:
            self._record_clone_reference_metrics(
                original_path=original_path,
                normalized_path=normalized_path,
                returned_path=normalized_path,
                trim_attempted=True,
                trim_applied=False,
                trim_status="trim_failed",
                duration_before_seconds=source_duration,
                duration_after_seconds=source_duration,
                trim_error=str(exc),
            )
            return normalized_path

        trimmed_duration = (
            self.audio_io.get_audio_metadata(trimmed_candidate).get("duration_seconds")
            or 0.0
        )
        trim_made_difference = (
            source_duration <= 0
            or trimmed_duration < max(0.0, source_duration - 0.05)
        )
        trim_is_plausible = trimmed_duration >= MIN_TRIMMED_CLONE_REFERENCE_SECONDS

        if trim_is_plausible and trim_made_difference:
            self._record_clone_reference_metrics(
                original_path=original_path,
                normalized_path=normalized_path,
                returned_path=trimmed_candidate,
                trim_attempted=True,
                trim_applied=True,
                trim_status="trim_applied",
                duration_before_seconds=source_duration,
                duration_after_seconds=trimmed_duration,
            )
            return trimmed_candidate

        try:
            os.remove(trimmed_candidate)
        except OSError:
            pass

        self._record_clone_reference_metrics(
            original_path=original_path,
            normalized_path=normalized_path,
            returned_path=normalized_path,
            trim_attempted=True,
            trim_applied=False,
            trim_status=(
                "trim_rejected_too_short"
                if not trim_is_plausible
                else "trim_not_needed"
            ),
            duration_before_seconds=source_duration,
            duration_after_seconds=trimmed_duration or source_duration,
        )
        return normalized_path

    def prune_normalized_clone_reference_cache(self):
        if not os.path.isdir(self.state.clone_ref_cache_dir):
            return

        now = time.time()
        entries = []
        for name in os.listdir(self.state.clone_ref_cache_dir):
            if not name.endswith(".wav"):
                continue
            path = os.path.join(self.state.clone_ref_cache_dir, name)
            try:
                stat_result = os.stat(path)
            except OSError:
                continue
            entries.append((path, stat_result.st_mtime, stat_result.st_size))

        for path, mtime, _ in list(entries):
            if now - mtime > self.normalized_clone_ref_max_age_seconds:
                try:
                    os.remove(path)
                except OSError:
                    pass

        remaining = [
            (p, m, s)
            for p, m, s in entries
            if now - m <= self.normalized_clone_ref_max_age_seconds
        ]
        if len(remaining) <= self.normalized_clone_ref_cache_limit:
            return

        remaining.sort(key=lambda item: item[1], reverse=True)
        for path, _, _ in remaining[self.normalized_clone_ref_cache_limit :]:
            try:
                os.remove(path)
            except OSError:
                pass

    def normalize_audio_with_stable_cache(self, input_path):
        if not os.path.exists(input_path):
            self.state.last_clone_reference_metrics = {
                "original_path": input_path,
                "trim_attempted": False,
                "trim_applied": False,
                "trim_status": "missing_input",
                "duration_before_seconds": 0.0,
                "duration_after_seconds": 0.0,
            }
            return None

        ext = os.path.splitext(input_path)[1].lower()
        normalized_path = None
        if ext == ".wav":
            try:
                with wave.open(input_path, "rb") as handle:
                    if (
                        handle.getnchannels() == 1
                        and handle.getframerate() == self.audio_io.sample_rate
                    ):
                        normalized_path = input_path
            except wave.Error:
                pass

        if normalized_path is None:
            cached_wav = self.clone_reference_cache_path(input_path)
            if os.path.exists(cached_wav):
                try:
                    os.utime(cached_wav, None)
                except OSError:
                    pass
                normalized_path = cached_wav
            elif self.state.audio_write_fn is not None:
                try:
                    normalized_path = self.audio_io.convert_audio_with_mlx(
                        input_path, cached_wav
                    )
                except Exception:
                    normalized_path = self.audio_io.convert_audio_to_wav(
                        input_path, cached_wav
                    )
            else:
                normalized_path = self.audio_io.convert_audio_to_wav(
                    input_path, cached_wav
                )

        returned_path = normalized_path
        if self.experimental_trim_enabled and normalized_path is not None:
            returned_path = self._trim_normalized_clone_reference(
                input_path, normalized_path
            )
        elif normalized_path is not None:
            duration = (
                self.audio_io.get_audio_metadata(normalized_path).get("duration_seconds")
                or 0.0
            )
            self._record_clone_reference_metrics(
                original_path=input_path,
                normalized_path=normalized_path,
                returned_path=normalized_path,
                trim_attempted=False,
                trim_applied=False,
                trim_status="trim_disabled",
                duration_before_seconds=duration,
                duration_after_seconds=duration,
            )

        self.prune_normalized_clone_reference_cache()
        return returned_path

    def normalize_clone_reference(self, ref_audio_path):
        return self.normalize_audio_with_stable_cache(ref_audio_path)

    def resolve_clone_transcript(
        self, clean_ref_audio_path, original_ref_audio_path, requested_transcript
    ):
        transcript = (requested_transcript or "").strip()
        if transcript:
            return transcript

        candidate_paths = []
        if original_ref_audio_path:
            candidate_paths.append(original_ref_audio_path)
        if clean_ref_audio_path and clean_ref_audio_path not in candidate_paths:
            candidate_paths.append(clean_ref_audio_path)

        for candidate_path in candidate_paths:
            sidecar = os.path.splitext(candidate_path)[0] + ".txt"
            if not os.path.exists(sidecar):
                continue

            try:
                with open(sidecar, "r", encoding="utf-8") as handle:
                    text = handle.read().strip()
                    if text:
                        return text
            except OSError:
                continue

        if not clean_ref_audio_path and not original_ref_audio_path:
            return None
        return None

    def clone_cache_key(self, clean_ref_audio_path, ref_text):
        stat_result = os.stat(clean_ref_audio_path)
        real_path = os.path.realpath(clean_ref_audio_path)
        cache_root = os.path.realpath(self.state.clone_ref_cache_dir)

        if real_path.startswith(cache_root + os.sep):
            file_identity = (real_path, stat_result.st_size)
        else:
            file_identity = (real_path, stat_result.st_size, stat_result.st_mtime_ns)

        return (
            self.state.current_model_path,
            *file_identity,
            (ref_text or "").strip(),
        )

    def cache_clone_context(self, cache_key, prepared_context):
        self.state.clone_context_cache[cache_key] = prepared_context
        self.state.clone_context_cache.move_to_end(cache_key)
        while len(self.state.clone_context_cache) > self.clone_context_cache_capacity:
            self.state.clone_context_cache.popitem(last=False)

    def get_or_prepare_clone_context(self, clean_ref_audio_path, ref_text):
        if (
            self.state.prepare_icl_context_fn is None
            or self.state.can_prepare_icl_fn is None
            or self.state.current_model is None
            or not self.state.can_prepare_icl_fn(self.state.current_model)
            or not ref_text
        ):
            return None, None

        cache_key = self.clone_cache_key(clean_ref_audio_path, ref_text)
        cached = self.state.clone_context_cache.get(cache_key)
        if cached is not None:
            self.state.clone_context_cache.move_to_end(cache_key)
            return cached, True

        prepared = self.state.prepare_icl_context_fn(
            self.state.current_model, clean_ref_audio_path, ref_text
        )
        self.cache_clone_context(cache_key, prepared)
        return prepared, False

    def can_use_shared_reference_clone_batch_fast_path(
        self,
        *,
        can_use_prepared,
        requested_stream,
    ):
        if (
            requested_stream
            or not can_use_prepared
            or self.state.batch_generate_prepared_icl_fn is None
        ):
            return False

        model = self.state.current_model
        if getattr(getattr(model, "config", None), "tts_model_type", None) != "base":
            return False

        if not hasattr(model, "_sample_token_batch"):
            return False

        speech_tokenizer = getattr(model, "speech_tokenizer", None)
        return hasattr(speech_tokenizer, "batch_decode")

    def clone_prime_identity_key(self, clean_ref_audio_path, ref_text):
        return (
            self.state.current_model_path,
            *self.clone_cache_key(clean_ref_audio_path, ref_text),
        )

    def reset_clone_streaming_state(self):
        decoder = getattr(
            getattr(self.state.current_model, "speech_tokenizer", None),
            "decoder",
            None,
        )
        reset_streaming_state = getattr(decoder, "reset_streaming_state", None)
        if callable(reset_streaming_state):
            reset_streaming_state()
