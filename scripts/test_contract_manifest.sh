#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
import importlib.util
import json
import pathlib

root = pathlib.Path.cwd()
contract_path = root / "Sources/Resources/qwenvoice_contract.json"
server_path = root / "Sources/Resources/backend/server.py"

contract = json.loads(contract_path.read_text(encoding="utf-8"))

spec = importlib.util.spec_from_file_location("qwenvoice_server", server_path)
server = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(server)
server._ensure_mlx = lambda: None

assert server.CONTRACT == contract, "Backend did not load the shared contract manifest"
assert server.handle_get_speakers({}) == contract["speakers"], "get_speakers drifted from the manifest"

model_info = server.handle_get_model_info({})
assert len(model_info) == len(contract["models"]), "get_model_info returned unexpected model count"

expected_output_subfolders = {
    model["mode"]: model["outputSubfolder"]
    for model in contract["models"]
}
for mode, output_subfolder in expected_output_subfolders.items():
    assert server._resolve_output_subfolder(mode) == output_subfolder, f"Output subfolder drifted for mode {mode}"

for expected, actual in zip(contract["models"], model_info):
    assert actual["id"] == expected["id"], f"Unexpected model id: {actual['id']}"
    assert actual["name"] == expected["name"], f"Unexpected model name for {expected['id']}"
    assert actual["folder"] == expected["folder"], f"Unexpected folder for {expected['id']}"
    assert actual["mode"] == expected["mode"], f"Unexpected mode for {expected['id']}"
    assert actual["tier"] == expected["tier"], f"Unexpected tier for {expected['id']}"
    assert actual["output_subfolder"] == expected["outputSubfolder"], f"Unexpected output subfolder for {expected['id']}"
    assert actual["hugging_face_repo"] == expected["huggingFaceRepo"], f"Unexpected repo for {expected['id']}"
    assert actual["required_relative_paths"] == expected["requiredRelativePaths"], f"Unexpected required files for {expected['id']}"
    assert isinstance(actual["downloaded"], bool), f"downloaded flag is not boolean for {expected['id']}"
    assert isinstance(actual["size_bytes"], int), f"size_bytes is not an int for {expected['id']}"

loaded_model = contract["models"][0]
mismatched_mode = next(
    model["mode"] for model in contract["models"]
    if model["mode"] != loaded_model["mode"]
)

server._current_model = object()
server._current_model_id = loaded_model["id"]

try:
    params = {"text": "manifest smoke test", "mode": mismatched_mode}
    if mismatched_mode == "custom":
        params["voice"] = contract["defaultSpeaker"]
    elif mismatched_mode == "design":
        params["instruct"] = "A calm narrator"
    elif mismatched_mode == "clone":
        params["ref_audio"] = str(root / "README.md")

    try:
        server.handle_generate(params)
        raise AssertionError("Mode mismatch did not raise an error")
    except ValueError as exc:
        assert "does not match loaded model" in str(exc), f"Unexpected mismatch error: {exc}"
finally:
    server._current_model = None
    server._current_model_id = None

print("Shared manifest smoke checks passed.")
PY
