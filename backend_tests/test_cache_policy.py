from __future__ import annotations

import importlib.util
import os
import pathlib
import tempfile
import unittest
import uuid


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT_DIR / "Sources/Resources/backend/server.py"
ENV_KEYS = ("QWENVOICE_CACHE_POLICY", "QWENVOICE_POST_REQUEST_CACHE_CLEAR")


class CachePolicyTests(unittest.TestCase):
    def test_default_policy_is_adaptive(self) -> None:
        module = self.load_server_module({})

        self.assertEqual(module.CACHE_POLICY, "adaptive")
        self.assertFalse(module._should_clear_cache_after_request(True))
        self.assertTrue(module._should_clear_cache_after_request(False))

    def test_legacy_cache_clear_env_maps_to_always(self) -> None:
        module = self.load_server_module({"QWENVOICE_POST_REQUEST_CACHE_CLEAR": "1"})

        self.assertEqual(module.CACHE_POLICY, "always")
        self.assertTrue(module._should_clear_cache_after_request(True))
        self.assertTrue(module._should_clear_cache_after_request(False))

    def test_explicit_policy_overrides_legacy_env(self) -> None:
        module = self.load_server_module(
            {
                "QWENVOICE_CACHE_POLICY": "never",
                "QWENVOICE_POST_REQUEST_CACHE_CLEAR": "1",
            }
        )

        self.assertEqual(module.CACHE_POLICY, "never")
        self.assertFalse(module._should_clear_cache_after_request(True))
        self.assertFalse(module._should_clear_cache_after_request(False))

    def test_normalized_clone_reference_cache_key_ignores_access_time_refresh(self) -> None:
        module = self.load_server_module({})
        module._current_model_path = "/tmp/fake-model"

        with tempfile.TemporaryDirectory() as temp_dir:
            cache_root = pathlib.Path(temp_dir) / "cache" / "normalized_clone_refs"
            cache_root.mkdir(parents=True)
            normalized_ref = cache_root / "reference_deadbeefcafebabe.wav"
            normalized_ref.write_bytes(b"123456")

            module.CLONE_REF_CACHE_DIR = str(cache_root)
            key_before = module._clone_cache_key(str(normalized_ref), "hello")

            os.utime(normalized_ref, None)
            key_after = module._clone_cache_key(str(normalized_ref), "hello")

            self.assertEqual(key_before, key_after)

    def test_non_normalized_clone_reference_cache_key_tracks_file_mutations(self) -> None:
        module = self.load_server_module({})
        module._current_model_path = "/tmp/fake-model"

        with tempfile.TemporaryDirectory() as temp_dir:
            ref_path = pathlib.Path(temp_dir) / "input.wav"
            ref_path.write_bytes(b"123456")

            key_before = module._clone_cache_key(str(ref_path), "hello")
            os.utime(ref_path, None)
            key_after = module._clone_cache_key(str(ref_path), "hello")

            self.assertNotEqual(key_before, key_after)

    def load_server_module(self, env_overrides: dict[str, str]) -> object:
        previous = {key: os.environ.get(key) for key in ENV_KEYS}

        try:
            for key in ENV_KEYS:
                os.environ.pop(key, None)
            os.environ.update(env_overrides)

            module_name = f"qwenvoice_server_cache_policy_{uuid.uuid4().hex}"
            spec = importlib.util.spec_from_file_location(module_name, SERVER_PATH)
            self.assertIsNotNone(spec)
            self.assertIsNotNone(spec.loader)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()
