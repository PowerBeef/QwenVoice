import os
import subprocess
import time
import wave


class AudioIOManager:
    def __init__(self, state, resources_dir, sample_rate):
        self.state = state
        self.resources_dir = resources_dir
        self.sample_rate = sample_rate

    def resolve_ffmpeg_binary(self):
        configured = os.environ.get("QWENVOICE_FFMPEG_PATH")
        if configured and os.path.exists(configured):
            return configured

        bundled = os.path.join(self.resources_dir, "ffmpeg")
        if os.path.exists(bundled):
            return bundled

        return "ffmpeg"

    def convert_audio_if_needed(self, input_path):
        if not os.path.exists(input_path):
            return None

        ext = os.path.splitext(input_path)[1].lower()
        if ext == ".wav":
            try:
                with wave.open(input_path, "rb") as handle:
                    if (
                        handle.getnchannels() == 1
                        and handle.getframerate() == self.sample_rate
                    ):
                        return input_path
            except wave.Error:
                pass

        temp_wav = os.path.join(
            self.state.outputs_dir, f"temp_convert_{time.time_ns()}.wav"
        )
        if self.state.audio_write_fn is not None:
            try:
                return self.convert_audio_with_mlx(input_path, temp_wav)
            except (OSError, RuntimeError, ValueError):
                pass
        return self.convert_audio_to_wav(input_path, temp_wav)

    def get_audio_metadata(self, wav_path):
        try:
            with wave.open(wav_path, "rb") as handle:
                frames = handle.getnframes()
                rate = handle.getframerate()
                duration = frames / float(rate) if rate > 0 else 0.0
                return {"frames": frames, "duration_seconds": duration}
        except Exception:
            return {"frames": None, "duration_seconds": 0.0}

    def convert_audio_to_wav(self, input_path, output_path):
        parent_dir = os.path.dirname(output_path)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)

        cmd = [
            self.resolve_ffmpeg_binary(),
            "-y",
            "-v",
            "error",
            "-i",
            input_path,
            "-ar",
            str(self.sample_rate),
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            output_path,
        ]

        try:
            subprocess.run(
                cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
            )
        except (subprocess.CalledProcessError, FileNotFoundError):
            raise RuntimeError("Could not convert audio. Is ffmpeg installed?")

        return output_path

    def convert_audio_with_mlx(self, input_path, output_path):
        from mlx_audio.utils import load_audio

        audio = load_audio(input_path, sample_rate=self.sample_rate)
        audio_np = self.state.np.array(audio, dtype=self.state.np.float32)
        if audio_np.ndim > 1:
            audio_np = audio_np.mean(axis=-1)

        parent_dir = os.path.dirname(output_path)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)
        self.state.audio_write_fn(output_path, audio_np, self.sample_rate, format="wav")
        return output_path

    def to_int16_audio_array(self, audio):
        array = audio if isinstance(audio, self.state.np.ndarray) else self.state.np.array(audio)

        if array.dtype in (self.state.np.float32, self.state.np.float64):
            array = self.state.np.clip(array, -1.0, 1.0)
            array = (array * 32767).astype(self.state.np.int16)
        elif array.dtype != self.state.np.int16:
            array = array.astype(self.state.np.int16)

        return array

    def flatten_audio_samples(self, audio):
        normalized = self.to_int16_audio_array(audio)
        if normalized.ndim == 1:
            nchannels = 1
            samples_flat = normalized
        else:
            nchannels = int(normalized.shape[1])
            samples_flat = normalized.reshape(-1)
        return normalized, samples_flat, nchannels

    def write_audio_file(self, output_path, audio, sample_rate):
        parent_dir = os.path.dirname(output_path)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)
        self.state.audio_write_fn(
            output_path,
            self.to_int16_audio_array(audio),
            sample_rate,
            format="wav",
        )
