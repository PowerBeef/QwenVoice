#!/usr/bin/env python3
"""Opt-in Gemini-backed evaluation probe for Voice Cloning tone guidance."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from collections.abc import Callable
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from benchmark_generation import (  # noqa: E402
    APP_MODELS_DIR,
    BackendClient,
    MODEL_MANIFEST,
    ensure_directory,
    ensure_model_available,
    prepare_kathleen_reference_assets,
    resolve_backend_python,
    resolve_ffmpeg_binary,
)

HOMEBREW_BIN_DIR = Path("/opt/homebrew/bin")
HOMEBREW_NODE_PATH = HOMEBREW_BIN_DIR / "node"
DEFAULT_GEMINI_BINARY = str(HOMEBREW_BIN_DIR / "gemini")
DEFAULT_GEMINI_MODEL = "gemini-3.1-pro-preview"
GEMINI_MODEL_FALLBACKS: tuple[str, ...] = (
    "gemini-3.1-pro-preview",
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
)
DEFAULT_SCRIPT = "The package is ready at the front desk for pickup."
PROMPT_TEMPLATE_PATH = SCRIPT_DIR / "prompts" / "clone_tone_gemini_prompt.md"
SCHEMA_PATH = SCRIPT_DIR / "prompts" / "clone_tone_response_schema.json"
DEFAULT_OUTPUT_ROOT = SCRIPT_DIR.parent / "build" / "tone-evals"
DEFAULT_MODEL_CACHE_DIR = DEFAULT_OUTPUT_ROOT / "model-cache"

TONE_CASES: tuple[dict[str, Any], ...] = (
    {
        "tone_id": "angry_strong",
        "requested_tone": "angry / strong",
        "instruct": "Furious and intensely angry, sharp and forceful delivery",
        "delivery_profile": {
            "preset_id": "angry",
            "intensity": "strong",
            "final_instruction": "Furious and intensely angry, sharp and forceful delivery",
        },
    },
    {
        "tone_id": "happy_normal",
        "requested_tone": "happy / normal",
        "instruct": "Happy and upbeat tone",
        "delivery_profile": {
            "preset_id": "happy",
            "intensity": "normal",
            "final_instruction": "Happy and upbeat tone",
        },
    },
    {
        "tone_id": "calm_strong",
        "requested_tone": "calm / strong",
        "instruct": "Deeply serene, meditative voice with slow, deliberate pace",
        "delivery_profile": {
            "preset_id": "calm",
            "intensity": "strong",
            "final_instruction": "Deeply serene, meditative voice with slow, deliberate pace",
        },
    },
    {
        "tone_id": "custom_brisk",
        "requested_tone": "custom / brisk energetic promo",
        "instruct": "Brisk, energetic, promo-style delivery with bright emphasis",
        "delivery_profile": {
            "custom_text": "Brisk, energetic, promo-style delivery with bright emphasis",
            "final_instruction": "Brisk, energetic, promo-style delivery with bright emphasis",
        },
    },
)

VALID_ENUMS = {
    "path_kind": {"transcripted", "no_transcript"},
    "relative_contrast": {"stronger", "slightly_stronger", "no_clear_difference", "weaker"},
    "target_match": {"clear", "partial", "poor"},
    "speaker_consistency": {"preserved", "slightly_shifted", "changed"},
    "confidence": {"low", "medium", "high"},
}


@dataclass(frozen=True)
class ToneScenario:
    scenario_id: str
    path_kind: str
    requested_tone: str
    text: str
    ref_audio: str
    ref_text: str | None
    instruct: str
    delivery_profile: dict[str, Any]


@dataclass(frozen=True)
class GeminiEvaluation:
    scenario_id: str
    path_kind: str
    requested_tone: str
    relative_contrast: str
    target_match: str
    speaker_consistency: str
    confidence: str
    passed: bool
    notes: str


class InfrastructureFailure(RuntimeError):
    """Raised when the Gemini judging harness itself is unavailable or malformed."""


class GeminiCLIInfrastructureFailure(InfrastructureFailure):
    """Raised when Gemini judging cannot proceed after retry/fallback handling."""

    def __init__(
        self,
        message: str,
        *,
        failure_reason: str | None = None,
        attempts: list[dict[str, Any]] | None = None,
    ) -> None:
        super().__init__(message)
        self.failure_reason = failure_reason or message
        self.attempts = attempts or []


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default="", help="Override the artifact root directory.")
    parser.add_argument("--python", default="", help="Explicit Python interpreter path for the backend runtime.")
    parser.add_argument(
        "--gemini-binary",
        default=DEFAULT_GEMINI_BINARY,
        help="Explicit Gemini CLI binary path.",
    )
    parser.add_argument("--gemini-model", default=DEFAULT_GEMINI_MODEL, help="Gemini model to use for judging.")
    parser.add_argument(
        "--model-cache-dir",
        default=str(DEFAULT_MODEL_CACHE_DIR),
        help="Cache directory used for linking installed models into the sandbox.",
    )
    return parser.parse_args()


def timestamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def resolve_gemini_binary(preferred_binary: str) -> str:
    gemini_path = Path(preferred_binary).expanduser()
    if not gemini_path.exists():
        raise InfrastructureFailure(
            f"Gemini CLI is not available at {gemini_path}. Install/authenticate Homebrew Gemini before running this probe."
        )
    if not os.access(gemini_path, os.X_OK):
        raise InfrastructureFailure(f"Gemini CLI exists at {gemini_path} but is not executable.")
    if gemini_path.parent == HOMEBREW_BIN_DIR and not HOMEBREW_NODE_PATH.exists():
        raise InfrastructureFailure(
            f"Homebrew Gemini requires {HOMEBREW_NODE_PATH}, but it was not found."
        )
    return str(gemini_path)


def build_gemini_env() -> dict[str, str]:
    env = dict(os.environ)
    current_path = env.get("PATH", "")
    homebrew_prefix = str(HOMEBREW_BIN_DIR)
    if current_path:
        env["PATH"] = f"{homebrew_prefix}:{current_path}"
    else:
        env["PATH"] = homebrew_prefix
    env["NO_COLOR"] = "1"
    env["CI"] = "1"
    return env


def gemini_model_candidates(primary_model: str) -> list[str]:
    candidates = [primary_model]
    for model in GEMINI_MODEL_FALLBACKS:
        if model not in candidates:
            candidates.append(model)
    return candidates


def is_capacity_failure(message: str) -> bool:
    normalized = message.lower()
    markers = (
        "429",
        "model_capacity_exhausted",
        "resource_exhausted",
        "rate limit",
        "too many requests",
    )
    return any(marker in normalized for marker in markers)


def build_scenarios(
    *,
    transcripted_ref_audio: Path,
    transcripted_ref_text: str,
    no_transcript_ref_audio: Path,
    text: str = DEFAULT_SCRIPT,
) -> list[ToneScenario]:
    scenarios: list[ToneScenario] = []
    for path_kind, ref_audio, ref_text in (
        ("transcripted", transcripted_ref_audio, transcripted_ref_text),
        ("no_transcript", no_transcript_ref_audio, None),
    ):
        for tone_case in TONE_CASES:
            scenarios.append(
                ToneScenario(
                    scenario_id=f"{path_kind}_{tone_case['tone_id']}",
                    path_kind=path_kind,
                    requested_tone=tone_case["requested_tone"],
                    text=text,
                    ref_audio=str(ref_audio),
                    ref_text=ref_text,
                    instruct=tone_case["instruct"],
                    delivery_profile=dict(tone_case["delivery_profile"]),
                )
            )
    return scenarios


def neutral_baseline_request(text: str, ref_audio: str, ref_text: str | None) -> dict[str, Any]:
    params: dict[str, Any] = {
        "mode": "clone",
        "text": text,
        "ref_audio": ref_audio,
    }
    if ref_text:
        params["ref_text"] = ref_text
    return params


def guided_request(scenario: ToneScenario) -> dict[str, Any]:
    params = neutral_baseline_request(scenario.text, scenario.ref_audio, scenario.ref_text)
    params["instruct"] = scenario.instruct
    params["delivery_profile"] = scenario.delivery_profile
    return params


def gemini_command(gemini_binary: str, model: str, prompt: str) -> list[str]:
    return [
        gemini_binary,
        "-m",
        model,
        "--yolo",
        "--output-format",
        "json",
        "-p",
        prompt,
    ]


def parse_auth_check(raw_output: str) -> dict[str, Any]:
    payload = extract_json_payload(raw_output)
    if payload.get("ok") is not True:
        raise ValueError("Gemini CLI auth check returned an unexpected response")
    return payload


def extract_json_payload(raw_output: str) -> dict[str, Any]:
    text = raw_output.strip()
    if not text:
        raise ValueError("Gemini CLI returned empty output")

    def try_parse(value: str) -> dict[str, Any] | None:
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None

    parsed = try_parse(text)
    if parsed is not None:
        for wrapper_key in ("response", "text", "content"):
            wrapped = parsed.get(wrapper_key)
            if isinstance(wrapped, str):
                nested = extract_json_payload(wrapped)
                if nested:
                    return nested
        return parsed

    if "```" in text:
        for block in text.split("```"):
            candidate = block.strip()
            if candidate.startswith("json"):
                candidate = candidate[4:].strip()
            parsed = try_parse(candidate)
            if parsed is not None:
                return parsed

    decoder = json.JSONDecoder()
    for index, character in enumerate(text):
        if character != "{":
            continue
        try:
            parsed, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            for wrapper_key in ("response", "text", "content"):
                wrapped = parsed.get(wrapper_key)
                if isinstance(wrapped, str):
                    nested = extract_json_payload(wrapped)
                    if nested:
                        return nested
            return parsed

    raise ValueError("Could not extract a JSON evaluation object from Gemini output")


def parse_gemini_evaluation(raw_output: str) -> GeminiEvaluation:
    payload = extract_json_payload(raw_output)
    required_string_fields = [
        "scenario_id",
        "path_kind",
        "requested_tone",
        "relative_contrast",
        "target_match",
        "speaker_consistency",
        "confidence",
        "notes",
    ]
    for field in required_string_fields:
        value = payload.get(field)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"Gemini evaluation is missing a valid '{field}' value")

    for field, valid_values in VALID_ENUMS.items():
        value = payload[field]
        if value not in valid_values:
            raise ValueError(f"Gemini evaluation field '{field}' must be one of {sorted(valid_values)}")

    passed = payload.get("pass")
    if not isinstance(passed, bool):
        raise ValueError("Gemini evaluation field 'pass' must be a boolean")

    deterministic_pass = (
        payload["relative_contrast"] in {"stronger", "slightly_stronger"}
        and payload["target_match"] in {"clear", "partial"}
        and payload["speaker_consistency"] in {"preserved", "slightly_shifted"}
        and payload["confidence"] != "low"
    )

    return GeminiEvaluation(
        scenario_id=payload["scenario_id"],
        path_kind=payload["path_kind"],
        requested_tone=payload["requested_tone"],
        relative_contrast=payload["relative_contrast"],
        target_match=payload["target_match"],
        speaker_consistency=payload["speaker_consistency"],
        confidence=payload["confidence"],
        passed=deterministic_pass,
        notes=payload["notes"].strip(),
    )


def summarize_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    pass_count = sum(1 for item in results if item["pass"])
    speaker_changed = any(item["speaker_consistency"] == "changed" for item in results)
    overall_pass = pass_count >= 6 and not speaker_changed
    return {
        "scenario_count": len(results),
        "pass_count": pass_count,
        "fail_count": len(results) - pass_count,
        "speaker_changed": speaker_changed,
        "overall_pass": overall_pass,
    }


def write_summary_markdown(
    summary: dict[str, Any],
    results: list[dict[str, Any]],
    judge_backend: dict[str, Any] | None = None,
) -> str:
    lines = [
        "# Voice Cloning Tone Evaluation",
        "",
        f"- Overall pass: {'yes' if summary['overall_pass'] else 'no'}",
        f"- Pass count: {summary['pass_count']} / {summary['scenario_count']}",
        f"- Speaker changed in any scenario: {'yes' if summary['speaker_changed'] else 'no'}",
        "",
    ]
    if judge_backend:
        fallback_order = ", ".join(judge_backend.get("model_fallback_order", [])) or "(none)"
        lines.extend(
            [
                "## Judge Backend",
                "",
                f"- Gemini binary: `{judge_backend.get('binary_path', '(unknown)')}`",
                f"- Homebrew PATH injected: {'yes' if judge_backend.get('homebrew_path_injected') else 'no'}",
                f"- Model fallback order: `{fallback_order}`",
            ]
        )
        auth_model = judge_backend.get("auth_check_model_used")
        if auth_model:
            lines.append(f"- Auth check model used: `{auth_model}`")
        lines.append("")

    lines.extend(
        [
        "| Scenario | Path | Tone | Contrast | Match | Speaker | Confidence | Pass |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for item in results:
        lines.append(
            f"| {item['scenario_id']} | {item['path_kind']} | {item['requested_tone']} | "
            f"{item['relative_contrast']} | {item['target_match']} | {item['speaker_consistency']} | "
            f"{item['confidence']} | {'yes' if item['pass'] else 'no'} |"
        )
    return "\n".join(lines) + "\n"


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def generate_clip(
    client: BackendClient,
    params: dict[str, Any],
    output_path: Path,
) -> dict[str, Any]:
    request = dict(params)
    request["output_path"] = str(output_path)
    response = client.call("generate", request, timeout=900.0)
    result = response["result"]
    actual_output = Path(result["audio_path"])
    if not actual_output.exists():
        raise RuntimeError(f"Expected generated audio file to exist: {actual_output}")
    return response


def assert_guided_backend_result(response: dict[str, Any], scenario_id: str) -> None:
    result = response["result"]
    if not result.get("delivery_instruction_applied"):
        raise RuntimeError(f"{scenario_id}: backend reported delivery_instruction_applied = false")
    if not Path(result["audio_path"]).exists():
        raise RuntimeError(f"{scenario_id}: guided clone output file is missing")


def invoke_gemini_with_fallback(
    *,
    gemini_binary: str,
    primary_model: str,
    prompt: str,
    cwd: Path,
    parser: Callable[[str], Any],
    context_name: str,
) -> tuple[Any, str, dict[str, Any]]:
    env = build_gemini_env()
    attempts: list[dict[str, Any]] = []

    for model in gemini_model_candidates(primary_model):
        command = gemini_command(gemini_binary, model, prompt)
        result = subprocess.run(
            command,
            cwd=str(cwd),
            text=True,
            capture_output=True,
            env=env,
        )
        raw_output = result.stdout.strip()
        failure_reason = result.stderr.strip() or raw_output or f"Gemini CLI exited with status {result.returncode}"
        capacity_failure = result.returncode != 0 and is_capacity_failure(failure_reason)

        attempt_record = {
            "model": model,
            "returncode": result.returncode,
            "capacity_failure": capacity_failure,
        }

        if result.returncode == 0:
            try:
                parsed = parser(raw_output)
            except ValueError as exc:
                attempt_record.update({"status": "malformed_json", "failure_reason": str(exc)})
                attempts.append(attempt_record)
                raise GeminiCLIInfrastructureFailure(
                    f"Gemini CLI returned malformed JSON for {context_name}: {exc}",
                    failure_reason=str(exc),
                    attempts=attempts,
                ) from exc

            attempt_record["status"] = "success"
            attempts.append(attempt_record)
            return (
                parsed,
                raw_output,
                {
                    "gemini_model_used": model,
                    "gemini_attempt_count": len(attempts),
                    "gemini_failure_reason": None,
                    "gemini_attempts": attempts,
                },
            )

        attempt_record.update({"status": "failed", "failure_reason": failure_reason})
        attempts.append(attempt_record)

        if capacity_failure:
            continue

        raise GeminiCLIInfrastructureFailure(
            f"Gemini CLI failed for {context_name}: {failure_reason}",
            failure_reason=failure_reason,
            attempts=attempts,
        )

    last_failure_reason = attempts[-1]["failure_reason"] if attempts else "Unknown Gemini failure"
    raise GeminiCLIInfrastructureFailure(
        f"Gemini CLI exhausted configured judge models for {context_name}: {last_failure_reason}",
        failure_reason=last_failure_reason,
        attempts=attempts,
    )


def validate_gemini_auth(gemini_binary: str, gemini_model: str) -> dict[str, Any]:
    prompt = 'Return exactly this JSON object: {"ok":true}'
    _, _, metadata = invoke_gemini_with_fallback(
        gemini_binary=gemini_binary,
        primary_model=gemini_model,
        prompt=prompt,
        cwd=SCRIPT_DIR,
        parser=parse_auth_check,
        context_name="auth-check",
    )
    return metadata


def evaluate_with_gemini(
    *,
    gemini_binary: str,
    gemini_model: str,
    scenario_dir: Path,
) -> tuple[GeminiEvaluation, str, dict[str, Any]]:
    prompt = PROMPT_TEMPLATE_PATH.read_text(encoding="utf-8")
    evaluation, raw_output, metadata = invoke_gemini_with_fallback(
        gemini_binary=gemini_binary,
        primary_model=gemini_model,
        prompt=prompt,
        cwd=scenario_dir,
        parser=parse_gemini_evaluation,
        context_name=scenario_dir.name,
    )
    return evaluation, raw_output, metadata


def build_judge_backend_summary(
    *,
    gemini_binary: str,
    primary_model: str,
    auth_metadata: dict[str, Any] | None,
    results: list[dict[str, Any]],
) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "binary_path": gemini_binary,
        "homebrew_path_injected": True,
        "model_fallback_order": gemini_model_candidates(primary_model),
        "scenario_models": {
            item["scenario_id"]: item.get("gemini_model_used")
            for item in results
            if item.get("gemini_model_used")
        },
    }
    if auth_metadata:
        summary["auth_check_model_used"] = auth_metadata.get("gemini_model_used")
        summary["auth_check_attempt_count"] = auth_metadata.get("gemini_attempt_count")
    return summary


def main() -> int:
    args = parse_args()
    output_root = Path(args.output_dir) if args.output_dir else DEFAULT_OUTPUT_ROOT / timestamp()
    run_root = ensure_directory(output_root)
    sandbox_root = ensure_directory(run_root / "sandbox")
    app_support_dir = ensure_directory(sandbox_root / "app-support")
    models_dir = ensure_directory(app_support_dir / "models")
    references_dir = ensure_directory(run_root / "references")
    scenarios_root = ensure_directory(run_root / "scenarios")

    client = None
    auth_metadata: dict[str, Any] | None = None
    evaluations: list[dict[str, Any]] = []
    gemini_binary = ""
    try:
        gemini_binary = resolve_gemini_binary(args.gemini_binary)
        auth_metadata = validate_gemini_auth(gemini_binary, args.gemini_model)

        clone_folder = MODEL_MANIFEST["pro_clone"]["folder"]
        if not (APP_MODELS_DIR / clone_folder).exists():
            raise RuntimeError("Voice Cloning model is not installed locally in ~/Library/Application Support/QwenVoice/models.")

        backend_python = resolve_backend_python(args.python)
        ffmpeg_path = resolve_ffmpeg_binary()

        model_state = ensure_model_available(
            "pro_clone",
            Path(args.model_cache_dir),
            models_dir,
            backend_python,
            download_missing=False,
        )
        if not model_state["available"]:
            raise RuntimeError(f"Voice Cloning model is unavailable: {model_state['error']}")

        reference_assets = prepare_kathleen_reference_assets(references_dir, ffmpeg_path)
        transcripted_ref_text = Path(reference_assets["seed_txt"]).read_text(encoding="utf-8").strip()
        scenarios = build_scenarios(
            transcripted_ref_audio=Path(reference_assets["seed_wav"]),
            transcripted_ref_text=transcripted_ref_text,
            no_transcript_ref_audio=Path(reference_assets["no_transcript_wav"]),
        )

        prompt_schema_copy = run_root / "response_schema.json"
        shutil.copy2(SCHEMA_PATH, prompt_schema_copy)

        client = BackendClient(
            backend_python,
            run_root / "rpc-events.jsonl",
            run_root / "backend.log",
            ffmpeg_path,
            "adaptive",
        )

        path_neutral_cache: dict[str, dict[str, Any]] = {}
        client.start()
        client.call("init", {"app_support_dir": str(app_support_dir)}, timeout=120.0)
        client.call("load_model", {"model_id": "pro_clone"}, timeout=900.0)

        for scenario in scenarios:
            path_dir = ensure_directory(scenarios_root / scenario.scenario_id)
            judge_dir = ensure_directory(path_dir / "judge")
            scenario_payload = {
                "scenario_id": scenario.scenario_id,
                "path_kind": scenario.path_kind,
                "requested_tone": scenario.requested_tone,
                "script": scenario.text,
                "ref_audio": scenario.ref_audio,
                "ref_text": scenario.ref_text,
            }
            write_json(path_dir / "scenario.json", scenario_payload)
            write_json(judge_dir / "scenario.json", scenario_payload)
            shutil.copy2(SCHEMA_PATH, judge_dir / "response_schema.json")

            neutral_target = path_dir / "neutral.wav"
            if scenario.path_kind not in path_neutral_cache:
                neutral_response = generate_clip(
                    client,
                    neutral_baseline_request(scenario.text, scenario.ref_audio, scenario.ref_text),
                    neutral_target,
                )
                write_json(path_dir / "neutral_backend.json", neutral_response)
                path_neutral_cache[scenario.path_kind] = {
                    "response": neutral_response,
                    "audio_path": neutral_target,
                }
                cached = path_neutral_cache[scenario.path_kind]
            else:
                cached = path_neutral_cache[scenario.path_kind]
                shutil.copy2(cached["audio_path"], neutral_target)
            write_json(path_dir / "neutral_backend.json", cached["response"])
            shutil.copy2(neutral_target, judge_dir / "neutral.wav")

            guided_output = path_dir / "guided.wav"
            guided_response = generate_clip(client, guided_request(scenario), guided_output)
            assert_guided_backend_result(guided_response, scenario.scenario_id)
            write_json(path_dir / "guided_backend.json", guided_response)
            shutil.copy2(guided_output, judge_dir / "guided.wav")

            try:
                evaluation, raw_output, gemini_metadata = evaluate_with_gemini(
                    gemini_binary=gemini_binary,
                    gemini_model=args.gemini_model,
                    scenario_dir=judge_dir,
                )
            except GeminiCLIInfrastructureFailure as exc:
                write_json(
                    path_dir / "gemini_raw.json",
                    {
                        "attempts": exc.attempts,
                        "gemini_failure_reason": exc.failure_reason,
                        "message": str(exc),
                    },
                )
                raise

            write_json(
                path_dir / "gemini_raw.json",
                {
                    "raw_output": raw_output,
                    **gemini_metadata,
                },
            )
            write_json(
                path_dir / "evaluation.json",
                {
                    **asdict(evaluation),
                    "gemini_model_used": gemini_metadata["gemini_model_used"],
                    "gemini_attempt_count": gemini_metadata["gemini_attempt_count"],
                    "gemini_failure_reason": gemini_metadata["gemini_failure_reason"],
                },
            )

            evaluation_record = {
                **asdict(evaluation),
                "delivery_instruction_applied": guided_response["result"].get("delivery_instruction_applied"),
                "delivery_instruction_strategy": guided_response["result"].get("delivery_instruction_strategy"),
                "delivery_plan_strength": guided_response["result"].get("delivery_plan_strength"),
                "speaker_similarity": guided_response["result"].get("speaker_similarity"),
                "delivery_retry_count": guided_response["result"].get("delivery_retry_count"),
                "delivery_compromised": guided_response["result"].get("delivery_compromised"),
                "guided_audio_path": str(guided_output),
                "neutral_audio_path": str(neutral_target),
                "gemini_model_used": gemini_metadata["gemini_model_used"],
                "gemini_attempt_count": gemini_metadata["gemini_attempt_count"],
                "gemini_failure_reason": gemini_metadata["gemini_failure_reason"],
            }
            evaluations.append(evaluation_record)

        summary = summarize_results(evaluations)
        summary_payload = {
            "judge_backend": build_judge_backend_summary(
                gemini_binary=gemini_binary,
                primary_model=args.gemini_model,
                auth_metadata=auth_metadata,
                results=evaluations,
            ),
            "reference_source": reference_assets["source"],
            "summary": summary,
            "results": evaluations,
        }
        write_json(run_root / "summary.json", summary_payload)
        (run_root / "summary.md").write_text(
            write_summary_markdown(summary, evaluations, summary_payload["judge_backend"]),
            encoding="utf-8",
        )

        print(json.dumps(summary_payload, indent=2, sort_keys=True))
        return 0 if summary["overall_pass"] else 1
    except InfrastructureFailure as exc:
        payload = {
            "failure_kind": "infrastructure",
            "message": str(exc),
            "judge_backend": build_judge_backend_summary(
                gemini_binary=gemini_binary,
                primary_model=args.gemini_model,
                auth_metadata=auth_metadata,
                results=evaluations,
            ),
        }
        write_json(run_root / "summary.json", payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 2
    except Exception as exc:
        payload = {
            "failure_kind": "probe",
            "message": str(exc),
        }
        write_json(run_root / "summary.json", payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 1
    finally:
        if client is not None:
            client.stop()


if __name__ == "__main__":
    raise SystemExit(main())
