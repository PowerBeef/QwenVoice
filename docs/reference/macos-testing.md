# macOS testing — lanes + the XPC dimension

The macOS testing/debugging/benchmarking/UI-review lanes. macOS is the dev host (no
device/Mirroring/burn-in) and the engine runs **out-of-process in an XPC service**
(`com.qwenvoice.app.engine-service`) — a separate process that can crash independently
and be **retired under memory pressure** then lazily relaunched. Several lanes target the
app **and** the service.

> Build/run/release stay in [`build.sh`](../../scripts/build.sh); this doc covers the lane
> driver **`scripts/macos_test.sh`**. For the canonical testing strategy (two-tier iOS model,
> fake backend, CI) see [`testing-runbook.md`](testing-runbook.md). For the iOS device lanes
> see [`ios-device-testing.md`](ios-device-testing.md). For the macOS app map + driving see
> [`macos-app-guide.md`](macos-app-guide.md).

## Prerequisites

- **Xcode 26** (with the Metal Toolchain component — `xcodebuild -downloadComponent MetalToolchain` if missing).
- A signing identity (Apple Development for dev; Developer ID for release — see
  [`macos-permissions.md`](macos-permissions.md)).
- The app built: `scripts/build.sh build` → `build/Vocello.app` (also preserves dSYMs to
  `build/macos/dsyms/`).
- The XPC service is embedded at `Vocello.app/Contents/XPCServices/QwenVoiceEngineService.xpc`.
- **Speed models for real-engine lanes** (one-time ~6.9 GB for all three modes, ~2.3 GB each): `scripts/macos_test.sh models ensure`
  installs `pro_custom_speed`, `pro_design_speed`, and `pro_clone_speed` headlessly via
  `vocello models install` into the canonical store, symlinks `QwenVoice-Debug/models` for UI
  smoke (`QWENVOICE_DEBUG=1`), and bootstraps the bench clone voice (`A_warm_elderly_woman`).

## Lane → tool map

| Lane | Verb | Captures / proves | Deeper analysis |
|------|------|-------------------|-----------------|
| Preflight | `preflight [--strict-models]` | Xcode + app + XPC bundle + dSYMs + model status | — |
| Models | `models check\|ensure\|install` | three Speed models + clone voice fixture | — |
| Test | `test` | `VocelloMacSmokeUITests` only (**12** smoke tests, 3-mode generation) | `axiom:test-runner` on the `.xcresult` |
| Bench | `build.sh cli bench` | deterministic perf/quality matrix | `summarize_generation_telemetry.py` |
| Crash | `crashes [--test]` | `.ips` for app + XPC service | `axiom:crash-analyzer` / `xcsym` vs the dSYMs |
| Debug | `debug` | LLDB attach (app + service PID) + `logs` | `./scripts/macos_test.sh debug`; Axiom `build-fixer` |
| Profile | `profile [spec]` | xctrace/Instruments on the engine (CLI in-process) | `axiom:performance-profiler` / `xcprof` |
| Review | `review [--baseline]` | sidebar-screen screenshot tour | `screenshot-validator` subagent / manual diff vs `docs/macos-review-baselines/` |
| XPC | `xpc [--crash-isolation]` | retirement/relaunch + crash isolation | — |
| Gate | `gate` | models → inputs → build_foundation → test → crashes → verdict; optional bounded `vocello bench` when `QWENVOICE_GATE_BENCH=1` | — |

## Crashes

macOS writes `.ips` crash reports to `~/Library/Logs/DiagnosticReports/`. The app crashes as
`Vocello-<date>-<pid>.ips`; the XPC service as `QwenVoiceEngineService-<pid>.ips` (or
matching `*engine-service*`). `scripts/build.sh build` preserves the build's dSYMs (app +
service + any others) to `build/macos/dsyms/`.

```sh
scripts/macos_test.sh crashes            # collect recent .ips → xcsym symbolicate
scripts/macos_test.sh crashes --test     # SIGSEGV a launched app to verify the lane
```

`xcsym crash <file> --dsym-dir build/macos/dsyms` symbolicates. If `xcsym` isn't on PATH
(install `axiom-tools`), the verb prints the exact command to run, or dispatch
`axiom:crash-analyzer`.

## Debug + logs

Dev builds have hardened runtime **OFF** (`build.sh` line 90), so LLDB attaches directly
(no `get-task-allow` needed). The XPC service is a separate process — attach by PID.

```sh
scripts/macos_test.sh debug              # launches app, prints LLDB attach for app + service PID
scripts/macos_test.sh logs               # retained os_log → build/macos-logs/<run>.log
```

The subsystem is `com.qwenvoice.app` (app + service + the `performance` signpost category).
For interactive debugging, `scripts/macos_test.sh debug` (LLDB attach by PID), Xcode → Debug → Attach to
Process, or XcodeBuildMCP debugging if you enable that workflow in `.xcodebuildmcp/config.yaml`.

## Profile

```sh
scripts/macos_test.sh profile custom:speed    # xctrace the vocello CLI (engine in-process)
```

Profiles the `vocello` CLI during a bench — the **deterministic engine profile** (same
engine code as the XPC service). Default template: Time Profiler; override via
`QVOICE_MAC_PROFILE_TEMPLATE` / `QVOICE_MAC_PROFILE_DURATION`. The lane **fails** if
`vocello bench` exits non-zero unless you pass `--allow-bench-fail` or set
`QVOICE_MAC_PROFILE_ALLOW_BENCH_FAIL=1` (useful when you only want the trace artifact).
The engine emits
`OSSignpost` intervals under `com.qwenvoice.app` / `performance`. To profile the XPC
service specifically (the production path): launch the app, `xctrace record --attach
QwenVoiceEngineService`, and generate via the UI.

## Review

```sh
scripts/macos_test.sh review              # capture the sidebar-screen tour
scripts/macos_test.sh review --baseline   # seed/update docs/macos-review-baselines/
```

Runs `VocelloMacReviewTourUITests` (walks the 6 sidebar screens, screenshots each via
`VocelloMacTestSupport.captureScreenshot`). Diff each capture against its committed baseline
via the **`screenshot-validator`** Axiom subagent (`/axiom:audit screenshots`) or a manual
visual pass. macOS is the host — direct capture,
no Mirroring chrome, no burn-in concern.

## XPC lifecycle (macOS-unique)

The XPC engine service is the macOS-specific testing dimension. It is:
- **Lazy** — spawned on the first generation; not present at app launch.
- **Retireable** — under memory pressure (floor8GBMac) or after an idle dwell, the service
  exits (`shutdownWhenIdle`); the app stays alive; the next generation lazily relaunches it.
- **Crash-isolated** — if the service crashes, the app survives; the next generation
  reconnects (the service auto-relaunches).

```sh
scripts/macos_test.sh xpc                    # watch the lifecycle (retire → relaunch)
scripts/macos_test.sh xpc --crash-isolation  # kill the service → assert the app survives
```

The verb launches the app with a short `QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS` and watches
the service process for SPAWNED/retired/relaunch events. `--crash-isolation` kills a running
service and asserts the app (`Vocello`) survives — the crash-isolation guarantee.
Triggering a generation is manual (the app is UI-driven); the verb monitors + asserts the
scriptable parts. Event-stream gaps are recorded by the service to
`diagnostics/engine-service/native-events.jsonl`.

## Gate

```sh
scripts/macos_test.sh gate    # models → check_project_inputs → build_foundation macos → test → crashes
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # …plus bounded custom/speed/medium bench + audioQC check
```

Steps: (1) `ensure_mac_test_models`, (2) `check_project_inputs`, (3) `build_foundation_targets macos`,
(4) `VocelloMacSmokeUITests` via `test` (re-ensures models + `QVOICE_REQUIRE_TEST_MODELS=1`),
(5) post-run crash check. Does **not** call the `preflight` verb. A single PASS/FAIL verdict +
per-step logs under `build/macos/gate-<run>/`. Deeper dives (bench/profile/review/xpc) are separate
verbs, not part of the every-merge gate.

| Level | Command | Proves |
|-------|---------|--------|
| Compile | `scripts/build_foundation_targets.sh macos` | the app + frameworks compile |
| Compile (test) | `xcodebuild build-for-testing -scheme QwenVoice -destination 'platform=macOS,arch=arm64'` | the test bundle compiles |
| UI smoke | `scripts/macos_test.sh test` | 12 smoke tests (+1 review tour if bare `xcodebuild test` runs the whole target) |
| UI review | `scripts/macos_test.sh review` | sidebar-screen tour vs baselines |
| Perf/quality | `scripts/build.sh cli bench --modes … --variants … --lengths …` | RTF/decode/audioQC + telemetry |
| Crash | `scripts/macos_test.sh crashes` | .ips collection + symbolication |
| XPC | `scripts/macos_test.sh xpc --crash-isolation` | service crash isolation |
| Pre-merge gate | `scripts/macos_test.sh gate` | the standing gate |

## Related docs

- [`macos-app-guide.md`](macos-app-guide.md) — the macOS app map + how to drive it in tests.
- [`macos-release-qa.md`](macos-release-qa.md) — the release QA gate sequence.
- [`macos-permissions.md`](macos-permissions.md) — TCC + signing.
- [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) — telemetry schema + bench recipes.
- [`cli.md`](cli.md) — the `vocello` CLI reference.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — the XPC host + macOS request lifecycle.
