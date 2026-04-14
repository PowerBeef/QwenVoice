import os
import re
import shutil


class VoiceRPCMixin:
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
