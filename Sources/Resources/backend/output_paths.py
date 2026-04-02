import os
import re
from datetime import datetime


class OutputPathResolver:
    def __init__(self, state, models, models_by_mode, filename_max_len):
        self.state = state
        self.models = models
        self.models_by_mode = models_by_mode
        self.filename_max_len = filename_max_len

    def get_smart_path(self, folder_name):
        full_path = os.path.join(self.state.models_dir, folder_name)
        if not os.path.exists(full_path):
            return None

        snapshots_dir = os.path.join(full_path, "snapshots")
        if os.path.exists(snapshots_dir):
            subfolders = [f for f in os.listdir(snapshots_dir) if not f.startswith(".")]
            if subfolders:
                return os.path.join(snapshots_dir, subfolders[0])

        return full_path

    def resolve_model_id_for_path(self, model_path):
        if not model_path:
            return None

        normalized = os.path.realpath(model_path)
        for model_id, model_def in self.models.items():
            resolved = self.get_smart_path(model_def["folder"])
            if resolved and os.path.realpath(resolved) == normalized:
                return model_id

        return None

    def resolve_model_request(self, model_id=None, model_path=None):
        if not model_path and model_id:
            model_def = self.models.get(model_id)
            if not model_def:
                raise ValueError(f"Unknown model_id: {model_id}")
            model_path = self.get_smart_path(model_def["folder"])
            if not model_path:
                raise FileNotFoundError(f"Model not found on disk: {model_def['folder']}")

        if not model_path:
            raise ValueError("Must provide model_id or model_path")

        resolved_model_id = model_id or self.resolve_model_id_for_path(model_path)
        return model_path, resolved_model_id

    def model_identity_key(self, resolved_model_id, model_path):
        return resolved_model_id or os.path.realpath(model_path)

    def make_output_path(self, subfolder, text_snippet):
        save_dir = os.path.join(self.state.outputs_dir, subfolder)
        os.makedirs(save_dir, exist_ok=True)

        timestamp = datetime.now().strftime("%Y%m%d_%H-%M-%S-%f")
        clean_text = (
            re.sub(r"[^\w\s-]", "", text_snippet)[: self.filename_max_len]
            .strip()
            .replace(" ", "_")
            or "audio"
        )
        filename = f"{timestamp}_{clean_text}.wav"
        return os.path.join(save_dir, filename)

    def infer_legacy_mode(self, voice=None, ref_audio=None):
        if ref_audio:
            return "clone"
        if voice:
            return "custom"
        return "design"

    def current_model_contract(self):
        if not self.state.current_model_id:
            return None
        return self.models.get(self.state.current_model_id)

    def resolve_generation_mode(self, requested_mode, voice=None, ref_audio=None):
        if requested_mode:
            return requested_mode

        current_model_contract = self.current_model_contract()
        if current_model_contract:
            return current_model_contract["mode"]

        return self.infer_legacy_mode(voice=voice, ref_audio=ref_audio)

    def resolve_output_subfolder(self, requested_mode, voice=None, ref_audio=None):
        current_model_contract = self.current_model_contract()
        if current_model_contract:
            return current_model_contract["outputSubfolder"]

        if requested_mode and requested_mode in self.models_by_mode:
            return self.models_by_mode[requested_mode]["outputSubfolder"]

        legacy_mode = self.infer_legacy_mode(voice=voice, ref_audio=ref_audio)
        if legacy_mode in self.models_by_mode:
            return self.models_by_mode[legacy_mode]["outputSubfolder"]

        return {
            "custom": "CustomVoice",
            "design": "VoiceDesign",
            "clone": "Clones",
        }[legacy_mode]

    def resolve_final_output_path(self, explicit_output_path, text, mode=None, voice=None, ref_audio=None):
        if explicit_output_path:
            parent_dir = os.path.dirname(explicit_output_path)
            if parent_dir:
                os.makedirs(parent_dir, exist_ok=True)
            return explicit_output_path

        subfolder = self.resolve_output_subfolder(mode, voice=voice, ref_audio=ref_audio)
        return self.make_output_path(subfolder, text)

    def derive_generation_paths(self, final_path):
        target_dir = os.path.dirname(final_path) or self.state.outputs_dir
        os.makedirs(target_dir, exist_ok=True)
        stem = os.path.splitext(os.path.basename(final_path))[0] or "audio"
        generated_path = os.path.join(target_dir, f"{stem}_000.wav")
        return target_dir, stem, generated_path
