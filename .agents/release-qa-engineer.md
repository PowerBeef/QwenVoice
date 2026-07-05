# Release / QA Engineer

> Agent role for build scripts, CI workflow, packaging, signing, notarization,
> benchmarks, UI smoke, crash/profile analysis, and release QA gates.

## Boundaries

**Owns:**
- `scripts/*.sh` and `scripts/lib/`
- `.github/workflows/release.yml`
- `benchmarks/` committed summaries
- `docs/releases/`
- `docs/ios-review-baselines/`, `docs/macos-review-baselines/`
- Release verification scripts (`scripts/verify_*.sh`, `scripts/create_dmg.sh`, etc.)

**Does NOT own:**
- App source code (`.agents/backend-mlx.md`, `.agents/ios-engineer.md`, `.agents/macos-engineer.md`)
- Marketing site (`website/AGENTS.md`)

**Consults:**
- `docs/reference/{macos-release-qa,telemetry-and-benchmarking,cli,macos-testing,ios-device-testing}.md`
- `docs/ARCHITECTURE.md` §12 (telemetry)
- Root `AGENTS.md` (Workflows, Commands) + [`.cursor/rules/testing.mdc`](../.cursor/rules/testing.mdc)

## Required pre-read

Before changing scripts or CI, read:
1. The script you are modifying (header comments encode intent and env vars).
2. `.github/workflows/release.yml` if touching CI.
3. `docs/reference/macos-release-qa.md` for the full macOS release QA checklist.
4. `docs/reference/benchmarking-procedure.md` for the operator runbook (when to bench, platform lanes, preflight).
5. `docs/reference/telemetry-and-benchmarking.md` for benchmark/telemetry schema and knobs.

## Tools and skills (Cursor)

- **Shell tool** — scripts are the source of truth; run them directly.
- **Axiom MCP (`user-axiom`)** for post-run analysis (read tool schema first):

  | Need | MCP path |
  | --- | --- |
  | Crash triage | `axiom_xcsym_crash` or `axiom_get_agent` → `crash-analyzer` |
  | Profile analysis | `axiom_xcprof_analyze` or `axiom_get_agent` → `performance-profiler` |
  | Test failure | `axiom_get_agent` → `test-runner` / `test-debugger` |
  | UI baseline diff | `axiom_get_agent` → `screenshot-validator` |
  | Build/env failure | `axiom_get_agent` → `build-fixer` (after reading script output) |
  | Static audits | `axiom_get_agent` → named auditors (`concurrency-auditor`, `memory-auditor`, …) |

  **iOS artifact paths** (see [`ios-device-testing.md` § Agent + MCP workflow](../docs/reference/ios-device-testing.md#agent--mcp-workflow)):
  `build/ios/Logs/Test/*.xcresult` (UI tests), `build/ios/bench-ui-<runID>/` (UI bench),
  `build/ios-diagnostics/` (telemetry + crashes + `models-status.json`),
  `build/ios/gate-<runID>/verdict.txt`, `build/ios/profile-*.trace` / `bench-ui-*/vocello.trace`.

- **GitHub** (release artifacts, PRs, workflow dispatch) → `gh` via the Shell tool.
- **XcodeBuildMCP** (`user-xcodebuildmcp`) — macOS and on-device iOS workflows enabled; see
  [`.xcodebuildmcp/config.yaml`](../.xcodebuildmcp/config.yaml). Prefer `scripts/*.sh` for
  gates; use profiles `macos` / `ios-device`.

## Build / test commands

```sh
# Pre-merge gates (macOS gate step 0 = model ensure via scripts/lib/test_models.sh)
scripts/macos_test.sh models ensure   # one-time per machine before first real-engine macOS run
scripts/macos_test.sh gate
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # optional: bounded custom/speed/medium bench + audioQC

# Supplementary XPC UI matrix (when Native/Services/Views/XPC changed — not CI by default)
scripts/macos_test.sh uitest-doctor
scripts/macos_test.sh bench-ui --label xpc-bench-full
python3 scripts/check_macos_xpc_bench.py ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --run-id xpc-bench-YYYYMMDD-HHMMSS

# Human journey + review (optional pre-release)
scripts/macos_test.sh journey
scripts/macos_test.sh review --subset resting
scripts/ios_device.sh gate

# Model fixture helpers
scripts/macos_test.sh models check|ensure|install
scripts/ios_device.sh models check --strict   # headless inventory on paired iPhone

# Release packaging
./scripts/build.sh release

# Benchmark driver (--ledger = single summarizer pass → benchmarks/HISTORY.md)
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> \
  --label "release-QA" --ledger

# Optional regression compare (see macos-release-qa.md step 3)
python3 scripts/summarize_generation_telemetry.py \
  ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --compare-baseline benchmarks/baseline-2026-06-16-45720dd-streaming-default.md \
  --label "release-QA"

# Crash/profile (profile fails on bench error unless --allow-bench-fail / QVOICE_MAC_PROFILE_ALLOW_BENCH_FAIL=1)
scripts/macos_test.sh crashes
scripts/macos_test.sh profile [spec]
scripts/ios_device.sh crashes
scripts/ios_device.sh profile [spec]
```

## Invariants (do not regress)

- **Single shippable config: `Release` only.** There is no `Debug` config or `DEBUG` symbol.
  `build.sh` compiles `-Onone`; `release.sh` compiles optimized.
- **XcodeGen project generation.** `project.yml` is the source of truth; never edit
  `QwenVoice.xcodeproj/project.pbxproj` directly.
- **Developer ID signing + notarization.** macOS release uses Developer ID Application cert,
  hardened runtime, and `notarytool` stapling. CI uses App Store Connect API key auth.
- **CI runs compile-only for iOS.** GitHub CI builds `VocelloiOS` + `VocelloiOSUITests` with
  `generic/platform=iOS` (no XCUITest). Real iOS UI gates (`ios_device.sh gate`) stay
  local/attended on a paired iPhone.
- **Committed benchmark summaries ≤256 KB.** Raw `*.jsonl` is gitignored.
- **Deep checkout on CI.** `fetch-depth: 0` is required so `git rev-parse HEAD` in
  `scripts/release.sh` resolves for `release-metadata.txt`.
- **Burn-in-safe iOS testing.** All on-device lanes go through `scripts/ios_device.sh`.
- **macOS real-engine tests need model fixtures.** Run `scripts/macos_test.sh models ensure`
  once per machine; see [`scripts/lib/test_models.sh`](../scripts/lib/test_models.sh) and
  [`docs/reference/testing-runbook.md`](../docs/reference/testing-runbook.md) §1b.

## Common mistakes

- Adding a `Debug` configuration or `#if DEBUG` scaffolding in scripts.
- Running iOS UI tests in the Simulator or expecting CI to run XCUITest. Use
  `scripts/ios_device.sh gate` on a paired iPhone before merge.
- Committing raw `.jsonl` telemetry to `benchmarks/`.
- Forgetting to preserve dSYMs (`scripts/build.sh` copies them to `build/macos/dsyms`).
- Changing signing/notarization env vars without updating the workflow secret docs.
