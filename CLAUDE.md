# CLAUDE.md — Vocello (QwenVoice)

> Durable onboarding for Claude Code and other MCP-capable agents. **Code wins over docs.**
> Scripts and machine-readable contracts are the gates; optional MCP tools and skills never are.
> When scope, platform, or gate expectations are unclear, **ask before editing**.
>
> **Active progress:** [`docs/development-progress.md`](docs/development-progress.md) · **Project map:** [`docs/project-map.html`](docs/project-map.html) · **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · **Domain rules:** [`.claude/rules/`](.claude/rules/)

## What this is

**Vocello** (`QwenVoice` repo): local-first TTS on Apple Silicon — **Qwen3-TTS + MLX**, Swift 6, macOS/iOS 26+. No bundled weights; models download from Hugging Face. Also ships the `vocello` CLI, `scripts/`, benchmarks, and `website/`.

macOS **2.1.0** released; iOS is on-device-capable on `main`, not publicly distributed yet.
Minimum support is Apple Silicon Mac with 8 GB or iPhone 15 Pro or newer. Canonical benchmark
evidence uses Mac mini M2 8 GB and iPhone 17 Pro; support and evidence hardware are not synonyms.

## Source of truth

`Sources/` → `project.yml` → machine-readable `config/` contracts → `scripts/` →
`.github/workflows/` → `CLAUDE.md` → other prose.

Model/speaker schema: [`Sources/Resources/qwenvoice_contract.json`](Sources/Resources/qwenvoice_contract.json).
The cross-platform artifact catalog
[`Sources/Resources/qwenvoice_production_model_catalog.json`](Sources/Resources/qwenvoice_production_model_catalog.json)
is complete for all six Speed/Quality artifacts and is the fail-closed macOS/CLI/iOS download
source. Static completeness does not substitute for explicit post-change live delivery evidence.
**If code or a machine-readable contract invalidates a doc, update the doc in the same change.**

## Before you edit

1. **Resume active work** — read [`docs/development-progress.md`](docs/development-progress.md), then confirm its checkpoint against the current checkout.
2. **Read the domain rule** — before working in a domain, read the matching file under [`.claude/rules/`](.claude/rules/) (see the routing table below).
3. **Inspect capabilities** — MCP servers and skills are user-scoped; verify a tool is currently callable before relying on it, and read every selected skill before use. Optional assists never substitute for the deterministic script gates.
4. **Minimal diff** — no drive-by refactors; preserve module boundaries and stable `accessibilityIdentifier` values.
5. **Close the loop in the same change** — a substantive arc lands together with its evidence and
   its doc updates, including narrative docs (`docs/development-progress.md`, the matching ADR or
   status report). The derived-catalogs hard rule enforces this for generated docs; this norm
   extends it to prose.
6. **Currency pass after dense workstreams** — close a multi-commit workstream with a
   `docs: currency pass` commit that re-syncs narrative prose with the tree before moving on.
7. **Ask** when the target platform or test scope is ambiguous. Commit/push policy is not
   ambiguous: deterministic verification is sufficient to preserve and share development work.

## Hard rules

| Rule | Detail / verify |
| --- | --- |
| **iOS runtime = physical device only** | Never use Simulator. `scripts/ios_device.sh` provides deterministic device/telemetry proof; interactive iOS UI QA runs through iPhone Mirroring on the paired phone. The generic physical-device SDK compile builds the app and standalone iOS policy-test bundle without a phone, but the selected Xcode must expose matching iOS Platform Support/runtime availability for `generic/platform=iOS`. `scripts/lib/ios_platform_preflight.py check` validates that host component before build setup and never downloads, boots, or executes a Simulator. Xcode 26 cannot execute the app-host-free tool-hosted bundle on a physical-device destination, so it remains compile-only; `gate` remains a physical-device runtime diagnostic, not a UI-result gate. |
| **`project.yml`, not pbxproj** | After edit: `./scripts/regenerate_project.sh` + `./scripts/check_project_inputs.sh`. iOS resources: `sources:` + `buildPhase: resources` (not `resources:`). |
| **Generated output follows one contract** | `config/build-output-policy.json` owns native repository output under `build/`, child-artifact retention, and heavy-lane free-space floors. Persistent Xcode caches are `build/cache/xcode/{macos,ios-device}`; packages are shared; scratch, evidence, symbols, and distribution outputs stay in their classified trees. `website/dist` is Vite-owned website output. Run `python3 scripts/build_output_policy.py status|validate`; never add an ad hoc DerivedData or `.build`, bypass a storage preflight, or delete a whole cache when a selective cleanup suffices. |
| **Release-only config** | The project has no Debug configuration or generic `DEBUG` symbol. Every production-affecting environment override is registered in `config/runtime-debug-knobs.json` and remains inert unless `QWENVOICE_DEBUG=1` enables the master runtime gate. Compile-time test isolation belongs in test targets or a narrowly named compilation condition, never hidden app behavior. |
| **Concurrency exceptions are registered** | Every owned `@unchecked Sendable` or other unsafe concurrency declaration must be justified and covered by `config/concurrency-safety.json`. Prefer actors, `Mutex`, immutable adapters, or value types; run `python3 scripts/runtime_security_contract.py` after changing either registry or a covered declaration. |
| **MLX pins in lockstep** | `mlx-swift` + `mlx-swift-lm` together; no Core ML. → [`.claude/rules/backend-mlx.md`](.claude/rules/backend-mlx.md) |
| **Engine invariants** | Prewarm slots, event streams, cancellation, request-local sampling/memory policy, and actor/classified-session/product-finalization authority → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`config/runtime-refactor-contract.json`](config/runtime-refactor-contract.json). The contract JSON is the status authority: Phase 4 `overallPromotion` passed 2026-07-20 with canonical matrices; Phases 7–13 and Phase 14 retirement remain open. Do not restate convergence status in prose — cite the contract. |
| **Privacy** | No PII, device identity, usernames, absolute paths, prompts, transcripts, secrets, or private metadata in any tracked content. |
| **Interactive UI QA = agent-driven computer use** | The scripted XCUITest stack was retired 2026-07-22 by maintainer decision. Interactive UI acceptance is an AI agent driving the genuine app with computer use — vision, screenshots, and clicks on real visible controls — macOS directly, iOS through iPhone Mirroring on the paired physical iPhone (never Simulator). Runbook: [`docs/reference/interactive-ui-qa.md`](docs/reference/interactive-ui-qa.md). Do not reintroduce a scripted UI-driver stack, coordinate tables, or Simulator lanes; the wiring gates fail closed on the retired artifacts. |
| **No hidden test UI** | QA observes genuine visible controls. Test-only code belongs in test targets; shippable app targets must not contain preview routes, invisible state markers, seeded UI state, or onboarding bypasses. Registered debug knobs (e.g. the virtual microphone) substitute inputs, never UI. |
| **One shared XcodeBuildMCP** | When an XcodeBuildMCP server is installed and callable, use one shared route. Call `session_show_defaults`, select `macos` or `ios-device`, and set a physical-device ID only at runtime. Never enable Simulator or UI-automation workflows for Vocello, and never configure a second server. Repository scripts remain the final gate. |
| **Scripts-first** | Repository guidance, scripts, and machine-readable contracts remain the gates. User-scoped MCP servers and skills assist only; they are never CI or packaging prerequisites. Gates enforce wiring (no retired harness artifacts, no Simulator UI workflows, no retired UI command aliases), not a prose keyword denylist. |
| **Publishing is deterministic-only** | Commits, pushes, pull requests, ordinary merges, ordinary CI, and release packaging require deterministic verification only. Missing models, a physical device, or interactive UI QA evidence must never block preserving, sharing, signing, notarizing, or uploading work. Interactive QA runs only on explicit request or as the recorded release-candidate checklist. |
| **Release evidence is process- and command-bound** | Release candidates use schema-v2 `release-evidence.json` plus a hashed `release-verification.json` bundle. A clean full-tree source identity and every platform-required step must be produced by the managed release subprocess, with the contract-defined command identity, in the same invocation and within the six-hour freshness window. Self-authored, substituted-command, partial, stale, or cross-source PASS files cannot authorize publication. iOS candidates first run the deterministic macOS gate plus device-SDK compile in that ledger, then require the non-device archive/IPA identity, entitlement, provisioning, signature, and UUID-continuity verifier. |
| **Benchmark history is PASS-only** | Successful memory-qualified benchmark runners publish one privacy-safe record under `benchmarks/runs/` and regenerate `benchmarks/HISTORY.md`. Raw telemetry, WAVs, screenshots, traces, and `.xcresult` bundles remain untracked. Publication never stages, commits, pushes, or turns model/device availability into a development gate. The telemetry-overhead observer-effect experiment is local-only because instrumenting its `off` lane would invalidate the comparison. |
| **Raw profile traces are ephemeral** | Exact-PID profiles hash, validate, summarize, and publish before discarding the multi-gigabyte raw trace. Use `--keep-trace` only for an explicit Instruments debugging session. Failed traces stay diagnostic until superseded or explicitly acknowledged with `--compact-profile-failure RUN_ID`; status reports that space separately from automatically eligible cleanup. `--routine` prunes scratch without touching the current app, canonical caches, dSYMs, models, source, or tracked history. |
| **Memory evidence must be qualified** | New publishable generation benchmarks require telemetry schema v8 plus benchmark-evidence manifest v2: exact run-scoped sample sidecars, start/stop and lifecycle boundaries, zero capture failures, ≥95% sampler coverage, and no critical pressure, memory warning/exit, `hardTrim`, or `fullUnload`. macOS app/engine totals are uptime-aligned; never add independent process peaks. |
| **Audio QA is autonomous** | Engine/language promotion uses deterministic PCM QC, fixed-seed evidence, locale-locked ASR consensus, and the applicable prosody/delivery gates. Human listening is optional annotation only. A QC warning may be tracked as `passedWithWarnings`, but it is not promotion-quality until a deterministic rule or code fix clears it. |
| **Derived catalogs stay fresh** | Fail-closed generated inventories must be rebuilt in the same change as their sources: owned-runtime `CURRENT_INVENTORY` / `FACADE_API_BASELINE`, `docs/project-health.md`, `docs/INDEX.md`, and the production model catalog when their inputs change. Prefer `python3 scripts/refresh_derived_artifacts.py refresh` then `validate` before commit/push. This does **not** auto-write narrative progress prose — when `config/runtime-refactor-contract.json` (or another meaning-bearing contract) changes status, update `docs/development-progress.md` and the matching ADR/status-report in the same change. Details: [`.claude/rules/derived-artifacts.md`](.claude/rules/derived-artifacts.md). |

Every active invariant must live here, in a domain rule, in an authoritative reference document,
or in a machine-readable contract named by one of those surfaces.

## Domain rule routing

| Work | Read first / use |
| --- | --- |
| MLX / engine / model catalog | [`.claude/rules/backend-mlx.md`](.claude/rules/backend-mlx.md), `docs/reference/mlx-guide.md`; optional Axiom Swift/concurrency/performance skills |
| iOS app (`Sources/iOS*`) | [`.claude/rules/ios.md`](.claude/rules/ios.md), `docs/reference/ios-app-guide.md`, `scripts/ios_device.sh` on a physical device only; optional XcodeBuildMCP `ios-device` |
| macOS app / XPC stack | [`.claude/rules/macos.md`](.claude/rules/macos.md), `docs/reference/macos-app-guide.md`; optional XcodeBuildMCP `macos` |
| Scripts / CI / release / benchmarks | [`.claude/rules/release-qa.md`](.claude/rules/release-qa.md); GitHub MCP when callable, otherwise `gh` |
| Website (`website/`) | [`website/CLAUDE.md`](website/CLAUDE.md); browser MCP for localhost verification |
| Derived/generated inventories | [`.claude/rules/derived-artifacts.md`](.claude/rules/derived-artifacts.md) |
| Interactive UI QA (explicit request or release candidate) | [`docs/reference/interactive-ui-qa.md`](docs/reference/interactive-ui-qa.md); agent-driven computer use — macOS direct, iOS via iPhone Mirroring |
| External systems and current APIs | sosumi / context7 / docs MCP when callable; otherwise primary vendor docs |

## Workflows

### Implement a change

```sh
./scripts/regenerate_project.sh      # if project.yml changed
python3 scripts/refresh_derived_artifacts.py refresh   # if owned-runtime/docs/catalog inputs changed
QVOICE_GATES=quick ./scripts/check_project_inputs.sh   # fast loop (see below)
./scripts/build.sh build             # macOS compile check
./scripts/build_foundation_targets.sh ios   # iOS app + pure policy-test bundle compile safety
```

**Fast iteration:** `QVOICE_GATES=quick` skips only the ~75 s script self-test suite, and only
while nothing under `scripts/` or `config/` has pending changes — the surfaces those tests cover.
Every wiring, privacy, link, and contract scan still runs, so a quick pass is commit-sufficient
for changes outside `scripts/`/`config/`. Ordinary CI and release lanes never set it and always
run the full suite. Batch gate runs: verify once at the end of a change set, not after every edit.

**Verify:** exit 0 (build is the typecheck; no formatter/linter).
The iOS compile requires the selected Xcode's matching iOS component even though it needs no phone
and never selects a Simulator destination. Restore the component through Xcode Settings if the
read-only preflight reports `blocked-toolchain-component`.

### Development verification — macOS

```sh
scripts/macos_test.sh test            # Core + XPC transport + owned Qwen3 runtime tests
./scripts/build.sh build
```

**Verify:** deterministic commands exit 0. This is enough to commit, push, open a pull request,
and merge ordinary development work. Do not run interactive UI QA solely to publish a development
checkpoint.

### Development verification — iOS

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios   # app + policy-test bundle device-SDK compile; no device/UI
```

**Verify:** deterministic commands exit 0. A paired phone, installed models, and interactive QA
results are not development-publishing prerequisites.

### Explicit frontend acceptance

Interactive UI QA is agent-driven computer use per
[`docs/reference/interactive-ui-qa.md`](docs/reference/interactive-ui-qa.md): the macOS checklist
against `./scripts/build.sh run`, the iOS checklist through iPhone Mirroring on the paired phone.
Run it only on explicit request or as the recorded release-candidate checklist. The deterministic
device diagnostics stay script-owned:

```sh
scripts/macos_test.sh gate
scripts/ios_device.sh preflight
scripts/ios_device.sh gate
```

QA first observes the visible Settings state: Custom, Design, and Clone Speed must show
installed/ready, Generate must be enabled, and the required clone voice must be visible before any
take. `models ensure` is explicit repair/bootstrap, never a substitute for that observation.

### Language-path verification (Phases 1–3)

```sh
scripts/macos_test.sh core-test                              # Phase 1 — macOS unit tests (no models)
python3 -m unittest scripts.test_check_ios_speech_assets     # offline Speech-bootstrap evidence fixtures
python3 scripts/test_check_language_hints.py                 # offline hint-gate fixtures
python3 scripts/test_check_language_output.py                # offline output-gate fixtures
scripts/ios_device.sh speech-assets                          # explicit DE/ES/JA/ZH system-asset bootstrap
scripts/macos_test.sh lang-bench --subset quick              # Phase 2 — macOS CLI hint gate (needs models)
scripts/ios_device.sh lang-bench --subset quick --label "lang-quick"  # Phases 2–3 — on-device hint + output (needs Speed)
scripts/ios_device.sh lang-bench --subset full --label "lang-full"   # full 19-cell matrix (hint + output gates)
scripts/ios_device.sh lang-bench --diagnostic-cohort                  # fixed 15-take autonomous failure cohort; no history
```

**Verify:** core-test + offline fixtures exit 0. iOS lang-bench must print **`hint_gate=PASS`**
and **`output_gate=PASS`** (quick: 6/6 output cells; full: 18/18 — negative control is hint-only).
Setup and interpretation: [`docs/reference/language-bench.md`](docs/reference/language-bench.md).
No listening verdict is required: exact fixed-seed WAV evidence, three-pass on-device ASR consensus,
PCM QC, and the applicable prosody gates own the automated result.

### Release QA

Release packaging is gated by deterministic build, test, identity, signing, crash, and artifact
checks. The interactive UI QA checklist is a standing release-candidate step: run it per candidate
and record the run ID and per-item verdicts — or a deliberate skip with its reason — in the release
notes entry (`docs/releases/`). Model-dependent engine benchmarks remain explicit quality QA. The
absence of any UI or model evidence never blocks signing, notarization, artifact upload, a macOS
package, or an iOS archive/TestFlight build.

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <voice> --label "release-QA"
```

**Verify:** packaging requires the applicable deterministic platform release check. When an engine
promotion benchmark is explicitly requested, that separate quality decision also requires clean
audio-QC, telemetry comparison, fixed-seed evidence, and the applicable automated language/prosody
gates. Listening remains optional independent annotation →
[`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md).

## Key paths

| Path | Purpose |
| --- | --- |
| `Sources/QwenVoiceCore/` | Engine, download, generation semantics |
| `Sources/QwenVoiceBackendCore/` | Backend provenance, defaults, policy vocabulary, finish reason, and minimal synthesis abstraction |
| `Packages/VocelloQwen3Core/` | Owned Qwen3-TTS and Mimi core runtime; stable `VocelloQwen3Core` product facade, compatibility-preserved `MLXAudio*` implementation products, lineage, capabilities, and deterministic runtime tests |
| `Sources/Resources/qwenvoice_production_model_catalog.json`, `config/model-catalog-schema-v2.json`, `config/model-artifact-receipts.json` | Complete exact artifact and shared-component identities for all six Speed/Quality packages; fail-closed production delivery contract |
| `config/runtime-refactor-contract.json`, `docs/decisions/runtime-streaming-quality-convergence.md` | Current shipping versus foundation authority for the staged runtime convergence program |
| `config/runtime-debug-knobs.json`, `config/concurrency-safety.json` | Runtime-debug master-gate and owned concurrency-exception registries |
| `Sources/QwenVoiceNative/`, `Sources/QwenVoiceEngineService/`, `Sources/QwenVoiceEngineSupport/` | macOS XPC stack |
| `Sources/iOS/`, `Sources/iOSSupport/` | iOS app |
| `Sources/iOS/IOSDeviceDiagnosticsRunner.swift` | Headless, non-UI physical-device diagnostics used by `ios_device.sh` |
| `Sources/SharedSupport/` | Shared player, persistence, transcriber |
| `scripts/*.sh` | Build, test, release |
| `config/language-bench-*.json` | Language hint bench corpus + matrix |
| `Tests/VocelloiOSLogicTests/` | App-host-free iOS policy contracts; compile-only generic device-SDK coverage in CI |
| `docs/reference/interactive-ui-qa.md` | Agent-driven computer-use UI QA checklists (macOS + iPhone Mirroring) |
| `docs/reference/model-delivery.md` | Shared downloader, iOS restoration ledger, retry/cancel, diagnostics, and isolated live proof |
| `benchmarks/`, `scripts/benchmark_history.py` | PASS-only, privacy-safe benchmark registry and generated index |
| `Tests/VocelloCoreTests/`, `Tests/VocelloEngineIntegrationTests/` | Deterministic Core/output/telemetry and XPC transport tests |
| `docs/project-map.html` | Canonical interactive feature, component, dependency, and workflow map |
| `docs/development-progress.md` | Current implementation checkpoint and remaining release work |
| `website/` | Marketing → [`website/CLAUDE.md`](website/CLAUDE.md) |

## Commands (common)

```sh
./scripts/build.sh run
./scripts/build.sh cli --help
scripts/macos_test.sh core-test
scripts/macos_test.sh lang-bench --subset quick
scripts/macos_test.sh test
scripts/macos_test.sh telemetry-overhead
scripts/macos_test.sh profile --kind memory custom:speed:
scripts/macos_test.sh memory --label retained-check   # fixed retained-memory sequence
scripts/ios_device.sh lang-bench --subset quick
scripts/ios_device.sh speech-assets
scripts/ios_device.sh profile --kind memory
scripts/ios_device.sh memory --voice-id <saved-voice-id> --label retained-check
scripts/ios_device.sh clone-conditioning --label focused-clone-proof  # local two-mode semantic proof
scripts/ios_device.sh memory-field-report       # local-only delayed MetricKit aggregate
python3 scripts/build_output_policy.py status
python3 scripts/build_output_policy.py validate
python3 scripts/refresh_derived_artifacts.py status
python3 scripts/refresh_derived_artifacts.py refresh
python3 scripts/refresh_derived_artifacts.py validate
scripts/clean_build_caches.sh --routine --dry-run
scripts/clean_build_caches.sh --cache macos --dry-run
```

Full lanes: [`docs/reference/macos-testing.md`](docs/reference/macos-testing.md), [`docs/reference/ios-device-testing.md`](docs/reference/ios-device-testing.md).

## Active / deep reading

| Doc | When |
| --- | --- |
| [`docs/development-progress.md`](docs/development-progress.md) | **Active checkpoint** — current topology, release work, and resume route |
| [`docs/reference/ios-ui-reference.md`](docs/reference/ios-ui-reference.md) | iOS screen map, stable identifiers, states, and physical-device expectations |
| [`docs/reference/language-bench.md`](docs/reference/language-bench.md) | language hint + output bench (Phases 1–3) |
| [`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md) | bench protocol |
| [`docs/reference/`](docs/reference/) | subsystem guides |

## Release & security (summary)

- **macOS:** protected version tag → verified draft candidate → public notarized DMG
  ([`.github/workflows/release.yml`](.github/workflows/release.yml)).
- **iOS:** optional TestFlight archive in CI; version in `project.yml`.
- **Website:** Vercel from `website/`.
- **Security:** see [`SECURITY.md`](SECURITY.md); macOS sandbox off (MLX), iOS App Group + increased
  memory limit, immutable Action pins, dependency review, CodeQL, SBOMs, and build attestations.

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md).
