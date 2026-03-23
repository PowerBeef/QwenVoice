# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

QwenVoice is a native macOS SwiftUI app (macOS 15+, Apple Silicon only) that runs Qwen3-TTS inference locally. It uses a two-process architecture:

1. **SwiftUI frontend** (`Sources/`) — UI, model downloads, playback, history persistence (SQLite via GRDB)
2. **Python backend** (`Sources/Resources/backend/server.py`) — MLX inference, communicates with Swift over newline-delimited JSON-RPC 2.0 on `stdin`/`stdout`

## Build Commands

```bash
# Regenerate .xcodeproj from project.yml (required after adding/removing source files)
./scripts/regenerate_project.sh

# Validate project inputs
./scripts/check_project_inputs.sh

# Build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build

# Swift unit tests (only-testing restricts to unit tests, excludes UI tests)
xcodebuild test -project QwenVoice.xcodeproj -scheme QwenVoice -only-testing:QwenVoiceTests -destination 'platform=macOS'

# Local release DMG
./scripts/release.sh

# GitHub Actions release workflows
# .github/workflows/project-inputs.yml  — validation
# .github/workflows/release-dual-ui.yml — builds QwenVoice-macos26.dmg + QwenVoice-macos15.dmg
# .github/workflows/test-suite.yml     — unit tests, UI tests, perf audit on PRs
```

## Agent Tooling

Prefer repo scripts and `xcodebuild` shell flows for all normal build and validation work.

- Default execution order: local repo truth (`rg`, source, scripts, manifests) → `xcodebuild` shell flows → `xcode-mcp` for project/build-setting inspection → `XcodeBuildMCP` only when a visual workflow is genuinely helpful
- Do not default to iOS simulator workflows — only for explicitly requested simulator work
- Use browser-facing MCPs only for web docs or browser tasks, not the native app UI
- Fall back to shell commands and repo scripts if a preferred MCP is unavailable

### MCP Routing

- `desktop-commander` — local file inspection and structured search
- `xcode-mcp` — project structure and build-setting inspection when shell output is noisy
- `XcodeBuildMCP` — build/run/log/screenshot workflows, not the default path
- `apple-docs` — first choice for Apple API, SwiftUI, AppKit, and platform guidance
- `context7` — third-party framework and library documentation
- `github` — hosted repo state, PR metadata, remote issue context (not local git)
- `playwright` / `chrome-devtools` — browser-based docs or tools only
- `openaiDeveloperDocs` — only for OpenAI API or OpenAI documentation tasks

## Skill Usage

This is a native macOS SwiftUI app. No Apple-platform-specific skills are installed; use general-purpose skills and repo scripts instead.

### Activity → Skill mapping

| When you are… | Use |
|---|---|
| Starting a new feature or creative work | `superpowers:brainstorming` |
| Planning multi-step implementation | `superpowers:writing-plans` |
| Executing a written plan | `superpowers:executing-plans` |
| Adding or modifying tests, doing TDD | `superpowers:test-driven-development` |
| Debugging a bug or test failure | `superpowers:systematic-debugging` |
| About to claim work is complete | `superpowers:verification-before-completion` |
| Finishing a development branch | `superpowers:finishing-a-development-branch` |
| Reviewing a PR | `code-review:code-review` |
| Guided feature development | `feature-dev:feature-dev` |
| Editing SwiftUI views, navigation, sheets, state patterns | `swiftui-ui-patterns` |
| Refactoring or splitting large SwiftUI view files | `swiftui-view-refactor` |
| Working with Liquid Glass / dual-build UI profiles | `swiftui-liquid-glass` |
| Reviewing Swift concurrency (async/await, actors, Sendable) | `swift-concurrency-expert` |
| Diagnosing SwiftUI performance (jank, re-renders, memory) | `swiftui-performance-audit` |
| Reviewing changed code for quality, reuse, efficiency | `simplify-code` |
| Running tests, benchmarks, or diagnostics | `python3 scripts/harness.py …` (direct, no skill) |

### RPC contract changes

When changes touch `server.py`, `PythonBridge.swift`, `RPCMessage.swift`, or `qwenvoice_contract.json`, manually verify Swift/Python RPC consistency (no dedicated agent installed).

### Do not use

These skills are web-focused and irrelevant to this native macOS app:

- `vercel:*`, `frontend-design`, `chrome-devtools-mcp:*`

## Architecture

### Source of Truth Priority

1. `Sources/` (live Swift code)
2. `project.yml` (XcodeGen manifest — drives `.xcodeproj`)
3. `docs/reference/current-state.md`
4. Prose docs

### Swift Frontend

- `QwenVoiceApp.swift` — app entry, shared services, app-support directory creation
- `ContentView.swift` — `NavigationSplitView` shell; routes the six sidebar destinations; owns all main-window titlebar/toolbar/search chrome (not child views)
- `PythonEnvironmentManager` — gates launch through `SetupView` until Python venv is ready
- `CustomVoiceView` — preset-speaker generation; `VoiceDesignView` — standalone voice design generation; `VoiceCloningView` — clone-from-reference generation
- All three generation views can present `BatchGenerationSheet`; single-generation flows use live streaming preview
- `GenerationWorkflowView` and related shared components drive the compact editor-first generation layout
- `WindowChromeConfigurator` — NSViewRepresentable controlling main-window titlebar appearance; referenced by `ContentView`
- `GenerationPersistence` — shared persist-to-database and autoplay logic used by all three generation views
- `SavedVoiceSheet` — standalone sheet for saving/editing enrolled voices; used by `VoicesView` and `HistoryView`
- `ContinuousVoiceDescriptionField` — NSViewRepresentable for the voice brief text field in `VoiceDesignView`
- `AudioPlayerViewModel` — persistent sidebar player; supports two-mode playback (file and live streaming) with pre-buffered chunk scheduling and automatic transition to final file on completion
  - Contains nested `PlaybackProgress` ObservableObject isolating timer-frequency properties (`currentTime`, `duration`) to prevent 10Hz fan-out to all screens that observe the parent ViewModel
- `ModelManagerViewModel` — model download/delete lifecycle; `SavedVoicesViewModel` — enrolled voice CRUD and voice picker state
- `HistoryView`, `VoicesView`, `ModelsView` — list-first management surfaces; toolbar/search affordances are owned by `ContentView`, not by these views
- `PreferencesView` lives in the app's `Settings` scene (opened via Cmd-,), not the main sidebar

### Python Backend RPC

`server.py` handles: `ping`, `init`, `load_model`, `prewarm_model`, `unload_model`, `generate`, `convert_audio`, `list_voices`, `enroll_voice`, `delete_voice`, `get_model_info`, `get_speakers`.

### Shared Contract

`Sources/Resources/qwenvoice_contract.json` is the source of truth for model registry, speakers, default speaker, output subfolders, required model files, and Hugging Face repos. Both Swift (`TTSContract.swift`, `TTSModel.swift`) and Python (`server.py`) load it. **Update the manifest first** when models/speakers/tiers change.

### Runtime Data Layout

```
~/Library/Application Support/QwenVoice/
  models/
  outputs/
    CustomVoice/
    VoiceDesign/
    Clones/
  voices/
  cache/
    normalized_clone_refs/
  history.sqlite
  python/
    .setup-complete
```

## Native UI Notes

- The main app window and Settings window are separate scenes — do not assume Preferences is reachable via sidebar routing
- The main-window detail stack keeps previously visited screens alive for draft preservation; titlebar chrome must be owned by `ContentView` or hidden views leak toolbar controls across tabs
- When automating Preferences, explicitly open the Settings window (`Cmd-,` / `showSettingsWindow:`) and scroll before interacting with lower controls
- macOS `Picker`/`Menu` controls surface as `MenuButton`/`MenuItem` in XCUI — do not assume `.button` elements
- History uses a native AppKit-backed toolbar search field
- `SetupView` uses `@ObservedObject var envManager` (not `@EnvironmentObject`) because it's rendered in `QwenVoiceApp` BEFORE `.environmentObject()` is attached — do not change this to `@EnvironmentObject`
- Voice Cloning does not support delivery/emotion instructions — the Qwen3-TTS Base model ignores them in clone mode. Do not add a Delivery picker to Voice Cloning.
- `TextInputView` uses `ScriptTextEditor` (NSTextView wrapper) for precise placeholder alignment and auto-hiding scrollbars — do not replace with SwiftUI `TextEditor`
- The sidebar `List` uses `.listStyle(.sidebar)` which renders with macOS translucent material by default. To make it opaque, add `.scrollContentBackground(.hidden)` + `.background(Color(nsColor: .windowBackgroundColor))`
- `PageScaffold` uses `.padding(.horizontal, 8)` for uniform left/right margins and `generationSectionSpacing: 8` for vertical gaps between panels — these values are intentionally aligned

## Key Change Patterns

### RPC contract change
Update together: `server.py` → `PythonBridge.swift` → `RPCMessage.swift` (if payload types change) → affected views and docs.

### Models or speakers change
Update together: `qwenvoice_contract.json` → Swift/Python consumers → docs asserting names or counts.

### Adding or renaming source files
1. Update `project.yml` if needed
2. Run `./scripts/regenerate_project.sh`
3. Verify the generated `.xcodeproj` did not pick up `__pycache__` or `.pyc` paths

### Adding or changing server.py pure functions
Run `python3 scripts/harness.py test --layer server` to verify. If the function is testable without MLX, add a test in `test_runner.py` layer (b).

### Adding or changing clone_delivery_pipeline.py
Run `python3 scripts/harness.py test --layer pipeline` to verify. Add tests in `test_runner.py` layer (a).

### Adding Swift test files
1. Add `.swift` file to `QwenVoiceTests/`
2. Run `./scripts/regenerate_project.sh`
3. Run `python3 scripts/harness.py test --layer swift` to verify

### Modifying live playback or AudioPlayerViewModel
Run `python3 scripts/harness.py test --layer swift` to verify. Manual smoke test: generate in all 3 modes with long text (forces multiple chunks), verify no clicks during streaming and smooth transition to final file playback.

### Modifying AudioPlayerViewModel published state
Timer-frequency properties (`currentTime`, `duration`) live in the nested `PlaybackProgress` object, not as `@Published` on the parent. Only `SidebarPlayerView` subscribes to `PlaybackProgress`. Do not move these back to `@Published` on the parent — it causes all 6 screens to re-render 10x/sec during playback.

### Modifying generation persistence or autoplay
All three generation views (Custom, Design, Cloning) use `GenerationPersistence.persistAndAutoplay()`. Update the shared helper in `Sources/Services/GenerationPersistence.swift`, not the individual views.

### Modifying PythonBridge.call() task group
The `call()` method uses a task group to race an RPC response against a timeout. The continuation registration runs inside a `Task { @MainActor in ... }` within a nonisolated `group.addTask` closure. This structure works around a Swift 6 region-based isolation checker bug — do not simplify by adding `@MainActor` directly to the `addTask` closure.

### Modifying history or database access
`DatabaseService` is `@MainActor`. Do not call `DatabaseService.shared` from `Task.detached` or nonisolated contexts — access it from MainActor-isolated code or use `await MainActor.run`.

## Project File Management

`project.yml` is the XcodeGen source for `QwenVoice.xcodeproj`. Defines three targets: `QwenVoice` (application), `QwenVoiceTests` (unit-test bundle), and `QwenVoiceUITests` (UI-test bundle). XcodeGen only creates one scheme (`QwenVoice`); use `-only-testing:` to restrict test runs. Always use `./scripts/regenerate_project.sh` (not raw `xcodegen generate`) when regeneration is needed. Current version: `1.1.7` / build `10`. Swift language mode: `6`.

## Test & Benchmark Harness

Single entry point: `scripts/harness.py` backed by `scripts/harness_lib/`. Four subcommands: `test`, `bench`, `diagnose`, `validate`. All structured output is JSON to stdout; progress to stderr.

```bash
# Fast pre-commit validation (no model/venv required)
python3 scripts/harness.py validate

# Test layers — run individually or all together
python3 scripts/harness.py test --layer pipeline    # Clone delivery pipeline pure-function tests (no deps)
python3 scripts/harness.py test --layer server      # server.py pure-function tests (no deps)
python3 scripts/harness.py test --layer contract    # Contract cross-validation (no deps)
python3 scripts/harness.py test --layer swift       # Swift unit tests via xcodebuild
python3 scripts/harness.py test --layer rpc         # RPC integration (needs app venv + installed model)
python3 scripts/harness.py test --layer ui          # XCUI tests (stub backend, no Python/ML required)
python3 scripts/harness.py test --layer design      # Screenshot baseline comparison
python3 scripts/harness.py test --layer perf        # Performance threshold audit
python3 scripts/harness.py test --layer all         # All layers (excludes ui/design/perf)

# Benchmarks (need app venv + installed models)
~/Library/Application\ Support/QwenVoice/python/bin/python3 scripts/harness.py bench --category latency --runs 3
~/Library/Application\ Support/QwenVoice/python/bin/python3 scripts/harness.py bench --category load
~/Library/Application\ Support/QwenVoice/python/bin/python3 scripts/harness.py bench --category quality
~/Library/Application\ Support/QwenVoice/python/bin/python3 scripts/harness.py bench --category release

# Diagnostics (works even with partial setup)
python3 scripts/harness.py diagnose
```

### Harness Architecture

- `scripts/harness_lib/paths.py` — shared path constants (`PROJECT_DIR`, `SERVER_PATH`, `CONTRACT_PATH`, `APP_VENV_PYTHON`, etc.)
- `scripts/harness_lib/output.py` — JSON envelope builders and `eprint()` stderr helper
- `scripts/harness_lib/contract.py` — contract loader, `model_ids()`, `speaker_list()`, `model_is_installed()`
- `scripts/harness_lib/stats.py` — `summarize_numeric()` for benchmark statistics
- `scripts/harness_lib/backend_client.py` — canonical JSON-RPC client (context manager, `call()`, `call_collecting_notifications()`, `stderr_excerpt()`)
- `scripts/harness_lib/test_runner.py` — test subcommand with layers (pipeline, server, RPC, contract, swift, audio, ui, design, perf)
- `scripts/harness_lib/bench_runner.py` — bench subcommand with 4 categories (latency, load, quality, release)
- `scripts/harness_lib/perf_profiler.py` — multi-tier performance profiler with bottleneck analysis
- `scripts/harness_lib/screenshot_diff.py` — pixel-level screenshot comparison for design regression
- `scripts/harness_lib/audio_test_runner.py` — audio pipeline chunk/property/tone tests
- `scripts/harness_lib/audio_analysis.py` — audio analysis utilities for quality benchmarks
- `scripts/harness_lib/ui_state_client.py` — client for querying app UI state during test runs
- `scripts/harness_lib/diagnose_runner.py` — diagnose subcommand (backend health, runtime env, model/voice inventory, history DB, disk usage)
- `scripts/harness_lib/validate_runner.py` — validate subcommand (contract consistency, backend importable, project inputs)

`scripts/evaluate_clone_tone_acoustic.py` imports `BackendClient` from `harness_lib.backend_client` (shared, not inline).

### Swift Unit Tests

`QwenVoiceTests/` (target type: `bundle.unit-test`, run with `-only-testing:QwenVoiceTests`):
- `PythonBridgeLineParserTests.swift` — JSON-RPC line parsing, notification handling
- `RPCMessageTests.swift` — RPCValue encoding/decoding round-trips, RPCResponse/RPCRequest variants
- `TTSContractTests.swift` — contract manifest validation, model-for-mode lookup, no-duplicate checks

### XCUI Tests

`QwenVoiceUITests/` (target type: `bundle.ui-testing`, run with `--layer ui`):
- 15 files (13 test + 2 support) covering sidebar navigation, all 6 views, setup flow, player bar, performance audit, screenshot capture
- Uses stub backend mode (`QWENVOICE_UI_TEST=1`, `QWENVOICE_UI_TEST_BACKEND_MODE=stub`) — no Python/ML required
- Screenshot baselines stored in `tests/screenshots/baselines/`
- Performance thresholds in `tests/perf/thresholds.json`

## Dual-Build UI Profiles

The app supports two visual profiles via compile-time flags:
- `QW_UI_LIQUID` — Liquid Glass (macOS 26+, `.glassEffect()` API)
- `QW_UI_LEGACY_GLASS` — Legacy styling (macOS 15, solid fills + strokes)

`AppTheme.swift` centralizes all profile-aware styling via `#if QW_UI_LIQUID` with `if #available(macOS 26, *)` runtime checks. The CI workflow (`release-dual-ui.yml`) builds both profiles in parallel.

### Modifying Liquid Glass styling
`AppTheme.swift` contains three key glass modifiers: `glass3DDepth(radius:intensity:)` (top highlight gradient + shadow), `glassTextField(radius:)` (glass background for text fields), and `smokedGlassTint` (shared tint color). `NativeSurfaceStyle` and `GlassGroupBoxStyle` are the two shared card styles — changes propagate globally. All glass surfaces use a solid dark fill (`.fill(Color(white: 0.13))` for cards, `0.16` for text fields) behind `.glassEffect()` to prevent transparency. Do not use `.glassEffect()` alone without a solid fill — it will be translucent. Picker controls use native macOS chrome with `.focusEffectDisabled()` — do not wrap them in glass backgrounds.

## Python Environment (Dev Builds)

Dev builds use `PythonEnvironmentManager` to create a venv from system Python. The search order deprioritizes Python 3.14 (poor wheel availability) — prefers 3.13 > 3.12 > 3.11 > 3.14. The bundled release runtime is Python 3.13.

## Documentation

- `docs/reference/current-state.md` — shared factual reference; keep aligned with this file
- `docs/reference/vendoring-runtime.md` — Python runtime bundling for release builds
- `qwen_tone.md` — tone/emotion guidance for Custom Voice and Voice Design

## Operational Safety

- **NEVER launch QwenVoice without killing existing instances first.** Each instance loads ML models and consumes significant RAM. Always `killall QwenVoice` before `open *.app`.
- Prefer asking the user before launching the app rather than launching automatically after builds.

## Practical Review Checklist

Before finishing:

1. confirm Swift and Python still agree on any cross-process change
2. keep accessibility identifiers stable across control-type changes
3. prefer the manifest over duplicated constants
4. prefer `./scripts/regenerate_project.sh` over raw `xcodegen generate`
5. keep `README.md`, `docs/reference/current-state.md`, and `CLAUDE.md` aligned when broad repo facts change
6. if a change touches Preferences, validate the separate Settings-window path
7. if a change touches picker-like controls, verify the actual macOS XCUI exposure (`MenuButton`/`MenuItem`)
8. if a change touches main-window toolbar or search chrome, verify controls are owned by `ContentView`
9. if a task involved docs or research, confirm the chosen MCP/skill matched the source type
10. if a change touches backend pure functions, run `python3 scripts/harness.py test --layer pipeline --layer server`
11. if a change touches the contract or model definitions, run `python3 scripts/harness.py test --layer contract`
12. run `python3 scripts/harness.py validate` as a fast pre-commit sanity check
