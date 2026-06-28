# macOS testing — lanes + the XPC dimension

The macOS testing/debugging/benchmarking/UI-review lanes. macOS is the dev host (no
device/Mirroring/burn-in) and the engine runs **out-of-process in an XPC service**
(`com.qwenvoice.app.engine-service`) — a separate process that can crash independently
and be **retired under memory pressure** then lazily relaunched. Several lanes target the
app **and** the service.

> Build/run/release stay in [`build.sh`](../../scripts/build.sh); this doc covers the lane
> driver **`scripts/macos_test.sh`**. For the iOS lanes see
> [`ios-device-testing.md`](ios-device-testing.md). For the macOS app map + driving see
> [`macos-app-guide.md`](macos-app-guide.md).

## Prerequisites

- **Xcode 26** (with the Metal Toolchain component — `xcodebuild -downloadComponent MetalToolchain` if missing).
- A signing identity (Apple Development for dev; Developer ID for release — see
  [`macos-permissions.md`](macos-permissions.md)).
- The app built: `scripts/build.sh build` → `build/Vocello.app` (also preserves dSYMs to
  `build/macos/dsyms/`).
- The XPC service is embedded at `Vocello.app/Contents/XPCServices/QwenVoiceEngineService.xpc`.
- **The Speed model installed** (one-time ~2.3 GB): `scripts/macos_test.sh models` checks
  presence + launches the app to install. Generation tests, `vocello bench`, and `profile`
  require it; the model persists across rebuilds (cleared only by `build.sh clean` /
  `clean_build_caches.sh --models`).

## Lane → tool map

| Lane | Verb | Captures / proves | Deeper analysis |
|------|------|-------------------|-----------------|
| Preflight | `preflight` | Xcode + app + XPC bundle + dSYMs | — |
| Test | `test` | VocelloMacUITests target (currently 11 tests: 10 smoke + 1 review tour) | `axiom:test-runner` on the `.xcresult` |
| Bench | `build.sh cli bench` | deterministic perf/quality matrix | `summarize_generation_telemetry.py` |
| Crash | `crashes [--test]` | `.ips` for app + XPC service | `axiom:crash-analyzer` / `xcsym` vs the dSYMs |
| Debug | `debug` | LLDB attach (app + service PID) + `logs` | XcodeBuildMCP debugging; `systematic-debugging` |
| Profile | `profile [spec]` | xctrace/Instruments on the engine (CLI in-process) | `axiom:performance-profiler` / `xcprof` |
| Review | `review [--baseline]` | sidebar-screen screenshot tour | vision MCP `ui_diff_check` vs `docs/macos-review-baselines/` |
| XPC | `xpc [--crash-isolation]` | retirement/relaunch + crash isolation | — |
| Gate | `gate` | preflight → build → test → crashes → verdict | — |

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
For interactive debugging, XcodeBuildMCP's debugging workflow or Xcode → Debug → Attach to
Process (by PID) both work.

## Profile

```sh
scripts/macos_test.sh profile custom:speed    # xctrace the vocello CLI (engine in-process)
```

Profiles the `vocello` CLI during a bench — the **deterministic engine profile** (same
engine code as the XPC service). Default template: Time Profiler; override via
`QVOICE_MAC_PROFILE_TEMPLATE` / `QVOICE_MAC_PROFILE_DURATION`. The engine emits
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
via a vision MCP (`mcp__zai-mcp-server__ui_diff_check`). macOS is the host — direct capture,
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
scripts/macos_test.sh gate    # check_project_inputs → build_foundation macos → test → crashes → verdict
```

A single PASS/FAIL verdict + per-step logs under `build/macos/gate-<run>/`. Deeper dives
(bench/profile/review/xpc) are separate verbs, not part of the every-merge gate.

## Verification ladder

| Level | Command | Proves |
|-------|---------|--------|
| Compile | `scripts/build_foundation_targets.sh macos` | the app + frameworks compile |
| Compile (test) | `xcodebuild build-for-testing -scheme QwenVoice -destination 'platform=macOS,arch=arm64'` | the test bundle compiles |
| UI smoke | `scripts/macos_test.sh test` | 10 smoke tests (launch, navigate, generate, cancel, history, voices, settings, batch) |
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
