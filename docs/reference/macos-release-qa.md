# macOS Release QA — the desktop release gate

The standing pre-release procedure for a macOS (Vocello.app / DMG) release. First executed in full
for v2.1.0 (2026-06-09); rerun the automated gates for every release and the interactive matrix for
releases that touched UI/engine surfaces. If this doc disagrees with the code, the code wins.

> For the macOS testing/debugging/profile/review lanes + the one-command `gate`, see
> [`macos-testing.md`](macos-testing.md). For the macOS app map + test-driving, see
> [`macos-app-guide.md`](macos-app-guide.md).

## Gate sequence

1. **Static gates** (always):
   ```sh
   ./scripts/check_project_inputs.sh
   ./scripts/build.sh build
   ./scripts/build_foundation_targets.sh macos && ./scripts/build_foundation_targets.sh ios
   ```
2. **Deterministic tests + Computer Use frontend acceptance** (always):
   ```sh
   scripts/macos_test.sh models ensure   # one-time per machine (~6.9 GB Speed trio; idempotent)
   scripts/macos_test.sh test            # Core + XPC transport + owned Qwen3 runtime + harness
   scripts/macos_agent_ui.sh impact      # release work normally selects full or benchmark
   # Invoke $vocello-macos-ui-qa full (or benchmark for backend/performance changes), then:
   scripts/macos_test.sh ui-report --suite full
   scripts/macos_test.sh gate
   ```
   Computer Use is the sole macOS frontend driver and targets the exact `build/Vocello.app`.
   The full report covers Custom/Design/Clone, playback, History/Voices/Settings, batch,
   reference import, XPC recovery, and semantic visual/accessibility review. It only passes when
   typed XPC/backend probes, the matching History row, readable WAV, fingerprints, and cleanup pass.
3. **Engine regression net** (when any engine/Sources change since the last green bench):
   ```sh
   scripts/macos_test.sh models ensure   # Speed trio + clone voice A_warm_elderly_woman
   QWENVOICE_DEBUG=1 ./build/vocello bench --modes custom,design,clone \
     --variants speed --lengths short,medium,long \
     --warm 3 --voice A_warm_elderly_woman --label "release-QA" --ledger
   ```
   Full procedure: [`benchmarking-procedure.md`](benchmarking-procedure.md) §4.1.
   Gate: audioQC pass on all cells; RTF within noise of the latest `benchmarks/HISTORY.md` rows;
   a **manual listening pass by ear** for any engine-adjacent change (there is no
   `vocello bench --review` subcommand). Optional regression compare against a committed baseline:
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
5. **Interactive matrix** (releases touching UI; `$vocello-macos-ui-qa full` is required;
   `scripts/macos_test.sh review` validates that structured report):
   | Flow | Key checks |
   |---|---|
   | Record→enroll | record sheet (virtual mic ok: `QWENVOICE_FAKE_MIC_WAV`), <10 s gate ("Need 10 s"), ≥10 s "Use This Clip", review player, **auto-transcription fills**, enrolled row |
   | Clone handoff | voices row "Open in Cloning" hydrates source/reference/transcript |
   | 3 modes e2e | generate per mode; streaming preview; player; no error states (`test` + `journey`) |
   | Cancel | mid-generation cancel returns UI clean (`test`) |
   | History replay | row appears + replay from history (`journey`) |
   | Error paths | model-missing rows (Download CTA), output-dir fallback (delete chosen dir → orange badge + "no longer exists" caption + Reset), engine-busy readiness |
   | History CRUD | persistence across relaunch, search filter, delete + confirmation dialog |
   | Saved Voices | quality warnings, preview, use, delete |
   | Batch | line-by-line → Generate All → per-line Saved results → Done/Reveal/History |
   | Brief editor | starter chips fill + counter; post-generation "Save to Saved Voices" CTA |
   | Recommended pickers | foreign-language script → "Recommended for your script" section |
   | Retirement transparency | `QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS=20` → service exits, NO error UI, transparent relaunch |
   | Shortcuts | Cmd+1…6, Cmd+Return, Space, Cmd+., Cmd+Shift+O/R, Cmd+, |
   | First-run | fresh `QWENVOICE_APP_SUPPORT_DIR` → disabled tabs, Settings redirect, "0 of N recommended", empty History/Voices |
   | Reduce Motion/Transparency | spot-check solid fills (or code-verify the `appAnimation` paths) |
   Caveat: TCC permission dialogs require a human to answer — verify with
   `scripts/permissions_doctor.sh` (see `macos-permissions.md`).
6. **Version bump**: `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml` (shared by
   the two user-facing targets) → `./scripts/regenerate_project.sh`.
7. **Local package + smoke**:
   ```sh
   ./scripts/release.sh --preflight full --signing-mode developer-id --signing-identity "<Developer ID Application: …>"
   scripts/verify_release_bundle.sh   # invoked by release.sh; rerun standalone if needed
   open build/Vocello.app             # NON-debug: real data dir — launch + one generation per available mode
   ```
   (No `--notarize` locally unless the API key env vars are present.)
8. **Notarized DMG**: publish the GitHub release → CI (`release.yml` `package` job) builds, signs,
   notarizes, staples, verifies (`verify_packaged_dmg.sh`), and attaches `Vocello-macos26.dmg`.

## Known-cosmetic non-bugs (do not file)

- Post-retirement readiness note briefly shows "Preparing Custom Voice" (§G residual; no connection
  is made and generation is unaffected).
- Enroll sheet: the first click on "Record…" immediately after typing in the Name field can be
  consumed by the field's focus-commit — a second click opens the sheet (observed v2.1.0 QA).

## v2.1.0 QA record (2026-06-09)

- Static audits: 5 auditors → 9 real fixes (`64b291d`): cancel-race in all three coordinators,
  drop-handler retain, zombie transcription task, batch-dismiss engine lock, pressure-monitor
  stop-on-deinit ×2, AVAudioPlayer delegate UAF hardening, DateFormatter caching, level-meter
  Canvas. Security scan: READY (usage strings present, no identifier leaks, HTTPS-only).
  Deferred (tracked, post-release): TTSEngineStore observation slicing/`@EnvironmentObject`
  unification, HistoryViewModel + SavedVoiceSheet coordinator extractions, remaining
  ObservableObject→`@Observable` migrations (AV wrappers), `Binding(get:set:)` computed
  properties, strict-concurrency enablement, XPC entitlements split (maintainer-declined).
- Automated smoke: 10/10 passed (107 s), including a real generation + real cancel.
- Interactive matrix: all flows passed (evidence in session; record/transcribe/handoff/batch/
  fallback/first-run all green). Reduce Motion code-verified only.
- Engine net: see the `release-QA net (post audit fixes)` HISTORY.md row.
