#!/usr/bin/env python3
"""Capture curated README screenshots for the GitHub landing page."""

from __future__ import annotations

import argparse
import math
import sys
import time
import wave
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from harness_lib.paths import PROJECT_DIR
from harness_lib.ui_state_client import UIStateClient, UIStateClientError
from harness_lib.ui_test_support import (
    build_ui_launch_environment,
    cleanup_ui_app_target,
    cleanup_ui_launch_context,
    kill_running_app_instances,
    launch_ui_app,
    prepare_ui_launch_context,
    resolve_ui_app_target,
)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Refresh repo-tracked README screenshots.")
    parser.add_argument(
        "--app-bundle",
        default=None,
        help="Optional explicit QwenVoice.app bundle to launch instead of building the current checkout.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(PROJECT_DIR / "docs" / "screenshots"),
        help="Directory where the README screenshots should be written.",
    )
    return parser


def _create_reference_wav(path: Path, *, duration_seconds: float = 1.0, sample_rate: int = 24_000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frequency = 440.0
    amplitude = 0.25
    frame_count = int(sample_rate * duration_seconds)

    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        for index in range(frame_count):
            sample = amplitude * math.sin(2 * math.pi * frequency * (index / sample_rate))
            wav_file.writeframesraw(int(sample * 32767).to_bytes(2, byteorder="little", signed=True))


def _wait_for_seed(client: UIStateClient, scenario: dict, timeout: float = 5.0) -> dict:
    expected = scenario["expected_state"]
    screen_id = scenario["screen_id"]

    matched, state = client.wait_for_state(
        lambda snapshot: (
            snapshot.get("activeScreen") == screen_id
            and snapshot.get("isGenerating") is False
            and all(snapshot.get(key) == value for key, value in expected.items())
        ),
        timeout=timeout,
        interval=0.05,
    )
    if not matched:
        raise RuntimeError(
            f"Seeded state for {scenario['name']} did not settle. "
            f"Expected {expected}, got {state}."
        )
    return state


def _capture_scenario(client: UIStateClient, scenario: dict, output_dir: Path) -> None:
    try:
        state = client.navigate(scenario["screen"])
    except UIStateClientError as exc:
        raise RuntimeError(f"Navigation to {scenario['screen']} failed: {exc.detail}") from exc

    if state.get("activeScreen") != scenario["screen_id"]:
        navigated, nav_state = client.wait_for_navigation(scenario["screen_id"], timeout=5)
        state = nav_state or state
        if not navigated or state.get("activeScreen") != scenario["screen_id"]:
            raise RuntimeError(
                f"Navigation did not reach {scenario['screen_id']} for {scenario['name']}. "
                f"Last state: {state}"
            )

    try:
        client.seed_screen(scenario["screen"], **scenario["seed_kwargs"])
    except UIStateClientError as exc:
        raise RuntimeError(f"Seeding {scenario['screen']} failed: {exc.detail}") from exc

    _wait_for_seed(client, scenario)
    time.sleep(0.2)

    capture_state = client.capture_screenshot(scenario["name"])
    if not capture_state.get("screenshotCaptured"):
        raise RuntimeError(
            f"Screenshot capture failed for {scenario['name']}: "
            f"{capture_state.get('screenshotFailureReason')}"
        )

    image_path = output_dir / f"{scenario['name']}.png"
    if not image_path.exists() or image_path.stat().st_size == 0:
        raise RuntimeError(f"Expected screenshot file was not written: {image_path}")


def main() -> int:
    args = _build_parser().parse_args()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    context = prepare_ui_launch_context(backend_mode="stub")
    target = None
    app_proc = None

    reference_audio_path = context.app_support_dir / "fixtures" / "readme-reference.wav"
    _create_reference_wav(reference_audio_path)

    scenarios = [
        {
            "name": "readme_custom_voice",
            "screen": "customVoice",
            "screen_id": "screen_customVoice",
            "seed_kwargs": {
                "speaker": "serena",
                "emotion": "Happy and upbeat tone",
                "text": "Welcome to QwenVoice. Everything runs locally on your Mac.",
            },
            "expected_state": {
                "selectedSpeaker": "serena",
                "emotion": "Happy and upbeat tone",
                "text": "Welcome to QwenVoice. Everything runs locally on your Mac.",
            },
        },
        {
            "name": "readme_voice_design",
            "screen": "voiceDesign",
            "screen_id": "screen_voiceDesign",
            "seed_kwargs": {
                "voice_description": "A warm documentary narrator with crisp consonants and steady pacing.",
                "emotion": "Calm, soothing, and reassuring",
                "text": "Tonight's report follows a team rebuilding speech tools for fully offline use.",
            },
            "expected_state": {
                "voiceDescription": "A warm documentary narrator with crisp consonants and steady pacing.",
                "emotion": "Calm, soothing, and reassuring",
                "text": "Tonight's report follows a team rebuilding speech tools for fully offline use.",
            },
        },
        {
            "name": "readme_voice_cloning",
            "screen": "voiceCloning",
            "screen_id": "screen_voiceCloning",
            "seed_kwargs": {
                "reference_audio_path": str(reference_audio_path),
                "reference_transcript": "This is the saved reference line used for the clone.",
                "text": "Thanks for listening. We'll be back with another update tomorrow morning.",
            },
            "expected_state": {
                "referenceAudioPath": str(reference_audio_path),
                "referenceTranscript": "This is the saved reference line used for the clone.",
                "text": "Thanks for listening. We'll be back with another update tomorrow morning.",
            },
        },
    ]

    for scenario in scenarios:
        image_path = output_dir / f"{scenario['name']}.png"
        image_path.unlink(missing_ok=True)

    try:
        success, target, details = resolve_ui_app_target(app_bundle=args.app_bundle)
        if not success or target is None:
            raise RuntimeError(f"Could not resolve app target: {details}")

        kill_running_app_instances()
        env = build_ui_launch_environment(context, screenshot_dir=str(output_dir))
        env["QWENVOICE_UI_TEST_WINDOW_SIZE"] = "1280x820"
        app_proc = launch_ui_app(str(target.app_binary), env, initial_screen="customVoice")

        client = UIStateClient()
        ready, state, failure_reason = client.wait_for_ready(timeout=20, ready_field="isReady")
        if not ready:
            raise RuntimeError(
                f"App did not become ready for README capture. "
                f"failure_reason={failure_reason}, state={state}"
            )

        for scenario in scenarios:
            _capture_scenario(client, scenario, output_dir)

        return 0
    finally:
        if app_proc is not None and app_proc.poll() is None:
            app_proc.terminate()
            try:
                app_proc.wait(timeout=5)
            except Exception:
                app_proc.kill()
        kill_running_app_instances()
        cleanup_ui_app_target(target)
        cleanup_ui_launch_context(context)


if __name__ == "__main__":
    raise SystemExit(main())
