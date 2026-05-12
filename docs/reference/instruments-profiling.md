# Instruments-Level Engine Profiling

This is the next layer below the cross-layer wall-clock probe (commits
`958567d`, `b46b2d7`, `37c21c3`). When `infer_ms` per-chunk numbers
have been fully attributed to engine sub-stages but you still need to
know *what the GPU is actually doing inside each stage*, this is the
tool.

## When To Use Instruments vs The Bench Helper

| Question | Right tool |
|---|---|
| "How long does the user wait between Cmd+Return and audio playback?" | `scripts/bench_ui_generation.sh` (desktop-UI bench, full pipeline) |
| "Which cells got faster or slower, and did warmup/cache flags explain it?" | `scripts/compare_ui_bench_runs.sh <baseline-run> <candidate-run>` |
| "How does that wall break down across engine / XPC / UI layers?" | `[Probe.Engine|Transport|UI]` lines in the bench log |
| "How does per-chunk `infer_ms` break down across talker / code predictor / decoder / eval cadence?" | Phase 1 + Phase 2a fields in the same probe |
| "Inside `talker_forward_ms`, which Metal kernels run, and is the GPU saturated or idle-waiting?" | **Instruments / `xctrace`** (this doc) |
| "Where does CPU time actually go inside the per-token loop?" | Time Profiler, captured in the same trace |
| "Is `eval(audioChunk)` waiting on a GPU command buffer, or is it actual compute?" | Metal System Trace, in the same trace |

The probe stops at wall-clock attribution. Instruments crosses into
GPU-kernel-level visibility.

## Signposts In Place

Nine `os_signpost` intervals fire on every per-token iteration of the
streaming generation, all under subsystem `com.qwenvoice.engine.qwen3`,
category `generation`:

| Signpost | What it brackets | Source |
|---|---|---|
| `Talker Forward` | `talker(inputEmbeds, cache: cache)` — the LLM forward pass per token | `Qwen3TTS.swift` per-token loop |
| `Sample First Codebook` | first-codebook token sampling after the talker forward pass | same |
| `Code Predictor Loop` | The 7-iteration multi-codebook prediction loop | same |
| `Code Predictor Step` | one sequential codebook predictor forward step | same |
| `Sample Predicted Codebook` | token sampling for one predicted codebook group | same |
| `Codec Embedding Assembly` | codebook embedding lookup and sum for the next token step | same |
| `Step Eval Flush` | The `eval(inputEmbeds, isEOS)` synchronous flush at policy `.full` | same |
| `EOS Read` | `isEOS.item(Bool.self)` readback after the eval policy boundary | same |
| `Audio Decoder` | `speechTokenizer.decoder.streamingStep(...)` | same |
| `Audio Chunk Eval` | The `eval(audioChunk)` after each streaming decoder run | same |

Coarser intervals already exist in `NativeStreamingSynthesisSession.swift`
under subsystem `com.qwenvoice.engine` (category `generation`):

| Signpost | What it brackets |
|---|---|
| `Native Generation Stream` | Streaming generation lifecycle wrapper |
| `Native First Audio Chunk` | First emitted streaming chunk |
| `Native Final WAV Finish` | Streaming final WAV finalization |
| `Native Quality-First Generation` | Quality-first full-result generation wrapper |
| `Native Final Audio Materialize` | Quality-first lazy MLX audio materialization into host floats |
| `Native PCM Limiter Convert` | Quality-first limiter and PCM16 conversion |
| `Native Final WAV Write` | Quality-first atomic PCM16 WAV write and publish |
| `Native Final WAV Manual Header Build` | RIFF/WAVE PCM16 header construction |
| `Native Final WAV Manual File Write` | Header and PCM16 payload write to the sibling temp file |
| `Native Final WAV Manual Publish` | Atomic temp-file publish to the final output URL |
| `Native Final WAV Writer Create` | Streaming final `AVAudioFile` writer setup |
| `Native Final WAV Buffer Build` | Streaming final PCM16 `AVAudioPCMBuffer` construction |
| `Native Final WAV AVAudioFile Write` | Streaming final `AVAudioFile.write(from:)` call |
| `Native Final WAV AVAudioFile Finalize` | Streaming final writer buffer release and `AVAudioFile` teardown |

Both subsystems show up together when the "os_signpost" instrument is
added in Instruments.

## Capture A Trace

```sh
./scripts/bench_instruments_trace.sh
```

Default: 30-second System Trace (CPU + Metal + signposts), output to
`build/instruments-traces/vocello-YYYYMMDD-HHMMSS.trace`. On storage
constrained machines, prefer a one-trace-at-a-time capture with compact
summary export and raw-trace cleanup:

```sh
./scripts/bench_instruments_trace.sh --seconds 60 \
    --template "Time Profiler" \
    --output build/instruments-traces/custom-speed-medium.trace \
    --summary-output build/instruments-traces/custom-speed-medium-summary.md \
    --summary-json build/instruments-traces/custom-speed-medium-summary.json \
    --cleanup-raw \
    --no-open \
    --min-free-gb 10
```

Workflow:

1. The script kills any running Vocello, resets defaults to land on
   Custom Voice, and relaunches a fresh debug build.
2. After the engine is Ready, the script starts `xctrace record` with
   the selected template and your chosen time window.
3. While recording, the operator triggers ONE generation in the
   Vocello UI: paste a script, hit Cmd+Return.
4. When the trace stops, the script exports a compact signpost summary
   when requested. With `--cleanup-raw`, it deletes the raw `.trace`,
   exported XML, and temporary xctrace logs immediately after summary
   extraction.

The trace captures the entire system, so the bundled
`QwenVoiceEngineService.xpc` helper (where the engine actually runs)
is captured alongside the Vocello main process.

Use the heavier `System Trace` template only when you need Metal/GPU
tracks and have enough free disk space. `Time Profiler` or `Logging`
templates are safer for quick signpost smoke checks.

## Reading The Trace

In Instruments:

1. **Add the "os_signpost" instrument** if not already present
   (View → Instruments Library, drag the os_signpost instrument onto
   the trace).
2. **Filter** by subsystem: `com.qwenvoice.engine.qwen3` for the
   per-token markers, or `com.qwenvoice.engine` for the coarser
   generation-lifecycle markers.
3. **Stack tracks vertically** so the os_signpost lane sits between
   the Time Profiler and the Metal GPU lane. This makes alignment
   instant.

What to look for:

- **`Talker Forward` with GPU idle** — kernel launch overhead, sampling,
  embed lookup happening on CPU. Could potentially overlap with the
  next prep step.
- **`Code Predictor Loop` with 7 sequential GPU bursts** — confirms the
  multi-codebook prediction is unbatched. A single multi-codebook
  dispatch could collapse those 7 bursts into one.
- **`Audio Chunk Eval` much longer than `Audio Decoder`** — the
  decoder kernel runs fast but `eval(audioChunk)` waits on it +
  flushes. Could pipeline with the next forward pass.
- **`Step Eval Flush` with substantial GPU activity** — confirms the
  eval flush IS doing real work (not just synchronizing). The Phase 2a
  finding about `.deferred` not being a wall-clock win comes from
  here: the GPU work is happening regardless of which sync point
  triggers it.
- **GPU idle gaps between engine stages** — these are pipeline
  opportunities. Anywhere the GPU sits idle while CPU works on
  housekeeping (sampling, list construction, MLX expression building)
  is amortizable.

## Phase 2b Findings And The Phase 2c Decision

Phase 2a delivered wall-clock attribution. Phase 2b used Instruments
traces to identify kernel-level slack. The first clean trace
(`/tmp/vocello-phase2b.trace`, May 2026, Custom Voice medium cold,
212 token iterations / 27 audio chunks / ~17 s audio) decomposed
per-iteration work as:

| Stage | p50 / iter | total | % of work |
|---|---|---|---|
| Step Eval Flush | 80 ms | 18.2 s | 62 % |
| Code Predictor Loop | 26 ms | 5.6 s | 19 % |
| Audio Chunk Eval | 135 ms / chunk | 3.7 s | 13 % |
| Talker Forward | 6 ms | 1.4 s | 5 % |
| Audio Decoder | 6 ms / chunk | 0.2 s | <1 % |

Step Eval Flush at 80 ms p50 was confirmed irreducible by the
`.deferred` policy experiment (commit `730e569`) — moving the sync
point doesn't reduce the underlying forward-pass GPU work.

Code Predictor Loop at 26 ms p50 was the next clear wall-clock
target, but architectural analysis showed **parallel codebook
prediction is not viable** in this Swift port:

1. Each codebook's input is built from `codeTokens.last!` — feeding
   back the previously-sampled codebook token. The autoregressive
   dependency is real, not optional.
2. `lmHead[generationStep]` is a per-step `Linear(1024, 2048)` head
   (15 of them, one per codebook). They cannot share a hidden state
   output.
3. The codebook KV cache (`codeCache`) builds sequentially via
   `cache.update(keys: k, values: v)`. State accumulates across
   inner-loop iterations.
4. `num_code_groups = 16` (15 inner-loop iterations, not 7 as the
   Phase 2c planning doc had assumed).
5. The upstream Python reference (`Blaizzy/mlx-audio`) doesn't expose
   a parallel-codebook config flag — it treats Qwen3 as a flat token
   stream via `mlx_lm.stream_generate`, so there's no published
   reference to port.

With the primary 12 % RTF target unreachable, Phase 2c shipped the
plan's next-priority alternative: **Audio Chunk Eval pipelining via
`asyncEval`** at the in-loop chunk boundary only. The change replaces
blocking `eval(audioChunk)` with non-blocking `asyncEval(audioChunk)`
inside the per-token loop's chunk emission so the engine returns to
the loop without CPU-blocking on Metal command-buffer drain. The
consumer's `samples.asArray(Float.self)` triggers materialisation off
the engine's critical path. The `Audio Chunk Eval` signpost interval
collapses from ~135 ms / chunk to near-zero for in-loop chunks
(asyncEval enqueue cost only) — that collapse IS the success signal.

**The trailing chunk stays on blocking `eval`.** The first cut of
Phase 2c asyncEval'd that one too; the historical live-preview
diagnostic path then truncated mid-script because the engine returned
with the final chunk still lazy, the awaited generation result raced
ahead of the broker's MainActor chunk-publication tasks, and
`AudioPlayerViewModel`'s `liveFinalFilePath` got set before the last
few chunks had been scheduled in the AVAudioEngine queue. As soon as
the next buffer drained, `handleLiveBufferPlaybackCompletion`'s
`liveScheduledCount == 0 && liveFinalFilePath != nil` branch fired an
early file-playback handoff. Blocking on the trailing chunk closes that
race. See
[`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md) for the
patch baseline.

## Open Investigation Tracks

If the trace shows the GPU is *fully saturated* during the per-token
loop (no idle gaps), the conclusion is that the M1's GPU is the
bottleneck and further wall-clock optimization requires either model
quantization (already at 4-bit Speed) or hardware (M2/M3/M4 with more
GPU cores).

Phase 2c's pipelining still leaves Step Eval Flush (62 % of work) as
the dominant per-iteration cost. The work itself is the per-token
forward sync; reducing it requires either a faster talker forward
(quantization, kernel-fusion of the SwiGLU + attention path, or
talker-layer batching across tokens) or a fundamentally different
generation strategy (e.g. speculative decoding). All of these are
research-grade, not local optimisations.

## Patch Note

`Qwen3TTS.swift` gains an `import os` and a private `Qwen3Signposts`
namespace. The signpost calls live in the per-token loop inside
`generateVoiceDesign(...)` (the inner generation function). This is a
local patch on top of the vendored MLXAudioTTS — preserve on rebase.
See [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md) for
the patch baseline.
