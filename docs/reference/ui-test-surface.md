# UI Test Surface

Reference for a Claude Code session driving the **Debug build** of Vocello via the computer-use MCP. Pair this with [`smoke-custom-voice.md`](smoke-custom-voice.md) for the first end-to-end runbook.

## Permissions

Computer-use access is granted per session and is not persisted. At the top of any session that drives the app:

1. Call `mcp__computer-use__request_access` with `applications: ["Vocello"]`. Vocello is a normal native app — tier "full" — so clicks, typing, modifier keys all work.
2. System-wide: macOS Accessibility permission must already be granted to the controlling app (Claude). If `osascript` System Events calls return permission errors, the user grants in *System Settings → Privacy & Security → Accessibility*.

The `osascript` calls inside `scripts/uitest.sh locate` rely on the same Accessibility permission and will surface the OS prompt the first time if not yet granted.

## Keyboard shortcuts

Some actions don't have an obvious visible button on the default macOS window size (1280×720 logical points) and are easier to trigger from the keyboard. Discovered shortcuts:

| Shortcut | Effect | Context |
|---|---|---|
| `cmd+return` | Trigger Generate on the current generation screen | Custom Voice (confirmed). Likely Voice Design and Voice Cloning too — verify when first used. |
| `cmd+,` | Open Settings window | Standard macOS convention; the app uses it. |

The runbook prefers `cmd+return` over hunting for a Generate button.

## Click vocabulary

Every interactive element in the macOS UI has a stable `accessibilityIdentifier`. Resolve any of these names to pixel coordinates with `scripts/uitest.sh locate <ax-id>`. The script prints `cx cy w h` (center coordinates + size). Container/screen identifiers are listed so a session can confirm "I'm on the right screen" before clicking.

### Sidebar

| Identifier | Kind | Purpose |
|---|---|---|
| `sidebar_customVoice` | row | Switch to Custom Voice generation |
| `sidebar_voiceDesign` | row | Switch to Voice Design generation |
| `sidebar_voiceCloning` | row | Switch to Voice Cloning generation |
| `sidebar_history` | row | Open Generation Library / History |
| `sidebar_voices` | row | Open Saved Voices library |
| `sidebar_settings` | row | Open Settings |
| `sidebarSection_generate` | header | "Generate" section label |
| `sidebarSection_library` | header | "Library" section label |
| `sidebarSection_settings` | header | "Settings" section label |

### Generation screens

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_customVoice` | container | Confirms Custom Voice screen is up |
| `screen_voiceDesign` | container | Confirms Voice Design screen is up |
| `screen_voiceCloning` | container | Confirms Voice Cloning screen is up |

#### Shared script composer (all three modes)

All three generation screens embed `TextInputView`, which exposes the same identifiers:

| Identifier | Kind | Purpose |
|---|---|---|
| `textInput_textEditor` | text field | The script text area. Click center, then `type` to populate. |
| `textInput_generateButton` | button | Generate (also bound to `Cmd+Return`). |
| `textInput_batchButton` | button | Batch generation mode toggle. |
| `textInput_charCount` | label | Character count display. |

This is the most useful identifier for autonomous driving — the script field finally has an AX id (it was the visual-fallback gap in element 1's smoke test).

#### Custom Voice fields

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_customVoice` | container | Custom Voice screen container |

Variant toggle and speaker/delivery pickers don't have unique AX ids catalogued yet; use `customVoice_*` guesses with `locate` on first contact and add what you find.

#### Voice Design fields

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_voiceDesign` | container | Voice Design screen container |
| `voiceDesign_configuration` | container | Top configuration panel (description, delivery, variant) |
| `voiceDesign_voiceDescriptionField` | text field | "Voice brief" / description input |
| `voiceDesign_voiceDescriptionValue` | value anchor | Read-only accessibility value reflecting the typed description |
| `voiceDesign_toneSpeed` | container | Delivery controls (emotion / intensity) |
| `voiceDesign_script` | container | Script composer panel (embeds `textInput_*`) |
| `voiceDesign_readiness` | status | "Ready to generate" / blocker text |
| `voiceDesign_saveVoiceButton` | button | "Save to Saved Voices" after a successful generation |
| `voiceDesign_saveVoiceCompleted` | badge | Replaces the save button once enrollment succeeds |

Variant toggle uses `GenerationVariantSelector` with prefix `voiceDesign` — likely `voiceDesign_variant_speed` / `voiceDesign_variant_quality`. Confirm on first contact.

#### Voice Cloning fields

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_voiceCloning` | container | Voice Cloning screen container |
| `voiceCloning_voiceSetup` | container | Reference source section |
| `voiceCloning_savedVoicePicker` | picker | Saved-voice dropdown (primary path) |
| `voiceCloning_importButton` | button | Import a reference audio file (NSOpenPanel — avoid in autonomous runs) |
| `voiceCloning_consentNotice` | label | Cloning consent notice |
| `voiceCloning_activeReference` | container | Selected reference display ("Saved voice ready" / "Imported file ready") |
| `voiceCloning_referenceWarning` | badge | Quality warning on the active reference |
| `voiceCloning_transcriptField` | container | Transcript section |
| `voiceCloning_transcriptInput` | text field | Optional reference transcript |
| `voiceCloning_readiness` | status | "Ready to generate" once reference + script are present |
| `voiceCloning_savedVoicesWarning` | label | Inline error if saved voices failed to load |
| `voiceCloning_savedVoicesRetry` | button | Retry loading saved voices |
| `voiceCloning_transcriptWarning` | label | Inline error on transcript load |

Voice Cloning requires a pre-existing saved voice for autonomous runs (the alternative is the file-picker dialog, which can't be driven through `type`). The Saved Voices enrollment fields (`voicesEnroll_*`) are documented in the Saved Voices section above.

### History

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_history` | container | History screen container |
| `history_searchField` | text field | Filter history rows |
| `history_sortPicker` | picker | Newest / oldest order |

### Saved Voices

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_voices` | container | Saved Voices screen container |
| `voices_enrollButton` | button | Add a new saved voice |
| `voices_retryButton` | button | Retry after a load failure |
| `voicesRow_<voiceID>` | row | One saved voice row (keyed by UUID) |
| `voicesRow_<voiceID>_use` | button | Use this voice in cloning |
| `voicesRow_<voiceID>_play` | button | Play a preview |
| `voicesRow_<voiceID>_delete` | button | Delete this voice |
| `voicesRow_<voiceID>_qualityWarning` | badge | Quality warning visible |
| `voicesRow_<voiceID>_replaceReference` | button | Replace reference clip |

### Voice enrollment modal

| Identifier | Kind | Purpose |
|---|---|---|
| `voicesEnroll_nameField` | text field | Voice display name |
| `voicesEnroll_audioPathField` | text field | Audio file path |
| `voicesEnroll_browseButton` | button | File picker |
| `voicesEnroll_transcriptField` | text field | Optional transcript |
| `voicesEnroll_confirmButton` | button | Save |
| `voicesEnroll_cancelButton` | button | Cancel |
| `voicesEnroll_errorMessage` | container | Inline error |
| `voicesEnroll_keepDespiteWarning` | button | Proceed past quality warning |
| `voicesEnroll_discardOnWarning` | button | Discard reference, edit again |
| `voicesEnroll_cancelOnWarning` | button | Cancel out of warning |

### Settings — model management

`<id>` below is a model id from `Sources/Resources/qwenvoice_contract.json` (e.g. `pro_custom`, `pro_design`, `pro_clone`).

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_settings` | container | Settings screen container |
| `settings_mode_<mode>` | segment | Switch sub-tab (custom / design / clone) |
| `settings_package_<id>` | row | Model package row |
| `settings_packageStatus_<id>` | label | Current status (downloaded, downloading, etc.) |
| `settings_download_<id>` | button | Start download |
| `settings_cancel_<id>` | button | Cancel in-progress download |
| `settings_repair_<id>` | button | Repair missing files |
| `settings_manage_<id>` | button | Reveal / delete |
| `settings_downloadProgress_<id>` | progress | Active download progress |
| `settings_checking_<id>` | label | "Checking…" indicator |
| `settings_downloadRecommendedModels` | button | One-click install all |
| `settings_cancelRecommendedSetup` | button | Cancel the recommended bundle |
| `settings_recommendedSetupProgress` | progress | Bundle progress |
| `settings_modelDownloadsSummary` | label | "X of Y models installed" |
| `preferences_autoPlayToggle` | toggle | Auto-play after generation |
| `preferences_outputDirectory` | text field | Output folder override |
| `preferences_browseButton` | button | Pick output folder |
| `preferences_outputResetButton` | button | Reset to default folder |
| `preferences_openFinderButton` | button | Reveal output folder |

### Startup diagnostics

| Identifier | Kind | Purpose |
|---|---|---|
| `startupDiagnostics_view` | container | Shown only if preflight failed |
| `startupDiagnostics_retryButton` | button | Re-run preflight |
| `startupDiagnostics_copyButton` | button | Copy diagnostics to clipboard |

## Locating an element

```sh
scripts/uitest.sh locate sidebar_customVoice
# example output (logical-points coordinate space, see caveat below):
# 413 221 202 34
```

The output is `cx cy w h` — center already computed — in **macOS logical-points space** (what `osascript` System Events reports). The computer-use screenshot you see may use a **different image pixel space**: on this Mac the screen is 1280×720 logical points but the captured screenshot renders at ~1456×816 image pixels, a ratio of ~1.138×. `mcp__computer-use__left_click` expects coordinates in screenshot-image pixels.

Two ways to handle this:

1. **Scale before clicking** (preferred when you know both sizes):
   ```
   image_width  = <from your most recent screenshot>
   image_height = <from your most recent screenshot>
   screen_w_h   = `scripts/uitest.sh screen-size`   # "1280 720" on this Mac
   sx = locate_cx * image_width  / screen_logical_w
   sy = locate_cy * image_height / screen_logical_h
   ```
2. **Visual-fallback click**: take a screenshot, find the target visually, and click the center of its visible rectangle. Use this when scaling is awkward (e.g., elements whose `accessibilityIdentifier` isn't yet catalogued in the click vocabulary).

The smoke runbook uses (2) for the script text area and Generate trigger (Cmd+Return), and (1) for the sidebar navigation.

If `locate` exits non-zero ("accessibility identifier not found"), either the screen isn't mounted yet (give SwiftUI another half-second and retry) or the identifier doesn't exist on the current screen. A screenshot will tell you which.

## Completion signals

Four independent ways to confirm a generation finished. Use at least two — they cross-check each other.

### 1. Log signposts

Subsystem `com.qwenvoice.app`. The key milestones are `OSSignposter` events (not regular `os.log` messages) — they only appear with `--signpost` enabled, which `scripts/uitest.sh logs` already passes to `log stream`. If you call `log stream` directly, include `--signpost` or the events will be silently dropped.

Sample line:

```
2026-05-13 21:33:06.295 Sp Vocello[93368:53c81] [com.qwenvoice.app:performance] [spid excl, process, event] Final File Ready
```

Stable substrings emitted by `AppPerformanceSignposts` (`Sources/Services/AppPerformanceSignposts.swift`):

| Substring | Meaning |
|---|---|
| `XPC Engine Command` begin/end | One round-trip to the engine XPC service (begin/end pair, category `xpc`) |
| `Preview To First Chunk` | First audio chunk decoded — TTS pipeline has started producing audio |
| `Final File Ready` | The on-disk `.wav` is fully written (emitted in `Sources/SharedSupport/Services/GenerationPersistence.swift`) |
| `Autoplay Start` | Playback has begun |

`Final File Ready` is the canonical "generation complete" marker. Poll for that substring in the log capture file. Note that `[Performance][...] autoplay_start_wall_ms=...` and similar lines go through `print()` (stderr), not OSLog — they only appear when the app's stderr is captured (e.g., launching the binary directly from a terminal), not from `log stream`.

### 2. File system

A `.wav` lands at:

```
~/Library/Application Support/QwenVoice-Debug/outputs/<Subfolder>/<filename>.wav
```

`<Subfolder>` is the `TTSModel.outputSubfolder` value — observed values are `CustomVoice/`, `VoiceDesign/`, and `Clones/` (PascalCase, not snake_case). Filenames look like `20260513_21-32-56-544_<first 20 chars of script>.wav`. The file appears once `Final File Ready` has fired. A non-zero byte size confirms a real generation; a current Speed-tier Custom Voice take is RIFF WAVE, 16-bit, mono, 24000 Hz, ~50 KB per second of audio.

### 3. Visible UI strings

When the agent can't (or shouldn't) tail logs and just has a screenshot, these stable strings reliably indicate state. They render as on-screen text in the Custom Voice screen and translate identically on the other generation screens.

| Visible state | Meaning |
|---|---|
| Script section header reads `Ready` | App is idle, ready to accept Generate |
| Engine status (sidebar footer) reads `Ready` | Engine warm and idle |
| Bottom status: `Ready to generate. Ready to generate and save.` | Script text is non-empty, can be submitted |
| Engine status reads `Starting engine...` | App just launched or model switched; wait before triggering |
| Script section header reads `Generating` + bottom status: `Generating final audio. Rendering the complete take. The file lands in the player when ready.` | A generation is in flight |
| Player widget appears in sidebar footer with waveform and `0:NN / 0:NN` duration | Generation completed and autoplay started |

The transition from "Generating" → Player widget visible is the strongest visual completion signal. Use it as a fallback when the log capture is unavailable.

### 4. Database

A row is inserted into `generations` in `~/Library/Application Support/QwenVoice-Debug/history.sqlite` after autoplay starts (slight lag after the `.wav` appears). Query with:

```sh
scripts/uitest.sh db "SELECT id, mode, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"
```

`db` opens the DB read-only so concurrent app access can't corrupt anything. Output is CSV.

## Reset semantics

`scripts/uitest.sh reset` always quits Vocello first to avoid racing with SQLite writes.

| Mode | Touches | Keeps | Time |
|---|---|---|---|
| (default) | `generations` rows, every file under `outputs/<mode>/` | models, saved voices, preferences, history table schema | ~1 s |
| `--include-voices` | above + `voices/` directory | models, preferences | ~1 s |
| `--full` | the entire `QwenVoice-Debug/` folder | nothing | <1 s rm, but next launch re-downloads ~5+ GB of models |

Default mode is the right choice between every test run. `--full` is for "I'm starting truly from scratch" scenarios.

## Artifact conventions

Every UI-driven run should anchor on a single directory from `scripts/uitest.sh artifacts-dir`:

```sh
ART=$(scripts/uitest.sh artifacts-dir)
# returns: /Users/.../build/uitest/20260513-201500
```

Convention for what to drop in `$ART/`:

- `pre.png` — screenshot before the test action
- `post.png` — screenshot after completion
- `log.txt` — captured `log stream` output for the run window
- `result.json` — structured outcome (pass/fail booleans, timings, paths, db row ids)

The `build/uitest/` parent is wiped by `scripts/build.sh clean` along with the rest of `build/`. Don't put anything load-bearing in there.

## Session flow (typical)

```
1. mcp__computer-use__request_access(["Vocello"])
2. scripts/build.sh debug                 # if Debug build is stale or missing
3. scripts/uitest.sh smoke-check          # confirm prerequisites
4. scripts/uitest.sh reset                # known-clean baseline
5. read SW SH < <(scripts/uitest.sh screen-size)   # for coord scaling
6. ART=$(scripts/uitest.sh artifacts-dir)
7. (scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)   # background, signpost-aware
8. scripts/uitest.sh prep                 # launch app
9. mcp__computer-use__open_application(app: "Vocello")   # ensure frontmost
10. /usr/sbin/screencapture -x "$ART/pre.png"
11. mcp__computer-use__screenshot         # for the agent's reasoning
12. <drive UI: locate → scale by (IW/SW, IH/SH) → left_click → type → cmd+return>
13. <poll $ART/log.txt for "Final File Ready">
14. scripts/uitest.sh db "SELECT ..."     # verify DB row
15. /usr/sbin/screencapture -x "$ART/post.png"
16. kill the background log PID; write $ART/result.json
17. Report $ART path + pass/fail + measured timings to the user.
```

That flow is the structure every future test runbook should follow.

## Recovery: when clicks miss or focus is stolen

Real macOS sessions throw curve balls. Handle them, don't fight them.

- **macOS notification appeared and stole focus.** `mcp__computer-use__left_click` returns an error naming `UserNotificationCenter` (or another non-allowed app) as frontmost. Recovery: take a fresh screenshot to confirm the notification has self-dismissed, then run `scripts/uitest.sh activate` to re-front Vocello, and retry the click.
- **Click landed but nothing happened.** Usually means Vocello wasn't frontmost (gray traffic lights in the screenshot are the giveaway — focused windows show red/yellow/green). Run `scripts/uitest.sh activate` and retry.
- **`locate` returns coords but the click misses by ~15%.** You forgot to scale from logical-points to screenshot-pixels. See the *Locating an element* section.
- **App opened to the wrong tab (Settings instead of Custom Voice).** Expected — Vocello restores the last-selected sidebar tab from a previous session. Just `locate sidebar_customVoice` and click; the smoke runbook already handles this.
- **`locate` itself fails with "no front window for Vocello".** Either the app hasn't laid out its window yet (wait 500 ms, retry), or Vocello is hidden behind another window (run `activate` first).

## Benchmark anchors

For multi-sample timing across cold/warm × variant × prompt-length, see [`bench-custom-voice.md`](bench-custom-voice.md). Element 2 of the autonomous-testing rollout adds five subcommands to `scripts/uitest.sh` that build on the same signpost+DB plumbing the smoke test verified:

| Subcommand | Purpose |
|---|---|
| `bench-wait [--since <ts>] [--timeout <sec>]` | Block until the next `Final File Ready` signpost after `<ts>`. |
| `bench-record <variant> <coldwarm> <bucket> --artifacts-dir <dir>` | Append one sample (timings, audio file, DB row, RTF) to `<dir>/bench-samples.jsonl`. |
| `bench-summarize <artifacts-dir>` | Group samples and emit `<dir>/bench-result.json` with count/mean/median/p95/min/max/stdev per (variant, phase, bucket, metric). |
| `bench-compare <artifacts-dir> [--baseline <path>]` | Diff a result against `docs/reference/benchmark-baselines.json`; emit a Markdown table; exit 1 on ±15 % breach. |
| `bench-update-baselines [--from <path>]` | Overwrite the committed baseline with the latest summary (review `git diff` before committing). |

The primary metrics tracked across runs are `ms_engine_start_to_final` (wall-clock from XPC engine-begin to `Final File Ready`) and `rtf` (audio seconds per generation second — higher is better). All five subcommands are pure shell + `python3` + `sqlite3` — no new dependencies.

## Debug build internals (for symbol/string introspection)

In Debug builds, Xcode extracts most of the app's compiled code into a separate dylib for faster incremental linking. The on-disk layout is:

```
build/DerivedData/Build/Products/Debug/Vocello.app/Contents/MacOS/
  Vocello                  # ~60 KB stub that loads the dylib
  Vocello.debug.dylib      # all the actual Swift code, strings, and symbols
```

If you need to verify whether new code landed (e.g. `strings`, `nm`, `otool -L`), inspect `Vocello.debug.dylib`, not the `Vocello` binary. Release builds collapse this back into a single executable.
