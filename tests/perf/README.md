# `tests/perf/`

Performance thresholds and the methodology behind them. `thresholds.json` is the values the perf suite compares against.

## How The Current Thresholds Were Set

The defaults in `thresholds.json` (e.g. `app_launch_to_ready_ms`, `sidebar_navigation_ms`) were established from local runs on the official minimum-hardware floor for the macOS release track:

- `Mac mini M1, 8 GB RAM`
- Cold launch, app support directory pre-warmed with the default Qwen3 model installed
- Release-config build via `./scripts/release.sh` (not a Debug app)
- No other heavy processes running (no `xcodebuild`, no `harness.py`, no packaging)

Baselines were taken as the median of at least 5 consecutive runs, rounded up to the nearest 50 ms to give ~10% headroom for natural variance across cold-cache / warm-cache state.

## Acceptable Variance

A single run may legitimately come in 5–10% above threshold and still reflect healthy behavior — cold-cache disk reads, AppleEvents setup, and macOS background indexing can all skew a single sample.

Treat a threshold hit as a regression when:

- Two consecutive runs exceed the threshold by more than 10%, **or**
- A single run exceeds the threshold by more than 30% (likely a hang or pathological path).

Do not treat a single 5% overshoot as a regression without a second run.

## Re-establishing Thresholds

If a hardware refresh changes the supported minimum (e.g., drops M1 in favor of M2), or if a structural change legitimately shifts the baseline (e.g., the engine-service XPC split moved some work off the main thread), regenerate the baselines:

1. Clean build: `rm -rf build/foundation build/harness` + `./scripts/build_foundation_targets.sh macos`.
2. Package a Release DMG: `./scripts/release.sh --output-name Vocello-macos26-perf`.
3. Install under a disposable app-support root (`QWENVOICE_APP_SUPPORT_DIR=$TMPDIR/qv-perf`).
4. Run the perf suite five times, median the results, round up to the next 50 ms.
5. Update `thresholds.json` in a dedicated PR; note the hardware + OS version + commit hash in the PR description so the reviewer can reproduce.

## What Is Not A Perf Regression

- First-run download of model files.
- First-run SQLite migration work (now gated behind `DatabaseService` readiness).
- Debug builds (these legitimately run 2–5× slower).
- Runs overlapping with other heavy work on the same machine.

The perf suite assumes a clean, idle machine. If those assumptions are violated, the numbers are not meaningful signal.

## Related

- `AGENTS.md` — "never overlap heavy processes" rule.
- [`../../docs/reference/release-readiness.md`](../../docs/reference/release-readiness.md) — signoff tiers that ultimately govern what perf regressions block a release.
