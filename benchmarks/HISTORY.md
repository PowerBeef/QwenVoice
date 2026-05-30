<!--
Performance history ledger — one compact row per benchmark run, to track changes
over time as backend/MLX optimization advances. Append a row with:

    python3 scripts/summarize_generation_telemetry.py --ledger-row --label "what changed" \
        >> benchmarks/HISTORY.md

(optionally `--cell mode/model/state` to pick a different headline cell; default is
custom/quality/warm). Rows MUST stay at the end of this file so `>>` lands correctly.
Keep this file a compact ledger — no raw JSONL (guard-enforced). See
docs/reference/telemetry-and-benchmarking.md → "Tracking performance over time".

Columns: date · short git SHA the run measured · cell (mode/model/state) ·
RTF (audioSec/wallSec, >1 = faster than realtime) · tok/s (codec tokens/s) ·
TTFC ms (submit→first chunk) · physFoot MB (phys_footprint peak, the OOM-relevant
figure) · trims (memory_trim count [worst level]) · QC (reference-free audio
defect verdict pass/warn/fail) · note.

Compare two runs with `git diff`, or ask the agent to diff the deltas. This is a
reference ledger, not an auto-compared baseline gate.
-->

# Performance history

| date | sha | cell | RTF | tok/s | TTFC ms | physFoot MB | trims | QC | note |
|------|-----|------|-----|-------|---------|-------------|-------|----|------|
