# macOS testing — Computer Use frontend + typed runtime probes

> Active rollout status and reinstall/resume sequence:
> [`docs/development-progress.md`](../development-progress.md).

macOS testing has two deliberately separate proof layers:

1. `$vocello-macos-ui-qa` is the sole frontend driver. Codex Computer Use operates the
   exact `build/Vocello.app`, observes fresh accessibility state before and after each action,
   and records semantic visual/accessibility findings.
2. Deterministic scripts and typed telemetry prove XPC, backend, persistence, and output
   behavior. A visual observation alone never proves generation completion.

iOS is not part of this migration. Its physical-device XCUITest gates remain authoritative.

## Prerequisites

- Xcode 26 and the Metal Toolchain component.
- `./scripts/build.sh build` has produced `build/Vocello.app`.
- Speed models are available for real-generation suites:
  `scripts/macos_test.sh models ensure`.
- Codex Computer Use has macOS Accessibility and Screen Recording permission.
- System Settings/TCC enrollment and first-time microphone permission are attended setup.

## Public lanes

| Lane | Command | Proof |
| --- | --- | --- |
| Deterministic tests | `scripts/macos_test.sh test` | Core/output/telemetry tests, injectable XPC transport tests, owned Qwen3 runtime tests, harness contracts; no UI driving |
| Core only | `scripts/macos_test.sh core-test` | `VocelloCoreTests`, including schema-v6 and atomic-WAV contracts |
| UI impact | `scripts/macos_agent_ui.sh impact` | Independent `requiredSuites` and `requiredRuntimeChecks` sets |
| Telemetry overhead | `scripts/macos_test.sh telemetry-overhead` | Seeded PCM parity plus off/lightweight/verbose median RTF and TTFC limits |
| UI report | `scripts/macos_test.sh ui-report --suite quick\|full\|benchmark` | Validates a fresh Computer Use report, typed probes, fingerprints, findings, and cleanup |
| Semantic review | `scripts/macos_test.sh review [--report <run>]` | Compatibility alias requiring a valid full report |
| UI benchmark | `scripts/macos_test.sh bench-ui [--report <run>]` | Valid benchmark report plus merged XPC/backend take matrix |
| XPC support | `scripts/macos_test.sh xpc status\|kill\|wait` | Process observation/mutation used inside the full Computer Use suite |
| Gate | `scripts/macos_test.sh gate` | Inputs, build, deterministic tests, crashes, then impact-selected attestation |

The removed `journey`, `uitest-doctor`, `VocelloMacUITests`, runner-signing, and hidden
`QWENVOICE_UI_TEST_HOOKS` workflows must not be revived.

## Computer Use suites

Invoke the repository skill directly in Codex:

```text
$vocello-macos-ui-qa quick
$vocello-macos-ui-qa full
$vocello-macos-ui-qa benchmark
$vocello-macos-ui-qa destructive
```

| Suite | Budget | Coverage |
| --- | --- | --- |
| Quick | at most 10 minutes | Exact launch, navigation, Custom generation/playback/history replay, semantic layout/copy/state/accessibility review |
| Full | 30–40 minutes with warm models | Quick plus Design, Clone, batch, controls, History/Saved Voices, reversible Settings, reference import, XPC kill/recovery and post-recovery generation |
| Benchmark | matrix-owned | Computer Use drives Custom/Design/Clone × length × cold/warm; shell timestamps, telemetry and aggregation remain deterministic |
| Destructive | explicit only | History/voice deletion and model cancel/repair/delete/download; requires `--allow-destructive` plus action-time Computer Use confirmation |

The scenario source of truth is
[`config/macos-ui-scenarios.json`](../../config/macos-ui-scenarios.json). The skill must:

- target the exact absolute `build/Vocello.app` path;
- obtain a fresh accessibility tree before and after every logical action;
- resolve fresh element indices and prefer stable `accessibilityIdentifier` values;
- record screenshot/coordinate fallbacks as automation warnings;
- continue independent scenarios after nonblocking findings;
- always perform idempotent cleanup.

## Session and evidence contract

[`scripts/macos_agent_ui.sh`](../../scripts/macos_agent_ui.sh) owns repeatable lifecycle and
verification:

```text
doctor
start --suite quick|full|benchmark|destructive [--allow-destructive]
now
benchmark-manifest
benchmark-take --index <n> --phase begin|complete|fail
checkpoint
issue
verify-generation
verify-history
verify-probes
xpc-status | xpc-kill | xpc-wait
finish
cleanup
validate-report
attest
attest-runtime
impact
```

`start` terminates stale app/service processes, resets only isolated debug history/output,
snapshots debug preferences and saved voices, preserves models, enables verbose telemetry,
launches one exact-path app process, and records source/build/toolchain/executable fingerprints.
Finish and cleanup restore the snapshot. Destructive runs instead receive a disposable app-support
root below the run directory and refuse shared production/debug model or voice roots. Evidence stays ignored under
`build/macos/agent-ui/<run-id>/`; the compact tracked attestation is
[`qa/macos-ui-attestation.json`](../../qa/macos-ui-attestation.json).

For `benchmark`, the manifest command returns the canonical 29 take definitions. Each ordered
`begin` stamps the run ID and current cell into telemetry (and exact-path relaunches the two cold cells),
while `complete` refuses to advance until the matching database row and readable WAV have been
recorded by `verify-generation`.

A report fails when it is blocked, contains a blocker/major issue, lacks a typed probe layer,
has stale source/build/toolchain/executable fingerprints, uses an insufficient suite, or fails cleanup.
Schema-v2 attestation has independent quick/full/benchmark entries: quick accepts quick or full;
full requires full; benchmark requires benchmark. Entries are preserved only while all shared
fingerprints match. Schema-v1 evidence remains diagnostic-only.

## Typed middle/backend proof

Schema-v6 `GenerationTelemetryRecord` rows retain v1–v5 decoding and legacy dictionaries for
tool compatibility, while validators consume:

- `FrontendGenerationMetrics`
- `EngineTransportMetrics`
- `BackendGenerationMetrics`
- `GenerationOutputMetrics`

The engine-service row records an opaque session identity, accepted/forwarded chunk evidence,
first/last sequence, gaps, duplicates, reordering, cancellation/terminal state, and duration.
The backend row records warm state, lifecycle stages, typed timing/counters, terminal reason,
final-chunk barrier, output publication, readability, memory and audio QC.

`verify-probes` joins rows by `generationID` and rejects missing or duplicate terminal rows,
non-monotonic stages, terminal disagreement, gaps/duplicates/reordering, transport completion
before backend terminal evidence, and a completed stream without its final barrier. Separate
generation/history assertions require the matching database row and a readable, non-empty WAV.
No telemetry row stores raw user script, transcript, voice description, or file path.

## Deterministic risk spine

[`config/backend-risk-spine.json`](../../config/backend-risk-spine.json) links the corrected
report IDs to current symbols and executable coverage. The first owned targets are:

- `VocelloCoreTests`: telemetry schema/legacy decoding and atomic readable WAV publication.
- `VocelloEngineIntegrationTests`: request/reply correlation, timeout cleanup, cancellation
  ordering, expected retirement, interruption and reconnection using injectable transport.
- vendored `Qwen3RuntimeTests`: FIFO/cancellation/throw stress, real learned-component loading,
  atomic tensor artifact integrity, bounded streaming, and seeded Metal decoder partition/reset parity.
- Python harness contracts: scenario/impact/report behavior and malformed cross-layer fixtures.

The source report directory is research evidence and remains unchanged; automation consumes the
compact manifest rather than parsing prose.

## Gate and CI behavior

```sh
scripts/macos_test.sh gate
```

The gate runs project-input checks, builds, deterministic tests and crash checks, then calls the
impact classifier. It unions every matched suite and runtime check. Headless CI builds the exact
app path and validates schema/source/build/toolchain identity, but it does not claim to execute
Computer Use or compare its ad-hoc-signed binary hash with the locally signed executable. Local
validation still requires the exact executable SHA used for Computer Use.

## XPC and crash diagnostics

The XPC service is lazy, retireable and crash-isolated. The full Computer Use suite kills it,
waits for absence/relaunch, and requires a successful generation after recovery. Use:

```sh
scripts/macos_test.sh xpc status
scripts/macos_test.sh xpc kill
scripts/macos_test.sh xpc wait --present --timeout 60
scripts/macos_test.sh crashes
scripts/macos_test.sh logs
scripts/macos_test.sh profile custom:speed
```

Crash reports remain gate-fatal when new `.ips` files appear.

## Related documents

- [`macos-app-guide.md`](macos-app-guide.md) — app surfaces and stable identifiers.
- [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md) — current macOS Computer Use route and iOS exploratory material.
- [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) — telemetry fields and benchmark analysis.
- [`macos-release-qa.md`](macos-release-qa.md) — release sequence.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — runtime hosts and XPC lifecycle.
