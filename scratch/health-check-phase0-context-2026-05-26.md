# Phase 0 — Reference Doc Cross-Check (2026-05-26)

## Method

Compared maintained reference docs against `Sources/`, `project.yml`, and `scripts/` per CONTRIBUTING source-of-truth order.

## Verified alignments

| Doc claim | Code reality | Status |
|-----------|--------------|--------|
| Vocello 2.0.0 / build 16 | `project.yml` MARKETING_VERSION 2.0.0, CURRENT_PROJECT_VERSION 16 | OK |
| macOS 26.0+ / iOS 26.0+ deployment | `project.yml` deployment targets | OK |
| Contract in `qwenvoice_contract.json` | Present under Sources/Resources/ | OK |
| macOS XPC + iOS ExtensionKit isolation | `EngineServiceHost`, `VocelloEngineExtensionHost`, `ExtensionBackedTTSEngine` | OK |
| Shared core in QwenVoiceCore | MLXTTSEngine, NativeEngineRuntime, streaming session | OK |
| Vendored mlx-audio-swift at fcbd04d + patches | UPSTREAM.md + patching.md | OK |
| CI = release.yml only (DMG + iOS compile) | `.github/workflows/release.yml` sole workflow | OK |
| Retired XCTest / broad QA gates | No test targets in project.yml; engineering-status confirms | OK (policy) |
| Prewarm slot gate documented | `acquirePrewarmSlot`/`releasePrewarmSlot` in NativeEngineRuntime | OK |
| Generation ownership in MLXTTSEngine | `beginUserModelOperation` for generation/batch/load/unload | OK |
| Decoder inputContext patch | Qwen3TTSSpeechTokenizer.swift lines 546–614 | OK |
| Live session stale-completion guard | AudioPlayerViewModel `Stale Completion Dropped` signpost | OK |
| iOS legacy zone ~28 IOS*.swift root files | Glob confirms legacy bodies under Sources/iOS/*.swift | OK |
| MLX pin 0.30.6 | project.yml packages.MLXSwift | OK (foundation audit notes 0.31.3 available) |

## Doc drift / gaps (not code defects)

| Item | Notes |
|------|-------|
| AGENTS.md references `ModeSegmented.swift` | File does not exist; mode UI is `IOSGenerationModeSelector` in IOSGenerateFlowViews.swift |
| M1 8GB floor proof | release-readiness: M1 findings not re-verified on M2 dev host |
| iPhone 15 Pro minimum proof | Pending; validation on iPhone 17 Pro only |
| iOS public release | Deferred per macOS-first track — docs consistent |
| MLX 0.30.6 vs upstream 0.31.3 | foundation-projects-audit accurate; intentional defer |
| AppModel comments say "Phase 3 upcoming" | Coordinators landed; comments stale |

## Release proof matrix (from release-readiness.md)

- macOS: public ship target YES; local Release smoke recorded
- iOS: TestFlight tooling maintained; public ship NO; entitlements/increased-memory pending
- Behavioral validation: local uitest.sh + manual only

## Patching policy alignment

`mlx-audio-swift-patching.md` rules match repo practice:
- Edits allowed when fix belongs below QwenVoiceCore
- QwenVoiceBackendCore is integration boundary
- No Python backend in vendor tree
- UPSTREAM.md for provenance only
