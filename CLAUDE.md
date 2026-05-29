# CLAUDE.md

This file provides guidance to Claude Code when working in this repository. It is the single, self-contained source of agent guidance for this repo — routing, conventions, and engine invariants all live here.

## What this repo is

Vocello (formerly QwenVoice) — a local, private text-to-speech macOS app powered by Qwen3-TTS via MLX on Apple Silicon. The macOS scheme is still called `QwenVoice` but the shipped public product is `Vocello.app` / `Vocello-macos26.dmg`. The iOS counterpart (`VocelloiOS`) is kept **compile-safe only** on `main`; on-device generation, memory proof, and TestFlight are deferred pending Apple's increased-memory entitlement, and iPhone release proof is not a public-release blocker for the current macOS-first release track. The public product website now lives in `website/` as a React + Vite app deployed by Vercel with that subdirectory as the project root.

Targets: macOS 26.0+ and iOS 26.0+, Apple Silicon only, Xcode 26.0. No Python runtime. No bundled model weights — models are downloaded from Hugging Face from Settings → Model Downloads on first run.

## Quick start

```sh
./scripts/build.sh run                       # Debug build → launch Vocello.app
./scripts/build_foundation_targets.sh macos  # macOS foundation build
./scripts/build_foundation_targets.sh ios    # iOS compile-safety only
npm --prefix website run build               # marketing website production build
```

First-time setup: install XcodeGen (`brew install xcodegen`) and optionally `xcbeautify` (`brew install xcbeautify`) for pretty-printed build output.

## Agent routing (Claude Code)

Use installed **skills** for workflow guidance and Axiom **subagents** (via the `Agent` tool with `subagent_type`) for audits. Do not copy skill files into this repo unless there is an explicit maintainer decision. Repo scripts remain authoritative.

**Before any iOS/Swift response, check whether an Axiom skill applies** — the Axiom routing discipline (environment/build → architecture → implementation) is in force on this repo. Route by symptom, then act.

**Mandatory subagent launches (high-risk)** — launch the relevant `Agent` before deep fixes; address or explicitly defer findings:

- **BUILD FAILED / Xcode env** → `axiom:build-fixer` (run `./scripts/build.sh debug` first)
- **Crash logs** (`.ips`, MetricKit) → `axiom:crash-analyzer` (or the `xcsym` tool / `/axiom:analyze-crash`)
- **Engine actor/async/gates** → `axiom:concurrency-auditor`
- **Memory / streaming / MLX cache** → `axiom:memory-auditor` (+ `axiom:swift-performance-analyzer` on the same diff)
- **GRDB migrations** → `axiom:database-schema-auditor`
- **Release / entitlements / privacy** → `axiom:security-privacy-scanner`
- **"Health check" / full audit** → `axiom:health-check`

### Axiom subagents (`Agent` tool, `subagent_type`)

| Symptom or scope | `subagent_type` | Pair with skill |
|---|---|---|
| BUILD FAILED / env | `axiom:build-fixer` | `axiom:axiom-build` |
| Crash / `.ips` | `axiom:crash-analyzer` | (`xcsym` tool) |
| Engine async / actors | `axiom:concurrency-auditor` | `axiom:axiom-concurrency` |
| Memory / leaks / trim | `axiom:memory-auditor` | `axiom:axiom-performance` |
| Swift runtime perf | `axiom:swift-performance-analyzer` | `axiom:axiom-performance` |
| GRDB / migrations | `axiom:database-schema-auditor` | `axiom:axiom-data` |
| Codable / JSON | `axiom:codable-auditor` | `axiom:axiom-data` |
| Security / privacy manifest | `axiom:security-privacy-scanner` | `axiom:axiom-security` |
| Full audit | `axiom:health-check` | |
| SwiftUI perf | `axiom:swiftui-performance-analyzer` | `axiom:axiom-swiftui` |
| SwiftUI architecture | `axiom:swiftui-architecture-auditor` | `axiom:axiom-swiftui` |
| SwiftUI layout | `axiom:swiftui-layout-auditor` | |
| Navigation | `axiom:swiftui-nav-auditor` | |
| UX flows | `axiom:ux-flow-auditor` | |
| Liquid Glass | `axiom:liquid-glass-auditor` | `axiom:axiom-design` |
| Storage / file layout | `axiom:storage-auditor` | `axiom:axiom-data` |
| Headless Instruments / `xctrace` | `axiom:performance-profiler` | `axiom:axiom-performance` |

### Backend and MLX

- `mlx-swift` — use for MLX array/runtime/memory behavior, cache/eval/lazy-array work, custom MLX operations, and backend performance changes.
- `mlx-swift-lm` — use for generation, streaming, KV-cache, wired-memory, or model-porting questions that overlap MLX LM internals or the vendored `mlx-audio-swift` stack.
- There is no dedicated Core ML skill in this environment; do not pivot ordinary Qwen3-TTS work to Core ML. MLX stays the default (and only) Qwen3-TTS backend unless a task explicitly asks for an architecture change.

### Apple framework docs

- `axiom:axiom-apple-docs` — router for Apple framework APIs, Swift compiler diagnostics, and the Xcode-bundled for-LLM documentation (Liquid Glass, Swift 6.2 concurrency, Foundation Models, SwiftData, StoreKit, etc.).
- `sosumi` MCP (`fetchAppleDocumentation`, `searchAppleDocumentation`, `fetchAppleVideoTranscript`) — fetch current Apple docs/WWDC transcripts for iOS 26+ and post-cutoff APIs.
- Xcode for-LLM guides and Swift diagnostics live under `/Applications/Xcode.app/...AdditionalDocumentation/` and the toolchain `share/doc/swift/diagnostics/` — read directly when a specific diagnostic or guide is named.

### Diagnostics, profiling, and Apple AI

- `axiom:axiom-performance` — current performance diagnostics router for slow paths, memory growth, leaks, battery, Instruments workflows, and MetricKit-related production/TestFlight diagnostics. MetricKit guidance lives under Axiom performance references; there is no standalone MetricKit skill.
- `axiom:performance-profiler` (Agent) — automated/headless Instruments or `xctrace` profiling and focused trace capture.
- `axiom:memory-auditor`, `axiom:concurrency-auditor`, `axiom:swift-performance-analyzer`, and `axiom:swiftui-performance-analyzer` (Agents) — memory, async/data-race, Swift runtime, and SwiftUI performance review passes.
- `axiom:axiom-ai` and `axiom:foundation-models-auditor` — use only when comparing or reviewing Apple Intelligence / Foundation Models / on-device-AI architecture. Keep MLX as the default Qwen3-TTS backend unless a task explicitly asks for an architecture change.

### iOS workflow

iPhone is **compile-safe only** on the current macOS-first track — there is no in-repo device-deploy, on-device proof, or Simulator UI-testing harness. iOS verification is `./scripts/build_foundation_targets.sh ios` (compile-safety). On-device generation, memory proof, and TestFlight are deferred pending Apple's increased-memory entitlement; planning hub: [`docs/reference/ios-shipping.md`](docs/reference/ios-shipping.md), admission policy: [`ios-memory-admission-policy.md`](docs/reference/ios-memory-admission-policy.md).

- **iOS SwiftUI feature work, refactors, architecture, render perf** — `axiom:axiom-swiftui` skill plus `axiom:swiftui-architecture-auditor`, `axiom:swiftui-performance-analyzer`, `axiom:swiftui-layout-auditor`, and `axiom:swiftui-nav-auditor` (Agents). Preserve the existing `@Observable` / `AppModel` architecture.
- **iOS retain cycles / memory growth** — `axiom:memory-auditor` (Agent) + `axiom:axiom-performance`, as a static / code-review pass.
- **iOS 26 Liquid Glass adoption or review** — `axiom:liquid-glass-auditor` (Agent) + `axiom:axiom-design`; keep the repo's iOS/macOS design-token alignment in mind before changing glass, tint, radius, or fallback behavior.
- Need a Simulator visual spot-check? `XcodeBuildMCP` (`mcp__XcodeBuildMCP__*`) is available, but real MLX generation can't run in the Simulator — treat it as UI-only.

### macOS workflow

- macOS build/run/debug — prefer the existing `./scripts/build.sh` entrypoint over creating new run scripts.
- DMG, archive, notarization, distribution-readiness — `axiom:axiom-shipping` plus `scripts/release.sh` and the `scripts/verify_*.sh` helpers.
- Code-signing, entitlements, hardened runtime, sandbox, Gatekeeper, provisioning — `axiom:axiom-security` and `axiom:axiom-macos`.
- macOS-specific windowing / AppKit interop / SwiftUI-on-macOS — `axiom:axiom-macos`; use only when the task directly touches those concerns.
- Telemetry — add or validate concise OSLog/signpost instrumentation directly; inspect it with `log show --signpost` or Instruments.

### Behavioral testing

There is **no automated UI-driving, smoke, or benchmark harness** in this repo. Behavioral validation is **manual local app acceptance**: build and launch the Debug app (`./scripts/build.sh run`), exercise the affected generation paths by hand, and listen to the output. Build/compile-safety is the only automated gate (`./scripts/build.sh debug`, `./scripts/build_foundation_targets.sh ios`). Do not reintroduce a UI-driving harness, computer-use bench tooling, smoke/bench runbooks, or committed timing baselines without an explicit maintainer decision (`scripts/check_project_inputs.sh` guards against the retired surfaces).

### Release, collaboration, and artifacts

- GitHub PRs/issues/CI: use the `gh` CLI via Bash (`gh pr`, `gh run`, `gh api`) and the `/review` skill for PR review. The GitHub MCP plugin is available if authenticated. Branch before committing if on `main`; commit/push only when the user asks.
- Hugging Face model/package downloads, uploads, cache checks, artifact verification: use the `hf` CLI via Bash (e.g. `hf download`, `hf cache scan`).

### Skill discipline

Do not auto-invoke unrelated skills. Skip `deep-research`, `anthropic-skills:*` (docx/pptx/xlsx/canvas/etc.), `design:*`, `productivity:*`, `engineering:*`, and `claude-api` unless a task explicitly targets that tooling. For website (React/Vite) work, use the `context7` MCP for library/framework docs and `impeccable:impeccable` for UI/UX passes; browser verification goes through the `chrome-devtools` MCP.

## Source of truth (when facts disagree)

Per `CONTRIBUTING.md`, trust in order: `Sources/` → `project.yml` → `scripts/` → `.github/workflows/release.yml` for the scoped CI boundary → `docs/reference/` → other prose. `Sources/Resources/qwenvoice_contract.json` is the canonical schema for speakers, models, variants, HF revisions, and required artifacts. For public website copy and visuals, `website/src/`, `website/PRODUCT.md`, and `website/DESIGN.md` are the maintained source, but product claims must still be checked against the app contract and maintained reference docs.

## Maintainer privacy

Do not commit personal identifiers into user-facing repo files (this file, `README.md`, `website/`, `docs/`, release notes, and script defaults): no legal names, personal emails, home paths (`/Users/<name>/...`), device nicknames, UDIDs, or hardcoded Apple team IDs. Bundle IDs (e.g. `com.patricedery.vocello`) and generic "Developer ID" / "notarized" language are fine. Scan for these patterns before committing any doc/website/script change.

## Project generation and build

The Xcode project is generated from `project.yml` via XcodeGen. Edit `project.yml` (not `.xcodeproj`) for structural changes, then regenerate.

**XcodeGen iOS resource gotcha.** The iOS app target lists `Sources/Resources/qwenvoice_contract.json`, `Sources/Resources/qwenvoice_ios_model_catalog.json`, `Sources/Resources/voice-previews`, and `Sources/Assets.xcassets` under its `sources:` block with an explicit `buildPhase: resources` override, not under `resources:`. XcodeGen 2.45.4 silently drops these files from the `VocelloiOS` Resources phase when they're listed under `resources:` directly — iOS builds compile but crash on first launch with missing bundled resources. The macOS target is unaffected because it uses the directory pattern (`- path: Sources/Resources` under `resources:`). Workaround landed in Track 0 of commit `287c969` (May 2026); leave the sources-block placement in place when editing `project.yml`.

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
./scripts/check_ios_catalog.sh            # iOS catalog/static sanity check
./scripts/clean_build_caches.sh           # nuke build caches
./scripts/export_diagnostics.sh           # collect diagnostics bundle
./scripts/verify_packaged_dmg.sh <dmg>    # verify a packaged DMG
./scripts/verify_release_bundle.sh <app>  # verify .app signing/entitlements
```

There is no SwiftFormat / SwiftLint config. There is no lint or typecheck command — the build is the typecheck.

### Build layout and cache

Only two maintained top-level folders belong under `build/`: `build/Debug/` and `build/Release/`. Debug is the default development/testing/debugging area; Release is the GitHub-release packaging area. Do not add new sibling folders under `build/`.

Sha256 fingerprints under `build/Debug/.cache/` and `build/Release/.cache/` (`project.yml.sha256`, `Package.resolved.sha256.<context>`) let `build.sh` skip XcodeGen and SwiftPM resolve when their inputs are unchanged. These directories self-heal — delete `build/` (or run `build.sh clean`) to force a cold rebuild. `xcodebuild` output is piped through `xcbeautify` when it's on `PATH` and stdout is a TTY.

### Single-resident build policy

At most one published Debug `.app` and one published Release `.app` + `.dmg` exist under `build/` at any time: `build/Debug/Vocello.app`, `build/Release/Vocello.app`, and `build/Release/Vocello-macos26.dmg`. Xcode incremental products stay nested under the owning folder's `DerivedData/`; release logs, metadata, source packages, result bundles, and package outputs live under `build/Release/`. Pruning is automatic with no opt-out; if `Vocello` is running it is quit (SIGTERM, then SIGKILL after a short grace period) before deletion. Failed builds skip pruning so previous artifacts stay intact for inspection.

### Runtime data folders

Debug and local Release builds intentionally write to different Application Support folders so Debug keeps day-to-day development state while each repo-local Release package starts clean:

- Debug: `~/Library/Application Support/QwenVoice-Debug/` (persistent across rebuilds — models, `history.sqlite`, outputs, voices, stream-session caches all live here)
- Repo-local Release: `~/Library/Application Support/QwenVoice-Release-Local/<release-data-id>/` (fresh per successful `scripts/release.sh` packaging)
- Installed/public Release: `~/Library/Application Support/QwenVoice/` (normal end-user storage once copied outside repo-local `build/Release/`)

Debug selection is compile-time inside `Sources/Services/AppPaths.swift` via `#if DEBUG`. Repo-local Release selection is runtime-gated by the signed `QwenVoiceLocalReleaseDataID` Info.plist value and the bundle path ending in `build/Release/Vocello.app`; copying the app elsewhere makes it use the installed/public Release store. This works because the QwenVoice macOS target's Debug config in `project.yml` includes `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` — do not remove it without also moving the data-folder logic to a custom flag.

The first Debug launch under this policy renames an existing `QwenVoice/` folder to `QwenVoice-Debug/` automatically (no env-var override set, target folder absent, legacy folder present). The `QWENVOICE_APP_SUPPORT_DIR` env var still overrides the root in either configuration and disables auto-migration when set.

Local Release defaults are isolated too: `AppDefaults` uses a release-id-specific preferences suite for repo-local Release apps, while Debug and installed/public Release use normal app preferences. To exercise Release with realistic data, copy/symlink data into the local release folder or use the env-var override.

## Testing policy — important

This repo keeps CI **scoped to release packaging plus compile-safety automation** — no XCTest targets, no automated bench/smoke/perceptual runs, no Python/CI benchmark harnesses. The sole workflow at `.github/workflows/release.yml` has two parallel jobs on `release.published` (and on manual `workflow_dispatch`): `package` (macOS DMG sign + notarize + staple via `scripts/release.sh`, attached to the GitHub Release) and `compile-ios` (iOS compile-safety only, no signing, no tests, runs `scripts/build_foundation_targets.sh ios`). `compile-ios` failures do not block the macOS DMG; the iOS signed-IPA path is deferred until the increased-memory entitlement approval, an iOS Distribution certificate, and provisioning profiles for `com.patricedery.vocello` plus `com.patricedery.vocello.engine-extension` are ready (see [`docs/reference/release-readiness.md`](docs/reference/release-readiness.md) § "iPhone Shipping Plan").

**Behavioral validation is manual and local only.** There is no automated UI-driving, smoke, or benchmark harness — exercise the app by hand. For Debug macOS behavior, `./scripts/build.sh run`, then drive the app yourself (Debug app path: `build/Debug/Vocello.app`). For release signoff, launch `build/Release/Vocello.app` only after `./scripts/release.sh` has produced the Release bundle. iPhone is compile-safe only (`./scripts/build_foundation_targets.sh ios`); there is no in-repo device-deploy or on-device proof tooling.

Do not reintroduce test bundles, QA shell scripts, a UI-driving / computer-use bench harness, smoke/bench runbooks, committed timing baselines, device-deploy or on-device proof scripts, agent configs, or additional GitHub Actions workflows beyond `release.yml` without an explicit maintainer decision. `scripts/check_project_inputs.sh` enforces the retired surfaces with a prohibited-paths list and a regex sweep of the working tree. Inspect that script for the current list rather than quoting names here (its patterns also trip on any file that mentions the banned names verbatim).

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

**Generation flows** (UI side): three coordinators map to the three workflows — `CustomVoiceCoordinator`, `VoiceDesignCoordinator`, `VoiceCloningCoordinator`. The active Qwen3 variants are Speed (1.7B 4-bit) and Quality (1.7B 8-bit); 0.6B artifacts were verified but are intentionally not listed, downloadable, or selected while the app focuses on the 1.7B implementation. Selection lives on the generation screens, while Settings manages all downloadable rows. iPhone resolves one 1.7B Speed package per mode from the bundled catalog. 8 GB Macs default to Speed; larger Macs default to Quality. iOS exposes an additional 3-segment intensity picker (`Subtle / Normal / Strong`) below the delivery preset selector when a non-neutral preset is chosen and the active model supports instruction control; `DeliveryInputState.selectedIntensity` carries the value through to `EmotionPreset.preset(preset, intensity:)`. iOS Voice Cloning also exposes a "Generate batch…" affordance backed by `IOSBatchGenerationCoordinator` (sequential single-call loop, distinct from the macOS `BatchGenerationRunner`) and `IOSBatchGenerationSheet`.

**iOS design tokens align to macOS** (May 2026, commit `287c969`). `IOSAppTheme.subtleGlassTint` is 14% opacity (matches macOS `surfaceGlassTint` dark); `accentStroke` is 34%; `accentWash` is 20%. Neutral palette is warm-tinted (`textSecondary` ~`#C5BFAE`, `textTertiary` ~`#7E7868`) rather than cool blue-gray. Card corner radii unify at 16 pt; chips and badges are flat (no glass) per the macOS May 2026 chip audit. Brand wordmark uses SF Rounded semibold, mirroring `Sources/Views/Sidebar/SidebarView.swift`. When changing iOS colors, check the macOS values first — these are intentionally locked together.

**iOS design redesign** (May 2026, commits `51d8dce` through `c89fba2`). The iOS app moved to a 4-tab IA (**Studio / Voices / History / Settings**) sourced from `design_references/Vocello iOS/` (React + CSS prototype) and `design_references/Vocello Design System/`. After the design tracks (A-P) landed, a six-phase ground-up rebuild reorganized the architecture (commits `2ff76af` … `c89fba2`):

**File layout** (post-rebuild):

- `Sources/iOS/Theme/Theme.swift` + `ThemeModifiers.swift` — canonical design tokens: Brand mode colors (`#EDCC8A` / `#BFAADC` / `#DBA887`), Surface ramp (canvas / stage / card / inline / field / dock), Text colors (warm-tinted neutrals), corner radii (chip 8 / input 10 / card 16 / stage 22), motion curves (cubic-bezier 0.22, 1, 0.36, 1 at 150/220/320/360/420 ms), branding constants. `themeGlassSurface` modifier with Reduce Transparency fallback.
- `Sources/iOS/App/AppModel.swift` — `@Observable` root state model. Owns tab, studio mode, drafts, pending clone handoff, onboarding gate, player sheet item, 3 `StudioGenerationCoordinator` instances.
- `Sources/iOS/App/RootView.swift` — flat tab routing on `appModel.tab`. Owns the global Player sheet `.sheet(item:)`, onboarding `fullScreenCover`, and `\.presentIOSPlayerSheet` environment closure injection.
- `Sources/iOS/App/TabDock.swift` — bottom glass dock; mode-tinted on Studio, neutral on Voices / History / Settings.
- `Sources/iOS/Studio/StudioScreen.swift` — Studio tab entry point. Reads AppModel; delegates the body to the existing per-mode views (refactor target for future work).
- `Sources/iOS/IOSGenerateFlowViews.swift` — `IOSGenerationModeSelector` animated 3-way pill with matched-geometry sliding selection.
- `Sources/iOS/Studio/StudioGenerationCoordinator.swift` — `@Observable` per-mode generation lifecycle (`isGenerating`, `errorMessage`, `lastCompletedOutput`). Replaces the scattered `@State` that used to live on each per-mode view.
- `Sources/iOS/Studio/IOSStudioInlinePlayerCard.swift` — completion-state mini player with Save / Download / Dismiss actions, 38-bar waveform, soft drop shadow per design notes (`0 2 10 / 0.22`), and expansion into the global Player sheet via `\.presentIOSPlayerSheet`.
- `Sources/iOS/Voices/VoicesScreen.swift` — unified built-in + saved voices entry; consumes `AppModel`.
- `Sources/iOS/History/HistoryScreen.swift` — History entry; row tap presents the full-screen Player sheet via `\.presentIOSPlayerSheet`.
- `Sources/iOS/Settings/SettingsScreen.swift` — Settings entry. Per-model rows + accessibility links still flow through the legacy `IOSSettingsContainerView` body.
- `Sources/iOS/Sheets/` — bottom sheets bundle: `IOSBottomSheets.swift` (Delivery / Voice / ReferenceClip / ModelInstall / DeleteModel), `IOSPlayerSheet.swift` + `IOSWordTimingPlanner.swift` (full-screen player with karaoke transcript), `IOSVoiceDesignBriefSheet.swift`.
- `Sources/iOS/Overlays/` — `IOSOnboardingFlow.swift` (3-step welcome, gated by `IOSAppDefaults.hasCompletedOnboarding`), `IOSRecordingOverlay.swift` (clone-reference capture via `AVAudioRecorder`, 10-20 s gate, requires `NSMicrophoneUsageDescription`).
- `Sources/iOSSupport/Services/IOSAppDefaults.swift` — iOS user-defaults keys (`hasCompletedOnboarding`, `autoplayCompletions`).

**Modern SwiftUI patterns:** `@Observable` + `@Environment(AppModel.self)` + `@Bindable` (no `@StateObject` / `@Published`); `.sheet(item:)`; `@available(iOS 26, *)` gating for Liquid Glass; `sensoryFeedback(_:trigger:)` for haptics; `foregroundStyle(_:)` everywhere; modern `.confirmationDialog` / `.alert`; stable `Identifiable` in every `ForEach`. For future SwiftUI work, use `axiom:axiom-swiftui` and the `axiom:swiftui-*-auditor` Agents rather than retired project-local skill references.

**iOSSupport concurrency note.** `Sources/iOSSupport/Services/DatabaseService.swift` keeps `DatabaseService.shared` as a plain `static let`, backed by GRDB's `DatabaseQueue` and the existing `@unchecked Sendable` conformance. `Sources/iOSSupport/Models/Generation.swift` keeps its shared `DateFormatter` as a plain private `static let` so formatting output stays unchanged. Do not reintroduce unsafe non-isolation annotations in iOSSupport for these values; macOS-side annotations are a separate code path and should be changed only after their own investigation.

**Legacy file zone.** Any `Sources/iOS/IOS*.swift` directly under the `Sources/iOS/` root (i.e. not in `Theme/`, `App/`, `Studio/`, `Voices/`, `History/`, `Settings/`, `Sheets/`, `Overlays/`) is a legacy body still rendering the per-mode generation flows, library lists, and settings rows. The new screen files are thin AppModel-aware shells around them; future cleanup can collapse the legacy bodies behind the new screens. Keep-list (engine wiring + entry point, not legacy): `QVoiceiOSApp.swift`, `QVoiceiOSRootView.swift`, `TTSEngineStore.swift`, `IOSAppBootstrap.swift`, `IOSEngineExtensionPoint.swift`, `IOSPreviewSupport.swift`, `IOSAccessibility.swift`, `IOSAccessibilityIdentifiers.swift`, `IOSModelInstallerViewModel.swift`, `IOSModelDeliveryActor.swift`, `IOSModelDeliveryBackgroundEvents.swift`, `IOSBatchGenerationCoordinator.swift`, `IOSBatchGenerationSheet.swift`, `IOSSimulatorTTSEngine.swift`, `IOSSimulatorFakeInstallRegistry.swift`, `IOSGenerationTextLimitPolicy.swift`.

**iOS UI audit pass** (May 2026, commits `f5841ef` through `374338c`). After the ground-up rebuild, a thirteen-commit audit closed every layout / chrome / sheet item:

- `RootView` (not the legacy shell) now owns the entire chrome stack — canvas color, mode-tinted backdrop, TabDock, now-playing rail, engine-lifecycle toast. `IOSStudioShellScreen` shrank to a horizontal-padding + top-padding pass-through. The dock active-pill, mode segmented rail, setup chips (44pt capsules with chevron.down), and Studio tab icon (`waveform`, not `waveform.badge.mic`) all match `design_references/Vocello iOS/app.css`.
- Composer is borderless 22pt SF Pro Display weight medium with letter-spacing -0.22pt; meta + counter row sits flush below. Composer is **`flex: 1`** via `Sources/iOS/Studio/IOSFlexibleTextEditor.swift` — a `UIViewRepresentable<UITextView>` wrapper around a custom `NoIntrinsicHeightTextView` whose `intrinsicContentSize` returns `UIView.noIntrinsicMetric` so SwiftUI's `.frame(maxHeight: .infinity)` drives sizing end-to-end (stock `TextEditor` ignored it). Canvas keeps a hardcoded `.padding(.bottom, 130)` so chips + Generate CTA clear the TabDock's visual extent (NavigationStack inside RootView doesn't propagate the dock's `safeAreaInset` reservation).
- Memory-indicator store + accessory + state retired (`80f6511`, -358 lines). The iOS-side `IOSGenerateMemoryIndicatorStore` (`IOSShellPrimitives.swift`) and its rendering accessory had been orphaned since R0 dropped the IOSStudioShellCanopy. Engine-side memory policy is untouched — `IOSMemoryPressureBand` (QwenVoiceCore), `TTSEngineStore.refreshMemoryPolicy()`, and the per-tier `NativeMemoryPolicyResolver` remain.
- All five bottom sheets (Voice / Delivery / ReferenceClip / ModelInstall / DeleteModel) + the full-screen Player sheet were rewritten to design spec: 2-col delivery grid with colored dots + descriptions, voice picker language pills + filter chips + per-row preview play, model install sheet's 56pt mode-tinted icon + size/`ON-DEVICE` pills + "Stays on your iPhone" privacy callout, Player sheet's centered 22pt header + 42-bar 96pt waveform + real scrubber track + thumb + centered karaoke transcript.
- Settings model rows now route Download/Delete through `IOSModelInstallSheet` + `IOSDeleteModelSheet` (replacing the previous bare button + system `confirmationDialog`).
- Voice picker preview play loads ~2.5s WAVs from `Sources/Resources/voice-previews/{aiden,ryan,vivian,serena}.wav` (24 kHz mono Int16 PCM, ~540 KB total bundled, generated via the macOS Vocello Debug app). `IOSVoicePreviewPlayer.swift` is the shared previewer; `IOSVoicePickerSheet` drives it via `@StateObject`. Auto-stop on row tap + on sheet dismiss.
- Audio preview/player chrome now uses shared reference primitives: mini / player / big waveform styles, 40pt circular `IOSPlayerIconButtonChrome`, 38-bar inline waveform, 42-bar full-sheet waveform, and matching Save / Download / Dismiss controls. Studio inline player expansion, Voices preview buttons, voice-picker rows, the now-playing rail, and the full Player sheet should stay visually aligned with `design_references/Vocello iOS/player.jsx`, `studio.jsx`, and `app.css`.
- DEBUG-only "Seed sample history" affordance in Settings (gated on `IOSSimulatorRuntimeSupport.isSimulator`) writes a silence WAV + Generation row so the Player sheet is reachable in Simulator runs where the stub engine never produces real takes.

**Entitlements:** App sandbox is **disabled** (`com.apple.security.app-sandbox = false` in `Sources/QwenVoice.entitlements`) — required for MLX. Hardened runtime is on with allow-unsigned-memory and disable-library-validation flags.

## Performance + memory adaptation (May 2026)

Non-obvious runtime behavior added across the May 2026 Phase 1+2+3 rollout. Future agents modifying engine code should know about these.

### Per-tier memory policy

`NativeMemoryPolicyResolver` picks a policy per `NativeDeviceMemoryClass` (floor8GBMac, mid16GBMac, highMemoryMac, iPhonePro). Key tier-specific behaviors:

- **floor8GBMac**: `clearCacheAfterGeneration: true`, `unloadAfterIdleSeconds: 120` (adaptive — see below), clone cache capacity = 1, `customPrewarmPolicy: .skipDedicatedCustomPrewarm` (`EngineServiceHost.swift` sets this conditionally), streaming tuning `clearMLXCacheOnStreamChunkEmit: true` / `mlxTokenMemoryClearCadence: 50`. **No hard MLX `Memory.memoryLimit`** — relies on `cacheLimitBytes` (256 MB); a 6 GB cap was tried and reverted in `b77c08e` (it tripped spurious OOM→Speed downgrades during cold-load peaks). Custom Voice doesn't run a dedicated prewarm — the work moves into the first generation proper.
- **mid16GBMac / highMemoryMac**: `customPrewarmPolicy: .eager`, longer idle windows, larger clone caches. Streaming tuning: mid16GBMac `clearMLXCacheOnStreamChunkEmit: true` / cadence 50; highMemoryMac `false` / cadence 200 (skips the per-chunk cache clear — it has the headroom).
- **iPhonePro**: tightest tier — cache 128 MB, unload after 30 s, clone cache = 1, streaming tuning `true` / 50. **No default hard `Memory.memoryLimit`** (a 5 GB default was tried and reverted in `b77c08e` — meaningless below the ~3 GB Jetsam ceiling); set only via the Debug `QVOICE_IOS_MLX_MEMORY_LIMIT_MB` override (process-lifetime).

### Streaming memory tuning

The per-tier `clearMLXCacheOnStreamChunkEmit` and `mlxTokenMemoryClearCadence` fields (on `NativeMemoryPolicy`) are pushed into the vendored backend via `Qwen3StreamingMemoryTuning.apply(clearOnStreamChunk:tokenCadence:)` (`third_party_patches/mlx-audio-swift/.../Qwen3StreamingMemoryTuning.swift`), a lock-guarded process-global. `clearOnStreamChunk` gates the per-streamed-chunk `clearGenerationCache()` in `Qwen3TTS.swift` (off on highMemoryMac); `tokenCadence` overrides the token-loop `Memory.clearCache()` interval. These two values are **constant per device class**, so the global is set to the same values across all modes/generations on a given machine — there is no cross-generation drift to worry about.

### runtime memory-pressure monitor

`Sources/QwenVoiceCore/NativeMemoryPressureMonitor.swift` wraps `DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical])` on macOS and iOS. `MLXTTSEngine.initialize(...)` starts it on floor8GBMac, mid16GBMac, and iPhonePro. Kernel pressure events map to `NativeMemoryTrimLevel` and route to `runtime.trimMemory(level:reason:)` — softTrim clears MLX cache + clone soft-trim; hardTrim clears all warm state. iOS still has no visible memory indicator; app-layer memory guardrails flow through `TTSEngineStore.refreshMemoryContext(...)`, combined app + engine-extension snapshots, and the per-tier `IOSMemoryBudgetPolicy`.

iPhone memory remediation notes: physical-device model installs do not eager-load the engine anymore; the first foreground generation loads with its request-specific capability profile. iOS foreground generation is streaming-first, while physical-device streaming chunks omit inline `previewAudio.pcm16LE` by default unless `QWENVOICE_STREAMING_PREVIEW_DATA=on` is set. `Qwen3TTSMemoryCaches.clearAll()` clears prepared tokenizer, speech-tokenizer, conditioning-prefix, and streaming-decoder bucket caches on iPhone hard-trim/full-unload/unload/failure paths; macOS cache warmth is intentionally preserved. As of May 2026, iOS **model admission blocking and in-flight critical cancel are disabled** while measuring extension Jetsam without the increased-memory entitlement (`docs/reference/ios-memory-admission-policy.md`); `guardModelAdmission` only records `model_admission_observed`. On iPhone, switching to a different model ID unloads and clears Qwen3 caches before the next load peak. Device diagnostics record combined app+extension resident/physical/GPU footprints and aggregate pressure bands. Debug iPhone builds can experiment with MLX limits via `QVOICE_IOS_MLX_MEMORY_LIMIT_MB` / `QVOICE_IOS_MLX_CACHE_LIMIT_MB`; the memory-limit override is process-lifetime for the launched app process and ignored outside Debug.

### Adaptive idle-unload on floor8GBMac

`MLXTTSEngine.adaptiveIdleUnloadDelay(...)` consults `memoryPressureMonitor.currentLevel` and shortens the 120 s default to 30 s under softTrim or 10 s under hardTrim. mid16GBMac and higher keep their baseline. The model reloads on the next generation (~500–700 ms cost) but peak RSS stays bounded.

### Prewarm reentrancy gate (CRITICAL)

`NativeEngineRuntime` is a Swift actor, but actors don't prevent reentrancy across suspension points. Both `ensureWarmStateIfNeeded` (Custom + Design + Clone path) and `ensureDesignConditioningWarmStateIfNeeded` call `try await model.prewarm*(...)`, which releases actor exclusivity while MLX work runs. Without protection, two callers (typically `prefetchInteractiveReadinessIfNeeded` + `prepareGeneration` racing on launch) reach MLX's KV cache slice updates concurrently and trip an assertion (crashed the engine in May 2026 with a C++ KV-cache assertion).

The fix is a monitor-style gate: `prewarmInFlight: Bool` + `prewarmWaiters: [CheckedContinuation<Void, Never>]` with `acquirePrewarmSlot()` / `releasePrewarmSlot()` helpers. Both ensure* methods call `await acquirePrewarmSlot()` first and `defer { releasePrewarmSlot() }`. **Do not remove the gate or restructure the prewarm path without preserving this serialization.**

**Anti-pattern (regressed once, fixed in `b77c08e`):** never pair `try? await acquirePrewarmSlot()` with an *unconditional* `defer { releasePrewarmSlot() }`. On a throw (cancellation) the slot is NOT held, so the defer releases a slot owned by another task and breaks the gate — reintroducing the concurrent-prewarm crash. Only register the release when the slot was actually acquired: `do { try await acquirePrewarmSlot() } catch { return }` then `defer { releasePrewarmSlot() }` (this is what `trimMemory` does).

### Generation ownership and cancellation (CRITICAL)

`MLXTTSEngine` owns admission for model-mutating work. Generation, batch generation, explicit load/unload, proactive warmup/prefetch, and clone priming must go through its model-operation gate so only one operation mutates model/runtime state at a time. Proactive warm operations skip/defer when the lease is occupied; user-triggered generation rejects cleanly when another generation is active.

The macOS and iOS app-facing stores expose `hasActiveGeneration`, and generation UIs must use that shared state to disable cross-mode controls and show cancellation. The macOS XPC host and iOS extension host reject concurrent generation instead of replacing active handles. Streaming chunks carry a UUID `generationID`; numeric `requestID` remains useful for logs/signposts but must not be the sole playback-session identity across service/runtime restarts. Vendored Qwen streaming producers must cancel their producer `Task` from `AsyncThrowingStream` termination and check cancellation inside token/decode loops so orphaned consumers cannot leave MLX generation running.

### Off-MainActor event forwarding + chunk-sequence diagnostics

The XPC hosts (`EngineServiceHost`, `VocelloEngineExtensionHost`) drain `engine.events` on a `Task.detached(priority: .utility)` (off MainActor) so the synchronous XPC encode can't make the consumer lag the producer — this is the resolution of the `d93612c` chunk-drop trap (see Known traps). `publish(.generationChunk(event))` runs off-main, guarded by `sessionLock`; only `lastPublishedEvent` hops to MainActor. Each `GenerationChunk` carries a monotonic `chunkSequence` (`UInt64(chunkIndex)`, reset per generation); the forwarding loop tracks it **per `generationID`** (reset when the id changes — otherwise the detector dies after generation #1) and records `engine_*_chunk_gap` to `native-events.jsonl` on a forward jump >1. Diagnostics only, and fired on a background task so the file I/O never blocks chunk delivery.

### LatestEventCoalescer

`MLXTTSEngine` feeds snapshot consumers via `LatestEventCoalescer` (`Sources/QwenVoiceCore/LatestEventCoalescer.swift`), a lock-guarded coalescing slot drained by one long-lived MainActor task. The off-MainActor MLX producer `push`es the latest preview-stripped event without allocating a `Task { @MainActor }` per chunk; the drain task updates `latestEvent`. `stop()` cancels the drain then `clear()`s the slot (`waitForUpdate()` is cancellation-aware so the drain can't leak). This replaced per-chunk MainActor task spawning.

### Quality → lower-memory OOM fallback on floor8GBMac

`MLXTTSEngine.loadModel(id:)` catches load failures on floor8GBMac. If the failed model was an 8-bit variant AND the error matches OOM heuristics (NSError localizedDescription contains "memory" / "allocate" / "allocation", or NSPOSIXErrorDomain ENOMEM), the engine retries with the active 1.7B Speed sibling derived via the registry. If the fallback ALSO fails, the original error propagates (no cascade).

### Settings → Performance → "Prefer lower-memory models"

Global UserDefaults override at key `QwenVoice.PreferSpeedEverywhere` (legacy key name retained). When set, `TTSContract.activeModel(...)` short-circuits the per-mode preference and returns the active `speed` variant. Default false (preserves existing per-mode behavior). UI in `SettingsView.swift` with `accessibilityIdentifier("settings_preferSpeedEverywhere")`.

### Prewarm signposts for bench traces

Two OSSignposter events in `NativeEngineRuntime` for forensics: `"Native Prewarm Cache Hit"` (fires when `loadCoordinator.isPrewarmed(...)` returns true) and `"Native Design Conditioning Reuse"` (fires on the `reused: true` branch of `ensureDesignConditioningWarmStateIfNeeded`). Inspect them via `log show --signpost` to confirm prewarm hits vs misses.

### Short-prompt Custom Voice prewarm depth

`NativeEngineRuntime.customPrewarmDepth(for:)` returns `"skip-decoder-bucket"` for `.custom` requests with `text.count <= 30`. The vendor's `Qwen3CustomVoicePrewarmDepth` enum (in `third_party_patches/mlx-audio-swift`) accepts that string and skips the decoder-bucket precompile during prewarm — the decoder compiles on first decode instead. Same output audio, only latency distribution changes. Only fires on tiers where `customPrewarmPolicy: .eager` (mid16GBMac + highMemoryMac); floor8GBMac skips the whole dedicated prewarm anyway.

### Headless-workload env vars

- `QWENVOICE_STREAMING_PREVIEW_DATA=off` (or `skip` / `false` / `0` / `no`) — skips per-chunk `previewAudio.pcm16LE` Data allocation. Default emits on macOS and Simulator, but physical iOS defaults to skip unless set to `on` / `emit` / `true` / `1` / `yes`.
- `QWENVOICE_STREAMING_OUTPUT_POLICY=file` — adds per-chunk file artifacts alongside the PCM preview. Default `pcm_preview` (PCM preview only, no per-chunk files). For physical iOS live debug chunk playback without inline PCM, set `QWENVOICE_STREAMING_OUTPUT_POLICY=file`, `QWENVOICE_STREAMING_PREVIEW_DATA=off`, and `QVOICE_IOS_EXTENSION_ENABLE_EVENT_SINK=1`.

## Known traps

### macOS engine event stream must stay `.unbounded`

`MLXTTSEngine.events` (Sources/QwenVoiceCore/MLXTTSEngine.swift around line 452) is the chunk-delivery path for streaming preview audio. The file-level contract above the declaration is explicit: it "must not drop `.chunk` events carrying preview audio." A May 2026 attempt to cap it via `.bufferingNewest(64)` on both platforms (commit `d93612c`) caused user-reported latency + audio-quality regressions across all three macOS modes — the producer (now off MainActor after the same commit's `chunkSink` change) outran the consumer (synchronous MainActor + XPC encode in `EngineServiceHost.eventForwardingTask`) and silently dropped chunks. Fix: keep iOS bounded (`.bufferingNewest(64)`) for engine-extension memory safety, but use `.unbounded` on macOS. Do not "harden" macOS event buffering without first preserving the chunk-delivery contract; if backpressure becomes a real concern, route it through a counter + diagnostics signal in `native-events.jsonl`, not by dropping chunks at the producer.

### Internal chunked generation and preview playback

`shouldStream: true` at the user-facing single-generation call sites (3 macOS coordinators + active iOS generation builders); the iOS readiness/prefetch builders stream too. This is Vocello's internal chunked preview/final-file pipeline, not a claim that the app exposes Qwen's public Python true end-to-end streaming API. Physical iOS defaults to final-file playback and omits inline PCM chunk payloads unless the Debug event sink plus chunk-file output are explicitly enabled. `BatchGenerationRunner` stays `shouldStream: false` by design — macOS batch is quality-first regardless. On macOS preview-enabled runs, the user hears the first audio chunk within ~3-6 seconds of pressing generate on cold cells, vs ~8-15 seconds for the materialize-then-play flow that preceded it.

**Perceived-speed gain.** Enabling streaming preview roughly halved time-to-first-sound on cold cells in the Phase 3 measurements (e.g. custom/cold-medium ≈9.9 s → 5.5 s, design/cold-medium ≈7.8 s → 3.1 s, clone/cold-medium ≈14 s → 5.8 s); warm-custom was the one cell that regressed. Those figures came from a since-removed bench harness — treat them as directional history, not a live baseline.

**Decoder drift bug + fix (do not reintroduce).** An early streaming-enable attempt produced audible audio RMS/peak drift across cells. The early "model-side sampling/RNG divergence" hypothesis was falsified; the real cause was that both paths invoke the same `streamingStep` decoder but with very different chunk sizes (300 tokens for `streamingDecode` vs ~12 for streaming), and `DecoderBlockUpsample.step()`'s output-side overlap-and-add accumulator produced LSB drift at every chunk boundary that amplified through `SnakeBeta` and downstream blocks. **The fix landed in `4fab110`** (input-side `inputContext` buffer + `callAsFunction([context, x])` + discard leading samples — each emitted sample is now a slice of one conv operation, matching batch-mode float parenthesisation regardless of chunk size). `CausalConv1d.step()` was audited and left unchanged; its `streamBuffer` already implements the equivalent pattern for stride=1.

**Autoplay signpost (`f6aa8e3`).** `prepareStreamingPreview` is defined but never called from production — the streaming-autoplay flow relies on the auto-init path in `AudioPlayerViewModel.startLiveSession`, invoked from `handleGenerationChunk` when the first streaming chunk arrives with a new session ID. That path set `liveAutoplayEnabled` but forgot `pendingAutoplaySignpost`, so `consumeAutoplaySignpostIfNeeded()` was a no-op and the "Autoplay Start" OSSignposter event never fired despite actual playback starting. `f6aa8e3` sets `pendingAutoplaySignpost = autoPlay` in `startLiveSession` so the signpost mirrors the live engine's actual play() call.

**Ruled out** by the investigation (do not re-litigate): `PCM16StreamLimiter` math (sequential, state-pure, no lookahead — `NativeStreamingSynthesisSession.swift:506`); LM token sampling (deterministic given seed); the transformer KV-cache (offset correctly tracked, normalization is over feature axis).

**Phase 4 follow-up investigation (post-`6c2ea52`):**

1. **Warm-after-cold streaming engagement race — fully fixed in `6c2ea52` + `be4dbcf`.** Two distinct races were stacked:
   - **Race A (engine retention, fixed in `6c2ea52`)**: `teardownLivePlayback(clearSession: true)` left `liveEngine` and `livePlayerNode` references non-nil after `.reset()`ing the engine. The next session's `appendLiveChunk` skipped `configureLiveEngine` (guard `if liveEngine == nil || livePlayerNode == nil` was false), and `attemptLivePlay`'s `liveEngine.start()` threw — silently swallowed. Fix: nil out the references in the clearSession block. Closed custom/warm and design/warm.
   - **Race B (stale buffer completions, fixed in `be4dbcf`)**: AVAudioEngine's per-buffer completion callback hops to MainActor via `Task { @MainActor in ... }`. Cold's late-firing tasks landed AFTER warm's `startLiveSession` had reset `liveScheduledCount = 0` and `liveQueuedAudioSeconds = 0`, then decremented warm's freshly-incremented counters and removed warm's entries from `liveBufferDurations`. `shouldStartLivePlayback`'s Policy 2 then could never trigger for warm. The `guard playbackMode == .live` was too coarse (warm IS .live). Fix: capture `liveSessionID` at `scheduleLiveBuffer` time and reject completions in `handleLiveBufferPlaybackCompletion` whose sessionID doesn't match the current `liveSessionID`.

   Verified across 10 streaming samples spanning 3 modes (clone, custom, design cold/warm pairs) — **10/10 engaged streaming, 0 fallbacks**. Pre-fix repro rate on clone/warm back-to-back pairs was ~50 %.

   Production signposts at every streaming state transition (`Chunk Received`, `Chunk Decoded`, `Live Session Start`, `Live Engine Play`, `Session Completed Recorded`, `Switch To File Playback`, `Should Start Reject Autoplay`, `Should Start Reject Buffer`, `Stale Completion Dropped`) — together they reconstruct the streaming state machine's complete trace in `log show --signpost`; useful for any future regression triage.

2. **Cold-cell audio loudness shift — not a regression.** An observed +1–3 dB louder RMS on cold cells was sampling noise: re-measurement with the fix in place showed deviation in both directions (≈−1.6 to +2.8 dB) under identical generation parameters. The "AVAudioFile applies gain" hypothesis was wrong — the streaming WAV writer (`IncrementalPCM16WAVFileWriter`) and the non-streaming `AtomicPCM16WAVWriter` write the same Int16 samples; per-cell deviation is dominated by run-to-run LM sampling variance.

## SPM dependencies (pinned in `project.yml`)

- `MLXSwift` 0.30.6 (`https://github.com/ml-explore/mlx-swift.git`)
- `MLXAudio` — **vendored locally** at `third_party_patches/mlx-audio-swift/` (Vocello-specific patches; targeted edits are allowed when they are narrow, documented, validated, and kept isolated from upstream refresh work)
- `SwiftHuggingFace` 0.9.0 (model downloads)
- `GRDB` 7.10.0 (local SQLite — history, saved voices, model metadata)

## Conventions to preserve

- Changes inside `third_party_patches/mlx-audio-swift/` are permitted for backend correctness, memory, cancellation, streaming, model-loading, and performance work when the fix genuinely belongs below `QwenVoiceCore`. Keep those edits small, preserve upstream style, document the behavior or performance reason in the commit or relevant doc, and run the validation gates listed in `docs/reference/mlx-audio-swift-patching.md`. Treat an upstream rebase/snapshot as a separate vendor-refresh task; do not mix it with a targeted local fix.
- `accessibilityIdentifier` values in UI (e.g., `voicesRow_*`, `voicesEnroll_*`) are stable surface area — keep them when refactoring views.
- Animations route through `appAnimation` / `AppLaunchConfiguration.performAnimated` so Reduced Motion is honored; Liquid Glass surfaces must fall back to solid fills when Reduce Transparency is on. Both are non-negotiable per `PRODUCT.md`.
- Do not propose reintroducing a Python backend, a standalone CLI, or bundled model weights.
- Keep macOS release artifacts named `Vocello.app` and `Vocello-macos26.dmg`.
- Use local plan mode when a plan is needed; do not introduce cloud-only planning instructions or environment-variable workarounds on this project.
- **Maintainer privacy:** see the "Maintainer privacy" section above — do not commit legal names, personal emails, home paths, device nicknames, UDIDs, or hardcoded Apple team IDs in user-facing docs or script defaults.

## Where to find more

- `docs/README.md` — documentation index
- `docs/reference/current-state.md` — current repo facts
- `docs/reference/release-readiness.md` — release signoff gates + iOS shipping plan
- `docs/reference/ios-shipping.md` — iPhone MLX, memory, entitlement hub (start here for on-device iOS)
- `docs/reference/ios-memory-admission-policy.md` — admission block / critical cancel (off by default May 2026)
- `docs/reference/ios-mlx-jetsam-feasibility.md` — Jetsam vs entitlement verdict and constraints
- `docs/reference/privacy-storage.md` — local storage and deletion
- `docs/qwen_tone.md` — prompt/tone guidance for voice generation
- `design_references/Vocello Design System/` — the Vocello design system: brand register (SKILL.md), color + type scale (`colors_and_type.css`), preview HTML pages per token family. Read before touching iOS chrome or shipping new mode tints.
- `design_references/Vocello iOS/` — iOS design prototype: React + CSS source (`app.css`, `tokens.css`, `chrome.jsx`, `studio.jsx`, `player.jsx`, `sheets.jsx`, `screens.jsx`, `data.js`) plus 64 reference screenshots. Canonical source for the May 2026 iOS redesign tracks.
- `docs/assets/voice-samples/` — three Quality-variant WAVs (Voice Design / Custom Voice / Voice Cloning) generated for the marketing site's Listen section. Regenerate via the Vocello Debug app and copy into this folder using the existing filenames.
- `CONTRIBUTING.md` — contributor workflow
