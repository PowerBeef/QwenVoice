# Optimization progress

Durable record of backend/MLX + output-quality optimization work — what was investigated, decided,
shipped, and deferred. The blow-by-blow lives in git history + `HISTORY.md`; this file is the **standing
status** so a future session (or maintainer) can resume without re-deriving it. Anchored to the reference
baseline. Point-in-time as of **2026-05-31**.

## Reference baseline

[`baseline-2026-05-31-641a541.md`](baseline-2026-05-31-641a541.md) — pre-optimization reference, CLI-driven
(`vocello bench`), native floor **8 GB** tier. Headline: **RTF 0.20–0.89 (slower than realtime)**; the
**decode loop dominates wall time** and scales ~linearly with length; **clone is the heaviest** per length
and on memory (~7.4–8.7 GB physFoot in-process); `trims = 0` everywhere. Perf-over-time ledger:
[`HISTORY.md`](HISTORY.md).

## Status at a glance

| # | Workstream | Status | Where |
|---|---|---|---|
| A | Per-stage decode breakdown (measure) | ✅ done | `ac86b8a` (`summarize_generation_telemetry.py`) |
| B | The ~586 ms "dropout" investigation | ✅ done — root-caused | this doc + `641a541` baseline note |
| C | Punctuation-aware audioQC recalibration | ✅ done + verified | `ac86b8a` (`NativeStreamingSynthesisSession.swift`) |
| D | CodePredictor RoPE fusion | ⏸ deferred — gated, not recommended | n/a |
| E | MLXSwift / mlx-swift-lm version bump (0.31.x) | ⏸ deferred — stay pinned, gated | this doc + CLAUDE.md "SPM dependencies" |
| F | iPhone 1.7B-4bit program — feasibility + WS0b profiling + compile/KV spikes | 🔬 see §F: compile rejected; **iOS RAM premise corrected — streaming peaks ~3 GB flat, KV windowing unneeded** | this doc + session plan |

## Grounding (the headline conclusion)

An external optimization report (a from-scratch iOS / iPhone-15-Pro playbook for Qwen3-TTS 1.7B) was
ground against Vocello's **shipped macOS engine**. Finding: the vendored `mlx-audio-swift` port **already
implements the large majority of its recommendations** — `small_to_mtp_projection` 2048→1024 bridge,
2048-dim speaker embedding, interleaved MRoPE `[24,20,20]`, Q/K RMSNorm, `MLXFast.scaledDotProductAttention`,
a single per-frame `eval()` (no per-step `.item()`), `asyncEval` streaming, the input-side decoder-drift fix
(`4fab110`), per-tier `GPU.cacheLimit`, fp16 KV cache, and a `compile(shapeless:)` SwiGLU. The report's two
"architecture corruption bugs" **do not exist here**. Adversarial verification dropped 7 of 12 candidate
levers as already-handled / overstated / infeasible. **The genuine remaining work is narrow**, and the
highest-value item was a quality finding, not a speed lever.

## A — Decode-loop measurement (done)

Added a per-stage **Decode breakdown** to the summarizer (`talker · sampCB0 · codePred · code2wav ·
stepEval · other`, from the `timingsMS` sub-keys already captured in the engine row).

**Key finding (changed the plan):** these are Swift-side wall-clock timers around **lazy** MLX ops, **not**
per-stage GPU compute. On custom/quality/long, `stepEval ≈ 77%` of decode is the **fused** compute of
Talker + 15× Code Predictor + sampling (the single per-frame `eval()`); `talker`/`codePred` measure graph
*build* time; `code2wav ≈ 0` because the decoder is `asyncEval`'d (Phase 2c) and overlaps the token loop —
pipelined, not free. **Consequence:** the wall-clock breakdown **cannot attribute decode *compute* per
stage**. Doing so needs an Instruments `xctrace` capture of the existing os_signpost intervals
("Talker Forward" / "Code Predictor Loop" / "Step Eval Flush" / "Audio Decoder"). This **gates D**.

## B — The ~586 ms "dropout" (done; root-caused — not an engine defect)

Effective sampling (all modes use `officialQualityDefault`): **temp 0.9, topK 50, topP 1.0 (nucleus off),
repetitionPenalty 1.05, minP 0.0**.

The baseline flagged a real ~586 ms mid-utterance silence. Investigation: it reproduced systematically on
long content (every long custom/design cell failed audioQC; clone passed), but objective analysis of fresh
takes showed **every interior silence ≥150 ms maps to a punctuation mark** — they are the model's **natural
prosodic pauses** at sentence/comma boundaries on long, slow narration, which the old fixed ≥400 ms detector
over-flagged. The one agy-confirmed genuine mid-phrase gap is positionally **adjacent to a comma pause** and
is indistinguishable from it by duration/amplitude alone (ear-only).

**Decision:** a sampling-side fix (e.g. minP floor / silence-run penalty) would suppress the model's
*natural* pauses to chase a rare, ear-only event — wrong tool, real prosody-degradation risk. Remediation
shifted to **C** (fix the tripwire); the listening pass stays the gate for the residual mid-phrase gap.

## C — Punctuation-aware audioQC recalibration (done, verified — `ac86b8a`)

`PCM16StreamLimiter` now records interior silence-run lengths; `makeAudioQCReport` counts **long pauses
(≥350 ms)** against the text's **pause budget** (interior punctuation boundaries, from `request.text`) and
flags only an **excess** beyond it (≥2 → fail, 1 → warn) or a single **egregious** ≥1200 ms gap (≥900 ms →
warn). Else `pass`. (`Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`.)

**Verified** (re-bench custom,design × speed,quality × all lengths + deterministic replication on real WAVs
+ synthetic cases): **15/16 cells now `pass`** (every false-positive `fail`/`warn` cleared); the lone
remaining `warn` is a **real-but-natural ~1116 ms sentence-boundary pause** (correctly routed to the ear).
Sensitivity retained — synthetic 1300 ms → fail, 11 long pauses → fail. Perf unchanged (engine untouched;
see the `3da580d` `HISTORY.md` row vs the `641a541` baseline). The residual rare mid-phrase gap is ear-only;
the **mandatory listening pass remains the perceptual gate**.

## D — CodePredictor RoPE fusion (deferred; **not recommended to start**)

CP RoPE is hand-rolled (`Qwen3TTSCodePredictor.swift`); `MLXFast.RoPE` exists in MLX-Swift 0.30.6 and the CP
uses standard 2D RoPE, so it *could* swap in. Realistic ceiling **~2–3 % RTF (CP only)**. **Gate (revised by
A):** the wall-clock breakdown can't decide if CP compute is a worthwhile slice of the fused `stepEval`, so
D should only be attempted **after an Instruments os_signpost capture** of one long/quality generation shows
the "Code Predictor Loop" interval is a meaningful fraction of "Step Eval Flush" GPU time. Vendored edit →
follow [`../docs/reference/mlx-audio-swift-patching.md`](../docs/reference/mlx-audio-swift-patching.md);
must preserve exact numerics (KV precision).

## E — MLXSwift / mlx-swift-lm version pin (deferred; **stay pinned**)

Pinned `exact: 0.30.6` (mlx-swift) + `2.30.6` (mlx-swift-lm) in **both** `project.yml` and the vendored
`third_party_patches/mlx-audio-swift/Package.swift`. Latest upstream is **0.31.3** (+ `mlx-swift-lm` 2.31.x;
a separate 3.x line also exists). **Decision: keep pinned at 0.30.6 / 2.30.6.** Rationale: the backend is
vendored + hand-ported and there's no automated test suite, so the exact pin keeps the compute substrate
deterministic; 0.30.6 is the benchmarked, working version and 0.31 adds nothing Vocello needs. 0.31 is **not
a free bump** — it changes the MLX quantization API (`Quantizable.toQuantized` gains a `QuantizationMode`;
quantize moved to a top-level fn), which touches the 4-bit (Speed) / 8-bit (Quality) model-load path, and
it's a core-MLX backend bump that can shift RTF/memory (what these benchmarks track). **When upgrading**
(quarterly review, or when a fix/model requires it): branch → bump all pin sites (project.yml mlx-swift +
vendored Package.swift mlx-swift & mlx-swift-lm, in lockstep) → `regenerate_project.sh` → both
`build_foundation_targets.sh` → `vocello bench` vs `baseline-2026-05-31-641a541.md` + listening pass → keep
only if RTF/quality/QC are unchanged; otherwise document the blocker and revert. Avoid the `mlx-swift-lm` 3.x
major line unless a feature specifically requires it.

## F — iPhone 1.7B 4-bit optimization program (2026-06-01)

> **Superseded for the *current* iOS state — see [`../docs/reference/ios-engine-optimization.md`](../docs/reference/ios-engine-optimization.md).**
> §F below is the original backend-feasibility study (its decode-loop + RAM-lever findings are still valid and
> shared by both platforms). But its **process model is out of date**: the engine no longer runs in an
> ExtensionKit extension — it runs **in-process in the app** (`7822a8a`; the extension was removed in
> `aed617c` because a non-UI extension's Jetsam cap can't be raised by the entitlement). On-device generation
> now works (iPhone 17 Pro, RTF ~1.6–1.9, ~3 GB streaming peak, 0 trims). The iOS-engine doc is the live iOS
> progress + roadmap record.

Goal: get Speed (4-bit) Qwen3-TTS running on iPhone 15 Pro (8 GB). Full plan + the 57-agent verified lever
inventory live in the session plan; this records the standing findings. (Historical note: this study assumed
the engine ran in the iOS ExtensionKit extension with a separate Jetsam budget — that approach was abandoned
in favor of the in-process engine; see the doc linked above.)

**Feasibility (isolated engine, Speed 4-bit):** Custom/Design ~2.8–3.3 GB (fits under the default streaming
limit per §F.1 — the entitlement is headroom insurance, not required); Clone/long ~4.7 GB (marginal — wants
the raised limit ≥~5.2 GB or a ~400 MB cut); Quality 8-bit ~5.7 GB+ (out of scope — iPhone is 4-bit-only).
Hard floor (4-bit weights + activations) ~2.2 GB. **The increased-memory entitlement is a self-serve
capability** (enable it on the App ID — not an Apple grant; already declared in both iOS entitlements files).
The actual #1 prerequisite is re-establishing on-device build/deploy/proof tooling + on-device validation.

**WS0b decode-loop GPU attribution** — `xctrace --instrument os_signpost`, custom/speed/long, **327 frames /
31.1 s** wall, native 8 GB Mac (paired Begin/End from the raw `os-signpost` table; the `os-signpost-interval`
table collapses because the engine reuses `OS_SIGNPOST_ID_EXCLUSIVE`):

| stage (Σ over 327 frames) | total ms | % gen | mean/frame | nature |
|---|---|---|---|---|
| **Step Eval Flush** (single per-frame `eval()`) | 19072 | 61% | 58.3 ms | **GPU compute** — talker + 15×CP + sampling, fused |
| **Code Predictor Loop** | 5233 | 17% | 16.0 ms | **Swift CPU** — builds the 15-pass graph each frame |
| **Talker Forward** | 1744 | 6% | 5.3 ms | **Swift CPU** — graph build |
| inter-frame gap (Code2Wav asyncEval + chunk plumbing) | ~4000 | ~13% | — | overlapped decode |
| Sample First/Predicted + Codec Embed + EOS | ~620 | 2% | — | mostly build |

**Findings (supersedes the old workstream D ordering):**
- **`compile()` the per-frame graph — TESTED & REJECTED (2026-06-01).** The ~21 ms/frame build overhead is
  dominated by constructing the **quantized** `Linear` projections (4-bit → `QuantizedLinear` after
  `quantize(model:)`; bits 4 / group 64 / affine). A throwaway validation spike compiled the full talker
  MLP *including* the quantized projections via `compile(inputs: [gate, up, down], shapeless: true)`. Result:
  it **builds and runs correctly** (audioQC **pass** — so compiling a quantized forward IS feasible on MLX
  0.30.6), but it **regressed warm RTF ~5%** in a clean same-session A/B (custom/speed/long: **eager 0.80 vs
  compiled 0.76**; decode 24.8 s → 27.2 s). Cause: declaring the quantized module params as `inputs:` makes
  `compile` marshal their state (packed weight + scales + biases) on every call, costing more than the Swift
  build overhead it removes — and that cost **scales with the compiled region**, so a bigger region (whole
  layer / the 15-pass CP loop) would regress *more*, not less. **Conclusion: the ~22% build overhead is not
  productively attackable via MLX 0.30.6 `compile` on this quantized stack; do not pursue the fixed-shape-KV
  + compile rewrite.** (Only untested variant — baking weights as trace constants with no `inputs:` — is
  discouraged by MLX docs for module state and risks correctness; not recommended.)
- **Step Eval Flush (GPU, 61%)** is the model's real compute — largely fixed for 1.7B 4-bit at this
  precision; no transparent lever (quantization-mode work is pinned out at MLX 0.30.6, see §E).
- RoPE fusion → `MLXFast.RoPE` (CP + Talker): only a small slice of the build, and the compile spike showed
  build-time is hard to reclaim cheaply here → expected marginal/uncertain; low priority.

**RAM-lever corrections (under the strict no-degradation bar):**
- **Sliding-window KV is NOT a transparent RAM lever.** `RotatingKVCache` (mlx-swift-lm `KVCache.swift:441`)
  grows in 256-token steps and only trims once it exceeds `maxSize`; a window large enough to be lossless
  (≥ the ~500–600-token real generation length) saves ~0 RAM, while a window small enough to cap RAM **drops
  oldest context** → not transparent → fails the strict bar on long content. Its real use is fixing shapes
  for the compile lever above.
- **Eager `talkerSourceWeights` release — TESTED, no-op (2026-06-01).** Reordered to free the source dict
  *before* the talker eval (pre-extracting the speaker subset). Clean same-session A/B on custom/speed/long:
  **no measurable load-peak reduction** (cold/warm physFoot + peakGPU within noise; RTF unchanged). Confirmed
  the prediction — with no speaker encoder, `talkerSourceWeights` ≈ the talker buffers already held by the
  model (MLX arrays are ref-shared), so releasing the dict frees ~nothing. Could help only the clone/base
  **speaker-encoder** path (holds the speaker subset across the eval); re-test there with a saved voice if
  clone/long RAM becomes the focus. **Reverted (not committed).**
- **Net (revised after the compile spike):** backend speed gains for 1.7B 4-bit on this stack are **limited**
  — GPU compute (61%) is fixed at this precision, and the build overhead (22%) is not compile-attackable
  (regresses). The primary iPhone RAM unlock is the **entitlement**; transparent backend RAM cuts are modest.
  The realistic path to acceptable **iPhone RTF** is therefore the entitlement + evaluating the smaller/faster
  **0.6B variant** for on-device use (CLAUDE.md notes it's verified but unlisted), **not** backend
  micro-optimization of the 1.7B decode loop. Worth confirming with one more os_signpost capture whether the
  ~13% inter-frame gap (Code2Wav/plumbing) hides any cheap win before closing speed work.

### F.1 — STREAMING vs NON-STREAMING peak RAM (2026-06-01) — the RAM premise was wrong

Chasing the iOS RAM target via the talker KV cache: a `RotatingKVCache` sliding window for the talker was
implemented + validated (parked on `feature/rotating-kv`). It is **correct** (audioQC pass with rotation
forced; full audio; RTF unchanged) but delivers **~0 RAM benefit** — windowing ~380 KV tokens on a 69 s
generation moved peak <5 MB. The investigation's "talker KV ≈ 2.7 GB / 30–50% of peak" was an **estimate
that the measurement refutes**: the talker KV is tens of MB, not GB.

**The real driver — and the headline correction to the whole RAM analysis:** the `vocello` bench / CLI
default is **non-streaming** (accumulates *all* generated codec tokens + decodes the full audio at the end),
but **iOS is streaming-first** (emits + releases chunks). Measured on the *same* 69–76 s custom/speed input:

| path | gpuAllocPeak | physFoot |
|---|---|---|
| non-streaming (bench default) | ~8.0 GB | ~7.6 GB |
| **streaming (what iOS uses)** | **~3.0 GB** | **~3.0 GB** |

And streaming peak is **flat with length** — short 2901 MB · medium 2860 MB · long-76 s 2992 MB. So the
non-streaming numbers that drove this entire optimization program (clone ~7–8 GB, "+3.4 GB short→long", the
"marginal/infeasible" feasibility verdict) **overstate the iOS-relevant peak by ~2.5×**. In the actual iOS
streaming path, **custom/Speed peaks at ~3 GB regardless of length** — comfortably viable on iPhone 15 Pro
(at/under even the default ~3.5–4 GB process limit; the entitlement is headroom/clone insurance, not a hard
blocker for custom/design). The +3.4 GB growth is non-streaming accumulation that iOS never incurs.

**Consequences:**
- **Re-baseline the iOS feasibility verdict on the STREAMING path** (the bench non-streaming peak is the wrong
  yardstick for iOS). Custom/Design Speed ≈ 3 GB flat. Clone streaming untested (no saved voice installed) —
  expect ~3.5–4 GB (speaker conditioning + ~3 GB floor); measure when a clone voice is available.
- **Talker-KV windowing is unnecessary for iOS** (KV isn't the driver; streaming already keeps peak flat).
  Originally parked on `feature/rotating-kv`; the "multi-minute single-shot" escape hatch was later closed too
  (see **§F.2** — the token cap forecloses it). Final disposition: shipped **env-only, off by default**.
- For any future bench that wants an iOS-representative peak, use `vocello generate --stream` (or a streaming
  bench mode), **not** the non-streaming full-result path.

### F.2 — Windowing revisited (default-on + toggle) → INERT at the token cap; shipped env-only (2026-06-01)

Revisited per a directive to enable the window on **both platforms, default-on, with a user disable toggle**.
Built the full feature — per-tier `W = 2048` default, a cross-process `NativeTalkerKVCacheGate`, a Settings
toggle on macOS + iOS, and the `initialize`-handshake relay — then two findings collapsed the rationale and it
was scoped back down:

1. **Generation is nondeterministic.** Two identical-config CLI runs of the same text differ (21.4 s vs
   22.6 s, different SHA) — the sampler is unseeded. So the plan's "byte-identical output" transparency test
   **cannot hold** regardless of cache. Transparency survives only *by construction*: `RotatingKVCache`
   returns bit-identical keys/values to `KVCacheSimple` until `offset` exceeds `maxSize`.

2. **The window is INERT at the current token cap.** `maxCacheSize = keep + W = keep + 2048`; tracing
   `updateInPlace` (`KVCache.swift:518`), the first *rotation* (overwrite of oldest generated KV) fires on
   **generated token 2049** (`idx == maxCacheSize → idx = keep`). But **`maxNewTokens = 2048`**
   (`Qwen3GenerationConfiguration()` default, `QwenVoiceBackendCore.swift:20`) — and the engine **hard-errors**
   at the cap, *discarding* the output (verified: a 535-word / 2894-char script → `NativeRuntimeError …
   "reached maxNewTokens before EOS. The output was discarded"`, exit 1). Generation therefore stops exactly
   one token *before* the first rotation. With `W = 2048 = maxNewTokens` the rotating cache **never rotates,
   never trims, never reorders** → bit-identical KV to `KVCacheSimple` on every realized generation, same peak.
   The "multi-minute single-shot" use case §F.1 left open **cannot occur** — the token cap forecloses it.

**Net:** `W ≥ maxNewTokens` ⇒ provably transparent but provably useless (no rotation; ~0 RAM benefit atop the
already-tiny talker KV per §F.1). `W < maxNewTokens` ⇒ *would* rotate, but those generations already error out
at the cap, and the talker-KV saving is still ~0. No win either way at the current config.

**Disposition (maintainer call):** dropped the default-on per-tier policy, the user-facing Settings toggles
(both platforms), and the IPC handshake relay. **Merged env-only plumbing** — the `QVOICE_TALKER_KV_WINDOW`
knob in `NativeMemoryPolicyResolver` + the vendored `RotatingKVCache` talker path — **off by default**. It is
dormant dev/insurance capability that activates only if the token ceiling is ever raised above the window
(e.g. `checkpointDefaultMaxNewTokens = 8192`). `feature/rotating-kv` deleted.

## Invariants / do-NOT (carried from the grounding)

- No hard `Memory.memoryLimit` (reverted in `b77c08e` — spurious OOM downgrades).
- No **output-side** silence gating/smoothing of dropouts (masks the root cause; risks clipping real pauses).
- Don't revert the decoder-drift fix to output-side overlap-add (`4fab110`).
- Don't pipeline the autoregressive 15-pass Code Predictor loop; don't quantize TTS KV; keep macOS
  `MLXTTSEngine.events` `.unbounded`.
- Don't "fix" the phantom 1.7B arch bugs (projection / speaker-dim / MRoPE are correct).

## iOS (now on-device-capable — see the iOS-engine doc)

iPhone is no longer compile-safe-only: on-device build/validation tooling is established, the entitlement is
enabled, and generation works on device (in-process). The `os_proc_available_memory()` gating + per-tier
policy are implemented (`NativeMemoryPolicyResolver` iPhonePro case + `IOSMemoryBudgetPolicy`); no hard
`memoryLimit` (reverted `b77c08e`). The remaining iOS levers (thermal-state monitoring + automatic 0.6B
fallback, the 0.6B variant evaluation, an 8 GB-device proof, the signed-IPA/TestFlight lane) + the full
progress record live in
[`../docs/reference/ios-engine-optimization.md`](../docs/reference/ios-engine-optimization.md). Entitlement
detail: [`../docs/reference/ios-increased-memory-entitlement-request.md`](../docs/reference/ios-increased-memory-entitlement-request.md).

### Live streaming playback — verified zero-cost (2026-06-06, `b961cc8`)

iOS live-preview playback (audio during generation) was checked for engine impact via an on-device A/B on
the same binary: live OFF (`QWENVOICE_STREAMING_PREVIEW_DATA=off` → `.skip` = pre-feature: no PCM, chunks
dropped, no consumer) vs ON (`.emit` = feature; the autorun harness keeps `AudioPlayerViewModel` alive so
the `AVAudioEngine` consumer is exercised too). iPhone 17 Pro, custom/speed, short+long × 3, interleaved.
**Result: no measurable cost** — RTF +0.5% overall (short −1.9% / long +0.2%, within run-to-run noise),
physFootprint peak identical (~2.7 GB, off-max 2731 vs on-max 2722 MB; inside the 2.4–3.3 GB band, far
under the 4.5 GB guard), **0 memory trims** across all 12 runs, audioQC all pass. Ledger rows in
[`HISTORY.md`](HISTORY.md). The `scripts/ios_device.sh` launch now forwards caller-set `QWENVOICE_*`/`QVOICE_*`
env, so this A/B is repeatable (`QWENVOICE_STREAMING_PREVIEW_DATA=off scripts/ios_device.sh bench …`).

## Next step (if resumed)

The only open lever is **D**, and only after the Instruments os_signpost capture above justifies it. The
quality tripwire (C) is in place; everything else the report proposed is already implemented or iOS-deferred.
