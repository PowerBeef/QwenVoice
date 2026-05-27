# Testing Overview

Vocello's behavioral testing surface is local-only. macOS uses the maintained smoke/bench harness; iPhone hardware validation uses the CoreDevice + iPhone Mirroring workflow when real MLX execution, model downloads, or memory guardrails need proof.

## Local layers

| Layer | Question it answers | Wall-clock | Tooling |
|---|---|---|---|
| **Functional smoke** | Did the generate path produce a WAV + DB row? | ~1 min per scenario | [`smoke-*.md`](.) runbooks, `scripts/uitest.sh smoke-check / reset / prep / verify-generation` |
| **Timing bench** | Is the latency, RTF, RMS, peak, and memory within ±15 % of the committed baseline across cold/warm × variant × prompt-length? | ~12 min per mode (24 samples) | [`bench-*.md`](.) runbooks, `scripts/uitest.sh bench-step / bench-summarize / bench-compare`, [`benchmark-baselines.json`](benchmark-baselines.json) |
| **iPhone device proof** | Does the real iPhone app install, drive model delivery/extension transport, collect memory evidence, and run MLX when the increased-memory entitlement is available? | Manual, scenario-dependent | [`ios-shipping.md`](ios-shipping.md), [`ios-device-screen-mirror-testing.md`](ios-device-screen-mirror-testing.md), `scripts/ios_device.sh`, `scripts/ios_device_proof_matrix.sh` |

The layers complement each other:

- The **smoke** catches "engine wedged / dialog blocked / WAV missing / DB row missing" — failures that are obvious from `pass=false` in `result.json`.
- The **bench** catches "engine took 2× longer than baseline" or "peak RSS doubled" — failures the smoke happily reports as pass.

The user is the final judge of subjective audio quality (naturalness, emotion match, pronunciation, pacing, artifacts) — those are listen-and-judge calls, not automated ones.

> **Reading bench flags.** `bench-compare` flags `ms_engine_start_to_final` and `rtf` independently at ±15 %, but treat them as a paired signal. If `ms` flags and `rtf` stays within gate, the latency change is LM output-length variance (the model occasionally emits a longer/shorter take for the same prompt), not engine throughput regression. `rtf` (audio-seconds per generation-second) normalizes out output-length and is the correct gate for engine throughput. Full reading rules + worked example in [`ui-test-surface.md`](ui-test-surface.md#reading-the-bench-compare-output--ms-vs-rtf-as-paired-signals).

## Decision table — what to run when X changes

| What changed | Smoke | Bench |
|---|:---:|:---:|
| Engine code (streaming, KV cache, decoder, vocoder, anything under `Sources/QwenVoice*` or `third_party_patches/mlx-audio-swift`) | ✅ | ✅ |
| Audio-path code (`PCM16StreamLimiter`, `AudioPlayerViewModel`, `GenerationPersistence`, WAV writers) | ✅ | ✅ |
| UI / view code (`Sources/Views/`, `Sources/iOS/`, coordinators, view models that don't touch audio) | ✅ | — |
| iOS reference-parity UI (`Sources/iOS/` matching `design_references/Vocello iOS/`) | iOS Simulator + reference workflow | — |
| iOS engine, model delivery, ExtensionKit IPC, or memory guardrails | iPhone device proof ([`ios-shipping.md`](ios-shipping.md)) | `ios_device_proof_matrix.sh` + targeted UI run |
| Prompt/tone configuration (`docs/qwen_tone.md`, voice-description handling) | — | — |
| Generation pipeline plumbing (cancellation, gating, request ID) | ✅ | ✅ |
| Saved-voice fixture changes (re-bootstrap UITestRef) | clone smoke + bootstrap | — |
| Bench-baseline-affecting change (deliberate perf work) | optional | ✅ + promote new baseline |
| Build/packaging change | — | — (build proof is separate, see [release-readiness.md](release-readiness.md)) |
| Documentation only | — | — |
| Cross-process IPC / XPC code (`Sources/QwenVoice{Native,EngineService,EngineSupport}`) | ✅ all three modes | ✅ one mode |

**"All three modes"** for smoke = run `smoke-custom-voice`, `smoke-voice-design`, `smoke-voice-cloning` back-to-back. **"One mode"** for bench = pick whichever mode is most directly exercised by the change.

## Recommended entry points

- **First-time agent in this repo?** Read [`ui-test-surface.md`](ui-test-surface.md) once for the AX-id vocabulary + standard smoke/bench skeletons + completion signals. Skim [`testing-cheatsheet.md`](testing-cheatsheet.md) for copy-pasteable commands. Then come back here for the decision table.
- **About to ship a perf-affecting change?** Run the full bench matrix for the affected mode, then promote the baseline if the numbers are intentional. See the per-mode `bench-*.md`.
- **About to ship an audio-path change?** Generate one sample in each mode and listen — naturalness, emotion match, pronunciation, pacing, and artifacts are human-judgment calls. The bench's RMS/peak gates catch loudness regressions; everything else is a listen.
- **About to ship iOS visual parity work?** Follow [`ios-reference-ui-workflow.md`](ios-reference-ui-workflow.md), then verify the affected states in the iPhone 17 Pro Simulator with the fake backend from [`ios-simulator-testing.md`](ios-simulator-testing.md).
- **About to validate iOS hardware behavior?** Follow [`ios-device-screen-mirror-testing.md`](ios-device-screen-mirror-testing.md): `scripts/ios_device.sh start`, drive the mirrored iPhone UI, capture screenshots, then `scripts/ios_device.sh pull`.
- **Triaging a bug report?** Run the matching smoke first to confirm reproduction. If the smoke passes but the user complains about quality, generate the same prompt locally and listen to it.

## What's not in this layer

- Build/compile proof — `./scripts/build_foundation_targets.sh macos|ios|all` (see [`backend-freeze-gate.md`](backend-freeze-gate.md)).
- Static project validation — `./scripts/check_project_inputs.sh`.
- Release-readiness gates — [`release-readiness.md`](release-readiness.md) for macOS DMG sign+notarize, iOS TestFlight, and the macOS-first release-track policy.
- No CI smoke/bench, no XCTest, no parallel Python benchmark harness — those surfaces were retired in May 2026 (see [AGENTS.md](../../AGENTS.md) "Testing policy — important"). The only CI workflow is scoped to macOS packaging plus iOS compile-safety.

## Cross-references

- [`testing-cheatsheet.md`](testing-cheatsheet.md) — single-page command card.
- [`ui-test-surface.md`](ui-test-surface.md) — the agent reference (AX ids, signposts, standard skeletons).
- [`ios-reference-ui-workflow.md`](ios-reference-ui-workflow.md) — interactive reference-to-native SwiftUI parity workflow.
- [`ios-simulator-testing.md`](ios-simulator-testing.md) — iPhone Simulator fake backend and scenario controls.
- [`ios-device-screen-mirror-testing.md`](ios-device-screen-mirror-testing.md) — real-device iPhone validation through CoreDevice and iPhone Mirroring.
- [`benchmark-baselines.json`](benchmark-baselines.json) — committed bench baselines (24 cells, schema v3, ±15 % gate on `ms_engine_start_to_final` + `rtf`).
