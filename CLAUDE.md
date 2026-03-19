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

# Swift unit tests
xcodebuild test -project QwenVoice.xcodeproj -scheme QwenVoiceTests -destination 'platform=macOS'

# Local release DMG
./scripts/release.sh

# GitHub Actions release workflows
# .github/workflows/project-inputs.yml  — validation
# .github/workflows/release-dual-ui.yml — builds QwenVoice-macos26.dmg + QwenVoice-macos15.dmg
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
- `AudioPlayerViewModel` — persistent sidebar player; supports two-mode playback (file and live streaming) with pre-buffered chunk scheduling and automatic transition to final file on completion
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

## Project File Management

`project.yml` is the XcodeGen source for `QwenVoice.xcodeproj`. Defines two targets: `QwenVoice` (application) and `QwenVoiceTests` (unit-test bundle). Always use `./scripts/regenerate_project.sh` (not raw `xcodegen generate`) when regeneration is needed. Current version: `1.1.7` / build `10`.

## Test & Benchmark Harness

Single entry point: `scripts/harness.py` backed by `scripts/harness_lib/`. Four subcommands: `test`, `bench`, `diagnose`, `validate`. All structured output is JSON to stdout; progress to stderr.

```bash
# Fast pre-commit validation (no model/venv required)
python3 scripts/harness.py validate

# Test layers — run individually or all together
python3 scripts/harness.py test --layer pipeline    # Clone delivery pipeline pure-function tests (no deps)
python3 scripts/harness.py test --layer server      # server.py pure-function tests (no deps)
python3 scripts/harness.py test --layer contract    # Contract cross-validation (no deps)
python3 scripts/harness.py test --layer swift       # Swift unit tests via xcodebuild (QwenVoiceTests scheme)
python3 scripts/harness.py test --layer rpc         # RPC integration (needs app venv + installed model)
python3 scripts/harness.py test --layer all         # All layers

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
- `scripts/harness_lib/test_runner.py` — test subcommand with 4 layers (pipeline, server, RPC, contract) + Swift xcodebuild
- `scripts/harness_lib/bench_runner.py` — bench subcommand with 4 categories (latency, load, quality, release)
- `scripts/harness_lib/diagnose_runner.py` — diagnose subcommand (backend health, runtime env, model/voice inventory, history DB, disk usage)
- `scripts/harness_lib/validate_runner.py` — validate subcommand (contract consistency, backend importable, project inputs)

`scripts/evaluate_clone_tone_acoustic.py` imports `BackendClient` from `harness_lib.backend_client` (shared, not inline).

### Swift Unit Tests

`QwenVoiceTests/` (scheme: `QwenVoiceTests`, target type: `bundle.unit-test`):
- `PythonBridgeLineParserTests.swift` — JSON-RPC line parsing, notification handling
- `RPCMessageTests.swift` — RPCValue encoding/decoding round-trips, RPCResponse/RPCRequest variants
- `TTSContractTests.swift` — contract manifest validation, model-for-mode lookup, no-duplicate checks

## Documentation

- `docs/reference/current-state.md` — shared factual reference; keep aligned with this file
- `qwen_tone.md` — tone/emotion guidance for Custom Voice and Voice Design

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
