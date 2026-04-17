class ModelInfoRPCMixin:
    def handle_get_model_info(self, params):
        models_info = []
        for model_id, model_def in self.models.items():
            installation_info = self.output_paths.model_installation_info(model_def)

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
                    **installation_info,
                    **self.resolved_model_capabilities(model_def),
                }
            )

        return models_info

    def handle_get_speakers(self, params):
        return self.speaker_map
