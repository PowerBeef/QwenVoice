# CLAUDE.md

`CLAUDE.md` is the authoritative repository operating guide for coding agents working in QwenVoice. Session-level user, system, and developer instructions still apply above this guide.

## Repo Overview

QwenVoice is the repository identity and continuity brand for the merged Vocello Apple-platform product line.

Current product reality:

- the repo stays `QwenVoice`
- the shipped iPhone app is `Vocello`
- the next macOS release ships as `Vocello.app` inside `Vocello-macos26.dmg`; the supporting framework/service/runtime modules (`QwenVoiceCore`, `QwenVoiceEngineService`, `QwenVoiceEngineSupport`, `QwenVoiceNative`) keep their `QwenVoice` names internally for continuity
- the current public milestone uses a `macOS-first release track`, with iPhone retained as a compile-safe and deferred release surface

The main working surfaces are:

- `Sources/` for the macOS app shell, shared app models/services/views, and the shipping Mac target
- `Sources/QwenVoiceCore/` for shared Apple-platform runtime semantics, contract types, model variants, and iOS extension transport
- `Sources/QwenVoiceNative/` for the macOS app-facing engine proxy/store/client layer
- `Sources/QwenVoiceEngineSupport/` for shared macOS engine IPC and transport types
- `Sources/QwenVoiceEngineService/` for the bundled macOS XPC helper
- `Sources/iOS/` and `Sources/iOSSupport/` for the iPhone app shell and iPhone-only support layers
- `Sources/SharedSupport/` for cross-platform playback, persistence, and other shared app-layer helpers
- `Sources/iOSEngineExtension/` for the isolated iPhone engine extension target
- `Sources/Resources/qwenvoice_contract.json` for shared model, variant, speaker, output, and required-file metadata
- `scripts/` plus `.github/workflows/` for validation, release packaging, and CI behavior
- `config/apple-platform-capability-matrix.json` for the maintained cross-platform capability, bundle-identity, and entitlement baseline used by release verification

This checkout is a native Apple-platform codebase for macOS and iPhone. Do not reintroduce a repo-owned Python backend, Python setup path, or standalone CLI surface.

## Maintained Docs

- `CLAUDE.md` — canonical repository operating guide for coding agents
- `README.md` — public landing page and end-user overview
- `CONTRIBUTING.md` — contributor workflow, source-of-truth order, validation entrypoints
- `docs/README.md` — documentation index
- `docs/qwen_tone.md` — supplemental tone and prompt-writing guidance
- `docs/reference/current-state.md` — current repo facts
- `docs/reference/engineering-status.md` — current strengths and caveats
- `docs/reference/backend-freeze-gate.md` — rebuilt QA gate for static validation, source/native/UI QA layers, builds, and unsigned release proof
- `docs/reference/frontend-backend-contract.md` — app-facing backend state, delivery state, and QA gate
- `docs/reference/release-readiness.md` — macOS-first release-track policy, proof status, public-homepage freeze rules, tier→workflow mapping
- `docs/reference/live-testing.md` — local QA lanes, strict e2e behavior, result paths, xcresult triage commands
- `docs/reference/privacy-storage.md` — local model, output, history, saved-voice, App Group, and deletion-path reference
- `docs/reference/vendoring-runtime.md` — runtime, vendoring, and packaging boundaries
- `docs/reference/mlx-audio-swift-patching.md` — vendor delta under `third_party_patches/mlx-audio-swift/`, rebase procedure, and post-rebase build checklist

There are no repo-tracked local skills under `.agents/skills/` or `.claude/skills/` in this checkout. Do not point contributors at removed CLI docs, deleted backend references, or deleted repo-scoped skills.

Public homepage posture:

- `README.md` leads with `QwenVoice` because that is the currently shipped public brand (`v1.2.3`). Its "A Note on What's Changing" section frames `Vocello` as the forward rebrand that lands with the next macOS release.
- The GitHub repo description must stay consistent with the README — do not claim a Vocello-first public posture while the published release is still QwenVoice-branded.
- Leave the GitHub homepage URL blank unless the user explicitly asks to restore or change it.
- Keep public messaging aligned with the currently shipped macOS product reality and the active `macOS-first release track`.
- Do not present iPhone as a current public release surface until the release-track policy changes. The iPhone app is framed publicly as the in-development "Vocello for iPhone" — standalone, 4-bit, open source in this repo, published via the App Store once ready.

Current release-track policy:

- The next public release target is macOS only.
- The next macOS release ships under the `Vocello` brand as `Vocello-macos26.dmg` and requires `macOS 26.0` as the minimum. `macOS 15` was supported only on the already-shipped `QwenVoice v1.2.3` and is retired going forward.
- Do not retroactively edit `QwenVoice v1.2.3` release notes or the shipped-state sections of `README.md` — they must stay accurate to what shipped.
- Keep iPhone green at generic compile level on the working branch, but do not treat iPhone release/TestFlight proof as blocking for the current milestone.
- Re-open iPhone release proof only through an explicit milestone change after the shared core is proven stable on macOS.

## Source Of Truth

When repo facts disagree, trust sources in this order:

1. `Sources/`
2. `project.yml`
3. `scripts/` plus `.github/workflows/`
4. `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, and `docs/reference/release-readiness.md`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for shared model, speaker, and platform-variant metadata.

## Claude Code Tooling

When operating in this repo with Claude Code, prefer the following over generic equivalents:

- Local validation and tests: `./scripts/qa.sh validate` and `./scripts/qa.sh test --layer {contract|swift|native|ios|e2e|all}` are the canonical entrypoints for CI, `release.sh`, and `rescue_gate.sh`.
- Audio-QC and generation-speed-profile bench runs: `./scripts/qa.sh test --layer perf` is the opt-in performance lane. It drives `GenerationQualityAuditLiveTests`, requires installed models under `~/Library/Application Support/QwenVoice/models` (or `QWENVOICE_AUDIO_QC_MODELS_ROOT`), and reads `QWENVOICE_QWEN3_GENERATION_SPEED_PROFILE`, `QWENVOICE_QWEN3_MEMORY_CLEAR_CADENCE`, `QWENVOICE_QWEN3_POST_REQUEST_CACHE_POLICY`, and the `QWENVOICE_AUDIO_QC_*` matrix env vars. Not part of `--layer all`. First-time model bootstrap uses `huggingface_hub` (`python3 -m pip install --user -r scripts/requirements-perf-bootstrap.txt`) to populate `$QWENVOICE_AUDIO_QC_MODELS_ROOT` from the `mlx-community` namespace.
- Perf-lane orchestration regression gate: `./scripts/qa.sh test --layer perf-static` runs only the static unit tests inside `GenerationQualityAuditLiveTests` (benchmark profile layout, long-text segmentation) — fast, model-free, and included in `--layer all`. Hosted CI runs this on every PR alongside `swift` and `native` so a benchmark-profile regression cannot hide inside the wider swift run.
- Apple platform docs (HIG, Swift, WWDC, Swift-DocC): use the `sosumi` MCP (`mcp__sosumi__searchAppleDocumentation`, `mcp__sosumi__fetchAppleDocumentation`, `mcp__sosumi__fetchAppleVideoTranscript`). Do not WebFetch developer.apple.com.
- Third-party Swift package docs (`mlx-swift`, `mlx-audio-swift`, `swift-collections`, `swift-numerics`, `swift-async-algorithms`, `swift-transformers`, `Hub`, `Jinja`, `EventSource`): use the `context7` MCP (`mcp__context7__resolve-library-id` then `mcp__context7__query-docs`). Prefer this over grepping `third_party_patches/` and `Package.resolved` for API discovery. Apple-platform docs still go through `sosumi`.
- Interactive Xcode build, test, or simulator inspection: use `XcodeBuildMCP` tools (`build_run_sim`, `test_sim`, `screenshot`, `snapshot_ui`, `list_sims`, `boot_sim`, `show_build_settings`). For headless test runs called from CI or release, use `./scripts/qa.sh`.
- GitHub PR, issue, workflow, release ops: use the `github` MCP. Routine `git` commands stay on Bash.
- macOS UI scripting beyond `xcodebuild`: use the `applescript` MCP for AppleScript-driven app or system automation.
- Triage failed `qa.sh` layers by reading the `.xcresult` bundles under `build/harness/results/<layer>/` with `xcrun xcresulttool get build-results --path …` (build) or `xcrun xcresulttool get test-results summary --path …` (test) before changing code.

Browser MCPs (`chrome-devtools`, `claude-in-chrome`) and computer-use are not relevant to this native macOS/iOS codebase. Do not introduce them into automated flows.

## Git Workflow Default

- Work on the user-designated branch (currently `claude/init-project-7ZdXV`).
- Do not create extra branches or worktrees unless the user explicitly asks for one.
- Do not let generic tool, plugin, or skill defaults override this repo-specific rule.

## Commit & Pull Requests

Use short imperative subjects, often scoped with a colon (for example, `Engine probe Phase 2c: …` or `Fix bench helper …`). Keep commits focused. Pull requests should describe behavior changes, list commands run, link related issues, and include screenshots or screen recordings for UI-facing changes.

## Safe Edit Boundaries

- `project.yml` drives `QwenVoice.xcodeproj`. Prefer editing `project.yml` and regenerating the project over hand-editing generated project files.
- The macOS app target intentionally excludes `Sources/QwenVoiceEngineService/`, `Sources/QwenVoiceEngineSupport/`, `Sources/iOS*/`, `Sources/Resources/ffmpeg/`, and `Sources/Resources/vendor/` as ordinary app sources while embedding the XPC service target through `project.yml`. Keep that split intact.
- The iPhone app target and the iPhone engine-extension target both depend on `QwenVoiceCore`. Keep engine execution isolated from the iPhone UI process.
- `third_party_patches/mlx-audio-swift/` is the repo-owned native backend source boundary for MLXAudioSwift. Keep its package manifest and pins aligned with `project.yml` and `Package.resolved`.
- `config/apple-platform-capability-matrix.json` is the release-verification source of truth for bundle identifiers, expected application groups, opportunistic memory-limit entitlements, and packaged-resource exclusions.
- If `Sources/Resources/ffmpeg/` or `Sources/Resources/vendor/` appear locally, treat them as generated or local-only leftovers, not as maintained tracked checkout surfaces.
- App data under `~/Library/Application Support/QwenVoice/` or a `QWENVOICE_APP_SUPPORT_DIR` override is runtime state, not repo source.
- Watch for accidental `__pycache__`, `.pyc`, `.DS_Store`, and `.profraw` paths when regenerating or reviewing changes.

## Architecture Boundaries

- `Sources/QwenVoiceApp.swift` composes macOS app-global services, owns the separate Settings scene, and initializes the app-facing Mac engine through `AppEngineSelection`.
- `Sources/ContentView.swift` owns the macOS `NavigationSplitView`, toolbar/search chrome, sidebar selection, and persisted generation drafts.
- `Sources/QwenVoiceNative/` is the macOS app-side engine layer: `TTSEngineStore`, `XPCNativeEngineClient`, chunk brokering, and the app-facing `MacTTSEngine` surface live there.
- `Sources/QwenVoiceEngineSupport/` is the shared macOS engine transport boundary used by both the app and the helper.
- `Sources/QwenVoiceEngineService/` hosts the active macOS shared-core runtime through `QwenVoiceCore` and owns the bundled macOS XPC helper entrypoint and session/host behavior.
- `Sources/QwenVoiceCore/` is the cross-platform engine core and shared semantic boundary. Keep it free of app-process UI assumptions.
- `Sources/iOSEngineExtension/` hosts the isolated iPhone engine process through ExtensionFoundation. Heavy generation and prewarm work belongs there, not in the iPhone UI app process.
- `Sources/iOS/VocelloEngineExtensionPoint.swift` owns monitor-backed iPhone extension discovery and preferred-identity selection, while `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` owns active transport replacement and teardown.
- `Sources/iOS/` and `Sources/iOSSupport/` own the iPhone SwiftUI shell, model delivery UX, library/history views, and memory-pressure coordination.
- `Sources/SharedSupport/` owns shared playback and generation-persistence surfaces that now serve both the macOS and iPhone apps.
- `Sources/Services/AppPaths.swift` and `Sources/iOSSupport/Services/AppPaths.swift` are the path boundaries for runtime data on each platform.
- The iPhone App Group surface is intentionally file-based and rooted under `Sources/iOSSupport/Services/AppPaths.swift`; keep shared state constrained to the required app-support subtree for models, downloads, outputs, voices, and cache data.
- `Sources/Models/TTSContract.swift`, `Sources/Models/TTSModel.swift`, and the `QwenVoiceCore` semantic types load `Sources/Resources/qwenvoice_contract.json`.

Default macOS runtime data layout:

```text
~/Library/Application Support/QwenVoice/
  models/
  outputs/
    CustomVoice/
    VoiceDesign/
    Clones/
  voices/
  history.sqlite
```

## Platform And Product Constraints

- Minimum supported OS versions are `macOS 26.0+` and `iOS 26.0+`.
- The official minimum hardware floor is `Mac mini M1, 8 GB RAM` and `iPhone 15 Pro`.
- Process isolation is a product requirement on both platforms. Do not move heavy generation, prewarm, or model-load work back into the UI process.
- `QW_UI_LEGACY_GLASS` and macOS 15 compatibility are retired. Do not restore older dual-profile or dual-OS support.
- macOS exposes both `Speed / 4-bit` and `Quality / 8-bit` variants for Custom Voice, Voice Design, and Voice Cloning.
- 8 GB/floor Macs default to and recommend Speed; mid/high-memory Macs default to and recommend Quality.
- Mac users may select either installed macOS variant per generation mode; legacy base IDs resolve to the hardware-recommended variant. Keep download/install/repair/delete metadata keyed by variant-specific IDs such as `pro_custom_speed` and `pro_custom_quality`.
- iPhone uses Speed-only model variants.
- Keep shared styling centralized in `Sources/Views/Components/AppTheme.swift` on macOS and in the iPhone shell primitives/theme layer on iOS.
- `QW_TEST_SUPPORT` is a Debug/test-only Swift compilation condition (stub engines, UI launch configuration, fault injection, fixture helpers, opt-in benchmark hooks). Release builds must not depend on it.

## Coding Style

Match the existing Swift style: 4-space indentation, `PascalCase` types, `camelCase` properties/functions, and descriptive enum cases. Keep SwiftUI views and coordinators focused by feature area. No repo-wide SwiftFormat or SwiftLint config is present, so preserve local formatting and avoid mass-formatting, especially under `third_party_patches/`.

## Native SwiftUI Discipline

- Keep UI work conservative, native, and stability-led. Prefer standard SwiftUI navigation, forms, lists, toolbars, sheets, controls, and system materials over theme-first redesigns.
- Do not reintroduce the removed desktop-studio shell, generated-reference redesign workflow, oversized hero chrome, inspector layout, full-window footer player, or decorative glass/card systems.
- Treat UI polish as small refinements to the existing app structure. Any broad layout change needs an explicit product decision and must not happen while runtime responsiveness or memory behavior is unstable.
- Keep generation screens responsive under backend activity: avoid speculative mode-switch work, broad environment-object invalidation, and visual effects that rebuild large view subtrees during prewarm or generation.
- Keep rescue work boring: no generated UI redesigns, no large Liquid Glass shell work, no screen-mount model warmup, and no overlapping heavy validation commands on this 8 GB development machine.

## Common Commands

Always start with the cheap gates:

```sh
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
```

Project regen (after editing `project.yml`):

```sh
./scripts/regenerate_project.sh
```

Builds:

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

Tests (qa.sh is the single entrypoint; pick the layer you need — there is no "single test" knob below the layer):

```sh
./scripts/qa.sh test --layer contract
./scripts/qa.sh test --layer swift
./scripts/qa.sh test --layer native
./scripts/qa.sh test --layer ios     # structurally skips when no iOS simulator is installed
./scripts/qa.sh test --layer e2e
QWENVOICE_E2E_STRICT=1 ./scripts/qa.sh test --layer e2e   # release-signoff strict mode
```

The opt-in performance/audio-QC lane (requires installed models, not part of `--layer all`):

```sh
./scripts/qa.sh test --layer perf
QWENVOICE_AUDIO_QC_MODES=CustomVoice ./scripts/qa.sh test --layer perf   # scope to a single mode
```

Compare a fresh perf-lane run against the committed baseline at `scripts/perf-baseline-manifest.json`:

```sh
./scripts/compare_perf_manifest.sh                                    # uses build/audio-qc/qa-perf/generation-manifest.json
./scripts/compare_perf_manifest.sh path/to/other-manifest.json
QWENVOICE_PERF_WALL_TOLERANCE_PCT=10 ./scripts/compare_perf_manifest.sh   # tighter wall/RTF tolerance
```

Local rescue and release:

```sh
./scripts/rescue_gate.sh --fast        # docs / static cleanup
./scripts/rescue_gate.sh                # full lane; gates on swap, override via QW_RESCUE_SWAP_LIMIT_MB
./scripts/release.sh --preflight full
./scripts/verify_release_bundle.sh build/Vocello.app
./scripts/verify_packaged_dmg.sh build/Vocello-macos26.dmg build/release-metadata.txt
```

iPhone TestFlight (deferred):

```sh
./scripts/check_ios_catalog.sh
./scripts/release_ios_testflight.sh
./scripts/verify_ios_release_archive.sh
```

Disk-space recovery (this dev machine has limited storage):

```sh
./scripts/clean_build_caches.sh             # remove always-safe items (~5 GB typical)
./scripts/clean_build_caches.sh --aggressive # also wipe qa.sh + release derived-data (~11 GB extra; slower next build)
./scripts/clean_build_caches.sh --dry-run    # print what would be removed
```

## Testing Conventions

Use XCTest. Name test files after the behavior under test (for example, `GenerationDraftsTests.swift`), and prefix test methods with `test…`. The lane preference (cheapest first, then progressively heavier) is covered above under Common Commands.

## Performance Benchmarking

Two complementary methods, both maintained:

### Default — desktop-UI bench (full-pipeline, user-perceived)

The **default** for any "is this fast / does it feel right?" question. Mirrors the actual user experience: text typed in the input box → Generate clicked → live-preview heard → final file saved → autoplay handoff. Captures issues invisible to the engine-only perf-lane (live-preview underruns, MainActor congestion, autoplay handoff hitches, sheet routing, batch dialog flow, paste latency, etc.).

Driven by Claude (via the computer-use MCP) or you manually:
1. Set up Vocello with the desired mode + brief + script
2. Trigger generation (Cmd+Return); the timing helper measures wall→file-stable + audio duration
3. Record a row per sample to a CSV

```sh
# Per-sample timing helper. Caller is responsible for placing Vocello
# with populated inputs in the foreground; the script issues Cmd+Return,
# waits for new wav file(s) to finish writing, sums afinfo audio
# duration across long-form batch segments, and appends a CSV row.
./scripts/bench_ui_generation.sh <mode> <length> <state> <sample> [csv_path] \
    [--log-file <path>]
#   mode:   custom | design | clone
#   state:  cold | warm
#   --log-file: optional; capture Vocello stdout to detect live-preview
#               anomalies (DEBUG-only). Adds columns: underrun_count,
#               total_stall_ms, ttfa_ms, max_chunk_gap_ms, decode_fails,
#               stream_errors, duration_mismatch_s, chunk_count.
```

To capture anomaly columns, launch Vocello via the binary so stdout is
redirectable, then pass the same path to every sample call:

```sh
LOG=/tmp/vocello-bench.log
nohup "$APP/Contents/MacOS/Vocello" > "$LOG" 2>&1 &
# ...drive UI...
./scripts/bench_ui_generation.sh custom medium warm 1 /tmp/results.csv --log-file "$LOG"
```

The `[LivePreview]` schema (DEBUG-only, emitted by `AudioPlayerViewModel`):

| Event | Keys |
|---|---|
| `session_start` | `session=<id>` |
| `chunk_arrived` | `seq audio_s cumulative_s queue_depth gap_ms` |
| `playback_started` | `ttfa_ms queue_depth` |
| `underrun_paused` | `underrun_n audio_played_s` |
| `underrun_resumed` | `stall_ms queue_depth` |
| `decode_failed` | `branch=<file\|inline>` |
| `stream_error` | `message=<text>` |
| `final_handoff` | `preview_audio_s final_audio_s delta_s` |
| `preview_completed` | `underruns total_stall_ms decode_fails stream_errors max_chunk_gap_ms chunk_count` |

Cold/warm protocol:
- **Cold**: kill Vocello (`pkill -x Vocello`), relaunch (`open …Vocello.app` or via binary), wait for "Engine ready", paste inputs, then call the helper
- **Warm**: call the helper back-to-back without restarting Vocello

Standard length tiers: micro (~3 words) / short (~10 words) / medium (~50 words) / long (~150 words) / very-long (~500–800 words, exercises long-form-batch routing).

**Memory pressure during the UI bench is a feature, not a failure.** The bench is meant to characterise behaviour at the hardware floor, including swap-pressure regimes real users hit. Do NOT abort a sweep because `vm.swapusage` is high — push through. The only legitimate abort is engine wedge (no chunk progress for >60 s with the Vocello process still alive). The single-instance rule (`pkill -x Vocello` before each cold relaunch) is the only memory-related invariant; overlapping instances confuse the engine's process identity logic and pollute the `[LivePreview]` trace.

Output dirs (the helper resolves these from `mode`):
- `~/Library/Application Support/QwenVoice/outputs/CustomVoice/`
- `~/Library/Application Support/QwenVoice/outputs/VoiceDesign/`
- `~/Library/Application Support/QwenVoice/outputs/Clones/`

### Tight engine regression check — `qa.sh perf`

Programmatic, narrow-scope, fast. Use when verifying engine internals haven't regressed (cold load, warm gen, RTF, chunk write timings, memory usage by stage), or for CI-style comparison against the committed baseline at `scripts/perf-baseline-manifest.json`.

Doesn't capture: paste latency, UI activation, sheet routing, autoplay handoff, live-preview underrun behavior, or anything the user actually feels.

```sh
./scripts/qa.sh test --layer perf
QWENVOICE_AUDIO_QC_MODES=CustomVoice ./scripts/qa.sh test --layer perf
./scripts/compare_perf_manifest.sh
```

When choosing: if the question is about user experience or end-to-end timing, use the desktop-UI bench. If it's about engine determinism / regression-bisecting an internal change, use `qa.sh perf`.

Notes:

- `scripts/qa.sh` is the primary local validation, test, and performance entrypoint.
- Maintained QA layers are `contract`, `swift`, `native`, `ios`, and `e2e`. `perf` is opt-in and not part of `--layer all`.
- `e2e` is the macOS XCUITest smoke layer. Hosted CI may soft-skip first-time macOS Accessibility/TCC or foreground-window activation failures; strict local release proof uses `QWENVOICE_E2E_STRICT=1`, where those issues fail instead of becoming skipped passes.
- The `perf` layer drives `GenerationQualityAuditLiveTests` for live audio-QC validation. It needs installed models under `QWENVOICE_AUDIO_QC_MODELS_ROOT` and is gated by a `vm.swapusage` preflight (refuses below `QWENVOICE_PERF_SWAP_MIN_FREE_MB` or above `QWENVOICE_PERF_SWAP_HARD_STOP_MB`).
- qa.sh artifacts live under `build/harness/{derived-data,results,source-packages,artifacts}`; heavy lanes serialize on `build/harness/.lock`.
- `QwenVoice Foundation`, `VocelloiOS Foundation`, and `Vocello UI` are the maintained plan-backed test schemes. The committed plans live under `tests/Plans/`.
- During the current `macOS-first release track`, the default required local release-readiness loop is `check_project_inputs`, `qa.sh validate`, `contract`, `swift`, `native`, foundation builds for macOS and iOS, `release.sh`, `verify_release_bundle.sh`, and `verify_packaged_dmg.sh`. Add strict `e2e` on the controlled release machine before public signoff.
- Generic iPhone compile proof comes from `./scripts/build_foundation_targets.sh ios` — the iOS QA layer requires an installed iPhone simulator.
- For deterministic local compile proof, prefer `./scripts/build_foundation_targets.sh` over a shared-DerivedData signed debug build. The script uses isolated build roots and `.xcresult` bundles.
- On this 8 GB development machine, keep validation deliberately low-RAM and serialized: run the cheapest relevant gate first, and never overlap heavy `xcodebuild`, `scripts/qa.sh`, release packaging, live app validation, or native smoke processes.
- If a QA layer fails, inspect the emitted `.xcresult` bundle under `build/harness/results/<layer>/` before changing code: `xcrun xcresulttool get build-results --path <path>` for builds, `xcrun xcresulttool get test-results summary --path <path>` for tests.
- SourceKit diagnostics like `No such module 'MLX'` or `Cannot find type X in scope` after an edit are index staleness, not real errors. Trust only `xcodebuild`, `scripts/qa.sh`, and `./scripts/build_foundation_targets.sh`.
- `xcodebuild` silently skips `-only-testing:QwenVoiceTests/<ClassName>` flags when `<ClassName>` doesn't exist (deleted/renamed). The lane will report success on the surviving subset. After deleting test classes, audit `scripts/qa.sh` for stale `-only-testing:` references — otherwise the layer's actual coverage is smaller than expected.
- The `swift` layer (~238 tests) and curated subset layers (`native`, `e2e`) can disagree on hosted CI: a test that passes under `swift` may fail under a smaller curated subset because tighter test packing exposes shared-state races (notably the bundled `QwenVoiceEngineService`'s engine-init state across `XPCNativeEngineClientTests` test methods). When seeing a per-layer hosted-CI failure that doesn't reproduce locally, check whether the failing test depends on the bundled XPC service AND whether the layer subset reorders test classes alphabetically.

## Swift Concurrency Gotchas

- `Self` cannot be referenced inside a `static let` initializer on a class (covariant-Self rule). Use the concrete type name (e.g. `EngineServiceHost.logger`) instead of `Self.logger` in static member initializers.
- `Task.detached { ... }` does not inherit cancellation from the parent. If cancellation must propagate, wrap `try await task.value` in `withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }`.
- `AsyncThrowingStream` iterators do not automatically observe the consuming task's cancellation when the producer runs in its own `Task`. Inside `for try await event in stream { ... }`, add `try Task.checkCancellation()` at the top of the loop body.
- When promoting a helper out of a `@MainActor`-isolated class to module scope, mark the closure parameter `@MainActor` (e.g. `condition: @escaping @MainActor () -> Bool`) and invoke via `await MainActor.run(body: condition)`. Without this, Swift 6 flags call sites that capture actor-isolated state with "Sending risks data race".
- `NSLock.lock()` / `NSLock.unlock()` are unavailable from async contexts in Swift 6. Use `OSAllocatedUnfairLock<State>` (`import os`) with `withLock { ... }` instead. Pattern: a single lock wraps all state, every accessor goes through `state.withLock { ... }`. Used by `QwenVoiceTests/Support/MockMLXModelCoordinator.swift` and `MockNativeStreamingSession.swift`.
- `Task.init`'s operation parameter is `@Sendable` regardless of the surrounding actor isolation. Capturing a non-Sendable `final class` instance into a wrapping `Task { ... }` triggers "Sending '<var>' risks causing data races" — even from `@MainActor` context. If the class is already designed for concurrent use (e.g. it uses `Task.detached` internally), the minimal safe fix is `@unchecked Sendable` on the class declaration. Done for `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift` so direct unit tests can wrap `session.run` in a Task.

## CI And Release Workflows

The active GitHub workflows are:

- `Project Inputs`
- `Apple Platform QA Gate`
- `Vocello macOS Release`
- `Vocello iOS TestFlight`

Release facts:

- macOS GitHub Releases carry the signed and notarized `Vocello-macos26.dmg`.
- iPhone distribution is App Store / TestFlight only. Do not add iPhone install artifacts to GitHub Releases.
- `scripts/release.sh` is the maintained local macOS packaging entrypoint.
- `scripts/release_ios_testflight.sh` is the maintained iPhone archive/export entrypoint; `scripts/verify_ios_release_archive.sh` is the structural verifier.
- Both release scripts use explicit derived-data and cloned-package roots under `build/foundation/` so resolve, build, archive, and export are separate phases.
- `Apple Platform QA Gate` is the shared-core regression gate for the current `macOS-first release track`: qa.sh and build `.xcresult` upload, generic iPhone compile proof, soft-skippable hosted UI smoke, and unsigned macOS release verification.
- `Vocello macOS Release` is the only signed/public release workflow required for the current milestone.
- `Vocello iOS TestFlight` remains maintained but is deferred from current public release signoff.
- Shipped macOS bundles and notarized DMGs must not contain `Contents/Resources/backend`, `Contents/Resources/python`, or bundled `Contents/Resources/ffmpeg`.

## When Changing X, Also Update Y

- Model registry, speakers, output folders, required model files, or platform-specific install variants:
  update `Sources/Resources/qwenvoice_contract.json` first, then the contract loaders, platform delivery code, and contract-facing docs.
- Adding or renaming source files:
  update `project.yml`, run `./scripts/regenerate_project.sh`, and confirm generated project files did not capture `__pycache__` or `.pyc` paths.
- Shared engine semantics or model-variant resolution:
  review `Sources/QwenVoiceCore/` and iPhone model delivery code together.
- macOS engine/client behavior:
  review `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineSupport/`, and `Sources/QwenVoiceEngineService/` together.
- iPhone engine-extension transport or host behavior:
  review `Sources/QwenVoiceCore/Extension*`, `Sources/iOSEngineExtension/`, `Sources/iOS/VocelloEngineExtensionPoint.swift`, and iPhone build coverage together.
- Memory-pressure, prewarm, or low-RAM admission behavior:
  review `Sources/QwenVoiceCore/IOSMemorySnapshot.swift`, `Sources/iOS/TTSEngineStore.swift`, `Sources/iOS/QVoiceiOSApp.swift`, and iPhone settings/status UI together.
- Playback or generation-persistence behavior:
  review `Sources/SharedSupport/` and affected macOS or iPhone feature views together.
- Engine prepare/load/streaming hot paths (`Sources/QwenVoiceCore/NativeEngineRuntime.swift`, `MLXModelLoadCoordinator.swift`, `NativeStreamingSynthesisSession.swift`):
  re-run `QWENVOICE_AUDIO_QC_MODES=CustomVoice ./scripts/qa.sh test --layer perf` and `./scripts/compare_perf_manifest.sh` against `scripts/perf-baseline-manifest.json`. Re-capture the baseline (overwrite from a fresh run) if the change is intentional and the regression is justified — pin the new baseline's `baselineCapturedAtCommit` field to the commit that introduces it.
- macOS release packaging or notarization behavior:
  keep `scripts/release.sh`, `scripts/create_dmg.sh`, `scripts/verify_release_bundle.sh`, `scripts/verify_packaged_dmg.sh`, `.github/workflows/macos-release.yml`, and release-facing docs aligned.
- iPhone archive/export/TestFlight behavior:
  keep `scripts/check_ios_catalog.sh`, `scripts/release_ios_testflight.sh`, `scripts/verify_ios_release_archive.sh`, `.github/workflows/ios-testflight.yml`, and iPhone distribution docs aligned.
- Broad repo facts that users or contributors rely on:
  update `CLAUDE.md`, `README.md`, `docs/README.md`, `docs/reference/current-state.md`, `docs/reference/engineering-status.md`, `docs/reference/backend-freeze-gate.md`, `docs/reference/frontend-backend-contract.md`, and `docs/reference/release-readiness.md`.

## Operational Safety

- Avoid running multiple `QwenVoice` or `Vocello` app instances at once while debugging model loads, clone prep, playback, XPC behavior, or engine-extension behavior. Kill an old instance before launching a new build.
- Never overlap heavy `xcodebuild`, `scripts/qa.sh`, release packaging, live app validation, or native smoke processes on this machine.
- Never run more than one heavy model load, generation, or benchmark at a time.
- For perf-lane runs (`qa.sh test --layer perf`, the programmatic regression gate), qa.sh's `vm.swapusage` preflight refuses to start when swap-used ≥ 8 GB or swap-free ≤ 512 MB (override via `QWENVOICE_PERF_SWAP_HARD_STOP_MB` / `QWENVOICE_PERF_SWAP_MIN_FREE_MB`). The preflight protects CI-style determinism, not the desktop-UI bench.
- **Desktop-UI bench is exempt from swap / RAM gating** as long as only one Vocello instance is running. The bench's job is to characterise behaviour at the hardware floor, including memory-pressure regimes the user actually hits. Don't abort a `bench_ui_generation.sh` run because of high swap; only abort if the engine itself is wedged (no chunk progress for >60 s with the process still alive). The single-instance rule (`pkill -x Vocello` before each cold relaunch) is non-negotiable — overlapping instances confuse the engine identity-key logic and pollute the trace.

## Storage Discipline

This dev machine has limited disk; the `build/` tree balloons quickly during active iteration (qa.sh, release packaging, perf-lane runs, foundation builds, audio-QC archives — easily 20+ GB combined). Don't accumulate artifacts.

- **`./scripts/clean_build_caches.sh`** removes always-safe items (stale `build/Vocello.app` + `Vocello-macos26.dmg` + release logs, `build/audio-qc/benchmark-v2/`). Run it after a session that produced a release build or a perf-lane benchmark archive you don't need to keep.
- **`./scripts/clean_build_caches.sh --aggressive`** additionally wipes `build/harness/derived-data/` + `source-packages/` and `build/foundation/macos-release-derived-data/` (~11 GB). Use before idle periods; trades ~5 min on the next `qa.sh` / `release.sh` while caches rebuild.
- **`--dry-run`** prints what would be removed without removing.
- **Don't keep parallel testbuilds.** `build/Vocello.app` is the single slot for the current release-mode build. Let `release.sh` overwrite it; don't preserve previous testbuilds elsewhere under `build/`.
- **Don't accumulate audio-QC recordings.** `build/audio-qc/benchmark-v2/` is for active investigation; the durable perf reference is the committed `scripts/perf-baseline-manifest.json`. Drop benchmark-v2 once an investigation is closed.
- **Foundation builds reuse `build/foundation/local-builds/`** — they overwrite, not append. Safe to leave.
- **Never** add cleanup to a hook that runs implicitly during builds — the user controls when caches drop because rebuild cost is non-trivial.

## Before Finishing

- Prefer manifest-backed data over duplicated constants.
- Keep accessibility identifiers stable when UI control types change.
- Re-run `./scripts/check_project_inputs.sh` and `./scripts/qa.sh validate` plus the most relevant QA layer before declaring work complete.
- If you changed engine architecture or runtime ownership, verify `CLAUDE.md` and `docs/reference/current-state.md` still describe the same app/service/runtime split.
- If you changed release behavior, verify the scripts, workflows, artifact names, `docs/reference/release-readiness.md`, and README/docs all still agree.
- If you changed any public-facing product copy, make sure the README and GitHub repo description still honor the active public homepage posture and current release-track policy.
- For doc-only refreshes, rerun the stale-reference grep and verify referenced commands, workflows, artifact names, and doc links still exist.
