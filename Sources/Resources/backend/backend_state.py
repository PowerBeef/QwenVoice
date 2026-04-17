import os
from collections import OrderedDict
from dataclasses import dataclass, field


def _path_layout(app_support_dir):
    return {
        "models_dir": os.path.join(app_support_dir, "models"),
        "outputs_dir": os.path.join(app_support_dir, "outputs"),
        "voices_dir": os.path.join(app_support_dir, "voices"),
        "clone_ref_cache_dir": os.path.join(
            app_support_dir, "cache", "normalized_clone_refs"
        ),
        "stream_sessions_dir": os.path.join(app_support_dir, "cache", "stream_sessions"),
    }


@dataclass
class BackendState:
    app_support_dir: str = os.path.expanduser("~/Library/Application Support/QwenVoice")
    current_model = None
    current_model_path: str | None = None
    current_model_id: str | None = None
    load_model_fn = None
    generate_audio_fn = None
    audio_write_fn = None
    mx = None
    np = None
    can_prepare_icl_fn = None
    prepare_icl_context_fn = None
    generate_prepared_icl_fn = None
    batch_generate_prepared_icl_fn = None
    enable_speech_tokenizer_encoder_fn = None
    clone_context_cache: OrderedDict = field(default_factory=OrderedDict)
    last_clone_reference_metrics: dict = field(default_factory=dict)
    mlx_audio_version: str | None = None
    prewarmed_model_keys: set = field(default_factory=set)
    primed_clone_reference_keys: set = field(default_factory=set)
    models_dir: str = field(init=False)
    outputs_dir: str = field(init=False)
    voices_dir: str = field(init=False)
    clone_ref_cache_dir: str = field(init=False)
    stream_sessions_dir: str = field(init=False)

    def __post_init__(self):
        self.configure_app_support_dir(self.app_support_dir)

    def configure_app_support_dir(self, app_support_dir):
        self.app_support_dir = app_support_dir
        layout = _path_layout(app_support_dir)
        self.models_dir = layout["models_dir"]
        self.outputs_dir = layout["outputs_dir"]
        self.voices_dir = layout["voices_dir"]
        self.clone_ref_cache_dir = layout["clone_ref_cache_dir"]
        self.stream_sessions_dir = layout["stream_sessions_dir"]

    def ensure_directories(self):
        for path in (
            self.models_dir,
            self.outputs_dir,
            self.voices_dir,
            self.clone_ref_cache_dir,
            self.stream_sessions_dir,
        ):
            os.makedirs(path, exist_ok=True)
