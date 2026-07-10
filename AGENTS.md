# AGENTS.md — Vocello (QwenVoice)

> Durable onboarding for Codex. **Code wins over docs.** When scope, platform, or gate expectations are unclear, **ask before editing**.
>
> **Project map:** [`docs/project-map.html`](docs/project-map.html) · **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · **Role playbooks:** [`.agents/`](.agents/)

## What this is

**Vocello** (`QwenVoice` repo): local-first TTS on Apple Silicon — **Qwen3-TTS + MLX**, Swift 6, macOS/iOS 26+. No bundled weights; models download from Hugging Face. Also ships the `vocello` CLI, `scripts/`, benchmarks, and `website/`.

macOS **2.1.0** released; iOS is on-device-capable on `main`, not publicly distributed yet.

## Source of truth

`Sources/` → `project.yml` → `scripts/` → `.github/workflows/release.yml` → `AGENTS.md` → other prose.

Model/speaker schema: [`Sources/Resources/qwenvoice_contract.json`](Sources/Resources/qwenvoice_contract.json). **If code invalidates a doc, update the doc in the same change.**

## Before you edit

1. **Pick a role** — read [`.agents/<role>.md`](.agents/) (backend, iOS, macOS, release-qa, website).
2. **Minimal diff** — no drive-by refactors; preserve module boundaries and stable `accessibilityIdentifier` values.
3. **Ask** when the target platform, test gate, or commit/push expectation is ambiguous.

## Hard rules

| Rule | Detail / verify |
| --- | --- |
| **iOS = physical device only** | Never use Simulator or simulator-oriented Codex skills/tools. Gate: `scripts/ios_device.sh gate`. → [`.agents/ios-engineer.md`](.agents/ios-engineer.md), [`docs/reference/ios-device-testing.md`](docs/reference/ios-device-testing.md) |
| **`project.yml`, not pbxproj** | After edit: `./scripts/regenerate_project.sh` + `./scripts/check_project_inputs.sh`. iOS resources: `sources:` + `buildPhase: resources` (not `resources:`). |
| **Release-only config** | Debug via `DebugMode.isEnabled` (`QWENVOICE_DEBUG=1`); `#if DEBUG` for test/sim scaffolding only. |
| **MLX pins in lockstep** | `mlx-swift` + `mlx-swift-lm` together; no Core ML. → [`.agents/backend-mlx.md`](.agents/backend-mlx.md) |
| **Engine invariants** | Prewarm slots, event streams, cancellation, memory policy → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| **Privacy** | No PII in tracked user-facing files. |
| **macOS UI = Computer Use** | The repository skill `$vocello-macos-ui-qa` is the sole macOS frontend driver. Its fresh typed attestation is gate-blocking when `scripts/macos_agent_ui.sh impact` selects quick/full/benchmark. XCUITest remains iOS-only. → [`docs/reference/macos-testing.md`](docs/reference/macos-testing.md) |

`.cursor/rules/` is retained as historical Cursor configuration, not as automatically active
Codex guidance. Every active invariant must live here, in a role playbook, or in an authoritative
reference document.

## Workflows

### Implement a change

```sh
./scripts/regenerate_project.sh      # if project.yml changed
./scripts/check_project_inputs.sh
./scripts/build.sh build             # macOS compile check
./scripts/build_foundation_targets.sh ios   # iOS-only compile safety
```

**Verify:** exit 0 (build is the typecheck; no formatter/linter).

### Pre-merge — macOS

```sh
scripts/macos_test.sh models ensure   # once per machine if needed
scripts/macos_test.sh test            # Core + XPC transport + owned Qwen3 runtime tests
scripts/macos_agent_ui.sh impact      # none, quick, full, or benchmark
# If UI evidence is required: invoke $vocello-macos-ui-qa <suite>
scripts/macos_test.sh gate
```

**Verify:** exit 0; no new `.ips` during the run (gate-fatal).

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

### Pre-merge — iOS

```sh
scripts/ios_device.sh preflight
scripts/ios_device.sh gate
```

**Verify:** exit 0 on paired iPhone; Speed model on device for generation (or `QVOICE_GATE_SKIP_GENERATION=1`).

### Release QA (optional)

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <voice> --label "release-QA" --ledger
```

**Verify:** listening pass + telemetry compare → [`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md).

## Key paths

| Path | Purpose |
| --- | --- |
| `Sources/QwenVoiceCore/` | Engine, download, generation semantics |
| `Sources/QwenVoiceBackendCore/` | MLX/audio primitives |
| `Sources/QwenVoiceNative/`, `EngineService/`, `EngineSupport/` | macOS XPC stack |
| `Sources/iOS/`, `iOSSupport/` | iOS app |
| `Sources/SharedSupport/` | Shared player, persistence, transcriber |
| `scripts/*.sh` | Build, test, release |
| `config/language-bench-*.json` | Language hint bench corpus + matrix |
| `.agents/skills/vocello-macos-ui-qa/` | Sole macOS frontend-driving workflow (Codex Computer Use) |
| `scripts/macos_agent_ui.sh`, `config/macos-*.json` | Session/evidence harness, scenario and impact contracts |
| `Tests/VocelloCoreTests/`, `Tests/VocelloEngineIntegrationTests/` | Deterministic Core/output/telemetry and XPC transport tests |
| `Tests/VocelloiOSUITests/` | Physical-device iOS XCUITest (unchanged) |
| `docs/project-map.html` | Canonical interactive feature, component, dependency, and workflow map |
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
scripts/macos_test.sh ui-report --suite quick|full|benchmark
scripts/ios_device.sh test
scripts/ios_device.sh lang-bench --subset quick
scripts/macos_test.sh review [--report <run>]
scripts/ios_device.sh review [--baseline]
```

Full lanes: [`docs/reference/macos-testing.md`](docs/reference/macos-testing.md), [`docs/reference/ios-device-testing.md`](docs/reference/ios-device-testing.md).

## Codex tool routing

**Scripts first** for build/test and deterministic proof. macOS frontend acceptance is the explicit
exception: the repository Computer Use skill drives the real UI while the shell harness supplies
typed, reproducible evidence. Before using a skill/plugin, read its instructions and keep actions
inside the selected role's ownership boundary.

| Work | Start here / use |
| --- | --- |
| MLX / engine | `.agents/backend-mlx.md`, `docs/reference/mlx-guide.md`, shell scripts |
| iOS | `.agents/ios-engineer.md`, `docs/reference/ios-app-guide.md`, `scripts/ios_device.sh` on a physical device only |
| macOS / XPC | `.agents/macos-engineer.md`, `docs/reference/macos-app-guide.md`, macOS Codex skills where relevant |
| Scripts / CI / GitHub | `.agents/release-qa-engineer.md`, shell scripts, installed GitHub integration |
| Website | `.agents/website-engineer.md`, Browser for localhost verification |
| macOS frontend QA | `$vocello-macos-ui-qa quick|full|benchmark|destructive` + `scripts/macos_agent_ui.sh`; exact `build/Vocello.app` only |
| iOS frontend QA | `scripts/ios_device.sh` + physical-device XCUITest; Computer Use migration is deferred |
| External systems and current APIs | Relevant installed Codex skill/plugin or connector; use authoritative documentation |

## Active / deep reading

| Doc | When |
| --- | --- |
| [`docs/rescue-plan-progress.md`](docs/rescue-plan-progress.md) | **Active rescue/QA** — read first |
| [`docs/reference/ios-agent-ui-tour.md`](docs/reference/ios-agent-ui-tour.md) | mirroir driving (Appendix B) |
| [`docs/reference/ui-smoke-runbooks.md`](docs/reference/ui-smoke-runbooks.md) | macOS Computer Use route + iOS exploratory smokes |
| [`docs/reference/ui-test-surface.md`](docs/reference/ui-test-surface.md) | accessibilityIdentifier catalog |
| [`docs/reference/language-bench.md`](docs/reference/language-bench.md) | language hint + output bench (Phases 1–3) |
| [`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md) | bench protocol |
| [`docs/reference/ios-device-probe.md`](docs/reference/ios-device-probe.md) | layered device-state / mirror probe |
| [`docs/reference/`](docs/reference/) | subsystem guides |

## Release & security (summary)

- **macOS:** GitHub release → notarized DMG ([`.github/workflows/release.yml`](.github/workflows/release.yml)).
- **iOS:** optional TestFlight archive in CI; version in `project.yml`.
- **Website:** Vercel from `website/`.
- **Security:** macOS sandbox off (MLX); iOS App Group + increased memory limit; local-first data.

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md).
