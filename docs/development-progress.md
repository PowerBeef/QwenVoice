# Vocello development progress and Codex resume checkpoint

> **Active maintainer checkpoint — 2026-07-10.** Read this after
> [`AGENTS.md`](../AGENTS.md) and before resuming the current macOS QA work.
> This is a development checkpoint, **not** a release-readiness declaration.

## Checkpoint identity

| Field | Value |
| --- | --- |
| Branch | `main`, tracking `origin/main` |
| Starting base | `d79044387c655f634cd966fd0b1b74d96dbf7bbf` |
| Resume commit | The commit containing this file; after `git pull --ff-only`, use `git rev-parse HEAD` |
| Active objective | Complete the macOS Computer Use frontend and typed runtime-probe overhaul |
| Release status | **Not ready** — full and benchmark Computer Use attestations are still required |

The checkpoint commit includes the implementation, tests, harness, contracts, guidance, and this
tracker. A clean checkout of `origin/main` is the recovery mechanism; no uncommitted local patch is
required to continue.

## Current status

| Workstream | Status | Durable source / evidence |
| --- | --- | --- |
| macOS frontend driver | **Implemented** | `$vocello-macos-ui-qa`; no macOS XCUITest target or hidden UI-test surface |
| Scenario and impact contracts | **Implemented** | Schema v2 in `config/macos-ui-scenarios.json` and `config/macos-test-impact.json` |
| Independent attestations | **Implemented** | Schema v2 `quick`, `full`, and `benchmark` entries in `qa/macos-ui-attestation.json` |
| Typed XPC and backend probes | **Implemented and tested** | Core, XPC integration, probe validator, and Qwen3 runtime test targets |
| Corrected-report risk spine | **Implemented for the tracked first tranche** | `config/backend-risk-spine.json`; every implemented item resolves to executable tests |
| Telemetry overhead/parity | **PASS** | Schema-v2 `telemetry-overhead` runtime check; seeded PCM parity and thresholds passed on 2026-07-10 |
| macOS deterministic lane | **PASS** | `scripts/macos_test.sh test` on 2026-07-10 |
| Exact macOS app build | **PASS** | `./scripts/build.sh build`; current signed bundle is `build/Vocello.app` |
| Harness regressions | **PASS** | 19 `scripts/test_macos_agent_ui.py` tests on 2026-07-10 |
| Project-input/document drift | **PASS** | `./scripts/check_project_inputs.sh` on 2026-07-10 |
| iOS shared compile safety | **PASS** | `./scripts/build_foundation_targets.sh ios` with the physical-device SDK on 2026-07-10 |
| Computer Use full suite | **Pending** | `qa/macos-ui-attestation.json` has no `full` entry |
| Computer Use benchmark | **Pending** | No `benchmark` entry; all ordered 29 takes remain to be driven and validated |
| Destructive suite | **Implemented, not executed** | Static authorization and disposable-root safeguards only; attended opt-in required |
| Broader corrected-report matrix | **Deferred** | Explicit `deferredMatrix` in `config/backend-risk-spine.json` |

`scripts/macos_agent_ui.sh impact` currently requires the independent `full` and `benchmark`
suites plus `telemetry-overhead`. The runtime check is satisfied; neither frontend suite may
substitute for the other.

## Resume after a Codex cleanup or reinstall

### 1. Restore repository truth

Do not copy an old working tree over the checkpoint and do not run destructive Git cleanup.

```sh
git switch main
git fetch origin
git pull --ff-only
git status --short --branch
git rev-parse HEAD
```

Expected: `main` tracks `origin/main`, the worktree is clean, and the reported commit is at least
the commit containing this document. Preserve installed models and saved voices; they are not
reconstructed from Git.

### 2. Restore Codex capabilities

1. Install and enable the bundled **Computer Use** plugin in Codex.
2. Do **not** manually add a second standalone `computer-use` MCP server. A Computer Use server
   listed as provided by the plugin is expected; a duplicate user-created MCP entry is not part of
   this repository's setup.
3. Start a **new Codex task** after installing or enabling the plugin so its skills and tools are
   loaded into the task.
4. In macOS System Settings → Privacy & Security, allow Codex Computer Use under Accessibility and
   Screen & System Audio Recording when prompted. Permission enrollment and system dialogs are
   attended setup, not autonomous test steps.
5. Treat `~/.codex/config.toml`, plugin enablement, and macOS privacy grants as user-scoped state.
   They are not repository guidance and must not be copied into tracked files.

Repository guidance follows OpenAI's durable customization split: conventions in
[`AGENTS.md`](https://developers.openai.com/codex/concepts/customization#agents-guidance), the
repeatable frontend workflow in the repository
[`skill`](https://developers.openai.com/codex/concepts/customization#skills), and live desktop
control through the installed plugin/MCP capability rather than prose-only claims.

### 3. Re-enter the project

Read, in order:

1. [`AGENTS.md`](../AGENTS.md)
2. this tracker
3. the applicable [role playbook](../.agents/)
4. [`project-map.html`](project-map.html)
5. [`reference/macos-testing.md`](reference/macos-testing.md) for this active workstream

Then verify the local harness without changing application state:

```sh
scripts/macos_agent_ui.sh impact
scripts/macos_agent_ui.sh doctor --suite full --json
scripts/macos_agent_ui.sh doctor --suite benchmark --json
```

Both doctor calls must report `"ready": true`. If Computer Use is missing from the new task, fix
plugin enablement and start another new task; do not weaken the repository gate or introduce a
replacement UI driver.

## Remaining acceptance work — run in order

The tracked implementation is deterministic-test clean. Finish the semantic evidence only after
the final tracked edit so fingerprints describe the exact checkout being accepted.

1. Confirm the machine is idle and required debug-context Speed models are installed:

   ```sh
   pgrep -x xcodebuild || true
   scripts/macos_test.sh models ensure
   ```

2. Confirm or rebuild the exact app Computer Use will drive. The checkpoint was built
   successfully, but a fresh checkout or cleaned `build/` directory needs this step again:

   ```sh
   ./scripts/build.sh build
   test -d build/Vocello.app
   ```

3. Invoke `$vocello-macos-ui-qa full`. It must complete within 40 minutes, restore preferences and
   saved voices, exercise XPC kill/recovery, and finish with matching History, WAV, and typed-probe
   evidence.

4. Validate and attest the full report:

   ```sh
   scripts/macos_test.sh ui-report --suite full
   scripts/macos_test.sh review
   ```

5. Invoke `$vocello-macos-ui-qa benchmark`. Computer Use must drive the ordered 29-take
   Custom/Design/Clone × length × cold/warm matrix; the shell harness owns timestamps,
   deterministic verification, and aggregation.

6. Validate and attest the benchmark report:

   ```sh
   scripts/macos_test.sh ui-report --suite benchmark
   scripts/macos_test.sh bench-ui
   ```

7. Run final acceptance:

   ```sh
   ./scripts/check_project_inputs.sh
   scripts/macos_test.sh test
   scripts/macos_test.sh crashes
   scripts/macos_test.sh gate
   ```

Acceptance requires fresh matching source/build/toolchain fingerprints, successful cleanup, no
blocker or major findings, a passing probe verdict, and no new crash report. A local app SHA is
checked against the exact executable Computer Use drove; CI rebuilds independently and does not
compare its differently signed binary byte-for-byte with the local app.

## Safety and scope boundaries

- **macOS frontend:** Computer Use only. Static accessibility-catalog validation remains allowed;
  macOS XCUITest, Peekaboo, coordinate shell drivers, and `uitest_measure.sh` are retired.
- **iOS frontend:** physical-device XCUITest remains authoritative. Never use Simulator or
  simulator-oriented Codex workflows for this repository.
- **Destructive macOS suite:** never starts implicitly. It needs `--allow-destructive`, a disposable
  app-support root, and action-time confirmation for deletion, repair, download, file upload, or
  permission-sensitive UI actions.
- **Evidence:** raw screenshots, telemetry, WAVs, databases, and reports stay ignored under
  `build/macos/agent-ui/`. Only the compact non-sensitive attestation is tracked.
- **Privacy:** probes record lengths, enums, bounded metrics, and stable digests—not scripts,
  transcripts, imported paths, or voice descriptions.
- **Research evidence:** preserve `QwenVoice_MLXAudio_Corrected_Report_Series_2026-07-10/`
  unchanged. Automation consumes the compact risk spine instead of parsing prose reports.

## Completion definition

This checkpoint becomes release-candidate ready only when the real `full` and `benchmark`
attestation entries are present and fresh, the runtime check remains valid, `review`, `bench-ui`,
and `gate` pass, and the resulting GitHub Actions run is green. Until then, retain the **Not ready**
status at the top of this document.
