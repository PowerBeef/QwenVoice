# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The repo root is `/Users/patricedery/Coding_Projects/QwenVoice`. Older notes that refer to a nested `QwenVoice/QwenVoice` path are stale.

## Build & Run

```bash
# Build (from repo root)
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

# Clean build
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice clean build

# Launch the built app (dynamically resolves DerivedData path)
open "$(xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -showBuildSettings 2>/dev/null | grep '^ *BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Qwen Voice.app"

# Regenerate .xcodeproj after adding/removing Swift files
xcodegen generate
# WARNING: XcodeGen overwrites Sources/QwenVoice.entitlements — restore it after regenerating

# Safely regenerate .xcodeproj (backs up + restores entitlements)
./scripts/regenerate_project.sh

# Bundle a standalone Python environment (for distribution)
./scripts/bundle_python.sh
```

## Testing

XCUITest end-to-end tests live in `QwenVoiceUITests/`. All tests work without downloaded models (800MB+ each); model-dependent tests use `XCTSkip`.

```bash
# Run smoke suite (default — one test per class, fastest CI gate)
./scripts/run_tests.sh

# Run all UI tests
./scripts/run_tests.sh --suite ui

# Run a single test class
./scripts/run_tests.sh SidebarNavigation

# Run a specific probe
./scripts/run_tests.sh --probe launch-speed

# List available test classes
./scripts/run_tests.sh --list

# Rerun only tests that failed last time
./scripts/run_tests.sh --rerun-failed

# Run with sharding for parallel CI
./scripts/run_tests.sh --shard 1/3
```

### Test suites
| Suite | Scope |
|-------|-------|
| `smoke` (default) | 1 test per class — fastest CI gate |
| `ui` | All non-generation test classes |
| `integration` | `GenerationFlowTests` only (requires model) |
| `all` | `ui` + `integration` |
| `debug` | `DebugHierarchyTests` only |

### Test probes
| Probe | Maps to |
|-------|---------|
| `launch-speed` | `DebugHierarchyTests/testAppWindowAndDefaultScreen` |
| `generation-perf` | `GenerationFlowTests/testFullCustomVoiceGeneration` |
| `history-accessibility` | `DebugHierarchyTests/testHistoryScreenIdentifiers` |
| `generation-benchmark` | Delegates to `run_generation_benchmark.sh` |

### Test infrastructure
`QwenVoiceUITestBase.swift` provides the full test infrastructure:
- **`UITestLaunchPolicy`**: `sharedPerClass` (one app launch per class, default) or `freshPerTest` (one launch per test)
- **`UITestScreen` enum**: Typed screen identifiers with `rootIdentifier` and `sidebarIdentifier` computed properties
- **`QwenVoiceUITestSession`**: Singleton managing app lifecycle — reuses running app via `activate()` instead of relaunching
- **Failure artifacts**: On test failure, screenshots and accessibility hierarchy are attached to the result bundle
- **Build caching**: SHA-256 fingerprint of all source files; skips `build-for-testing` when unchanged

Test counts: sidebar navigation (2), custom voice (5), voice cloning (3), models (2), history (2), voices (2), preferences (2), generation flow (1, skipped without model), debug (2).

### Accessibility identifiers
All UI elements have `accessibilityIdentifier` values following the pattern `"{viewScope}_{elementName}"`. When adding new UI elements, follow this convention so tests can find them.

## Architecture

**Two-process design:** SwiftUI frontend + Python backend (`server.py`) communicating via JSON-RPC 2.0 over stdin/stdout pipes.

### Swift → Python communication flow
1. `QwenVoiceApp.swift` calls `pythonBridge.start()` on launch, which spawns `server.py` as a subprocess
2. `PythonBridge.swift` (JSON-RPC client) sends newline-delimited JSON requests; reads responses line-by-line
3. The Python process sends a `ready` notification on startup → sets `PythonBridge.isReady = true`
4. Progress updates arrive as `progress` notifications (no `id` field) before the final response
5. Streaming generation sends `generation_chunk` notifications (with `request_id`) for each audio chunk as it's generated
6. Only one model lives in GPU memory at a time; `load_model` unloads the previous before loading
7. RPC calls have timeouts: 300s for generation, 10s for `ping`. On timeout, `PythonBridgeError.timeout(seconds:)` is thrown with the actual duration

### Streaming generation
Custom Voice and Voice Design modes support streaming output via `generation_chunk` notifications:
1. Swift calls `generateCustomStreaming()` or `generateDesignStreaming()` with `stream: true` and a `streamingInterval` (default 2.0s)
2. Python writes each chunk to `{stem}__chunk_{index:03d}.wav` and sends a `generation_chunk` notification
3. `PythonBridge` routes notifications to per-request `onGenerationChunk` callbacks via `generationChunkHandlers[requestID]`
4. After all chunks, Python concatenates them into the final output file
5. Voice cloning does NOT support streaming — it uses the prepared ICL fast path instead

### Clone performance optimization (Prepared ICL Context)
Voice cloning uses a two-level caching system to avoid re-encoding reference audio on every request:

**In-process LRU cache** (capacity: 8 entries):
- Cache key: `(model_path, canonical_ref_path, file_size, mtime_ns, transcript)`
- On hit: returns cached `PreparedICLContext` (8 pre-computed MLX arrays) — skips the expensive encoder pass
- Cleared on model load/unload

**Persistent disk cache** for normalized reference audio (capacity: 32 files, 30-day TTL):
- Location: `~/Library/Application Support/QwenVoice/cache/normalized_clone_refs/`
- SHA-256 fingerprint of `(real_path, size, mtime_ns)` → stable WAV filename
- Non-WAV files (mp3, m4a, etc.) are converted to WAV once via ffmpeg and cached
- Pruned at startup via `handle_init`

**Speed patch** (`mlx_audio_qwen_speed_patch.py`):
- `try_enable_speech_tokenizer_encoder()`: Fixes upstream mlx-audio bug where the speech tokenizer encoder is loaded decoder-only. Rebuilds the full encoder from on-disk weights
- `prepare_icl_context()`: Pre-computes all reference-dependent state (ref codes, text embeddings, codec embeddings, special tokens) in one shot
- `prepare_icl_generation_inputs_from_context()`: Per-request fast path — combines cached reference state with new target text via array concatenation only (no model forward passes)
- `generate_with_prepared_icl()`: Custom autoregressive decode loop that bypasses the standard `generate_audio()` path. Includes `effective_max_tokens` cap at `min(max_tokens, max(75, target_token_count * 6))` and periodic GPU cache clearing every 50 steps
- Trims reference audio prefix from decoded output proportionally by frame ratio

The patch is vendored two ways: as a standalone file at `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py` (imported first), and baked into the repacked `mlx-audio==0.3.1.post1` wheel as `mlx_audio/qwenvoice_speed_patch.py` (fallback import).

### AppLaunchConfiguration
`QwenVoiceApp.swift` defines `AppLaunchConfiguration` — a centralized, immutable struct parsed from launch arguments:
- `isUITest`: Inferred from any `--uitest*` flag
- `animationsEnabled`: Disabled when `--uitest` or `--uitest-disable-animations` present
- `fastIdle`: Skips delays (e.g., sidebar first-responder 300ms wait)
- `initialSidebarItem`: Deep-links to a screen via `--uitest-screen=<name>`
- `performAnimated(_:_:)`: Static method that gates all `withAnimation` calls through the config
- `.appAnimation(_:value:)`: View extension that gates all `.animation()` modifiers

All animations in the app go through these gates — there are zero raw `withAnimation` calls in view files.

### Python path resolution (dev vs. bundled)
`PythonBridge.findPython()` checks in order:
1. Bundled Python at `Resources/python/bin/python3` (production)
2. App Support venv at `~/Library/Application Support/QwenVoice/python/bin/python3` (auto-created by `PythonEnvironmentManager`)
3. Dev project venv relative to source file — resolves to `cli/.venv/bin/python3`
4. System Python: versioned paths (3.13 → 3.14 → 3.12 → 3.11) at `/opt/homebrew/bin/` and `/usr/local/bin/`

Note: `/usr/bin/python3` is intentionally excluded — on macOS 14+ it's an Xcode Command Line Tools stub that may pop a GUI dialog.

### Model download
Models are downloaded via `HuggingFaceDownloader.swift` using native URLSession (no external CLI tools). `ModelManagerViewModel.swift` manages download/delete state. Models land in `~/Library/Application Support/QwenVoice/models/<folder-name>/`. The `get_smart_path()` function in `server.py` handles the `snapshots/` subdirectory that HuggingFace Hub sometimes creates. There are 3 models (all Pro 1.7B 8-bit): Custom Voice, Voice Design, Voice Cloning.

`HuggingFaceDownloader` uses a `withLock<Result>()` helper around `NSLock` for all thread-safe state access. It resolves LFS file sizes from the `lfs.size` field (not the pointer file `size`), filters `.gitattributes`, and copies downloaded temp files to UUID-named paths before URLSession deletes them.

### Key files
| File | Role |
|------|------|
| `Sources/Resources/backend/server.py` | Python JSON-RPC server; all ML inference, caching, and streaming happen here |
| `Sources/Resources/backend/mlx_audio_qwen_speed_patch.py` | Prepared ICL context for clone speed; speech tokenizer encoder repair |
| `Sources/Services/PythonBridge.swift` | Swift JSON-RPC client; spawns Python, streaming chunk handlers, async continuations with timeouts |
| `Sources/Models/TTSModel.swift` | Model registry (3 Pro models), `GenerationMode` enum, speaker list |
| `Sources/Models/RPCMessage.swift` | JSON-RPC 2.0 codec — `RPCValue` enum for type-safe JSON |
| `Sources/Models/Generation.swift` | GRDB history record; `audioFileExists`, `textPreview` computed properties |
| `Sources/Models/EmotionPreset.swift` | Predefined emotion/tone presets |
| `Sources/Services/DatabaseService.swift` | GRDB SQLite — stores generation history; v2 migration adds `sortOrder`; LIKE-escaped search |
| `Sources/Services/AudioService.swift` | `shouldAutoPlay` (UserDefaults), `configuredOutputsRoot` (user-configurable output dir), `makeOutputPath` |
| `Sources/Services/WaveformService.swift` | Waveform data extraction for visualization |
| `Sources/ViewModels/ModelManagerViewModel.swift` | Download/delete model state, `ModelStatus` enum |
| `Sources/ViewModels/AudioPlayerViewModel.swift` | Deferred autoplay with retry (60ms + 180ms), `playbackError`, path-pinned cancellation |
| `Sources/Services/HuggingFaceDownloader.swift` | Native URLSession model downloader; `withLock` helper, `DownloadError` enum, LFS size resolution |
| `Sources/Services/PythonEnvironmentManager.swift` | Venv creation, incremental dep update, pip retry (3 attempts), import validation, bundled Python fast path |
| `Sources/QwenVoiceApp.swift` | @main entry point, `AppLaunchConfiguration`, window setup, keyboard shortcuts, directory scaffold |
| `Sources/ContentView.swift` | `SidebarItem` enum + `NavigationSplitView` root; `.navigateToModels` + `.generationSaved` notifications |
| `Sources/Views/SetupView.swift` | First-boot Python setup UI (states: checking → settingUp → ready/failed) |
| `Sources/Views/Components/AppTheme.swift` | Glassmorphism `glassCard()`, monochromatic accent color, `ChipStyle`, `AuroraBackground`, animation gating |
| `Sources/Views/Components/TextInputView.swift` | Shared chat-style input bar (text field + circular generate button) |
| `Sources/Views/Components/LayoutConstants.swift` | Shared layout dimensions; `contentColumn()` centers content at 700pt max width |
| `project.yml` | XcodeGen config — edit this instead of `.xcodeproj` |
| `AGENTS.md` | Agent-facing operational guide with trust hierarchy and implementation reality notes |
| `third_party_patches/mlx-audio/` | Speed patch source + vendoring documentation |

### Project structure
```
Sources/
├── QwenVoiceApp.swift              # @main, AppLaunchConfiguration, keyboard shortcuts
├── ContentView.swift               # Root NavigationSplitView + sidebar routing + notifications
├── Models/
│   ├── TTSModel.swift              # Model registry, GenerationMode enum, speakers
│   ├── Generation.swift            # GRDB history record (v2: sortOrder column)
│   ├── Voice.swift                 # Voice cloning reference
│   ├── RPCMessage.swift            # JSON-RPC 2.0 codec
│   └── EmotionPreset.swift         # Emotion preset definitions
├── Services/
│   ├── PythonBridge.swift          # JSON-RPC client, subprocess, streaming chunk handlers
│   ├── PythonEnvironmentManager.swift  # Venv setup, incremental update, pip retry, import validation
│   ├── DatabaseService.swift       # GRDB SQLite (v2 migration), LIKE-escaped search
│   ├── HuggingFaceDownloader.swift # Native URLSession downloader, withLock, DownloadError
│   ├── AudioService.swift          # shouldAutoPlay, configurable output directory
│   └── WaveformService.swift       # Waveform extraction
├── ViewModels/
│   ├── ModelManagerViewModel.swift  # Download/delete state
│   └── AudioPlayerViewModel.swift   # Deferred autoplay with retry, playbackError
├── Views/
│   ├── SetupView.swift             # First-boot Python setup
│   ├── Sidebar/SidebarView.swift   # Navigation rail, backend/generation status, first-responder hack
│   ├── Generate/
│   │   ├── CustomVoiceView.swift   # Preset speakers + Voice Design (via chip)
│   │   └── VoiceCloningView.swift  # Clone from reference audio + saved voices
│   ├── Library/
│   │   ├── HistoryView.swift       # Generation history, notification-driven refresh
│   │   └── VoicesView.swift        # Enrolled voices, three-state loading
│   ├── Settings/
│   │   ├── ModelsView.swift        # Download/delete models, progress bars
│   │   └── PreferencesView.swift   # Custom prefSection layout, bundled vs. venv detection
│   └── Components/
│       ├── AppTheme.swift          # Glassmorphism, monochromatic colors, animation gating
│       ├── TextInputView.swift     # Shared chat-style input
│       ├── SidebarPlayerView.swift # Sidebar waveform + playback controls + tap-to-seek
│       ├── EmotionPickerView.swift # Emotion preset buttons
│       ├── BatchGenerationSheet.swift  # Batch mode modal, polymorphic mode handling
│       ├── WaveformView.swift      # Waveform visualization
│       ├── FlowLayout.swift        # Wrapping layout for chips
│       └── LayoutConstants.swift   # Shared dimensions, contentColumn()
├── Assets.xcassets/                # App asset catalog source
├── Resources/
│   ├── backend/
│   │   ├── server.py               # Python JSON-RPC backend
│   │   └── mlx_audio_qwen_speed_patch.py  # Clone speed optimization
│   ├── requirements.txt            # Python deps (mlx-audio==0.3.1.post1)
│   └── vendor/                     # Vendored wheels (excluded from app bundle by project.yml)
├── Info.plist
└── QwenVoice.entitlements          # Sandboxing disabled, unsigned code loading

third_party_patches/
└── mlx-audio/
    ├── qwenvoice_speed_patch.py    # Canonical source for the speed patch
    └── qwenvoice-speed.patch       # Vendoring strategy documentation

scripts/
├── release.sh                      # 7-step release pipeline with bundle verification
├── bundle_python.sh                # Python 3.13 standalone with import validation + runtime manifest
├── bundle_ffmpeg.sh                # Embed ffmpeg binary
├── regenerate_project.sh           # XcodeGen + entitlements backup/restore
├── create_dmg.sh                   # DMG distribution
├── run_tests.sh                    # Unified test runner: suites, probes, sharding, build cache
├── build_mlx_audio_wheel.sh        # Repack upstream mlx-audio wheel with speed patch
├── verify_release_bundle.sh        # 7-step bundle integrity verifier (imports, ffmpeg, manifest, otool)
├── benchmark_generation.py         # Backend-first performance benchmark (JSON-RPC, 10 scenarios)
├── run_generation_benchmark.sh     # Thin wrapper for benchmark_generation.py
├── record_demo.sh                  # Automated screen recording via JXA + CoreGraphics
├── test_generation.sh              # Wrapper → run_tests.sh --suite integration --probe generation-perf
├── test_history_ui.sh              # Wrapper → run_tests.sh --suite debug --probe history-accessibility
└── test_launch_speed.sh            # Wrapper → run_tests.sh --suite integration --probe launch-speed
```

### Python environment setup
`PythonEnvironmentManager.swift` handles first-boot venv creation. On launch, the app shows `SetupView` until the venv is ready, then switches to `ContentView`.

- **Marker file:** `~/Library/Application Support/QwenVoice/python/.setup-complete` stores a SHA256 hash of `requirements.txt`. If missing or stale, the app attempts an incremental dependency update before falling back to full venv recreation.
- **Incremental updates:** When `requirements.txt` changes but the venv exists, `pip install -r requirements.txt` is attempted on the existing venv first. On failure, falls through to full recreation. The `updatingDependencies` setup phase surfaces this state to the UI.
- **Pip retry:** Installs are retried up to 3 times with 2-second delays for transient network failures.
- **Import validation:** Before writing the marker, critical imports are validated: `mlx`, `mlx_audio`, `transformers`, `numpy`, `soundfile`, `huggingface_hub`. The marker is only written after validation passes.
- **Bundled Python fast path:** In production builds with bundled Python, the full venv setup is bypassed — only import validation runs.
- **Vendored wheels:** `PythonEnvironmentManager` checks for a `Resources/vendor/` directory in the app bundle and passes it to `pip install --find-links` for offline/faster installs.
- **Python discovery order:** Prefers 3.13 → 3.14 → 3.12 → 3.11. `/usr/bin/python3` is excluded (macOS 14+ stub). Generic `python3` paths are version-verified to 3.11–3.14.
- **Backend restart:** `needsBackendRestart` flag signals `QwenVoiceApp` to stop/restart `PythonBridge` after a `resetEnvironment()` call.
- **Continuation safety:** `nonisolated(unsafe) var resumed` flag prevents double-resumption of `CheckedContinuation` in process termination handlers.

### App Support directory layout
```
~/Library/Application Support/QwenVoice/
  python/            ← venv (created by PythonEnvironmentManager)
    .setup-complete  ← SHA256 hash of requirements.txt
  models/            ← downloaded model folders
  outputs/
    CustomVoice/     ← generated .wav files
    VoiceDesign/
    Clones/
  voices/            ← enrolled voice .wav + .txt transcript pairs
  cache/
    normalized_clone_refs/  ← persistent WAV cache for clone references (32 files, 30-day TTL)
  history.sqlite     ← GRDB generation history
```

### Generate views pattern
Two generate views (`CustomVoiceView`, `VoiceCloningView`) share the same structure. Voice Design is accessed via the "Custom" chip in `CustomVoiceView` (no separate view).
- `isModelDownloaded` computed property checks `QwenVoiceApp.modelsDir/<model.folder>` on disk (checked both as a computed property and defensively inside the async generate Task)
- Orange warning banner + disabled Generate/Batch buttons when model not present
- "Go to Models" posts `Notification.Name.navigateToModels` → `ContentView` switches sidebar
- `TextInputView` is the shared chat-style input bar (text field + circular generate button), embedded inside each view's controls glass card
- After successful generation: saves to DB, posts `.generationSaved` notification, calls `audioPlayer.playFile(..., deferAutoStart: true)` if `AudioService.shouldAutoPlay`
- `deferAutoStart: true` uses `AudioPlayerViewModel.scheduleAutoplay()` which retries at 60ms and 180ms to handle the race between Python file write and Swift file read

### AudioPlayerViewModel deferred autoplay
The player implements path-pinned retry logic for autoplay after generation:
- `autoplayRetryScheduleNs`: [60ms, 180ms] — two attempts before giving up
- Each retry checks `currentFilePath == path` to abort if the user navigated to a different generation
- `attemptPlay(reportFailure:)` suppresses errors during retry; only the final exhaustion sets `playbackError`
- `autoplayTask` is cancelled on any new `playFile()`, `play()`, or `stop()` call
- `playbackError` is a `@Published` string surfaced in the UI

### RPC methods (server.py ↔ PythonBridge.swift)

| Method | Params | Purpose |
|--------|--------|---------|
| `ping` | — | Healthcheck |
| `init` | `app_support_dir` | Configure paths; prunes clone reference cache |
| `load_model` | `model_id` or `model_path` | Load 1.7B model to GPU (unloads previous); enables speech tokenizer encoder; clears clone context cache |
| `unload_model` | — | Free GPU memory; clears clone context cache |
| `generate` | `text` + mode params + optional params | Generate audio (see below) |
| `convert_audio` | `input_path`, `output_path?` | Convert to 24kHz mono WAV |
| `list_voices` | — | List enrolled voices |
| `enroll_voice` | `name`, `audio_path`, `transcript?` | Save voice reference (.wav + .txt) |
| `delete_voice` | `name` | Delete enrolled voice files; name is sanitized |
| `get_model_info` | — | Model metadata & download status |
| `get_speakers` | — | Speaker map (4 English speakers) |

**`generate` parameters:**

| Param | Type | Default | Purpose |
|-------|------|---------|---------|
| `text` | string | required | Text to synthesize (stripped; whitespace-only rejected) |
| `voice` | string | — | Preset speaker name → Custom Voice mode |
| `instruct` | string | — | Voice description → Voice Design mode |
| `ref_audio` | string | — | Reference audio path → Voice Cloning mode |
| `ref_text` | string | None | Explicit transcript for clone reference (fallback: sidecar .txt) |
| `speed` | float | 1.0 | Speed scale (Custom Voice only) |
| `temperature` | float | 0.6 | Sampling temperature |
| `max_tokens` | int | None | Hard cap on generated tokens |
| `stream` | bool | False | Enable streaming chunk output (Custom/Design only) |
| `streaming_interval` | float | 2.0 | Seconds between streamed chunks |
| `benchmark` | bool | False | Include timing breakdown in response |
| `benchmark_label` | string | None | Override label for benchmark output |

**Mode detection:** `ref_audio` present → clone, `voice` present → custom, `instruct` only → design.

**GPU cache clearing:** Post-request `mx.clear_cache()` is behind a `POST_REQUEST_CACHE_CLEAR = False` flag (disabled by default). Selective clearing happens inside the ICL decode loop: after every token's code predictor pass, and periodically every 50 steps.

**Notifications during generation:**
- `progress`: Status updates (no `id` field)
- `generation_chunk`: Streaming audio chunks with `request_id`, `chunk_index`, `chunk_path`, `is_final`

### DatabaseService
- **v2 migration** adds `sortOrder` integer column with backfill by `createdAt DESC` order
- **`generationSelectColumns`** static constant for DRY column lists
- **`searchGenerations()`** uses LIKE-escaped sanitization (backslash, `%`, `_`) with `COALESCE(voice, '')` for nullable columns
- **`deleteAllGenerations()`** batch delete; silently returns if `dbQueue` is nil
- **Error strategy:** Write operations throw `DatabaseServiceError.notInitialized(reason)`. Read operations return empty arrays with console warning.

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/release.sh` | 7-step release: bundle deps → build → verify bundle → DMG. Flags: `--skip-deps`, `--skip-build` |
| `scripts/bundle_python.sh` | Python 3.13 standalone with import validation, mlx-audio version check, runtime manifest, size reduction |
| `scripts/bundle_ffmpeg.sh` | Embed ffmpeg binary from Homebrew releases |
| `scripts/regenerate_project.sh` | XcodeGen + entitlements backup/restore |
| `scripts/create_dmg.sh` | Create DMG distribution |
| `scripts/run_tests.sh` | Unified test runner: suites (`smoke`/`ui`/`integration`/`all`/`debug`), probes, sharding, build cache, `--rerun-failed`, JSON summary, failure diagnostics |
| `scripts/build_mlx_audio_wheel.sh` | Repack upstream `mlx-audio==0.3.1` wheel with speed patch → `0.3.1.post1` |
| `scripts/verify_release_bundle.sh` | 7-step verifier: required files, Python imports, speed patch, ffmpeg, manifest integrity, `otool` native library leak detection, backend smoke test |
| `scripts/benchmark_generation.py` | Backend-first JSON-RPC benchmark: 10 scenarios, cold/warm runs, clone cache speedup ratios, streaming metrics. Outputs `summary.json`, `report.md`, `raw_samples.csv` |
| `scripts/run_generation_benchmark.sh` | Thin wrapper — finds Python, delegates to `benchmark_generation.py` |
| `scripts/record_demo.sh` | Automated screen recording via JXA + CoreGraphics + ffmpeg |
| `scripts/test_download.sh` | Test HuggingFace download flow |
| `scripts/test_generation.sh` | Wrapper → `run_tests.sh --suite integration --probe generation-perf` |
| `scripts/test_history_ui.sh` | Wrapper → `run_tests.sh --suite debug --probe history-accessibility` |
| `scripts/test_launch_speed.sh` | Wrapper → `run_tests.sh --suite integration --probe launch-speed` |

### Dependencies
- **Swift:** GRDB 7.0.0 (SQLite) — only SPM package
- **Python:** app backend uses a repacked `mlx-audio==0.3.1.post1` (vendored wheel in `Sources/Resources/vendor/`; built by `scripts/build_mlx_audio_wheel.sh`). Key deps: `mlx==0.30.3`, `mlx-lm==0.30.5`, `mlx-metal==0.30.3`, `transformers==5.0.0rc3`, `numpy==2.3.5`, `librosa`, `soundfile`, `huggingface_hub`, `audioop-lts` (3.13+ only)
- **System:** ffmpeg (brew or bundled), Python 3.11–3.14

## Distribution

- **GitHub repo:** PowerBeef/QwenVoice
- **Version:** 1.1.0 (build 4)
- The app is unsigned (`CODE_SIGN_IDENTITY="-"`) — users must run `xattr -cr "/Applications/Qwen Voice.app"` after installing from the DMG
- Release build: `./scripts/release.sh` (7-step pipeline: bundle Python 3.13 + ffmpeg → build → verify bundle → DMG)
- `bundle_python.sh` writes a `.qwenvoice-runtime-manifest.json` into the Python bundle with SHA-256 of requirements, mlx-audio version, and build timestamp
- `verify_release_bundle.sh` checks imports, speed patch presence, ffmpeg, manifest integrity, and uses `otool -L` to detect leaked Homebrew dylib paths
- Models are NOT bundled in the DMG (~2.7 GB total) — users download in-app via ModelsView
- **Entitlements:** Sandboxing disabled, unsigned executable memory allowed, library validation disabled — required for Python subprocess execution and MLX .dylib loading

## Data Corrections

- 3 Pro (1.7B) models only — Lite (0.6B) tier was removed (Pro runs fine on all Apple Silicon Macs with 8GB+ RAM)
- There are 4 English preset speakers: ryan, aiden, serena, vivian
- Instruction control (`instruct` param) is probabilistic — complex multi-dimensional requests may not be followed precisely
- `Generation.modelTier` always writes `"pro"` — lite tier values are legacy only
- `sortOrder` column exists in the DB but is not yet used in list rendering queries

## Gotchas

- **SourceKit false errors** on cross-file Swift references are expected until the project is opened in Xcode — the build still succeeds.
- The compiled binary is tiny (~58KB); the actual Swift code compiles into `Qwen Voice.debug.dylib` in debug builds.
- macOS 14.0+ deployment target; Swift 5.9; Apple Silicon only (arm64).
- **Changing `requirements.txt` invalidates the venv marker** — the app first tries an incremental `pip install` on the existing venv; on failure it recreates from scratch. After editing requirements manually: recreate the venv, `pip install -r requirements.txt`, and write `shasum -a 256 requirements.txt | awk '{print $1}'` to `python/.setup-complete`.
- **`audioop-lts` is 3.13+ only** — it backports the `audioop` stdlib module removed in 3.13. The environment marker in `requirements.txt` ensures pip skips it on 3.12 where `audioop` is built-in.
- **No auto-restart on backend crash** — if the Python process terminates, `PythonBridge.isReady` becomes `false`, `cancelAllPending(error: .processTerminated)` fires for all waiting continuations, and generation views disable. The user must quit and reopen the app. `stop()` terminates the process and waits for exit in a detached task to avoid zombie processes.
- **RPC timeout** — `PythonBridge.call()` times out after 300s (generation) or 10s (ping). On timeout the pending request and any `generationChunkHandlers` are cleaned up in a `defer` block, and `PythonBridgeError.timeout(seconds:)` is thrown.
- **DatabaseService.saveGeneration throws** `DatabaseServiceError.notInitialized(reason)` when `dbQueue` is nil (init failed). Callers must handle errors. Read-only methods return empty arrays with a console warning.
- **HuggingFaceDownloader thread safety** — all `continuations`, `destinations`, and progress state access goes through `withLock<Result>()` which wraps `NSLock` with `defer { lock.unlock() }`. Safe temp file move to UUID path prevents URLSession from deleting downloads before they're moved to final destination.
- **VoiceCloningView drop handler** validates file extensions against `[wav, mp3, aiff, aif, m4a, flac, ogg]`; non-audio files are rejected with an error message.
- **Voice name sanitization** — both `enroll_voice` and `delete_voice` in server.py sanitize the name parameter to prevent path traversal.
- **XcodeGen overwrites entitlements** — always use `scripts/regenerate_project.sh` instead of `xcodegen generate` directly.
- **Asset catalog:** `project.yml` points at `Sources/Assets.xcassets`. The checked-in `.xcodeproj` should match after regeneration.
- **Audio sample rate:** 24000 Hz for all generated audio.
- **ContentView `.id(selectedItem)`** forces full view recreation on sidebar navigation to prevent state bleed between screens.
- **SidebarView first-responder hack** — walks the view hierarchy to find `NSOutlineView` and call `makeFirstResponder` after 300ms (or immediately in `fastIdle` test mode) to get accent-colored selection highlight instead of grey.
- **PythonEnvironmentManager continuation safety** — `nonisolated(unsafe) var resumed` flag prevents double-resumption crashes in process termination handlers.
- **AudioPlayerViewModel delegate identity check** — `self.player === player` in `audioPlayerDidFinishPlaying` prevents acting on stale delegate callbacks from replaced players.
- **Vendored wheel exclusion** — `project.yml` excludes `vendor/`, `**/*.whl`, `**/__pycache__/**`, `**/*.pyc` from the app bundle resources. The wheel is only used during pip install, not at runtime.
- **Speed patch import order** — `server.py` tries `from mlx_audio_qwen_speed_patch import ...` (local file) first, then `from mlx_audio.qwenvoice_speed_patch import ...` (wheel). If both fail, clone optimization is silently disabled and generation falls back to the standard path.
- **`/usr/bin/python3` excluded** from both `PythonBridge` and `PythonEnvironmentManager` — on macOS 14+ it's an Xcode CLT stub that may show a GUI dialog.
