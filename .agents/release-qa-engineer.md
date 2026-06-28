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
- Root `AGENTS.md` §8 (commands), §12 (testing), §13 (deployment)

## Required pre-read

Before changing scripts or CI, read:
1. The script you are modifying (header comments encode intent and env vars).
2. `.github/workflows/release.yml` if touching CI.
3. `docs/reference/macos-release-qa.md` for the full macOS release QA checklist.
4. `docs/reference/telemetry-and-benchmarking.md` for benchmark/telemetry expectations.

## Tools and skills

- **`axiom`** skill (`Skill` tool) — for `xcsym` crash symbolication, `xcprof` profiling,
  test-runner/debugger, and build-fixer agents.
- **Axiom agents via `Agent` tool:**
  - `axiom:crash-analyzer` for `.ips` / MetricKit / `.crash`
  - `axiom:performance-profiler` for Instruments/xctrace analysis
  - `axiom:test-runner` / `axiom:test-debugger` for `.xcresult` investigation
  - `axiom:build-fixer` for environment/build failures (after inspecting script output)
- **`mcp__github__*`** — for release artifacts, PRs, workflow dispatch.
- **`mcp__xcodebuildmcp__*`** — for macOS `.xcresult` inspection only.
- **Bash** — scripts are the source of truth; run them directly.

## Build / test commands

```sh
# Pre-merge gates
scripts/macos_test.sh gate
scripts/ios_device.sh gate

# Release packaging
./scripts/build.sh release

# Benchmark driver
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> \
  --label "release-QA" --ledger

# Aggregate telemetry
scripts/summarize_generation_telemetry.py

# Crash/profile
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
- **No tests in CI.** `.github/workflows/release.yml` is scoped to packaging only; local gates
  (`macos_test.sh gate`, `ios_device.sh gate`) stay local-only.
- **Committed benchmark summaries ≤256 KB.** Raw `*.jsonl` is gitignored.
- **Deep checkout on CI.** `fetch-depth: 0` is required so `git rev-parse HEAD` in
  `scripts/release.sh` resolves for `release-metadata.txt`.
- **Burn-in-safe iOS testing.** All on-device lanes go through `scripts/ios_device.sh`.

## Common mistakes

- Adding a `Debug` configuration or `#if DEBUG` scaffolding in scripts.
- Running iOS UI tests in the simulator.
- Committing raw `.jsonl` telemetry to `benchmarks/`.
- Forgetting to preserve dSYMs (`scripts/build.sh` copies them to `build/macos/dsyms`).
- Changing signing/notarization env vars without updating the workflow secret docs.
