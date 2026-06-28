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
2. **Automated UI smoke** (always — the permanent `VocelloMacUITests` target):
   ```sh
   xcodebuild test -project QwenVoice.xcodeproj -scheme QwenVoice \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
   ```
   11 tests: launch/markers, sidebar + Cmd-key navigation, composer typing (strict char-count),
   a REAL generation through to the player bar (no engine error/crash states), mid-generation
   cancel, History/Voices/Settings surfaces, enroll + batch sheets. Tests run against the debug
   data dir (`QWENVOICE_DEBUG=1` in `launchEnvironment`) and skip generation cells gracefully when
   models aren't installed. Expect **0 failures** (skips acceptable only on model-less machines).
3. **Engine regression net** (when any engine/Sources change since the last green bench):
   ```sh
   QWENVOICE_DEBUG=1 ./build/vocello bench --variants speed --lengths short,medium,long \
     --warm 3 --voice <prepared-voice> --label "release-QA" --ledger
   ```
   Gate: audioQC pass on all cells; RTF within noise of the latest `benchmarks/HISTORY.md` rows;
   the **listening pass** (`vocello bench --review` / by ear) for any engine-adjacent change.
4. **Static audits** (release-sized changesets): run the five Axiom auditors per AGENTS.md routing
   (swiftui-architecture, swiftui-performance, memory, concurrency, security-privacy) scoped to the
   changed surfaces; fix or explicitly defer findings.
5. **Interactive matrix** (releases touching UI; drive via computer-use — never AppleScript):
   | Flow | Key checks |
   |---|---|
   | Record→enroll | record sheet (virtual mic ok: `QWENVOICE_FAKE_MIC_WAV`), <10 s gate ("Need 10 s"), ≥10 s "Use This Clip", review player, **auto-transcription fills**, enrolled row |
   | Clone handoff | voices row "Open in Cloning" hydrates source/reference/transcript |
   | 3 modes e2e | generate per mode; streaming preview; player; no error states |
   | Cancel | mid-generation cancel returns UI clean (also automated) |
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
   Caveat: TCC dialogs are invisible to computer-use — pause for a human + verify with
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
