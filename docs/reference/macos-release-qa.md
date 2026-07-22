# macOS Release QA — the desktop release gate

> Before starting a release run, confirm the active acceptance state in
> [`docs/development-progress.md`](../development-progress.md).

The standing pre-release procedure for a macOS (Vocello.app / DMG) release. First executed in full
for v2.1.0 (2026-06-09); rerun the deterministic gates for every release, run the standing
release-candidate interactive QA checklist and record its verdicts (step 2b). If this doc
disagrees with the code, the code wins.

This is a release-only gate, not a commit, push, pull-request, ordinary-merge, or ordinary-CI
check. Missing model or interactive-QA evidence never blocks a macOS package. Signing,
notarization, and upload depend on deterministic release-readiness and artifact checks.

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
   of installed models and interactive-QA evidence.
2a. **Optional model-dependent telemetry diagnostic** (never packaging-blocking):
   ```sh
   scripts/macos_test.sh telemetry-overhead
   ```
   This is deeper engine evidence when the model fixture is available; absence of the fixture does
   not block signing, notarization, or upload. Its three mode-order rotations, raw PCM/timing
   evidence, verdict, and machine context stay local. It does not publish schema-v2 history because
   instrumenting the `off` lane would invalidate the observer-effect comparison.
2b. **Standing release-candidate interactive UI QA** (run and record; never packaging-blocking):
   run the macOS checklist in [`interactive-ui-qa.md`](interactive-ui-qa.md) — agent-driven
   computer use against `./scripts/build.sh run` — for every release candidate, and record its
   run ID and per-item verdicts, or a deliberate skip with the reason, in that release's
   `docs/releases/<version>.md` entry. Screenshot evidence stays untracked under the
   interactive-QA artifacts tree. A missing or skipped run never blocks signing, notarization,
   packaging, or upload — recording the skip keeps the omission visible instead of silent.
   If the visible Settings state is incomplete, run `scripts/macos_test.sh models ensure` only as
   an explicit repair/bootstrap action, then start a fresh QA run.
3. **Engine regression net** (when any engine/Sources change since the last green bench):
   ```sh
   # Explicit model-dependent engine QA; repair fixtures only when this optional run is requested.
   QWENVOICE_DEBUG=1 ./build/vocello bench --modes custom,design,clone \
     --variants speed --lengths short,medium,long \
     --warm 3 --voice A_warm_elderly_woman --label "release-QA"
   ```
   Full procedure: [`benchmarking-procedure.md`](benchmarking-procedure.md) §4.1.
   Gate: clean audioQC on all required cells; RTF within noise of the latest
   `benchmarks/HISTORY.md` rows; fixed-seed evidence and any applicable automated
   language/prosody checks pass. Human listening is optional annotation.
   Optional regression compare against a committed baseline:
   ```sh
   python3 scripts/summarize_generation_telemetry.py \
     ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
     --run-id <run-id> --evidence-manifest <run-artifact-dir>/benchmark-evidence.json \
     --compare-baseline benchmarks/baselines/mac-gate-bench.json \
     --label "release-QA"
   ```
   Investigate any highlighted cell before shipping.
   Successful in-repository benchmarks publish a privacy-safe `engine-generation` record and
   regenerate `benchmarks/HISTORY.md`; do not append to that generated file manually. An optional
   subjective listening note may be added later with `scripts/benchmark_history.py annotate`.
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
   The release runner requires 20 GiB of host free space before readiness work and checks again
   before its isolated build. If it stops, inspect `python3 scripts/build_output_policy.py status`
   and apply only the bounded cleanup it reports; never delete `build/dist/` or the canonical
   development caches merely to satisfy the release lane.
   Release builds use isolated `build/scratch/derived-data/release-macos/` state and place the
   signed app, metadata, and DMG under `build/dist/macos/`; they never invalidate the persistent
   development cache. Routine cleanup does not remove these distribution outputs.
   An attended launch or generation pass can be performed when models are available, but it is not
   part of the packaging gate.
   (No `--notarize` locally unless the API key env vars are present.)
7. **Atomic Release candidate**: push the protected version tag or dispatch `release.yml` with the
   exact existing tag. CI verifies tag/source/version identity, builds, signs, notarizes, staples,
   verifies (`verify_packaged_dmg.sh`), emits SPDX and CycloneDX inventories, writes
   `SHA256SUMS` plus `release-evidence.json`, and attests the DMG. Only then does it create or reuse
   a draft GitHub Release, upload the candidate, download every asset, and verify the digests.
   Reusing a draft first removes every prior asset; the workflow then requires the remote asset-name
   set to match the current candidate exactly before downloading and validating it. Publication is
   the final step. A failure leaves only an Actions artifact or draft Release, never a public
   placeholder or a stale extra asset.

   `release-evidence.json` is schema v2. It embeds a clean full-tree source identity and hashes a
   `release-verification.json` bundle containing the platform required-step ledger and its individual
   manifests. Required steps are accepted only when the release runner launched them as managed
   subprocesses in the same invocation, all digests match the captured source, and completion is
   within the contract's six-hour freshness window. A manually written PASS file, stale ledger,
   missing step, changed untracked source file, or mixed invocation fails before publication.

## Known-cosmetic non-bugs (do not file)

- Post-retirement readiness note briefly shows "Preparing Custom Voice" (§G residual; no connection
  is made and generation is unaffected).
- Enroll sheet: the first click on "Record…" immediately after typing in the Name field can be
  consumed by the field's focus-commit — a second click opens the sheet (observed v2.1.0 QA).
