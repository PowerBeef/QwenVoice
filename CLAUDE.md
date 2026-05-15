# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Vocello (formerly QwenVoice) — a local, private text-to-speech macOS app powered by Qwen3-TTS via MLX on Apple Silicon. The macOS scheme is still called `QwenVoice` but the shipped product is `Vocello.app` / `Vocello-macos26.dmg`. An iOS counterpart (`VocelloiOS`) is kept compile-safe but is not a release target for the current milestone.

Targets: macOS 26.0+ and iOS 26.0+, Apple Silicon only, Xcode 26.0. No Python runtime. No bundled model weights — models are downloaded from Hugging Face from Settings → Model Downloads on first run.

## Source of truth (when facts disagree)

Per `CONTRIBUTING.md`, trust in order: `Sources/` → `project.yml` → `scripts/` → `docs/reference/` → other prose. `Sources/Resources/qwenvoice_contract.json` is the canonical schema for speakers, models, variants, HF revisions, and required artifacts.

## Project generation and build

The Xcode project is generated from `project.yml` via XcodeGen. Edit `project.yml` (not `.xcodeproj`) for structural changes, then regenerate.

Preferred entrypoint for day-to-day work — wraps the steps below and skips regen / SPM resolve when their inputs are unchanged:

```sh
./scripts/build.sh debug                  # fast incremental Debug build, no launch
./scripts/build.sh run                    # Debug build → launch Vocello.app
./scripts/build.sh run --logs             # also: --telemetry, --verify, --debug (lldb)
./scripts/build.sh release [args...]      # delegates to scripts/release.sh
./scripts/build.sh clean                  # rm -rf build/
```

Lower-level scripts (still supported, used by `build.sh` internally):

```sh
./scripts/regenerate_project.sh           # rebuild QwenVoice.xcodeproj from project.yml
./scripts/check_project_inputs.sh         # static validator — run before any build
./scripts/build_foundation_targets.sh macos   # macOS foundation build (always clean)
./scripts/build_foundation_targets.sh ios     # iOS compile-safety build (always clean)
./scripts/build_foundation_targets.sh all     # both
./scripts/build_and_run.sh                # legacy debug build → install → launch
./scripts/release.sh                      # macOS release packaging (ad-hoc signed DMG by default)
./scripts/release_ios_testflight.sh       # iOS TestFlight build/sign/notarize/upload
./scripts/clean_build_caches.sh           # nuke build caches
./scripts/export_diagnostics.sh           # collect diagnostics bundle
./scripts/verify_packaged_dmg.sh <dmg>    # verify a packaged DMG
./scripts/verify_release_bundle.sh <app>  # verify .app signing/entitlements
```

There is no SwiftFormat / SwiftLint config. There is no lint or typecheck command — the build is the typecheck.

### Build cache

Sha256 fingerprints at `build/.cache/` (`project.yml.sha256`, `Package.resolved.sha256.<context>`) let `build.sh` skip XcodeGen and SwiftPM resolve when their inputs are unchanged. The directory self-heals — delete it (or run `build.sh clean`) to force a cold rebuild. `xcodebuild` output is piped through `xcbeautify` when it's on `PATH` and stdout is a TTY.

### Single-resident build policy

At most one Debug `.app` and one Release `.app` + `.dmg` exist under `build/` at any time. Every successful `build.sh debug` and `build.sh release` (or direct `scripts/release.sh`) prunes the previous build of the same kind, including the intermediate Release `.app` inside `build/foundation/macos-release-derived-data/` and any older-named DMGs. Pruning is automatic with no opt-out; if `Vocello` is running it is quit (SIGTERM, then SIGKILL after a short grace period) before deletion. Failed builds skip pruning so previous artifacts stay intact for inspection.

### Runtime data folders

Release and Debug builds intentionally write to different Application Support folders so that Release behaves like a real end-user first launch while Debug accumulates state across rebuilds:

- Release: `~/Library/Application Support/QwenVoice/` (end-user-equivalent; not used for routine testing)
- Debug: `~/Library/Application Support/QwenVoice-Debug/` (persistent across rebuilds — models, `history.sqlite`, outputs, voices, stream-session caches all live here)

The split is compile-time inside `Sources/Services/AppPaths.swift` via `#if DEBUG`, so it holds regardless of launch method (Finder, Xcode Run, `build.sh run`, lldb). This works because the QwenVoice macOS target's Debug config in `project.yml` includes `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` — do not remove it without also moving the data-folder logic to a custom flag.

The first Debug launch under this policy renames an existing `QwenVoice/` folder to `QwenVoice-Debug/` automatically (no env-var override set, target folder absent, legacy folder present). The `QWENVOICE_APP_SUPPORT_DIR` env var still overrides the root in either configuration and disables auto-migration when set.

Release builds therefore start with an empty `QwenVoice/` after the first Debug launch — that's intentional. To exercise Release with realistic data, copy/symlink data into `~/Library/Application Support/QwenVoice/` manually or use the env-var override.

### Autonomous UI testing

The Debug build is drivable by a Claude Code session via the computer-use MCP. Entry point is `scripts/uitest.sh` (subcommands: `prep`, `reset [--include-voices|--full]`, `locate <ax-id>`, `scaled-locate`, `screen-size`, `activate`, `logs`, `db <sql>`, `artifacts-dir`, `smoke-check [<mode>]`, plus the bench-* family: `bench-wait`, `bench-step`, `bench-record`, `bench-summarize`, `bench-compare`, `bench-update-baselines`). The agent's reference for what's clickable and how to verify generation completion lives at `docs/reference/ui-test-surface.md`. Test artifacts land in `build/uitest/<timestamp>/` and are wiped by `scripts/build.sh clean`.

Smoke runbooks (one per generation mode):

- `docs/reference/smoke-custom-voice.md`
- `docs/reference/smoke-voice-design.md`
- `docs/reference/smoke-voice-cloning.md` (requires the `UITestRef` saved-voice fixture — see bootstrap below)

Smoke runbooks for non-generation surfaces:

- `docs/reference/smoke-settings.md` — Settings screen renders + Custom Voice model packages show "Ready"
- `docs/reference/smoke-history.md` — History list renders + search filters + row plays
- `docs/reference/smoke-saved-voices.md` — Saved Voices lists the `UITestRef` fixture + row plays

Saved-voice fixture bootstrap (one-time, autonomous):

- `docs/reference/bootstrap-saved-voice.md` — generates `voices/UITestRef.wav` via Voice Design → Save to Saved Voices, no file picker needed

Benchmark runbooks share the bench-* harness (`bench-wait`, `bench-step <mode> <variant> <coldwarm> <bucket>` as the one-shot per-sample wrapper, `bench-record` for the raw record-only call, `bench-summarize`, `bench-compare`, `bench-update-baselines`):

- `docs/reference/bench-custom-voice.md`
- `docs/reference/bench-voice-design.md`
- `docs/reference/bench-voice-cloning.md`

Committed baselines live at `docs/reference/benchmark-baselines.json` (schema v3, regression-ready, 24 cells × n=3 on Apple M2 — full coverage of the 3 modes × 2 variants × cold/medium + warm/{short,medium,long} matrix as of May 2026). Every cell carries `ms_engine_start_to_final`, `ms_engine_start_to_autoplay`, `audio_duration_s`, `rtf`, `audio_rms_dbfs`, `audio_peak_dbfs`, `peak_rss_mb` (combined Vocello + XPC), and the `peak_rss_mb_app` / `peak_rss_mb_xpc` split. `bench-compare` flags drift on `ms_engine_start_to_final` and `rtf` at ±15 %; depth metrics are recorded in the baseline for forensic comparison but not gated on directly.

## Testing policy — important

This repo intentionally has **no XCTest targets, no automated test harness, and no CI** as of May 2026. Behavioral validation is **manual**: after a clean foundation build, launch `build/Vocello.app` and exercise the affected paths by hand. Do not reintroduce test bundles, QA shell scripts, agent configs, benchmark harnesses, or any GitHub Actions workflow without an explicit maintainer decision — `scripts/check_project_inputs.sh` enforces this with a prohibited-paths list and a regex sweep of the working tree. Inspect that script for the current list rather than quoting names here (its patterns also trip on any file that mentions the banned names verbatim).

Recent commits that establish this stance: *"Retire all CI workflows; reset to local-only operation"*, *"Remove test harness and agent config"*, *"Scope CI to building and packaging validations only"*.

## Architecture

Two-platform Swift codebase with an out-of-process engine on each platform.

**Core modules (under `Sources/`):**

- `QwenVoiceCore/` — shared engine semantics: `TTSEngine` protocol, `MLXTTSEngine`, `TTSEngineError` (renamed from `MLXTTSEngineError`; a back-compat typealias remains), `GenerationMode`, lifecycle types, audio preparation.
- `QwenVoiceBackendCore/` — low-level MLX + audio primitives (model loading, synthesis, codecs).
- `QwenVoiceEngineService/` — **macOS XPC service** that runs TTS generation in an isolated process (`EngineServiceHost.swift`). The macOS app talks to it via `QwenVoiceNative`.
- `QwenVoiceNative/` — macOS app-facing engine proxy / store / client layer; bridges the XPC service to UI.
- `QwenVoiceEngineSupport/` — native runtime helpers (memory policy, streaming, telemetry).
- `iOSEngineExtension/` — **iOS ExtensionKit extension** (`VocelloEngineExtension`) that runs heavy generation outside the iPhone UI process.
- `iOS/` + `iOSSupport/` — iOS app surface.
- Main macOS app sources at the top level of `Sources/`: `QwenVoiceApp.swift` (entry), `ContentView.swift`, `Views/`, `ViewModels/`, `Models/`, `Services/`, `SharedSupport/`.

**Engine routing:** `AppEngineSelection.current()` picks the engine per platform — XPC client on macOS, extension-backed engine on iOS.

**Generation flows** (UI side): three coordinators map to the three workflows — `CustomVoiceCoordinator`, `VoiceDesignCoordinator`, `VoiceCloningCoordinator`. Speed (4-bit) vs Quality (8-bit) variant choice lives on the generation screens, not in Settings. iPhone is Speed-only; 8 GB Macs default to Speed, larger Macs default to Quality.

**Entitlements:** App sandbox is **disabled** (`com.apple.security.app-sandbox = false` in `Sources/QwenVoice.entitlements`) — required for MLX. Hardened runtime is on with allow-unsigned-memory and disable-library-validation flags.

## SPM dependencies (pinned in `project.yml`)

- `MLXSwift` 0.30.6 (`https://github.com/ml-explore/mlx-swift.git`)
- `MLXAudio` — **vendored locally** at `third_party_patches/mlx-audio-swift/` (Vocello-specific patches; do not replace with the upstream package without porting patches)
- `SwiftHuggingFace` 0.9.0 (model downloads)
- `GRDB` 7.10.0 (local SQLite — history, saved voices, model metadata)

## Conventions to preserve

- `accessibilityIdentifier` values in UI (e.g., `voicesRow_*`, `voicesEnroll_*`) are stable surface area — keep them when refactoring views.
- Animations route through `appAnimation` / `AppLaunchConfiguration.performAnimated` so Reduced Motion is honored; Liquid Glass surfaces must fall back to solid fills when Reduce Transparency is on. Both are non-negotiable per `PRODUCT.md`.
- Do not propose reintroducing a Python backend, a standalone CLI, or bundled model weights.
- Keep macOS release artifacts named `Vocello.app` and `Vocello-macos26.dmg`.

## Where to find more

- `docs/README.md` — documentation index
- `docs/reference/current-state.md` — current repo facts
- `docs/reference/release-readiness.md` — release signoff gates
- `docs/reference/privacy-storage.md` — local storage and deletion
- `docs/qwen_tone.md` — prompt/tone guidance for voice generation
- `CONTRIBUTING.md` — contributor workflow
