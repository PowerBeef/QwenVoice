import sys
import os
import tempfile
import shutil
import io
import json
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import summarize_generation_telemetry as sgt


def test_load_merged_runs_frontend_overhead():
    """Merged rows join app TTFC with engine first-chunk mark and compute overhead."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "generations-merged.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(fixture_path, os.path.join(tmp, "generations-merged.jsonl"))
        runs = sgt.load_merged_runs(tmp)
        assert len(runs) == 3
        run1 = next(r for r in runs if r["generationID"] == "gen-merged-001")
        assert run1["appTTFCMS"] == 450
        assert run1["engineFirstChunkMS"] == 380
        assert run1["engineServiceFirstChunkMS"] == 390
        assert run1["frontendOverheadMS"] == 70
        run2 = next(r for r in runs if r["generationID"] == "gen-merged-002")
        assert run2["frontendOverheadMS"] == 100
        run3 = next(r for r in runs if r["generationID"] == "gen-merged-003")
        assert "frontendOverheadMS" not in run3


def test_merged_table_cli(monkeypatch):
    """The --merged flag prints the cross-layer first-chunk latency table."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    merged_fixture = os.path.join(os.path.dirname(__file__), "fixtures", "generations-merged.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))
        shutil.copy(merged_fixture, os.path.join(tmp, "generations-merged.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp, "--merged"])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "Cross-layer first-chunk latency" in text
        assert "gen-merged-001" in text
        assert "gen-merged-002" in text
        assert "frontendOverheadMS" in text
        # gen-merged-001: 450 - 380 = 70
        assert "70" in text


def test_iqr_basic():
    assert sgt.iqr([1, 2, 3, 4, 5, 6, 7]) == 4.0


def test_iqr_even_length():
    assert sgt.iqr([1, 2, 3, 4, 5, 6, 7, 8]) == 4.0


def test_iqr_insufficient_values():
    assert sgt.iqr([42]) is None
    assert sgt.iqr([]) is None


def test_iqr_filters_non_numeric():
    assert sgt.iqr([1, 2, "noise", 3, 4, None]) == 2.0


def test_iqr_zero_spread():
    assert sgt.iqr([5, 5, 5, 5]) == 0.0


def test_mad_basic():
    vals = [1, 2, 3, 4, 5]
    assert sgt.mad(vals) == 1.0


def test_mad_empty():
    assert sgt.mad([]) is None


def test_mad_filters_non_numeric():
    assert sgt.mad([1, 2, "x", 3, 4]) == 1.0


def test_reject_outliers():
    vals = [1.0, 2.0, 3.0, 4.0, 5.0, 100.0]
    filtered = sgt.reject_outliers(vals)
    assert 100.0 not in filtered
    assert filtered == [1.0, 2.0, 3.0, 4.0, 5.0]


def test_reject_outliers_custom_factor():
    vals = [1.0, 2.0, 3.0, 4.0, 5.0, 100.0]
    # A very wide factor keeps the extreme value inside the fence.
    assert 100.0 in sgt.reject_outliers(vals, factor=100.0)


def test_reject_outliers_too_few():
    vals = [1.0, 2.0, 3.0]
    assert sgt.reject_outliers(vals) == vals


def test_reject_outliers_minimum_four():
    # With exactly 4 samples the upper quartile includes the extreme value, so the
    # Tukey fence engulfs it; the function should still run without error and return
    # the sorted input unchanged.
    vals = [1.0, 2.0, 3.0, 100.0]
    assert sgt.reject_outliers(vals) == sorted(vals)


def test_reject_outliers_zero_iqr():
    vals = [5.0, 5.0, 5.0, 5.0, 5.0, 100.0]
    filtered = sgt.reject_outliers(vals)
    # Zero IQR collapses the fence to Q1 == Q3, so the non-equal value is rejected.
    assert 100.0 not in filtered


def test_show_variance_integration(monkeypatch):
    """Run the summarizer end-to-end with --show-variance and verify columns appear."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp, "--show-variance"])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "RTF_IQR" in text
        assert "physFoot_IQR" in text


def test_default_table_without_variance(monkeypatch):
    """The default table must not include variance columns."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "RTF_IQR" not in text
        assert "physFoot_IQR" not in text


def test_chunk_timeline_first_chunk_arrival():
    """chunkTimeline aggregates are extracted and firstChunkArrivalMS is correct."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-001")
        assert run["firstChunkArrivalMS"] == 12
        assert run["chunkCount"] == 4
        assert run["medianInterChunkMS"] == 33


def test_chunk_timeline_table(monkeypatch):
    """The chunk-timeline summary table appears only when chunkTimeline data exists."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "Chunk timeline summary" in text
        assert "firstChunkMS" in text
        assert "medianInterChunkMS" in text
        assert "codePred" in text
        assert "audioDecoder" in text


def test_chunk_timeline_substage_medians():
    """Per-chunk substage medians are extracted correctly."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-001")
        assert run["chunk_talkerForwardMS"] == 10.5
        assert run["chunk_codePredictorMS"] == 20.5
        assert run["chunk_streamStepEvalMS"] == 5.5
        assert run["chunk_audioDecoderMS"] == 2


def test_chunk_timeline_single_chunk():
    """A single-chunk timeline has no inter-chunk interval."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-004")
        assert run["chunkCount"] == 1
        assert run["firstChunkArrivalMS"] == 18
        assert run["medianInterChunkMS"] is None


def test_chunk_timeline_empty_list():
    """An empty chunkTimeline list leaves all chunk aggregates as None."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-005")
        assert run["chunkCount"] is None
        assert run["firstChunkArrivalMS"] is None
        assert run["medianInterChunkMS"] is None
        assert run["chunk_talkerForwardMS"] is None
        assert run["chunk_codePredictorMS"] is None
        assert run["chunk_streamStepEvalMS"] is None
        assert run["chunk_audioDecoderMS"] is None


def test_chunk_timeline_missing_substage_keys():
    """Missing substage keys in some chunks do not silently default to 0."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-006")
        # talkerForwardMS is present in only one chunk; if it defaulted to 0 for the
        # missing chunk the median would be 10, so 20 proves the omission is honored.
        assert run["chunk_talkerForwardMS"] == 20
        assert run["chunk_codePredictorMS"] == 41
        assert run["chunk_streamStepEvalMS"] == 10.5
        assert run["chunk_audioDecoderMS"] == 5.5


def test_chunk_timeline_cell_level_aggregation(monkeypatch):
    """Multiple runs in the same cell are aggregated by median in the printed table."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        chunk_section = text.split("Chunk timeline summary", 1)[1].split("\n\nRTF =")[0]
        warm_short_line = [
            line for line in chunk_section.splitlines()
            if "custom" in line and "warm" in line and "short" in line
        ]
        assert len(warm_short_line) == 1
        # gen-chunk-001 (12 ms) and gen-chunk-004 (18 ms) share custom/4bit/warm/short.
        assert "15" in warm_short_line[0]
        assert "33" in warm_short_line[0]


def test_aggregate_runs_streams_and_summarizes():
    """aggregate_runs streams JSONL and returns per-run rows + finalized cell summaries."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs, cells, delivery_cells, _ = sgt.aggregate_runs(tmp)
        assert len(runs) == 4
        assert not delivery_cells

        key_4bit_warm_short = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "short")
        assert key_4bit_warm_short in cells
        summary = cells[key_4bit_warm_short]
        assert summary["n"] == 1
        assert summary["rtf"] == 1.05
        assert summary["tokps"] == 1550.0
        assert summary["decodeLoopMS"] == 210
        assert summary["peakGpuMB"] == 3000
        assert summary["physFootMB"] == 4050
        assert summary["qcVerdict"] == "pass"

        key_8bit_warm_medium = ("custom", "Qwen3-TTS-12Hz-1.7B-8bit", "warm", "medium")
        assert key_8bit_warm_medium in cells
        summary = cells[key_8bit_warm_medium]
        assert summary["n"] == 2
        assert summary["rtf"] == 0.935  # median of 0.92 and 0.95
        assert summary["trims"] == 0.5  # median of 0 and 1
        assert summary["worstTrim"] == "softTrim"
        assert summary["qcVerdict"] == "warn:clipping"


def test_aggregate_runs_chunk_cells():
    """Chunk-timeline substages are aggregated into chunkSubstageMS medians."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs, cells, _, _ = sgt.aggregate_runs(tmp)
        key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "short")
        summary = cells[key]
        assert summary["n"] == 2
        assert summary["chunkCount"] == 2.5  # counts 4 and 1
        assert summary["firstChunkArrivalMS"] == 15.0  # median of 12 and 18
        assert summary["medianInterChunkMS"] == 33  # both have 33
        cs = summary["chunkSubstageMS"]
        assert cs["talkerForwardMS"] == 11.75
        assert cs["codePredictorMS"] == 22.25
        assert cs["streamStepEvalMS"] == 6.25
        assert cs["audioDecoderMS"] == 2.5


def test_cell_accumulator_worst_qc():
    """finalize reports the worst QC verdict and the flags that tripped it."""
    acc = sgt.CellAccumulator(key=("custom", "model", "warm", "short"))
    acc.add_run({"qcVerdict": "pass", "qcFlags": []})
    acc.add_run({"qcVerdict": "warn", "qcFlags": ["clipping:0.02"]})
    acc.add_run({"qcVerdict": "pass", "qcFlags": []})
    summary = acc.finalize()
    assert summary["qcVerdict"] == "warn:clipping"


def test_cell_accumulator_trim_severity():
    """finalize reports the worst trim level seen in the cell."""
    acc = sgt.CellAccumulator(key=("custom", "model", "warm", "short"))
    acc.add_run({"trims": 1, "worstTrim": "softTrim"})
    acc.add_run({"trims": 2, "worstTrim": "hardTrim"})
    summary = acc.finalize()
    assert summary["worstTrim"] == "hardTrim"
    assert summary["trims"] == 1.5


def test_aggregate_runs_delivery_cells():
    """Rows with a non-empty delivery id are aggregated into delivery_cells."""
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        with open(os.path.join(engine_dir, "generations.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({
                "generationID": "gen-d1",
                "mode": "custom",
                "modelID": "Qwen3-TTS-12Hz-1.7B-4bit",
                "warmState": "warm",
                "notes": {"delivery": "instruct-demo", "deviceClass": "mid16GBMac"},
                "derivedMetrics": {"audioSecondsPerWallSecond": 1.0, "tokensPerSecond": 1000.0},
                "timingsMS": {"qwen_token_loop_total": 200},
                "summary": {"physFootprintPeakMB": 3000, "stageMarks": []},
                "mlxMemoryByStage": {},
                "audioQC": {"verdict": "pass", "flags": []},
            }) + "\n")
            f.write(json.dumps({
                "generationID": "gen-d2",
                "mode": "custom",
                "modelID": "Qwen3-TTS-12Hz-1.7B-4bit",
                "warmState": "warm",
                "notes": {"delivery": "instruct-demo", "deviceClass": "mid16GBMac"},
                "derivedMetrics": {"audioSecondsPerWallSecond": 1.2, "tokensPerSecond": 1200.0},
                "timingsMS": {"qwen_token_loop_total": 180},
                "summary": {"physFootprintPeakMB": 3200, "stageMarks": []},
                "mlxMemoryByStage": {},
                "audioQC": {"verdict": "pass", "flags": []},
            }) + "\n")

        runs, cells, delivery_cells, _ = sgt.aggregate_runs(tmp)
        assert len(runs) == 2
        assert not cells
        key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "instruct-demo")
        assert key in delivery_cells
        summary = delivery_cells[key]
        assert summary["delivery"] == "instruct-demo"
        assert summary["lenBucket"] is None
        assert summary["n"] == 2
        assert summary["rtf"] == 1.1
        assert summary["physFootMB"] == 3100


def test_aggregate_runs_skips_non_success_finish_reason():
    """Failed/superseded/cancelled engine rows are omitted from medians."""
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        base = {
            "mode": "custom",
            "modelID": "Qwen3-TTS-12Hz-1.7B-4bit",
            "warmState": "warm",
            "notes": {"deviceClass": "mid16GBMac", "promptChars": "35"},
            "derivedMetrics": {"audioSecondsPerWallSecond": 1.0, "tokensPerSecond": 1000.0},
            "timingsMS": {"qwen_token_loop_total": 200},
            "summary": {"physFootprintPeakMB": 3000, "stageMarks": []},
            "mlxMemoryByStage": {},
            "audioQC": {"verdict": "pass", "flags": []},
        }
        with open(os.path.join(engine_dir, "generations.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({**base, "generationID": "gen-ok", "finishReason": "eos"}) + "\n")
            f.write(json.dumps({**base, "generationID": "gen-fail", "finishReason": "failed",
                                "derivedMetrics": {"audioSecondsPerWallSecond": 9.9,
                                                   "tokensPerSecond": 9999.0}}) + "\n")
            f.write(json.dumps({**base, "generationID": "gen-super", "finishReason": "superseded",
                                "derivedMetrics": {"audioSecondsPerWallSecond": 8.8,
                                                   "tokensPerSecond": 8888.0}}) + "\n")

        runs, cells, _, skipped = sgt.aggregate_runs(tmp)
        assert skipped == 2
        assert len(runs) == 1
        assert runs[0]["generationID"] == "gen-ok"
        key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "short")
        assert cells[key]["rtf"] == 1.0
        assert cells[key]["n"] == 1


def test_load_runs_skips_non_success_finish_reason():
    """load_runs applies the same finishReason filter as aggregate_runs."""
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        with open(os.path.join(engine_dir, "generations.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({
                "generationID": "gen-ok",
                "mode": "custom",
                "modelID": "Qwen3-TTS-12Hz-1.7B-4bit",
                "warmState": "warm",
                "finishReason": "completed",
                "notes": {"deviceClass": "mid16GBMac"},
                "derivedMetrics": {},
                "timingsMS": {},
                "summary": {"stageMarks": []},
                "mlxMemoryByStage": {},
                "audioQC": {"verdict": "pass", "flags": []},
            }) + "\n")
            f.write(json.dumps({
                "generationID": "gen-cancel",
                "mode": "custom",
                "modelID": "Qwen3-TTS-12Hz-1.7B-4bit",
                "warmState": "warm",
                "finishReason": "cancelled",
                "notes": {"deviceClass": "mid16GBMac"},
                "derivedMetrics": {},
                "timingsMS": {},
                "summary": {"stageMarks": []},
                "mlxMemoryByStage": {},
                "audioQC": {"verdict": "pass", "flags": []},
            }) + "\n")

        runs = sgt.load_runs(tmp)
        assert [r["generationID"] for r in runs] == ["gen-ok"]


def test_emit_ledger_row_with_table(monkeypatch):
    """--emit-ledger-row prints the full table plus a ledger marker and row."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        monkeypatch.setattr(
            sys, "argv",
            ["summarize_generation_telemetry.py", tmp, "--emit-ledger-row", "--label", "test"],
        )
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "Telemetry summary" in text
        assert "# ledger-row" in text
        assert "| 2026-" in text.split("# ledger-row")[-1]


def test_mimi_decoder_breakdown_aggregation():
    """mimiDecoderBreakdownMS per-chunk fields are aggregated into cell medians."""
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        chunk = {
            "chunkIndex": 0,
            "arrivalMS": 10,
            "talkerForwardMS": 5,
            "codePredictorMS": 10,
            "streamStepEvalMS": 2,
            "audioDecoderMS": 8,
            "streamStepEvalEnqueueMS": 0,
            "streamStepEvalWaitMS": 0,
            "streamStepEOSReadMS": 0,
            "audioChunkEvalMS": 0,
            "mimiDecoderBreakdownMS": {
                "quantizerMS": 1,
                "preConvMS": 1,
                "preTransformerMS": 2,
                "upsampleMS": 1,
                "initConvMS": 0,
                "decoderBlocksMS": 2,
                "outputSnakeMS": 0,
                "outputConvMS": 1,
                "totalMS": 8,
            },
        }
        with open(os.path.join(engine_dir, "generations.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({
                "generationID": "gen-mimi-001",
                "mode": "custom",
                "modelID": "Qwen3-TTS-12Hz-1.7B-4bit",
                "warmState": "warm",
                "notes": {"delivery": "", "deviceClass": "mid16GBMac"},
                "derivedMetrics": {"audioSecondsPerWallSecond": 1.0, "tokensPerSecond": 1000.0},
                "timingsMS": {"qwen_token_loop_total": 200},
                "summary": {"physFootprintPeakMB": 3000, "stageMarks": []},
                "mlxMemoryByStage": {},
                "chunkTimeline": [chunk],
                "audioQC": {"verdict": "pass", "flags": []},
            }) + "\n")

        runs, cells, _, _ = sgt.aggregate_runs(tmp)
        run = runs[0]
        assert run["mimi_quantizerMS"] == 1
        assert run["mimi_decoderBlocksMS"] == 2
        key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "n/a")
        md = cells[key]["mimiDecoderBreakdownMS"]
        assert md["quantizerMS"] == 1
        assert md["totalMS"] == 8
