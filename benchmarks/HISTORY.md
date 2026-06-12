<!--
Performance history ledger — one compact row per benchmark run, to track changes
over time as backend/MLX optimization advances. Append a row with:

    python3 scripts/summarize_generation_telemetry.py --ledger-row --label "what changed" \
        >> benchmarks/HISTORY.md

(optionally `--cell mode/model/state` to pick a different headline cell; default is
custom/quality/warm). Rows MUST stay at the end of this file so `>>` lands correctly.
Keep this file a compact ledger — no raw JSONL (guard-enforced). See
docs/reference/telemetry-and-benchmarking.md → "Tracking performance over time".

Columns: date · short git SHA the run measured · cell (mode/model/state[/len];
the summarizer appends the length bucket — older rows predate it) ·
RTF (audioSec/wallSec, >1 = faster than realtime) · tok/s (codec tokens/s) ·
TTFC ms (submit→first chunk) · physFoot MB (phys_footprint peak, the OOM-relevant
figure) · trims (memory_trim count [worst level]) · QC (reference-free audio
defect verdict pass/warn/fail) · note · uiMaxStall ms (trailing, added 2026-06 —
max main-thread stall during the generation; "—" for CLI bench rows, which have
no UI process; older rows predate the column).

Compare two runs with `git diff`, or ask the agent to diff the deltas. This is a
reference ledger, not an auto-compared baseline gate.
-->

# Performance history

| date | sha | cell | RTF | tok/s | TTFC ms | physFoot MB | trims | QC | note | uiMaxStall ms |
|------|-----|------|-----|-------|---------|-------------|-------|----|------|---------------|
| 2026-05-30 | 06166f0 | custom/pro_custom_quality/warm | 0.66 | 8.31 | 1114 | 4079 | 0 | warn:dropout | baseline pre-optimization; QC dropout = natural comma-pause (listening PASS); Quality = genuine 8-bit, native floor tier |
| 2026-05-30 | 670d5c8 | custom/pro_custom_quality/warm/medium | 0.70 | 8.79 | 1001 | 4114 | 0 | warn:dropout | baseline pre-opt LENGTH SWEEP (short/med/long); Quality genuine 8-bit, native floor; listening PASS (dropout+clicks = detector false-positives on natural pauses) |
| 2026-05-31 | 641a541 | custom/pro_custom_quality/warm/medium | 0.83 | 10.39 | - | 5773 | 0 | warn:dropout | reference baseline 2026-05-31 641a541 — CLI-driven, native floor 8GB |
| 2026-05-31 | 3da580d | custom/pro_custom_quality/warm/medium | 0.82 | 10.20 | - | 5745 | 0 | pass | audioQC punctuation-aware recalibration (ac86b8a) — engine unchanged, perf flat; QC false-positives cleared (custom+design all pass; 1 design/quality/long warn = real-but-natural 1116ms sentence pause) |
| 2026-06-06 | b961cc8 | custom/iphone_pro_speed/cold/long | 1.841 | 23.0 | - | 2621 | 0 | pass | iOS DEVICE A/B — live-preview OFF (.skip, pre-feature). iPhone 17 Pro, median of 3, autorun harness |
| 2026-06-06 | b961cc8 | custom/iphone_pro_speed/cold/long | 1.844 | 23.0 | - | 2717 | 0 | pass | iOS DEVICE A/B — live-preview ON (.emit, feature). RTF +0.2% / physFoot +3.7% vs OFF = within noise; 0 trims, QC pass ⇒ live streaming playback has no generation-perf/memory cost |
| 2026-06-09 | 1e80357 | custom/pro_custom_speed/warm/medium | 0.84 | 10.52 | - | 4757 | 0 | pass | pre-ui-kpi baseline (smoothness ws, speed-only) | - |
| 2026-06-09 | 50c74ff | custom/pro_custom_speed/warm/medium | 0.83 | 10.38 | - | 4535 | 0 | pass | post smoothness ws (KPI+admission+retirement) sanity | - |
| 2026-06-09 | a2b5f15 | custom/pro_custom_speed/warm/medium | 0.83 | 10.38 | - | 4486 | 0 | pass | P1 vendored Qwen3 specialization (expect unchanged) | - |
| 2026-06-09 | a2b5f15 | custom/pro_custom_speed/warm/long | 0.80 | 10.04 | - | 6078 | 0 | warn:dropout | P2 sampler scratch + CP step constants (P1+P2 binary) | - |
| 2026-06-09 | a2b5f15 | custom/pro_custom_speed/warm/long | 0.81 | 10.17 | - | 6285 | 0 | pass | P2 re-run after cool-down (clone via prepared voice) | - |
| 2026-06-09 | a2b5f15 | custom/pro_custom_speed/warm/long | 0.80 | 9.94 | - | 6231 | 0 | pass | P2 A/B control: P1-only binary, same conditions | - |
| 2026-06-09 | 23be8d4 | custom/pro_custom_speed/warm/long | 1.02 | 12.81 | - | 5913 | 0 | pass | P3 fused CP RoPE (bf16-ULP numerics delta; gate pending) | - |
| 2026-06-09 | f3cd2aa | clone/pro_clone_speed/warm/long | 0.58 | 7.21 | - | 7226 | 0 | pass | P4 KV-quant A/B: off (P3 binary) | - |
| 2026-06-09 | f3cd2aa | clone/pro_clone_speed/warm/long | 0.53 | 6.57 | - | 6955 | 0 | pass | P4 KV-quant A/B: 8-bit | - |
| 2026-06-09 | fc3aaf8 | custom/pro_custom_speed/warm/medium | 1.11 | 13.82 | - | 4493 | 0 | pass | P6 final full-matrix (P0-P4) | - |
| 2026-06-09 | 90e16b3 | custom/pro_custom_speed/warm/medium | 1.03 | 12.85 | - | 4539 | 0 | pass | release-QA net (post audit fixes) | - |
| 2026-06-12 | a2c5206 | custom/pro_custom_speed/warm/medium | 1.06 | 13.19 | - | 4877 | 0 | pass | v2.1.0 release-QA | - |
