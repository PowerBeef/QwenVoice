# AGENTS.md — Vocello (QwenVoice)

> Onboarding for AI agents in Cursor. **Code wins over docs.** When scope, platform, or gate expectations are unclear, **ask before editing**.
>
> **Invariants:** [`.cursor/rules/`](.cursor/rules/) · **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · **Role playbooks:** [`.agents/`](.agents/)

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
| **iOS = physical device only** | Never Simulator or sim MCP tools. Gate: `scripts/ios_device.sh gate`. → [`.cursor/rules/testing.mdc`](.cursor/rules/testing.mdc), [`.cursor/rules/ios.mdc`](.cursor/rules/ios.mdc) |
| **`project.yml`, not pbxproj** | After edit: `./scripts/regenerate_project.sh` + `./scripts/check_project_inputs.sh`. iOS resources: `sources:` + `buildPhase: resources` (not `resources:`). |
| **Release-only config** | Debug via `DebugMode.isEnabled` (`QWENVOICE_DEBUG=1`); `#if DEBUG` for test/sim scaffolding only. |
| **MLX pins in lockstep** | `mlx-swift` + `mlx-swift-lm` together; no Core ML. → [`.agents/backend-mlx.md`](.agents/backend-mlx.md) |
| **Engine invariants** | Prewarm slots, event streams, cancellation, memory policy → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| **Privacy** | No PII in tracked user-facing files. |
| **Agent UI ≠ gates** | Exploratory mirroir/peekaboo only → [`.cursor/rules/agent-ui-driving.mdc`](.cursor/rules/agent-ui-driving.mdc) |

Full invariant list: [`.cursor/rules/project-structure.mdc`](.cursor/rules/project-structure.mdc).

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
scripts/macos_test.sh core-test       # VocelloCoreTests (language semantics; also gate step 3)
scripts/macos_test.sh gate
```

**Verify:** exit 0; no new `.ips` during the run (gate-fatal).

### Language-path verification (Phases 1–2)

```sh
scripts/macos_test.sh core-test                              # Phase 1 — macOS unit tests (no models)
python3 scripts/test_check_language_hints.py                 # offline hint-gate fixtures
scripts/macos_test.sh lang-bench --subset quick              # Phase 2 — macOS CLI (needs models)
scripts/ios_device.sh lang-bench --subset quick --label "…"  # Phase 2 — on-device (needs Speed)
```

**Verify:** core-test + offline fixtures exit 0; lang-bench prints `PASS` and
`check_language_hints.py` matches `notes.languageHint` to
`config/language-bench-matrix.json`. Runbook:
[`docs/reference/language-bench.md`](docs/reference/language-bench.md). Phase 3 (in-app Speech
round-trip) not yet implemented.

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
| `Tests/Vocello*UITests/` | XCUITest smoke/bench |
| `Tests/VocelloCoreTests/` | macOS unit tests (language semantics) |
| `website/` | Marketing → [`website/AGENTS.md`](website/AGENTS.md) |

Module graph and lifecycles: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Commands (common)

```sh
./scripts/build.sh run
./scripts/build.sh cli --help
scripts/macos_test.sh core-test
scripts/macos_test.sh lang-bench --subset quick
scripts/macos_test.sh test
scripts/ios_device.sh test
scripts/ios_device.sh lang-bench --subset quick
scripts/macos_test.sh review [--baseline]
scripts/ios_device.sh review [--baseline]
```

Full lanes: [`docs/reference/macos-testing.md`](docs/reference/macos-testing.md), [`docs/reference/ios-device-testing.md`](docs/reference/ios-device-testing.md).

## Tool routing (Cursor)

**Scripts first** for build/test — gates are never agent-driven screen control.

MCP inventory: [`.cursor/rules/mcp-routing.mdc`](.cursor/rules/mcp-routing.mdc).

| Work | Start here |
| --- | --- |
| MLX / engine | `.agents/backend-mlx.md`, `docs/reference/mlx-guide.md` |
| iOS | `.agents/ios-engineer.md`, `docs/reference/ios-app-guide.md` |
| macOS / XPC | `.agents/macos-engineer.md`, `docs/reference/macos-app-guide.md` |
| Scripts / CI | `.agents/release-qa-engineer.md` |
| Crashes / profiles | Axiom MCP via mcp-routing |
| Library docs | Context7 MCP |

Dispatch large work via Cursor `Task`; pass the role file path.

## Active / deep reading

| Doc | When |
| --- | --- |
| [`docs/rescue-plan-progress.md`](docs/rescue-plan-progress.md) | **Active rescue/QA** — read first |
| [`docs/reference/ios-agent-ui-tour.md`](docs/reference/ios-agent-ui-tour.md) | mirroir driving (Appendix B) |
| [`docs/reference/ui-smoke-runbooks.md`](docs/reference/ui-smoke-runbooks.md) | exploratory smokes |
| [`docs/reference/ui-test-surface.md`](docs/reference/ui-test-surface.md) | accessibilityIdentifier catalog |
| [`docs/reference/language-bench.md`](docs/reference/language-bench.md) | language hint bench (Phases 1–2) |
| [`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md) | bench protocol |
| [`docs/reference/ios-device-probe.md`](docs/reference/ios-device-probe.md) | layered device-state / mirror probe |
| [`docs/reference/`](docs/reference/) | subsystem guides |

## Release & security (summary)

- **macOS:** GitHub release → notarized DMG ([`.github/workflows/release.yml`](.github/workflows/release.yml)).
- **iOS:** optional TestFlight archive in CI; version in `project.yml`.
- **Website:** Vercel from `website/`.
- **Security:** macOS sandbox off (MLX); iOS App Group + increased memory limit; local-first data.

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md).
