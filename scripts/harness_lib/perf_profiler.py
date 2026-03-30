"""Exhaustive performance profiler for the QwenVoice TTS pipeline.

Captures both client-side wall time AND server-side pipeline stage timings
across model modes, text lengths, speakers, and cache states. Produces a
ranked bottleneck analysis at the end.

Intended entry point: ``run_all_tiers(client, runs, tiers, output_dir)``.
"""

from __future__ import annotations

import json
import os
import platform
import subprocess
import tempfile
import time
import urllib.request
import wave
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .contract import load_contract, model_is_installed, speaker_list
from .output import build_suite_result, build_test_result, eprint
from .paths import PROJECT_DIR, ensure_directory
from .stats import summarize_numeric

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TEXT_SHORT = "Hello world."
TEXT_MEDIUM = (
    "The package is ready at the front desk for pickup. "
    "Please bring a valid ID and the confirmation email when you arrive."
)
TEXT_LONG = (
    "Artificial intelligence has rapidly transformed from a niche academic "
    "pursuit into one of the most consequential technologies of the modern "
    "era. Large language models, capable of generating coherent text across "
    "a wide range of domains, have captured the imagination of researchers "
    "and the general public alike. Meanwhile, text-to-speech systems have "
    "reached a point where synthesized voices are often indistinguishable "
    "from natural human speech, opening new possibilities for accessibility, "
    "creative media production, and personalized assistants."
)
TEXT_EXTRA_LONG = (
    "In the early days of computing, speech synthesis was a laboratory "
    "curiosity that produced harsh, robotic voices barely intelligible to "
    "untrained ears. Researchers spent decades refining concatenative "
    "methods, splicing tiny recorded fragments of phonemes together to "
    "approximate natural flow. The results improved steadily, but the "
    "breakthrough arrived with neural network architectures that could learn "
    "acoustic patterns directly from data. Modern systems leverage attention "
    "mechanisms and diffusion models to capture the subtle prosodic "
    "variations, intonation curves, and rhythmic patterns that make human "
    "speech so expressive. Today, a single model can convincingly reproduce "
    "dozens of distinct voices, adjust speaking rate and emotional tone on "
    "demand, and maintain consistent quality across passages of arbitrary "
    "length. This technological leap has profound implications: audiobook "
    "narration, real-time translation, assistive devices for people with "
    "speech impairments, and creative tools for filmmakers and game "
    "developers all stand to benefit enormously."
)

TEXT_BY_LENGTH: dict[str, str] = {
    "short": TEXT_SHORT,
    "medium": TEXT_MEDIUM,
    "long": TEXT_LONG,
    "extra_long": TEXT_EXTRA_LONG,
}

KATHLEEN_BASE_URL = "https://raw.githubusercontent.com/rhasspy/dataset-voice-kathleen/master"
KATHLEEN_STEMS = [
    "data/arctic_a0001_1592748600",
    "data/arctic_a0002_1592748556",
    "data/arctic_a0003_1592748511",
    "data/arctic_a0004_1592748478",
]
APP_STREAMING_INTERVAL = 0.32

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _system_info() -> dict[str, Any]:
    """Gather basic system information for the report."""
    info: dict[str, Any] = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python_version": platform.python_version(),
    }
    # Apple Silicon chip name
    try:
        chip = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True, timeout=5
        ).strip()
        info["chip"] = chip
    except Exception:
        pass
    # Physical memory
    try:
        mem_bytes = int(
            subprocess.check_output(
                ["sysctl", "-n", "hw.memsize"], text=True, timeout=5
            ).strip()
        )
        info["memory_gb"] = round(mem_bytes / (1024**3), 1)
    except Exception:
        pass
    return info


def _first_chunk_ms(notifications: list[dict[str, Any]]) -> float | None:
    """Extract the first generation_chunk notification timestamp."""
    for n in notifications:
        if n.get("method") == "generation_chunk" and "_received_at_ms" in n:
            return n["_received_at_ms"]
    return None


def _extract_benchmark_timings(result: dict[str, Any]) -> dict[str, Any]:
    """Pull benchmark timings dict out of the generate result."""
    bm = result.get("benchmark", {})
    return dict(bm.get("timings_ms", {}))


def _extract_benchmark_flags(result: dict[str, Any]) -> dict[str, Any]:
    """Pull benchmark flag fields out of the generate result."""
    bm = result.get("benchmark", {})
    flags = dict(bm)
    flags.pop("timings_ms", None)
    return flags


def _make_generate_params(
    mode: str,
    text: str,
    output_path: str,
    *,
    voice: str | None = None,
    voice_description: str | None = None,
    ref_audio: str | None = None,
    ref_text: str | None = None,
    stream: bool = True,
    benchmark_label: str | None = None,
) -> dict[str, Any]:
    """Build a generate RPC params dict."""
    params: dict[str, Any] = {
        "text": text,
        "output_path": output_path,
        "benchmark": True,
        "stream": stream,
    }
    if stream:
        params["streaming_interval"] = APP_STREAMING_INTERVAL
    if benchmark_label:
        params["benchmark_label"] = benchmark_label
    if mode == "custom":
        params["voice"] = voice or "vivian"
    elif mode == "design":
        params["instruct"] = voice_description or "A young female speaker with a clear voice"
    elif mode == "clone":
        if ref_audio:
            params["ref_audio"] = ref_audio
        if ref_text:
            params["ref_text"] = ref_text
    return params


def _run_single_generation(
    client: Any,
    params: dict[str, Any],
    timeout: float = 300.0,
) -> dict[str, Any]:
    """Run one generation call and return a structured timing record."""
    rss_before = client.get_process_rss_mb()
    result, notifications = client.call_collecting_notifications_timed(
        "generate", params, timeout=timeout,
    )
    rss_after = client.get_process_rss_mb()

    wall_ms = result.get("_wall_ms", 0.0)
    first_chunk = _first_chunk_ms(notifications)
    server_timings = _extract_benchmark_timings(result)
    server_flags = _extract_benchmark_flags(result)
    server_total = server_timings.get("total_backend", 0)
    rpc_overhead = round(wall_ms - server_total, 2) if server_total else None

    return {
        "wall_ms": wall_ms,
        "first_chunk_ms": first_chunk,
        "rpc_overhead_ms": rpc_overhead,
        "rss_before_mb": rss_before,
        "rss_after_mb": rss_after,
        "server_timings_ms": server_timings,
        "server_flags": server_flags,
        "notification_count": len(notifications),
    }


def _multi_run(
    client: Any,
    params: dict[str, Any],
    runs: int,
    label: str,
    timeout: float = 300.0,
) -> dict[str, Any]:
    """Run a generation scenario multiple times and summarize."""
    records: list[dict[str, Any]] = []
    wall_times: list[float] = []
    first_chunks: list[float] = []

    for i in range(runs):
        eprint(f"    {label} run {i + 1}/{runs}...")
        with tempfile.TemporaryDirectory() as tmp:
            params_copy = dict(params)
            params_copy["output_path"] = os.path.join(tmp, f"perf_{i}.wav")
            try:
                rec = _run_single_generation(client, params_copy, timeout=timeout)
                records.append(rec)
                wall_times.append(rec["wall_ms"])
                if rec["first_chunk_ms"] is not None:
                    first_chunks.append(rec["first_chunk_ms"])
            except Exception as exc:
                records.append({"error": str(exc)})

    summary: dict[str, Any] = {"label": label, "runs": len(records)}
    if wall_times:
        summary["wall_ms"] = summarize_numeric(wall_times)
    if first_chunks:
        summary["first_chunk_ms"] = summarize_numeric(first_chunks)

    # Aggregate server timing keys
    timing_keys: set[str] = set()
    for rec in records:
        timing_keys.update(rec.get("server_timings_ms", {}).keys())
    for key in sorted(timing_keys):
        vals = [
            rec["server_timings_ms"][key]
            for rec in records
            if key in rec.get("server_timings_ms", {})
        ]
        if vals:
            summary[f"server_{key}_ms"] = summarize_numeric([float(v) for v in vals])

    # RSS
    rss_afters = [rec["rss_after_mb"] for rec in records if rec.get("rss_after_mb") is not None]
    if rss_afters:
        summary["rss_after_mb"] = summarize_numeric(rss_afters)

    summary["raw_records"] = records
    return summary


# ---------------------------------------------------------------------------
# Kathleen reference audio for clone benchmarks
# ---------------------------------------------------------------------------

def _download_file(url: str, dest: Path) -> Path:
    ensure_directory(dest.parent)
    with urllib.request.urlopen(url) as resp:
        dest.write_bytes(resp.read())
    return dest


def _concatenate_wav(sources: list[Path], dest: Path) -> Path:
    if not sources:
        raise RuntimeError("No source WAV files")
    frames: list[bytes] = []
    params = None
    for src in sources:
        with wave.open(str(src), "rb") as wf:
            if params is None:
                params = wf.getparams()
            frames.append(wf.readframes(wf.getnframes()))
    with wave.open(str(dest), "wb") as wf:
        wf.setparams(params)  # type: ignore[arg-type]
        for chunk in frames:
            wf.writeframes(chunk)
    return dest


def _prepare_kathleen_reference(work_dir: Path) -> tuple[str, str]:
    """Download Kathleen clips, concatenate, return (wav_path, transcript)."""
    ref_dir = ensure_directory(work_dir / "kathleen_ref")
    clips: list[Path] = []
    transcripts: list[str] = []
    for stem in KATHLEEN_STEMS:
        wav_name = Path(stem).name + ".wav"
        txt_name = Path(stem).name + ".txt"
        wav_path = ref_dir / wav_name
        txt_path = ref_dir / txt_name
        if not wav_path.exists():
            eprint(f"      Downloading {wav_name}...")
            _download_file(f"{KATHLEEN_BASE_URL}/{stem}.wav", wav_path)
        if not txt_path.exists():
            _download_file(f"{KATHLEEN_BASE_URL}/{stem}.txt", txt_path)
        clips.append(wav_path)
        transcripts.append(txt_path.read_text(encoding="utf-8").strip())

    combined_text = " ".join(t for t in transcripts if t)
    seed = _concatenate_wav(clips, ref_dir / "reference_seed.wav")
    return str(seed), combined_text


# ---------------------------------------------------------------------------
# Tier 1: Generation Performance
# ---------------------------------------------------------------------------

def _run_tier1(client: Any, contract: dict, runs: int, work_dir: Path) -> dict[str, Any]:
    """Generation performance across modes, text lengths, speakers, cache, delivery."""
    eprint("  [Tier 1] Generation performance...")
    results: list[dict[str, Any]] = []
    installed = [m for m in contract["models"] if model_is_installed(m["id"])]
    if not installed:
        results.append(build_test_result("tier1_no_models", passed=True, skip_reason="No models installed"))
        return build_suite_result("tier1_generation", results, 0)

    start = time.perf_counter()
    kathleen_ref: tuple[str, str] | None = None

    for model_def in installed:
        mid = model_def["id"]
        mode = model_def["mode"]

        eprint(f"    Loading {mid}...")
        client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)

        # --- 1a: Text length scaling ---
        for length_name, text in TEXT_BY_LENGTH.items():
            label = f"text_{mode}_{length_name}"
            params = _make_generate_params(
                mode, text, "/tmp/placeholder.wav",
                benchmark_label=label,
                ref_audio=None, ref_text=None,
            )
            # For clone mode, set up ref audio
            if mode == "clone":
                if kathleen_ref is None:
                    eprint("    Preparing Kathleen reference audio...")
                    kathleen_ref = _prepare_kathleen_reference(work_dir)
                params["ref_audio"] = kathleen_ref[0]
                params["ref_text"] = kathleen_ref[1]

            summary = _multi_run(client, params, runs, label)
            results.append(build_test_result(label, passed=True, details=summary))

        # --- 1b: Speaker comparison (custom mode only) ---
        if mode == "custom":
            speakers = speaker_list()
            for spk in speakers:
                label = f"speaker_{spk}"
                params = _make_generate_params(
                    "custom", TEXT_MEDIUM, "/tmp/placeholder.wav",
                    voice=spk, benchmark_label=label,
                )
                summary = _multi_run(client, params, runs, label)
                results.append(build_test_result(label, passed=True, details=summary))

        # --- 1c: Streaming vs non-streaming (custom mode) ---
        if mode == "custom":
            for stream_val in (True, False):
                label = f"stream_{stream_val}"
                params = _make_generate_params(
                    "custom", TEXT_MEDIUM, "/tmp/placeholder.wav",
                    stream=stream_val, benchmark_label=label,
                )
                summary = _multi_run(client, params, runs, label)
                results.append(build_test_result(label, passed=True, details=summary))

        # --- 1d: Cache hit vs miss ---
        label_cold = f"cache_cold_{mode}"
        label_warm = f"cache_warm_{mode}"
        params_base = _make_generate_params(
            mode, TEXT_MEDIUM, "/tmp/placeholder.wav",
            benchmark_label=f"cache_{mode}",
        )
        if mode == "clone" and kathleen_ref:
            params_base["ref_audio"] = kathleen_ref[0]
            params_base["ref_text"] = kathleen_ref[1]

        # Cold run (first time)
        summary_cold = _multi_run(client, params_base, 1, label_cold)
        results.append(build_test_result(label_cold, passed=True, details=summary_cold))
        # Warm run (repeat — should hit cache)
        summary_warm = _multi_run(client, params_base, runs, label_warm)
        results.append(build_test_result(label_warm, passed=True, details=summary_warm))

        client.call("unload_model", timeout=30)

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("tier1_generation", results, duration_ms)


# ---------------------------------------------------------------------------
# Tier 2: Model Operations
# ---------------------------------------------------------------------------

def _run_tier2(client: Any, contract: dict, runs: int, work_dir: Path | None = None) -> dict[str, Any]:
    """Model load, switch, and prewarm benchmarks."""
    eprint("  [Tier 2] Model operations...")
    results: list[dict[str, Any]] = []
    installed = [m for m in contract["models"] if model_is_installed(m["id"])]
    if not installed:
        results.append(build_test_result("tier2_no_models", passed=True, skip_reason="No models installed"))
        return build_suite_result("tier2_model_ops", results, 0)

    start = time.perf_counter()
    kathleen_ref: tuple[str, str] | None = None

    # --- 2a: Cold model load (each model) ---
    for model_def in installed:
        mid = model_def["id"]
        load_times: list[float] = []
        rss_before: float | None = None
        rss_after: float | None = None
        server_load: float | None = None
        for i in range(runs):
            eprint(f"    Cold load {mid} run {i + 1}/{runs}...")
            rss_before = client.get_process_rss_mb()
            t0 = time.perf_counter()
            result = client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)
            load_ms = (time.perf_counter() - t0) * 1000
            rss_after = client.get_process_rss_mb()
            load_times.append(load_ms)
            server_load = result.get("benchmark", {}).get("timings_ms", {}).get("load_model_total")
            client.call("unload_model", timeout=30)

        results.append(build_test_result(
            f"cold_load_{mid}",
            passed=True,
            details={
                "load_ms": summarize_numeric(load_times),
                "rss_before_mb": rss_before,
                "rss_after_mb": rss_after,
                "server_load_ms": server_load,
            },
        ))

    # --- 2b: Model switch cost ---
    if len(installed) >= 2:
        switch_times: list[float] = []
        a, b = installed[0], installed[1]
        for i in range(runs):
            eprint(f"    Switch {a['id']} -> {b['id']} run {i + 1}/{runs}...")
            client.call("load_model", {"model_id": a["id"], "benchmark": True}, timeout=120)
            t0 = time.perf_counter()
            client.call("unload_model", timeout=30)
            client.call("load_model", {"model_id": b["id"], "benchmark": True}, timeout=120)
            switch_ms = (time.perf_counter() - t0) * 1000
            switch_times.append(switch_ms)
            client.call("unload_model", timeout=30)

        results.append(build_test_result(
            f"switch_{a['id']}_to_{b['id']}",
            passed=True,
            details={"switch_ms": summarize_numeric(switch_times)},
        ))

    # --- 2c: Prewarm effectiveness ---
    for model_def in installed:
        mid = model_def["id"]
        mode = model_def["mode"]

        # Prepare clone ref if needed
        clone_kwargs: dict[str, str] = {}
        if mode == "clone":
            if kathleen_ref is None and work_dir is not None:
                eprint("    Preparing Kathleen reference audio...")
                kathleen_ref = _prepare_kathleen_reference(work_dir)
            if kathleen_ref:
                clone_kwargs = {"ref_audio": kathleen_ref[0], "ref_text": kathleen_ref[1]}
            else:
                results.append(build_test_result(
                    f"prewarm_{mid}", passed=True,
                    skip_reason="No reference audio for clone prewarm benchmark",
                ))
                continue

        # Without prewarm
        client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)
        no_prewarm_times: list[float] = []
        no_prewarm_records: list[dict[str, Any]] = []
        for i in range(runs):
            eprint(f"    No-prewarm generate {mid} run {i + 1}/{runs}...")
            with tempfile.TemporaryDirectory() as tmp:
                params = _make_generate_params(
                    mode, TEXT_MEDIUM, os.path.join(tmp, "test.wav"),
                    benchmark_label="no_prewarm",
                    **clone_kwargs,
                )
                rec = _run_single_generation(client, params, timeout=300)
                rec["scenario"] = "no_prewarm"
                no_prewarm_records.append(rec)
                no_prewarm_times.append(rec["wall_ms"])
        client.call("unload_model", timeout=30)

        # With prewarm
        client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)
        eprint(f"    Prewarming {mid}...")
        prewarm_params: dict[str, Any] = {"model_id": mid, "mode": mode, "benchmark": True}
        if clone_kwargs:
            prewarm_params["ref_audio"] = clone_kwargs["ref_audio"]
            prewarm_params["ref_text"] = clone_kwargs["ref_text"]
        client.call("prewarm_model", prewarm_params, timeout=120)
        prewarm_times: list[float] = []
        prewarm_records: list[dict[str, Any]] = []
        for i in range(runs):
            eprint(f"    With-prewarm generate {mid} run {i + 1}/{runs}...")
            with tempfile.TemporaryDirectory() as tmp:
                params = _make_generate_params(
                    mode, TEXT_MEDIUM, os.path.join(tmp, "test.wav"),
                    benchmark_label="with_prewarm",
                    **clone_kwargs,
                )
                rec = _run_single_generation(client, params, timeout=300)
                rec["scenario"] = "with_prewarm"
                prewarm_records.append(rec)
                prewarm_times.append(rec["wall_ms"])
        client.call("unload_model", timeout=30)

        no_prewarm_mean = summarize_numeric(no_prewarm_times)["mean"]
        prewarm_mean = summarize_numeric(prewarm_times)["mean"]
        speedup_pct = (
            round((1 - prewarm_mean / max(no_prewarm_mean, 0.01)) * 100, 1)
            if no_prewarm_times and prewarm_times
            else None
        )
        results.append(build_test_result(
            f"prewarm_{mid}",
            passed=True,
            details={
                "no_prewarm_ms": summarize_numeric(no_prewarm_times),
                "with_prewarm_ms": summarize_numeric(prewarm_times),
                "speedup_pct": speedup_pct,
                "raw_records": no_prewarm_records + prewarm_records,
            },
        ))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("tier2_model_ops", results, duration_ms)


# ---------------------------------------------------------------------------
# Tier 3: System-Level Profiling
# ---------------------------------------------------------------------------

def _run_tier3(client: Any, contract: dict, runs: int, work_dir: Path | None = None) -> dict[str, Any]:
    """Memory profiling, cache policy impact, rapid back-to-back stress."""
    eprint("  [Tier 3] System-level profiling...")
    results: list[dict[str, Any]] = []
    installed = [m for m in contract["models"] if model_is_installed(m["id"])]
    if not installed:
        results.append(build_test_result("tier3_no_models", passed=True, skip_reason="No models installed"))
        return build_suite_result("tier3_system", results, 0)

    start = time.perf_counter()
    kathleen_ref: tuple[str, str] | None = None

    def _clone_kwargs_for(mode: str) -> dict[str, str]:
        nonlocal kathleen_ref
        if mode != "clone":
            return {}
        if kathleen_ref is None and work_dir is not None:
            eprint("    Preparing Kathleen reference audio...")
            kathleen_ref = _prepare_kathleen_reference(work_dir)
        if kathleen_ref:
            return {"ref_audio": kathleen_ref[0], "ref_text": kathleen_ref[1]}
        return {}

    # --- 3a: Memory profile per model ---
    for model_def in installed:
        mid = model_def["id"]
        mode = model_def["mode"]
        eprint(f"    Memory profile {mid}...")

        clone_kw = _clone_kwargs_for(mode)
        if mode == "clone" and not clone_kw:
            results.append(build_test_result(
                f"memory_{mid}", passed=True,
                skip_reason="No reference audio for clone memory benchmark",
            ))
            continue

        rss_baseline = client.get_process_rss_mb()
        client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)
        rss_loaded = client.get_process_rss_mb()

        # Generate to measure peak
        with tempfile.TemporaryDirectory() as tmp:
            params = _make_generate_params(
                mode, TEXT_MEDIUM, os.path.join(tmp, "mem.wav"),
                benchmark_label="memory_profile",
                **clone_kw,
            )
            result, _ = client.call_collecting_notifications_timed("generate", params, timeout=300)
        rss_after_gen = client.get_process_rss_mb()
        peak_mem = result.get("benchmark", {}).get("peak_memory_mb")

        client.call("unload_model", timeout=30)
        rss_unloaded = client.get_process_rss_mb()

        results.append(build_test_result(
            f"memory_{mid}",
            passed=True,
            details={
                "rss_baseline_mb": rss_baseline,
                "rss_loaded_mb": rss_loaded,
                "rss_after_generate_mb": rss_after_gen,
                "rss_after_unload_mb": rss_unloaded,
                "peak_memory_mb": peak_mem,
                "model_footprint_mb": round(
                    (rss_loaded or 0) - (rss_baseline or 0), 1
                ) if rss_loaded and rss_baseline else None,
            },
        ))

    # --- 3b: Rapid back-to-back stress (10 generations) ---
    model_def = installed[0]
    mid = model_def["id"]
    mode = model_def["mode"]
    stress_clone_kw = _clone_kwargs_for(mode)
    eprint(f"    Rapid stress test ({mid}, 10 generations)...")
    client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)

    stress_times: list[float] = []
    stress_rss: list[float] = []
    for i in range(10):
        with tempfile.TemporaryDirectory() as tmp:
            params = _make_generate_params(
                mode, TEXT_MEDIUM, os.path.join(tmp, f"stress_{i}.wav"),
                benchmark_label=f"stress_{i}",
                **stress_clone_kw,
            )
            t0 = time.perf_counter()
            client.call_collecting_notifications_timed("generate", params, timeout=300)
            stress_times.append((time.perf_counter() - t0) * 1000)
            rss = client.get_process_rss_mb()
            if rss is not None:
                stress_rss.append(rss)

    client.call("unload_model", timeout=30)

    # Check for degradation: is last-3 avg > first-3 avg by >10%?
    degradation = None
    if len(stress_times) >= 6:
        first3 = sum(stress_times[:3]) / 3
        last3 = sum(stress_times[-3:]) / 3
        degradation = round((last3 / max(first3, 0.01) - 1) * 100, 1)

    # Check for memory leak: is last RSS > first RSS by >5%?
    memory_leak = None
    if len(stress_rss) >= 6:
        memory_leak = round(stress_rss[-1] - stress_rss[0], 1)

    results.append(build_test_result(
        f"stress_{mid}",
        passed=True,
        details={
            "wall_ms": summarize_numeric(stress_times),
            "rss_progression_mb": stress_rss,
            "degradation_pct": degradation,
            "memory_drift_mb": memory_leak,
            "raw_times_ms": [round(t, 1) for t in stress_times],
        },
    ))

    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("tier3_system", results, duration_ms)


# ---------------------------------------------------------------------------
# Tier 4: Clone-Specific Deep Dive
# ---------------------------------------------------------------------------

def _run_tier4(client: Any, contract: dict, runs: int, work_dir: Path) -> dict[str, Any]:
    """Clone-specific profiling: ref audio, context cache, delivery matrix."""
    eprint("  [Tier 4] Clone deep dive...")
    results: list[dict[str, Any]] = []

    clone_model = next(
        (m for m in contract["models"] if m["mode"] == "clone" and model_is_installed(m["id"])),
        None,
    )
    if not clone_model:
        results.append(build_test_result(
            "tier4_no_clone_model", passed=True, skip_reason="Clone model not installed",
        ))
        return build_suite_result("tier4_clone_dive", results, 0)

    start = time.perf_counter()
    mid = clone_model["id"]

    eprint("    Preparing Kathleen reference audio...")
    ref_wav, ref_text = _prepare_kathleen_reference(work_dir)

    eprint(f"    Loading {mid}...")
    client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)

    # --- 4a: Clone context cache behavior ---
    # First generation = cache miss, second = cache hit
    eprint("    Clone context cache test...")
    cache_miss_times: list[float] = []
    cache_hit_times: list[float] = []
    cache_miss_prepare_times: list[float] = []
    cache_hit_prepare_times: list[float] = []

    for i in range(runs):
        # Unload/reload to force cache miss
        if i > 0:
            client.call("unload_model", timeout=30)
            client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)

        with tempfile.TemporaryDirectory() as tmp:
            params = _make_generate_params(
                "clone", TEXT_MEDIUM, os.path.join(tmp, "miss.wav"),
                ref_audio=ref_wav, ref_text=ref_text,
                benchmark_label="cache_miss",
            )
            rec = _run_single_generation(client, params)
            cache_miss_times.append(rec["wall_ms"])
            prepare_ms = rec.get("server_timings_ms", {}).get("prepare_clone_context")
            if prepare_ms is not None:
                cache_miss_prepare_times.append(float(prepare_ms))

        # Second generation with same ref = cache hit
        with tempfile.TemporaryDirectory() as tmp:
            params = _make_generate_params(
                "clone", TEXT_MEDIUM, os.path.join(tmp, "hit.wav"),
                ref_audio=ref_wav, ref_text=ref_text,
                benchmark_label="cache_hit",
            )
            rec = _run_single_generation(client, params)
            cache_hit_times.append(rec["wall_ms"])
            prepare_ms = rec.get("server_timings_ms", {}).get("prepare_clone_context")
            if prepare_ms is not None:
                cache_hit_prepare_times.append(float(prepare_ms))

    results.append(build_test_result(
        "clone_context_cache",
        passed=True,
        details={
            "cache_miss_ms": summarize_numeric(cache_miss_times),
            "cache_hit_ms": summarize_numeric(cache_hit_times),
            "cache_miss_prepare_clone_context_ms": summarize_numeric(cache_miss_prepare_times) if cache_miss_prepare_times else None,
            "cache_hit_prepare_clone_context_ms": summarize_numeric(cache_hit_prepare_times) if cache_hit_prepare_times else None,
            "speedup_pct": round(
                (1 - summarize_numeric(cache_hit_times)["mean"] / max(summarize_numeric(cache_miss_times)["mean"], 0.01)) * 100,
                1,
            ),
        },
    ))

    eprint("    Clone priming effectiveness test...")
    primed_first_times: list[float] = []
    prime_wall_times: list[float] = []
    prime_first_chunk_times: list[float] = []
    repeated_after_prime_times: list[float] = []

    for i in range(runs):
        client.call("unload_model", timeout=30)
        client.call("load_model", {"model_id": mid, "benchmark": True}, timeout=120)

        prime_start = time.perf_counter()
        prime_result = client.call(
            "prime_clone_reference",
            {
                "model_id": mid,
                "ref_audio": ref_wav,
                "ref_text": ref_text,
                "streaming_interval": APP_STREAMING_INTERVAL,
                "benchmark": True,
            },
            timeout=120,
        )
        prime_wall_times.append((time.perf_counter() - prime_start) * 1000)
        prime_first_chunk = (
            prime_result.get("benchmark", {})
            .get("timings_ms", {})
            .get("first_stream_chunk")
        )
        if prime_first_chunk is not None:
            prime_first_chunk_times.append(float(prime_first_chunk))

        with tempfile.TemporaryDirectory() as tmp:
            params = _make_generate_params(
                "clone", TEXT_MEDIUM, os.path.join(tmp, "primed.wav"),
                ref_audio=ref_wav, ref_text=ref_text,
                benchmark_label="primed_first_generate",
            )
            rec = _run_single_generation(client, params)
            primed_first_times.append(rec["wall_ms"])

        with tempfile.TemporaryDirectory() as tmp:
            params = _make_generate_params(
                "clone", TEXT_MEDIUM, os.path.join(tmp, "primed_repeat.wav"),
                ref_audio=ref_wav, ref_text=ref_text,
                benchmark_label="primed_repeat",
            )
            rec = _run_single_generation(client, params)
            repeated_after_prime_times.append(rec["wall_ms"])

    results.append(build_test_result(
        "clone_reference_prime",
        passed=True,
        details={
            "cold_first_generate_ms": summarize_numeric(cache_miss_times),
            "prime_wall_ms": summarize_numeric(prime_wall_times),
            "prime_first_stream_chunk_ms": summarize_numeric(prime_first_chunk_times) if prime_first_chunk_times else None,
            "primed_first_generate_ms": summarize_numeric(primed_first_times),
            "repeated_same_reference_ms": summarize_numeric(repeated_after_prime_times),
            "primed_speedup_pct": round(
                (1 - summarize_numeric(primed_first_times)["mean"] / max(summarize_numeric(cache_miss_times)["mean"], 0.01)) * 100,
                1,
            ),
        },
    ))

    client.call("unload_model", timeout=30)
    duration_ms = int((time.perf_counter() - start) * 1000)
    return build_suite_result("tier4_clone_dive", results, duration_ms)


# ---------------------------------------------------------------------------
# Bottleneck Analysis Engine
# ---------------------------------------------------------------------------

def analyze_bottlenecks(tier_results: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Aggregate timing breakdowns and identify top bottlenecks."""
    # Collect all server_timings from all tier results
    all_timings: list[dict[str, float]] = []
    all_wall_times: list[float] = []

    for tier_name, suite in tier_results.items():
        for result in suite.get("results", []):
            details = result.get("details", {})
            # From multi-run records
            for rec in details.get("raw_records", []):
                if isinstance(rec, dict) and "server_timings_ms" in rec and "wall_ms" in rec:
                    all_timings.append(rec["server_timings_ms"])
                    all_wall_times.append(rec["wall_ms"])

            if details and not details.get("raw_records"):
                summary_timings = {
                    key.removeprefix("server_").removesuffix("_ms"): value.get("mean")
                    for key, value in details.items()
                    if key.startswith("server_")
                    and key.endswith("_ms")
                    and isinstance(value, dict)
                    and value.get("mean") is not None
                }
                wall_summary = details.get("wall_ms")
                if summary_timings:
                    all_timings.append(summary_timings)
                    if isinstance(wall_summary, dict) and wall_summary.get("mean") is not None:
                        all_wall_times.append(float(wall_summary["mean"]))

    if not all_timings:
        return {"top_bottlenecks": [], "recommendations": ["No timing data collected."]}

    # Aggregate by timing component
    component_totals: dict[str, list[float]] = {}
    for t in all_timings:
        for key, val in t.items():
            if isinstance(val, (int, float)) and val >= 0:
                component_totals.setdefault(key, []).append(float(val))

    avg_wall = sum(all_wall_times) / len(all_wall_times) if all_wall_times else 1.0

    # Compute average contribution and % of wall time
    components: list[dict[str, Any]] = []
    for key, vals in component_totals.items():
        avg = sum(vals) / len(vals)
        pct = round(avg / max(avg_wall, 0.01) * 100, 1)
        components.append({
            "component": key,
            "avg_ms": round(avg, 1),
            "avg_pct_of_wall": pct,
            "sample_count": len(vals),
            "max_ms": round(max(vals), 1),
        })

    # Sort by average time descending
    components.sort(key=lambda c: c["avg_ms"], reverse=True)

    # Top-3 bottlenecks
    top = components[:3]
    for i, c in enumerate(top):
        c["rank"] = i + 1

    # Generate recommendations
    recommendations: list[str] = []
    for c in top:
        name = c["component"]
        pct = c["avg_pct_of_wall"]
        if name == "generation" and pct > 50:
            recommendations.append(
                f"MLX inference ({name}) is {pct}% of wall time — "
                "optimization should focus on model quantization, batch size, or KV cache."
            )
        elif name == "total_backend" and pct > 90:
            recommendations.append(
                "Server-side processing dominates wall time — RPC overhead is minimal."
            )
        elif name == "normalize_reference" and pct > 10:
            recommendations.append(
                f"Reference audio normalization ({pct}% of wall time) — "
                "consider pre-normalizing reference audio or caching normalized versions."
            )
        elif name == "prepare_clone_context" and pct > 15:
            recommendations.append(
                f"Clone context preparation ({pct}% of wall time) — "
                "ensure context caching is working; check cache hit rates."
            )
        elif name == "write_output" and pct > 5:
            recommendations.append(
                f"Output writing ({pct}% of wall time) — "
                "consider async writes or memory-mapped I/O for large files."
            )
        elif c["avg_ms"] > 100:
            recommendations.append(
                f"{name} averages {c['avg_ms']:.0f}ms ({pct}% of wall time)."
            )

    # Detect anomalies — any component where max > 2× median
    anomalies: list[dict[str, Any]] = []
    for key, vals in component_totals.items():
        if len(vals) < 3:
            continue
        sorted_vals = sorted(vals)
        median = sorted_vals[len(sorted_vals) // 2]
        max_val = max(vals)
        if median > 0 and max_val > 2 * median:
            anomalies.append({
                "component": key,
                "median_ms": round(median, 1),
                "max_ms": round(max_val, 1),
                "ratio": round(max_val / median, 1),
            })

    # RPC overhead analysis
    rpc_overheads: list[float] = [
        rec.get("rpc_overhead_ms", 0)
        for suite in tier_results.values()
        for result in suite.get("results", [])
        for rec in result.get("details", {}).get("raw_records", [])
        if isinstance(rec, dict) and rec.get("rpc_overhead_ms") is not None
    ]

    return {
        "top_bottlenecks": top,
        "all_components": components,
        "anomalies": anomalies,
        "recommendations": recommendations,
        "rpc_overhead_ms": summarize_numeric(rpc_overheads) if rpc_overheads else None,
        "total_samples": len(all_timings),
        "avg_wall_ms": round(avg_wall, 1),
    }


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

TIER_RUNNERS = {
    "1": "tier1",
    "2": "tier2",
    "3": "tier3",
    "4": "tier4",
}


def run_all_tiers(
    client: Any,
    runs: int = 3,
    tiers: str = "all",
    output_dir: str | Path | None = None,
) -> dict[str, Any]:
    """Run the specified profiler tiers and return the full result envelope.

    Args:
        client: A started BackendClient instance.
        runs: Repetitions per scenario.
        tiers: Comma-separated tier numbers, or "all".
        output_dir: Directory for results JSON.  Created if needed.

    Returns:
        Full results dict including tiers and bottleneck analysis.
    """
    contract = load_contract()

    if tiers == "all":
        selected = ["1", "2", "3", "4"]
    else:
        selected = [t.strip() for t in tiers.split(",")]

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = Path(output_dir) if output_dir else PROJECT_DIR / "build" / "benchmarks" / timestamp
    ensure_directory(out_dir)
    work_dir = ensure_directory(out_dir / "_work")

    eprint(f"==> Performance profiler — tiers: {','.join(selected)}, runs: {runs}")
    eprint(f"    Output: {out_dir}")

    # Init backend
    client.call("init", timeout=30)

    tier_results: dict[str, dict[str, Any]] = {}

    if "1" in selected:
        tier_results["tier1_generation"] = _run_tier1(client, contract, runs, work_dir)
    if "2" in selected:
        tier_results["tier2_model_ops"] = _run_tier2(client, contract, runs, work_dir)
    if "3" in selected:
        tier_results["tier3_system"] = _run_tier3(client, contract, runs, work_dir)
    if "4" in selected:
        tier_results["tier4_clone_dive"] = _run_tier4(client, contract, runs, work_dir)

    # Bottleneck analysis
    eprint("  Analyzing bottlenecks...")
    bottleneck = analyze_bottlenecks(tier_results)

    full_result = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "system": _system_info(),
        "config": {"runs": runs, "tiers": selected},
        "tiers": tier_results,
        "bottleneck_analysis": bottleneck,
    }

    # Save results
    results_path = out_dir / "perf_results.json"
    results_path.write_text(json.dumps(full_result, indent=2, default=str), encoding="utf-8")
    eprint(f"  Results saved to {results_path}")

    return full_result
