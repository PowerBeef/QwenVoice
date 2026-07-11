# AGENTS.md — Vocello (QwenVoice)

> Durable onboarding for Codex. **Code wins over docs.** When scope, platform, or gate expectations are unclear, **ask before editing**.
>
> **Active progress:** [`docs/development-progress.md`](docs/development-progress.md) · **Project map:** [`docs/project-map.html`](docs/project-map.html) · **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · **Role playbooks:** [`.agents/`](.agents/)

## What this is

**Vocello** (`QwenVoice` repo): local-first TTS on Apple Silicon — **Qwen3-TTS + MLX**, Swift 6, macOS/iOS 26+. No bundled weights; models download from Hugging Face. Also ships the `vocello` CLI, `scripts/`, benchmarks, and `website/`.

macOS **2.1.0** released; iOS is on-device-capable on `main`, not publicly distributed yet.

## Source of truth

`Sources/` → `project.yml` → `scripts/` → `.github/workflows/release.yml` → `AGENTS.md` → other prose.

Model/speaker schema: [`Sources/Resources/qwenvoice_contract.json`](Sources/Resources/qwenvoice_contract.json). **If code invalidates a doc, update the doc in the same change.**

## Before you edit

1. **Resume active work** — read [`docs/development-progress.md`](docs/development-progress.md) when it exists, then confirm its checkpoint against the current checkout.
2. **Pick a role** — read [`.agents/<role>.md`](.agents/) (backend, iOS, macOS, release-qa, website).
3. **Inspect capabilities** — for relevant tasks, inspect the installed OpenAI plugin and skill inventory before choosing optional tooling. Read every selected skill before use.
4. **Minimal diff** — no drive-by refactors; preserve module boundaries and stable `accessibilityIdentifier` values.
5. **Ask** when the target platform or test scope is ambiguous. Commit/push policy is not
   ambiguous: deterministic verification is sufficient to preserve and share development work.

### After a Codex reinstall

1. Restore a clean `main` from `origin/main`; never discard a dirty tree without reviewing it.
2. Confirm Xcode, the paired physical iPhone, signing identities, and the repository scripts before
   explicit frontend acceptance. Ordinary deterministic development does not require a phone.
3. Inspect the installed OpenAI plugin and skill inventory for optional build/debug assistance.
   Repository scripts and XCUITest remain authoritative; `~/.codex` remains user-scoped state.
4. Run the deterministic development checks below. Run XCUITest only when frontend acceptance is
   explicitly requested or when preparing the corresponding platform release.

## Hard rules

| Rule | Detail / verify |
| --- | --- |
| **iOS runtime/UI = physical device + XCUITest** | Never use Simulator. XCUITest drives the paired physical iPhone; scripts provide deterministic device/telemetry proof. The generic physical-device SDK compile needs no phone. `scripts/ios_device.sh gate` remains a physical-device runtime diagnostic, not a UI-result gate. |
| **`project.yml`, not pbxproj** | After edit: `./scripts/regenerate_project.sh` + `./scripts/check_project_inputs.sh`. iOS resources: `sources:` + `buildPhase: resources` (not `resources:`). |
| **Release-only config** | The project has no Debug configuration or generic `DEBUG` symbol. Runtime diagnostics use `DebugMode.isEnabled` (`QWENVOICE_DEBUG=1`); compile-time test isolation belongs in test targets or a narrowly named compilation condition, never hidden app behavior. |
| **MLX pins in lockstep** | `mlx-swift` + `mlx-swift-lm` together; no Core ML. → [`.agents/backend-mlx.md`](.agents/backend-mlx.md) |
| **Engine invariants** | Prewarm slots, event streams, cancellation, memory policy → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| **Privacy** | No PII in tracked user-facing files. |
| **All app UI = XCUITest** | XCUITest is the sole autonomous app UI driver for the native macOS test host and the paired physical iPhone. No Simulator, alternate desktop-control MCP, or coordinate bridge is active. |
| **No hidden test UI** | XCUITest observes genuine visible controls. Test-only code belongs in test targets; shippable app targets must not contain preview routes, invisible state markers, seeded UI state, or onboarding bypasses. |
| **One shared XcodeBuildMCP** | OpenAI Build iOS Apps supplies the shared server; Build macOS Apps consumes it. Call `session_show_defaults`, select `macos` or `ios-device`, and set a physical-device ID only at runtime. Never configure a second server. Repository scripts remain the final gate. |
| **Codex/ChatGPT Desktop only** | This repository has no compatibility layer for another agent IDE. Codex/ChatGPT Desktop, installed OpenAI plugins, repository skills, and repository scripts are the supported development environment. |
| **Publishing is deterministic-only** | Commits, pushes, pull requests, ordinary merges, ordinary CI, and release packaging require deterministic verification only. Missing models, a physical device, or XCUITest evidence must never block preserving, sharing, signing, notarizing, or uploading work. UI lanes run only for explicit frontend QA. |

Every active invariant must live here, in a role playbook, or in an authoritative reference document.

## Workflows

### Implement a change

```sh
./scripts/regenerate_project.sh      # if project.yml changed
./scripts/check_project_inputs.sh
./scripts/build.sh build             # macOS compile check
./scripts/build_foundation_targets.sh ios   # iOS-only compile safety
```

**Verify:** exit 0 (build is the typecheck; no formatter/linter).

### Development verification — macOS

```sh
scripts/macos_test.sh test            # Core + XPC transport + owned Qwen3 runtime tests
./scripts/build.sh build
```

**Verify:** deterministic commands exit 0. This is enough to commit, push, open a pull request,
and merge ordinary development work. Do not invoke XCUITest solely to publish a development
checkpoint.

### Development verification — iOS

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios   # physical-device SDK compile safety; no device/UI
```

**Verify:** deterministic commands exit 0. A paired phone, installed models, and XCUITest results
are not development-publishing prerequisites.

### Explicit frontend acceptance

Run these strict lanes only when the user explicitly requests frontend/device acceptance:

```sh
# macOS: native app UI on the current Mac.
scripts/ui_test.sh macos smoke
scripts/ui_test.sh macos benchmark
scripts/macos_test.sh gate

# iOS: paired physical iPhone only; never Simulator.
scripts/ios_device.sh preflight
scripts/ui_test.sh ios smoke
scripts/ui_test.sh ios benchmark
scripts/ios_device.sh gate
```

The platform `gate` commands remain deterministic/device diagnostics. They do not consume or
validate XCUITest results.

Generation UI tests first assert the visible Settings state: Custom, Design, and Clone Speed must
show installed/ready, Generate must be enabled, and the required clone voice must be visible before
any take. `models ensure` is explicit repair/bootstrap, never a substitute for that observation.

### Language-path verification (Phases 1–3)

```sh
scripts/macos_test.sh core-test                              # Phase 1 — macOS unit tests (no models)
python3 scripts/test_check_language_hints.py                 # offline hint-gate fixtures
python3 scripts/test_check_language_output.py                # offline output-gate fixtures
scripts/macos_test.sh lang-bench --subset quick              # Phase 2 — macOS CLI hint gate (needs models)
scripts/ios_device.sh lang-bench --subset quick --label "…"  # Phases 2–3 — on-device hint + output (needs Speed)
scripts/ios_device.sh lang-bench --subset full --label "…"   # full 19-cell matrix (hint + output gates)
```

**Verify:** core-test + offline fixtures exit 0. iOS lang-bench must print **`hint_gate=PASS`**
and **`output_gate=PASS`** (quick: 6/6 output cells; full: 18/18 — negative control is hint-only).
`check_language_hints.py` matches `notes.languageHint` to `config/language-bench-matrix.json`.
Phase 3 adds locale-locked ASR via `check_language_output.py`. **DE/ES/ZH/JA output cells**
require on-device Speech assets — setup: [`language-bench.md`](docs/reference/language-bench.md)
§ Phase 3 prerequisites (dictation languages + Wi‑Fi download on the phone).

### Release QA

Release packaging is gated by deterministic build, test, identity, signing, crash, and artifact
checks. XCUITest smoke, UI benchmarks, and model-dependent engine benchmarks remain explicit quality
QA, but their absence never blocks signing, notarization, artifact upload, a macOS package, or an iOS
archive/TestFlight build.

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <voice> --label "release-QA" --ledger
```

**Verify:** packaging requires the applicable deterministic platform release check. When an engine
promotion benchmark is explicitly requested, that separate quality decision also requires its
audio-QC, telemetry comparison, and listening verdict →
[`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md).

## Key paths

| Path | Purpose |
| --- | --- |
| `Sources/QwenVoiceCore/` | Engine, download, generation semantics |
| `Sources/QwenVoiceBackendCore/` | MLX/audio primitives |
| `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineService/`, `Sources/QwenVoiceEngineSupport/` | macOS XPC stack |
| `Sources/iOS/`, `Sources/iOSSupport/` | iOS app |
| `Sources/iOS/IOSDeviceDiagnosticsRunner.swift` | Headless, non-UI physical-device diagnostics used by `ios_device.sh` |
| `Sources/SharedSupport/` | Shared player, persistence, transcriber |
| `scripts/*.sh` | Build, test, release |
| `config/language-bench-*.json` | Language hint bench corpus + matrix |
| `Tests/UIAutomationSupport/` | Shared XCUITest waits, fixtures, queries, and evidence helpers |
| `Tests/VocelloMacUITests/` | macOS smoke and benchmark UI tests |
| `Tests/VocelloiOSUITests/` | Physical-iPhone smoke and benchmark UI tests |
| `scripts/ui_test.sh` | Unified explicit XCUITest entry point |
| `Tests/VocelloCoreTests/`, `Tests/VocelloEngineIntegrationTests/` | Deterministic Core/output/telemetry and XPC transport tests |
| `docs/project-map.html` | Canonical interactive feature, component, dependency, and workflow map |
| `docs/development-progress.md` | Current implementation checkpoint and remaining release work |
| `website/` | Marketing → [`website/AGENTS.md`](website/AGENTS.md) |

Interactive feature/module map: [`docs/project-map.html`](docs/project-map.html). Deeper lifecycle
narrative: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Commands (common)

```sh
./scripts/build.sh run
./scripts/build.sh cli --help
scripts/macos_test.sh core-test
scripts/macos_test.sh lang-bench --subset quick
scripts/macos_test.sh test
scripts/macos_test.sh telemetry-overhead
scripts/ui_test.sh macos smoke
scripts/ui_test.sh macos benchmark
scripts/ui_test.sh ios smoke
scripts/ui_test.sh ios benchmark
scripts/ios_device.sh lang-bench --subset quick
```

Full lanes: [`docs/reference/macos-testing.md`](docs/reference/macos-testing.md), [`docs/reference/ios-device-testing.md`](docs/reference/ios-device-testing.md).

## Codex tool routing

**Scripts first** for build/test and deterministic proof. XCUITest is the sole autonomous app UI
driver on macOS and the paired physical iPhone. Before using an optional skill/plugin, read its
instructions and keep actions inside the selected role's ownership boundary. User-scoped Codex
configuration and plugin state are never repository sources of truth.

| Work | Start here / use |
| --- | --- |
| MLX / engine | `.agents/backend-mlx.md`, `docs/reference/mlx-guide.md`, shell scripts |
| iOS | `.agents/ios-engineer.md`, `docs/reference/ios-app-guide.md`, `scripts/ios_device.sh` on a physical device only |
| macOS / XPC | `.agents/macos-engineer.md`, `docs/reference/macos-app-guide.md`, macOS Codex skills where relevant |
| Scripts / CI / GitHub | `.agents/release-qa-engineer.md`, shell scripts, installed GitHub integration |
| Website | `.agents/website-engineer.md`, Browser for localhost verification |
| macOS frontend QA | `scripts/ui_test.sh macos smoke|benchmark`; native macOS target only |
| iOS frontend QA | `scripts/ui_test.sh ios smoke|benchmark`; paired physical iPhone only |
| External systems and current APIs | Relevant installed Codex skill/plugin or connector; use authoritative documentation |

## Active / deep reading

| Doc | When |
| --- | --- |
| [`docs/development-progress.md`](docs/development-progress.md) | **Active checkpoint** — current topology, release work, and resume route |
| [`docs/reference/ios-ui-reference.md`](docs/reference/ios-ui-reference.md) | iOS screen map, stable identifiers, states, and physical-device expectations |
| [`docs/reference/language-bench.md`](docs/reference/language-bench.md) | language hint + output bench (Phases 1–3) |
| [`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md) | bench protocol |
| [`docs/reference/`](docs/reference/) | subsystem guides |

## Release & security (summary)

- **macOS:** GitHub release → notarized DMG ([`.github/workflows/release.yml`](.github/workflows/release.yml)).
- **iOS:** optional TestFlight archive in CI; version in `project.yml`.
- **Website:** Vercel from `website/`.
- **Security:** macOS sandbox off (MLX); iOS App Group + increased memory limit; local-first data.

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md).
