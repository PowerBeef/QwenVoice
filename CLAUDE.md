# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Vocello** (repo: QwenVoice; macOS app module still `QwenVoice`, iOS app module
`QVoiceiOS`) is a local-first, private text-to-speech app for Apple Silicon.
It synthesizes speech **on-device** with Qwen3-TTS models accelerated through
**MLX** (native Swift packages — no Python runtime, no bundled weights, no cloud
generation). Models download on demand from Hugging Face after install. Stable
macOS release is **Vocello 2.1.0**; iOS is on-device-capable on `main` but not
yet distributed. Platforms: macOS 26+, iOS 26+, Apple Silicon, Xcode 26, Swift 6.

The repo also ships: a headless macOS CLI (`vocello`, links the engine
in-process), a marketing site (`website/`, React + Vite on Vercel), and Python 3
benchmark/diagnostic scripts (`benchmarks/`, `scripts/*.py`).

## Source of truth

This file is the **main agent guide** for the repo. For deep architecture and
engine invariants see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); for
per-subsystem detail see [`docs/reference/`](docs/reference/). When facts
disagree, trust in this order: `Sources/` → `project.yml` → `scripts/` →
`.github/workflows/release.yml` → `CLAUDE.md` → other prose.
`Sources/Resources/qwenvoice_contract.json` is the canonical schema for
speakers/models/variants/HF revisions. **If you change something that
invalidates a doc, update the doc in the same change.**

## Hard rules (do not violate)

- **iOS is on-device only. Never use the iOS Simulator** or simulator-only tools
  for iOS UI work — no `xcodebuild -destination 'platform=iOS Simulator…'` and
  **no XcodeBuildMCP simulator tools** (`build_run_sim`, `snapshot_ui`,
  `list_sims`, …) or Axiom `simulator-tester` for the `VocelloiOS` target. Use
  `scripts/ios_device.sh` (see Commands). The iOS Simulator is intentionally
  unsupported — the engine runs in-process on Metal.
- **`project.yml` is the Xcode project source of truth.** Never edit
  `QwenVoice.xcodeproj/project.pbxproj` directly. Edit `project.yml`, then
  `./scripts/regenerate_project.sh`. (XcodeGen gotcha: the iOS target lists its
  bundled JSON/catalog/`voice-previews` under `sources:` with
  `buildPhase: resources`, **not** under `resources:` — XcodeGen silently drops
  them otherwise and iOS builds compile but crash on launch. See `project.yml`.)
- **Single shippable config: `Release` only.** No `DEBUG` symbol, no
  Debug-vs-Release fork. `build.sh` compiles `-Onone` for the local loop;
  `release.sh` compiles the same config optimized. Debug capabilities are gated
  at runtime by `DebugMode.isEnabled` (`QWENVOICE_DEBUG=1` env, or the hidden
  7-tap version label in Settings → `UserDefaults QwenVoice.DebugModeEnabled`).
  Reserve `#if DEBUG` for test/sim scaffolding only.
- **SPM deps are pinned exact for backend determinism.** Move `mlx-swift` and
  `mlx-swift-lm` **in lockstep** (never one alone); don't float pins without a
  benchmark-gated review on a throwaway branch (`vocello bench` + listening
  pass). MLX is the **only** Qwen3-TTS backend — do not pivot to Core ML.
- **`accessibilityIdentifier` values** (e.g. `voicesRow_*`, `textInput_*`,
  `studioChip_*`) are stable surface area and must survive refactors.
- **App sandbox is disabled** (`Sources/QwenVoice.entitlements`) because MLX
  requires it. Hardened runtime is on for release (`allow-unsigned-memory`,
  `disable-library-validation`); iOS has `increased-memory-limit`.
- **Privacy:** never commit personal identifiers (legal names, emails, home
  paths, device nicknames, UDIDs, hardcoded team IDs) into user-facing files
  (`README.md`, `website/`, `docs/`, release notes). Technical bundle IDs like
  `com.patricedery.vocello` are fine.

### Engine invariants (do not regress)

The full list lives in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (engine
core + the macOS/iOS request lifecycles). The ones most likely to bite: the
**prewarm reentrancy gate** (`acquire/releasePrewarmSlot` —
never pair a throwing `try? await acquire` with an unconditional
`defer { release }`); **event streams** (macOS `.unbounded`, iOS
`.bufferingNewest(64)`); **cancellation ownership** (iOS cancel is cooperative
only — discard the result on `Task.isCancelled` so cancelled takes never land in
History; `MLXTTSEngine.generate`'s catch must not rethrow `CancellationError`
early); **per-tier memory** (`NativeMemoryPolicyResolver` — no hard
`Memory.memoryLimit` in production, no Quality→Speed OOM fallback); **decoder
drift** (vendored `Qwen3TTSSpeechTokenizer` uses input-side overlap-and-add);
**XPC event forwarding** drains `engine.events` on `Task.detached(.utility)`, off
`MainActor`.

## Commands

```sh
# Project generation + validation (run check before any build/commit)
./scripts/regenerate_project.sh          # regenerate QwenVoice.xcodeproj from project.yml
./scripts/check_project_inputs.sh        # required pre-build / pre-commit gate

# macOS local loop (single Release config, -Onone)
./scripts/build.sh build                 # fast build, no launch
./scripts/build.sh run [--telemetry]     # build + launch Vocello.app (+ stream logs)
./scripts/build.sh cli [--help]          # build/run the headless vocello CLI
./scripts/build.sh release               # optimized signed DMG (via release.sh)
./scripts/build.sh clean                 # rm -rf build/ (~7 GB; next build is full)
QWENVOICE_DEBUG=1 ./scripts/build.sh run # debug data folder + telemetry

# Foundation compile-safety (throwaway DerivedData, removed on exit)
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios   # compile-safety only

# macOS UI smoke (single VocelloMacSmokeUITests class, 10 tests)
xcodebuild test -project QwenVoice.xcodeproj -scheme QwenVoice \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData

# iOS — ON-DEVICE ONLY (paired iPhone; observe via iPhone Mirroring, OLED-safe; `build`
# preserves a dSYM under build/ios/dsyms/ for symbolication). One verb per lane
# (see docs/reference/ios-device-testing.md §3 for the lane→tool map + burn-in policy):
scripts/ios_device.sh preflight          # readiness: mirror+device+signing+app+dSYM + unlock advisory
scripts/ios_device.sh bench [spec]       # build → install → autorun → pull → summarize (generation proof)
scripts/ios_device.sh ui-test|test       # VocelloiOSUITests on device (test = + verdict + artifacts)
scripts/ios_device.sh profile [spec]     # Instruments/xctrace trace of an autorun generation
scripts/ios_device.sh review [--baseline]# UI capture tour + baseline diff (vision MCP)
scripts/ios_device.sh crashes [--test]   # pull + xcsym-symbolicate MetricKit crash/hang diagnostics
scripts/ios_device.sh debug [spec]       # get-task-allow build + attached launch + LLDB attach guidance
scripts/ios_device.sh logs [spec]        # attached launch → retained build/ios-logs/<run>.log
scripts/ios_device.sh gate               # pre-merge gate: preflight → test → crashes → verdict
scripts/ios_device.sh launch|console|pull|shot|mirror

# Perf/quality (deterministic driver; listening pass is the mandatory pre-merge gate)
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> --label "release-QA" --ledger

# Marketing site
npm --prefix website run dev|build
```

Telemetry (when `QWENVOICE_DEBUG=1`) writes JSONL under
`~/Library/Application Support/QwenVoice-Debug/diagnostics/`; aggregate with
`scripts/summarize_generation_telemetry.py`. Committed benchmark logs must be
≤256 KB; raw `*.jsonl` is gitignored.

## Architecture (big picture)

Full code-verified map: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (modules,
dependency graph, runtime, macOS/iOS request lifecycles, persistence, model
management, telemetry). The summary below is the day-to-day essentials.

Three engine hosts sharing one core:

- **macOS** — engine runs **out-of-process** in an XPC service
  (`QwenVoiceEngineService` / `EngineServiceHost.swift`) for crash isolation and
  memory containment; the app talks to it over XPC via `QwenVoiceNative`.
- **iOS** — engine runs **in-process** (`MLXTTSEngine` via
  `NativeRuntimeFactory`). The old ExtensionKit extension was removed (non-UI
  extensions are Jetsam-capped independently of `increased-memory-limit`).
- **CLI** — `vocello` links the engine frameworks in-process and reuses models
  the app already installed.

Module flow: `QwenVoiceBackendCore` (low-level MLX + audio: model load,
synthesis, codecs) → `QwenVoiceCore` (`TTSEngine`, `MLXTTSEngine`,
`TTSEngineError`, `GenerationMode`, audio prep) → platform hosts above.
`SharedSupport/` is the dual-platform UI share point (player view model,
transcriber, reference-clip recorder, language detector). Generation flows
through coordinators: macOS `Sources/ViewModels/`
(`CustomVoiceCoordinator`, `VoiceDesignCoordinator`, `VoiceCloningCoordinator`);
iOS `Sources/iOS/Studio/` (`StudioGenerationCoordinator`,
`IOSBatchGenerationCoordinator`). Engine selection is a single option
(`AppEngineSelection.current()` → `.native` everywhere); platform differences
are enforced by the runtime factory + the XPC/in-process split.

Three generation modes: **Custom Voice** (built-in Qwen3 speakers + delivery
prompt), **Voice Design** (natural-language voice brief), **Voice Cloning**
(reference clip). Models: Qwen3-TTS 1.7B in **Speed (4-bit)** / **Quality
(8-bit)**.

## Claude Code tool, skill & MCP routing

Reach for the **Bash scripts above first** for build/run/test — they encode the
single-config, deterministic local loop. Then:

- **MLX / backend / `QwenVoiceBackendCore` work** → `mlx-swift` + `mlx-swift-lm`
  skills, and read `docs/reference/{mlx-guide,qwen3-tts-guide,mimi-codec-guide,
  metal-guide}.md` before touching `MLXArray`/`Memory`/`GPU`, prompt
  construction, or the vendored codec.
- **Apple framework APIs / iOS 26 / post-cutoff APIs** → `sosumi`
  (`searchAppleDocumentation` / `fetchAppleDocumentation`) + `axiom-apple-docs`
  / `axiom-swiftui` skills. **Library/framework/SDK/CLI docs (non-Apple)** →
  `context7` (resolve-library-id → query-docs) per the global rule.
- **macOS build/run/inspect** → the Bash scripts, or `XcodeBuildMCP` for a quick
  check (macOS scheme `QwenVoice`). `XcodeBuildMCP` simulator tools are
  **off-limits for iOS** (on-device rule).
- **iOS on-device lanes** (`scripts/ios_device.sh`, one verb per lane) →
  `test`→`axiom:test-runner` on the `.xcresult`; `crashes`→`axiom:crash-analyzer` / `xcsym`
  vs the build dSYM; `profile`→`axiom:performance-profiler` / `xcprof`; `debug`→XcodeBuildMCP
  device/debugging; `review`→vision MCP `mcp__zai-mcp-server__ui_diff_check` vs
  `docs/ios-review-baselines/`. Burn-in-safe by construction; the full map + policy is in
  `docs/reference/ios-device-testing.md` §3. `gate` = preflight → test → crashes → verdict.
- **Process / planning** → Superpowers: `brainstorming` before creative/feature
  work, `systematic-debugging` for any bug/test failure, `writing-plans` /
  `executing-plans`, `verification-before-completion` before claiming done,
  `requesting-code-review` / `finishing-a-development-branch`,
  `using-git-worktrees` for isolation.
- **Review & audits** → `/code-review`, `/security-review`, `/simplify`, and
  Axiom auditors (`concurrency-auditor`, `memory-auditor`,
  `swift-performance-analyzer`, `swiftui-{architecture,layout,nav,performance}-auditor`,
  `codable-auditor`, `security-privacy-scanner`, `accessibility-auditor`,
  `energy-auditor`, `liquid-glass-auditor`).
- **Crash logs (.ips / MetricKit / .crash)** → `axiom:crash-analyzer` agent /
  `xcsym` (via `axiom-tools`). **Profiling** → `axiom:performance-profiler` /
  `xcprof`. **Build/environment failures** → `axiom:build-fixer` (but inspect
  the relevant `scripts/*.sh` output via Bash first).
- **GitHub** (issues/PRs/releases/remote search) → `mcp__github__*`; `gh`/`git`
  via Bash for local-only ops. **Hugging Face** (model revisions/downloads) →
  `hf` CLI via Bash + `huggingface-skills`. **Marketing site (`website/`)** →
  `chrome-devtools-mcp` for browser verification + `npm --prefix website`.

## Conventions quick-reference

- Animations route through `appAnimation` / `AppLaunchConfiguration.performAnimated`
  (honor Reduce Motion). Liquid Glass surfaces fall back to solid fills under
  Reduce Transparency. No color-only signal — mode colors always pair with an
  icon/label/position cue.
- iOS vertical scroll surfaces use `IOSScrollView` (not raw `ScrollView`) — it
  bundles no-rubber-band, custom indicator, and the bottom fade that keeps
  content clear of the TabDock. Pass `bottomFadeHeight: 0` for sheets above the dock.
- There is no formatter/linter; **the build is the typecheck.** Follow existing
  Swift style; keep minimal changes and preserve module boundaries. Vendored
  patches under `third_party_patches/mlx-audio-swift/` are allowed when the fix
  belongs below `QwenVoiceCore` — keep them small and upstream-styled.
- Branch hygiene: once a PR merges into `main`, delete the remote feature branch
  immediately and fast-forward/remove the local branch. Don't leave stale merged
  branches on `origin`.
- **Commits / pushes:** once an implementation or phase is complete and verified
  (gates green), commit and push to `main` without asking each time. Use
  Conventional Commits and end commit messages with
  `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Read for depth

- `docs/ARCHITECTURE.md` — **start here**: unified, code-verified map of modules,
  dependencies, runtime architecture (XPC vs in-process), the generation
  lifecycle, persistence, model management, and telemetry.
- `docs/reference/` — per-subsystem reading list: `mlx-guide.md`,
  `qwen3-tts-guide.md`, `mimi-codec-guide.md`, `metal-guide.md`,
  `swift-performance-guide.md`, `ios-engine-optimization.md`,
  `telemetry-and-benchmarking.md`, `cli.md`, `macos-release-qa.md`,
  `ios-device-testing.md`, `privacy-storage.md`, `macos-permissions.md`,
  `mlx-audio-swift-patching.md`.
- `PRODUCT.md` (product/brand) · `website/AGENTS.md` + `website/PRODUCT.md`
  (marketing site) · `docs/qwen_tone.md` (tone prompt-writing; supplemental,
  may lag shipped behavior — trust README/CLAUDE.md first).
