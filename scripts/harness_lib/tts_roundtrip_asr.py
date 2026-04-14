#!/usr/bin/env python3
"""Offline ASR helper for the TTS round-trip harness benchmark."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _resolve_model(candidates: list[str]) -> str:
    try:
        from huggingface_hub import snapshot_download
    except Exception as exc:  # pragma: no cover - exercised through harness subprocess
        raise RuntimeError(f"huggingface_hub is unavailable: {exc}") from exc

    checked: list[str] = []
    for candidate in candidates:
        normalized = candidate.strip()
        if not normalized:
            continue
        checked.append(normalized)

        local_path = Path(normalized).expanduser()
        if local_path.exists():
            return str(local_path)

        if "/" not in normalized:
            continue

        try:
            return snapshot_download(normalized, local_files_only=True)
        except Exception:
            continue

    checked_display = ", ".join(checked) if checked else "<none>"
    raise RuntimeError(
        "No locally installed ASR evaluator was found. Checked: "
        f"{checked_display}"
    )


def _transcribe_files(model_path: str, files: list[str]) -> dict[str, str]:
    try:
        from mlx_audio.stt import load
    except Exception as exc:  # pragma: no cover - exercised through harness subprocess
        raise RuntimeError(f"mlx_audio STT is unavailable: {exc}") from exc

    model = load(model_path)
    transcripts: dict[str, str] = {}
    for audio_path in files:
        result = model.generate(audio_path, verbose=False)
        text = getattr(result, "text", None)
        transcripts[audio_path] = text if isinstance(text, str) else str(result)
    return transcripts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request-json", required=True)
    parser.add_argument("--output-json", required=True)
    args = parser.parse_args()

    request = json.loads(Path(args.request_json).read_text(encoding="utf-8"))
    files = [str(item) for item in request.get("files", [])]
    candidates = [str(item) for item in request.get("model_candidates", [])]

    try:
        resolved_model = _resolve_model(candidates)
        payload = {
            "resolved_model": resolved_model,
            "transcripts": _transcribe_files(resolved_model, files),
        }
    except RuntimeError as exc:
        sys.stderr.write(str(exc) + "\n")
        return 2
    except Exception as exc:
        sys.stderr.write(f"ASR evaluation failed: {exc}\n")
        return 1

    Path(args.output_json).write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
