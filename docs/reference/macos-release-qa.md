# macOS Release QA — the desktop release gate

> Before starting a release run, confirm the active acceptance state in
> [`docs/development-progress.md`](../development-progress.md).

The standing pre-release procedure for a macOS (Vocello.app / DMG) release. First executed in full
for v2.1.0 (2026-06-09); rerun the deterministic gates for every release and use the interactive
UI lanes only when frontend acceptance is explicitly requested. If this doc disagrees with the code,
the code wins.

This is a release-only gate, not a commit, push, pull-request, ordinary-merge, or ordinary-CI
check. Missing model or XCUITest evidence never blocks a macOS package. Signing, notarization, and
upload depend on deterministic release-readiness and artifact checks.

> For the macOS testing/debugging/profile lanes + the one-command `gate`, see
> [`macos-testing.md`](macos-testing.md). For the macOS app map + test-driving, see
> [`macos-app-guide.md`](macos-app-guide.md).

## Gate sequence

1. **Static gates** (always):
   ```sh
   ./scripts/check_project_inputs.sh
   ./scripts/build.sh build
   ./scripts/build_foundation_targets.sh macos && ./scripts/build_foundation_targets.sh ios
   ```
2. **Deterministic release readiness** (always):
   ```sh
   scripts/macos_test.sh test
   scripts/macos_test.sh release-readiness
   ```
   The packaging entry point invokes `release-readiness` before signing. It must remain independent
   of installed models and XCUITest evidence.
2a. **Optional model-dependent telemetry diagnostic** (never packaging-blocking):
   ```sh
   scripts/macos_test.sh telemetry-overhead
   ```
   This is deeper engine evidence when the model fixture is available; absence of the fixture does
   not block signing, notarization, or upload.
2b. **Optional explicit frontend acceptance** (never packaging-blocking):
   ```sh
   scripts/ui_test.sh macos smoke       # includes visible model readiness
   scripts/ui_test.sh macos benchmark
   ```
   If the visible Settings state is incomplete, run `scripts/macos_test.sh models ensure` only as
   an explicit repair/bootstrap action, then start a fresh smoke run.
   XCUITest is the sole autonomous macOS app UI driver and targets its configured native test host.
   Smoke covers sidebar navigation, visible model and clone-reference readiness, one real Custom
   generation, the completed player, and History. Benchmark owns the configurable
   Custom/Design/Clone matrix and defaults to exactly 29 takes. Both lanes fail on a new crash;
   benchmark additionally validates exact telemetry count/order, History, readable WAVs, and
   audio-QC evidence for every take.
3. **Engine regression net** (when any engine/Sources change since the last green bench):
   ```sh
   # Explicit model-dependent engine QA; repair fixtures only when this optional run is requested.
   QWENVOICE_DEBUG=1 ./build/vocello bench --modes custom,design,clone \
     --variants speed --lengths short,medium,long \
     --warm 3 --voice A_warm_elderly_woman --label "release-QA" --ledger
   ```
   Full procedure: [`benchmarking-procedure.md`](benchmarking-procedure.md) §4.1.
   Gate: audioQC pass on all cells; RTF within noise of the latest `benchmarks/HISTORY.md` rows;
   a **manual listening pass by ear** over the generated WAVs for any engine-adjacent change.
   Optional regression compare against a committed baseline:
   ```sh
   python3 scripts/summarize_generation_telemetry.py \
     ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
     --compare-baseline benchmarks/baseline-2026-06-16-45720dd-streaming-default.md \
     --label "release-QA"
   ```
   Investigate any highlighted cell before shipping.
4. **Static audits** (release-sized changesets): use the relevant installed Codex macOS skills
   plus direct code review for SwiftUI architecture/performance, memory, concurrency, signing,
   and security/privacy. Scope findings to changed surfaces; fix or explicitly defer them.
5. **Version bump**: `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml` (shared by
   the two user-facing targets) → `./scripts/regenerate_project.sh`.
6. **Local package verification**:
   ```sh
   ./scripts/release.sh --preflight full --signing-mode developer-id --signing-identity "<Developer ID Application: …>"
   scripts/verify_release_bundle.sh   # invoked by release.sh; rerun standalone if needed
   ```
   An attended launch or generation pass can be performed when models are available, but it is not
   part of the packaging gate.
   (No `--notarize` locally unless the API key env vars are present.)
7. **Notarized DMG**: publish the GitHub release → CI (`release.yml` `package` job) builds, signs,
   notarizes, staples, verifies (`verify_packaged_dmg.sh`), and attaches `Vocello-macos26.dmg`.

## Known-cosmetic non-bugs (do not file)

- Post-retirement readiness note briefly shows "Preparing Custom Voice" (§G residual; no connection
  is made and generation is unaffected).
- Enroll sheet: the first click on "Record…" immediately after typing in the Name field can be
  consumed by the field's focus-commit — a second click opens the sheet (observed v2.1.0 QA).
