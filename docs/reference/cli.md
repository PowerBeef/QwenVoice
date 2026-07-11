# The `vocello` CLI

`vocello` is a headless macOS command-line surface over the same in-process MLX engine the app uses.
It serves two roles:

- **User-facing generation** — synthesize speech from the terminal (Custom Voice / Voice Design /
  Voice Cloning), one clip or many, scriptable with JSON output and stdin piping.
- **Deterministic benchmark/test driver** — drive the perf/quality matrix in-process (cold/warm
  controlled exactly via load/unload, no UI waits), aggregate telemetry, and append a perf-ledger row.

It links the engine frameworks directly (no XPC), **ships no model weights and no Python**, and runs
**in place** beside its MLX metallib bundle. It shares the same on-disk model store as the app
(`~/Library/Application Support/QwenVoice/models` by default). Install weights via the app
(Settings → Model downloads) or headlessly with `vocello models install <id>` — the same
HuggingFace downloader the app uses. `generate`/`bench` fail fast if a requested model isn't
installed (`vocello models list` / `models status` show what's present). For macOS UI tests and
bench in debug context, see [`testing-runbook.md`](testing-runbook.md) §1b (`scripts/macos_test.sh models ensure`).

## Build & run

```sh
./scripts/build.sh cli                 # build build/vocello (single config, -Onone)
./scripts/build.sh cli generate --text "Hello." --variant speed   # build + run with args
build/vocello <command> [options]      # run the already-built binary
```

`build/vocello` is a symlink to the real binary under `build/DerivedData/…`; macOS resolves it so the
adjacent MLX shader bundle (`default.metallib`) stays reachable. **Don't copy the binary elsewhere** —
it must run in place. The contract (`qwenvoice_contract.json`) is bundled into the tool, and is also
discovered repo-relative, so the CLI works from the repo root or any subdirectory; pass `--manifest`
to override.

By default the CLI uses the app's runtime data directory
(`~/Library/Application Support/QwenVoice`, or `QwenVoice-Debug` when `QWENVOICE_DEBUG` is truthy);
`--data-dir <path>` overrides it. `bench` defaults to the debug-isolated folder (which holds the full
model set) and forces telemetry on.

## Conventions

- **stdout is machine-readable** (an output path, one per line, or a JSON object); **stderr carries
  human progress notes**. Pipe stdout to capture results cleanly.
- `--json` switches stdout to a structured JSON object/array (on `generate`, `batch`, `voices list`,
  `speakers list`, `models`).
- `--quiet` suppresses the stderr notes; `--verbose` adds per-step detail.
- Exit codes: `0` success · `1` error · `2` usage / unknown command · `130` interrupted (Ctrl-C).

## Commands

### `generate` — synthesize one clip

```sh
vocello generate --mode custom|design|clone --variant speed|quality \
                 (--text "…" | --text-file <path> | piped stdin) [--out <path>] [options]
```

| Option | Meaning |
|---|---|
| `--mode` | `custom` (default) · `design` · `clone` |
| `--variant` | `speed` (default, 4-bit) · `quality` (8-bit) |
| `--text` / `--text-file` | inline text or a file (`-` reads stdin); with neither, piped stdin is used |
| `--speaker` | (custom) speaker id; default = contract default (see `vocello speakers list`) |
| `--voice-brief` | (design) plain-language voice description |
| `--voice` / `--reference` / `--transcript` | (clone) a saved voice name/id, or a reference `.wav` + optional transcript |
| `--delivery` | optional delivery style |
| `--seed` | deterministic sampling seed — the same request + seed reproduces the same take bit-for-bit |
| `--variation` | `expressive` (default, official sampling) · `balanced` · `consistent` — trades take-to-take liveliness for repeatability |
| `--out` | output `.wav` path; default → `<data>/outputs/cli/` |
| `--stream` | streaming synthesis at the app's 320ms cadence; reports first-chunk latency (TTFC) + chunk count (default) |
| `--no-stream` | accumulate the full result before decoding (old non-streaming behavior) |
| `--play` | play the result with `afplay` when done |
| `--json` | emit a JSON result object instead of the bare path |

Streaming is now the default for `vocello generate`. It mirrors the app's engine streaming path (same
`streamingInterval` and chunk delivery) and reports the user-perceived first-chunk latency, but it does
**not** play audio as it generates — there is no live preview player; `--play` plays the completed file.
Generation output is identical to the non-streaming path. Use `--no-stream` to force the old
accumulate-then-decode behavior.

**Selecting a mode** — three equivalent ways: the shortcut subcommands `vocello custom|design|clone …`
(a `--file` makes them route to `batch`), the explicit `--mode <mode>` flag, or — when you omit `--mode`
at an interactive terminal — a numbered picker. Scripted/piped runs without `--mode` default to `custom`
(no prompt). `vocello modes` lists the modes and what each needs.

Prints the output WAV path on stdout (or a JSON object: `audioPath`, `durationSeconds`, `wallSeconds`,
`realtimeFactor`, `finishReason`, `mode`, `variant`, `modelID`, and — when `--stream` — `firstChunkMS`
and `chunks`).

### `batch` — synthesize many clips with a single model load

```sh
vocello batch --file <path|-> --mode … --variant … \
              [--speaker <id> | --voice <name> | --voice-brief "…"] [--out-dir <dir>] [options]
```

One non-empty line per clip; all clips share the same voice/mode/variant, so the engine runs them
through **one loaded model** — far faster than repeated `generate` calls. Reads stdin when `--file` is
omitted or `-`. Prints one output WAV path per line (or a JSON summary with `--json`). Also accepts
`--seed` (applied to every item — re-running the batch reproduces it, and a fixed seed steadies
cross-segment character) and `--variation`, like `generate`.

### `voices` — manage saved clone voices

```sh
vocello voices list [--json]
vocello voices enroll --name <name> --audio <wav> [--transcript "…"]
vocello voices delete --id <id>
```

### `speakers` — list built-in Custom Voice speakers

```sh
vocello speakers list [--json]
```

Lists the built-in Qwen3 speaker presets (id, display name, language; the contract default is marked)
so you don't have to guess `--speaker` ids. Read-only — doesn't boot the engine, so it returns
instantly.

### `modes` — list the generation modes

```sh
vocello modes [--json]
```

Lists the three generation modes (`custom` / `design` / `clone`) and what each needs (`--speaker` /
`--voice-brief` / `--voice` | `--reference`). Static and instant. Select a mode via the
`vocello custom|design|clone …` shortcut, `generate --mode <mode>`, or the interactive picker.

### `deliveries` — list delivery presets + instruction text

```sh
vocello deliveries [--json]
```

Lists every built-in delivery preset as a preset id and the natural-language instruction
the model receives (the source of truth is `EmotionPreset`). Static and instant. These ids are the
`bench --delivery <id>` cells, and `--json` is the DRY feed for `scripts/delivery_adherence.py` — the
objective, reference-free delivery-adherence measurement (F0 / speaking-rate / duration deltas vs a
same-seed neutral take). See `scripts/analyze_delivery.py` + the §I.3 writeup in
[`../../benchmarks/OPTIMIZATION.md`](../../benchmarks/OPTIMIZATION.md).

### `models` — inventory and install

```sh
vocello models list [--json]
vocello models status [<id>] [--json]      # adds missing-file detail
vocello models install <id> [--verbose]    # headless download into the shared models dir
```

Shows each model's install state, on-disk size, and (for `status`) any missing required files.
`install` uses the same `HuggingFaceDownloader` as the macOS app — a CLI-installed model is
immediately usable in the app, and vice versa. Variant-scoped ids (`pro_custom_speed`, `…_quality`)
are what `generate --variant` selects.

For test/bench lanes with `QWENVOICE_DEBUG=1`, weights live under `QwenVoice-Debug/`; the test
driver symlinks `QwenVoice-Debug/models` → the canonical store (see [`testing-runbook.md`](testing-runbook.md) §1b).

### `bench` — drive the perf/quality matrix + aggregate

```sh
vocello bench [--modes custom,design,clone] [--variants speed,quality] \
              [--lengths short,medium,long] [--warm 3] [options]
```

Per cell: 1 cold (medium) for Custom/Design + N warm per length; Voice Cloning is warm-only.
Telemetry defaults to lightweight; use `--telemetry off` for engine-only WAV runs without
instrumentation. Results land in `<data>/diagnostics` and are summarized by
`scripts/summarize_generation_telemetry.py` (skipped when `--telemetry off`).

| Option | Meaning |
|---|---|
| `--modes` / `--variants` / `--lengths` | matrix axes (comma lists) |
| `--warm` | warm reps per (cell × length); default 3 |
| `--voice` / `--voice-brief` | clone voice name / design brief |
| `--delivery [list]` | add **instruct-bearing delivery cells** (Custom/Design, warm, medium text, 1 take each): comma list of preset ids (e.g. `happy,calm,whisper`); the bare flag runs the default set (`happy,calm,whisper`). Rows are stamped `notes.delivery` and summarized in their own block, so the headline matrix and `--ledger` row stay comparable; the plain warm takes double as the neutral reference for prosody/delivery A/Bs |
| `--label "<note>"` | stamp a note on the summary / ledger row |
| `--ledger` | append a one-line row to `benchmarks/HISTORY.md` via a **single** summarizer pass (`--emit-ledger-row`) |
| `--force-class` | **dev/diagnostic only** — force a constrained memory tier on any Mac: `8gb` · `16gb` · `high` · `iphone` (sets the `QWENVOICE_FORCE_MEMORY_CLASS` knob, relayed to the engine over the `initialize` handshake; stamps `notes.deviceClass`) |
| `--telemetry` | `off` · `lightweight` (default) · `verbose` (raw per-sample sidecars) |
| `--seed` | deterministic sampling seed applied to every benchmark take |
| `--no-stream` | accumulate the full result before decoding (old bench behavior) |
| `--ttfc` | add an engine first-chunk-latency probe per cell → table + `diagnostics/bench-ttfc.json` |
| `--keep` / `--force` | append to existing diagnostics / allow clearing even the real app data dir |
| `--data-dir` / `--manifest` | override the runtime data dir (default: the debug-isolated folder) / the `qwenvoice_contract.json` path |
| `--no-summary` | skip running the aggregator |

**Streaming by default.** `vocello bench` runs the streaming path by default, so its
memory numbers match the iOS/app streaming reality. Streaming takes drain `engine.events`
and disable inline preview PCM (`QWENVOICE_STREAMING_PREVIEW_DATA=off`) so long matrices
do not retain chunk events across takes. Pass `--no-stream` to run the old accumulate-then-decode
behavior for comparison.

**What it measures.** Engine truth — RTF, decode, memory, per-stage GPU, and the `audioQC` verdict.
It does **not** capture the app's end-to-end through-XPC latency (TTFC/TTFA) or the merged 3-layer
telemetry row — those exist only in the real app process topology — and CLI rows carry no UI-stall
counters (no UI process), so the summarizer's `UIstall` column shows `—` for bench runs. `--ttfc` adds an *engine-side*
first-chunk probe (a warm streaming take per cell, run after the summary so it doesn't perturb the
RTF/decode medians) — distinct from the app's buffered TTFA.

**Preflight.** Before running, `bench` fails fast if any requested `(mode × variant)` model isn't
installed (listing the missing ids), and fails if `clone` is in `--modes` but the saved voice
(`--voice`, default `A_warm_elderly_woman`) is absent. Prerequisites: the requested models
installed; a saved clone voice when clone is in the matrix.

The deterministic `audioQC` gate, `scripts/prosody_quality_gate.py`, and
`scripts/delivery_adherence.py` provide automated gating for bench runs.
**Manual listening by ear** remains mandatory before explicitly promoting or releasing an
engine-adjacent change; it does not block an ordinary development commit, push, pull request, or
merge.

## Examples

```sh
# Custom Voice, speed, save to a path
vocello generate --mode custom --variant speed --text "The train left at dawn." --out /tmp/clip.wav

# Pipe a script in, stream it, get JSON with first-chunk latency
echo "Hello there." | vocello generate --variant speed --stream --json

# Voice Design from a brief
vocello generate --mode design --voice-brief "A warm, calm narrator" --text "Once upon a time…"

# Bulk: one model load for many lines
vocello batch --file lines.txt --mode custom --variant speed --out-dir /tmp/batch

# Discover what's available (instant — no engine boot)
vocello speakers list
vocello models list
vocello models install pro_custom_speed   # headless; shared with the app

# One-command benchmark: forced 8 GB tier, labelled, append a ledger row
vocello bench --modes custom --variants speed --lengths short,medium,long --warm 3 \
              --label "my change" --ledger --force-class 8gb
```

## See also

- [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) — the telemetry schema, the bench
  matrix in depth, the `audioQC` gate, and the listening pass.
