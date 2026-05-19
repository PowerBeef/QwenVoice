# UI Test Surface

Reference for a Claude Code session driving the **Debug build** of Vocello via the computer-use MCP. Pair this with [`smoke-custom-voice.md`](smoke-custom-voice.md) for the first end-to-end runbook.

## Permissions

Two distinct permission layers:

1. **Session-level computer-use grant** (Claude Code). Before any other computer-use action, call:

   ```
   mcp__computer-use__request_access(
       apps: ["Vocello"],
       reason: "Drive the Vocello Debug build for UI smoke + bench runs."
   )
   ```

   The user approves the application list once per session. Later `request_access` calls extend the allowlist without re-prompting for already-granted apps. `mcp__computer-use__list_granted_applications()` shows what's currently in the allowlist.

2. **System-level macOS Accessibility** (granted to Claude Code in *System Settings → Privacy & Security → Accessibility*). The `osascript` System Events calls inside `scripts/uitest.sh locate` rely on this — they will surface the OS prompt the first time if not yet granted. This is separate from the computer-use grant above.

To bring Vocello to the front mid-run, call `mcp__computer-use__open_application(app: "Vocello")`.

Current Claude Code computer-use tool mapping:

| Action | Tool |
|---|---|
| Request session access (once) | `mcp__computer-use__request_access(apps: ["Vocello"], reason: "...")` |
| Bring Vocello to front | `mcp__computer-use__open_application(app: "Vocello")` |
| Capture visual state | `mcp__computer-use__screenshot()` — full-screen primary display, allowlist-filtered. Subsequent click coordinates are in this image's pixel space. |
| Click at coords | `mcp__computer-use__left_click(coordinate: [x, y])` — targets the frontmost app. |
| Type into focused field | `mcp__computer-use__type(text: "...")` |
| Press key / chord | `mcp__computer-use__key(text: "cmd+Return")` |
| Batched click+type+key | `mcp__computer-use__computer_batch(actions: [...])` — one round-trip for a predictable sequence. |
| Zoom for fine detail | `mcp__computer-use__zoom(region: [x0, y0, x1, y1])` (read-only — coords still come from the most recent full-screen screenshot) |
| Inspect cursor | `mcp__computer-use__cursor_position()` |

Vocello is a native productivity-class app and falls under tier **"full"** — no click/type restrictions.

## Keyboard shortcuts

Some actions don't have an obvious visible button on the default macOS window size (1280×720 logical points) and are easier to trigger from the keyboard. Discovered shortcuts:

| Shortcut | Effect | Context |
|---|---|---|
| `cmd+Return` | Trigger Generate on the current generation screen | Shared by Custom Voice, Voice Design, and Voice Cloning through `TextInputView`. Pass as `key(text: "cmd+Return")`. |
| `cmd+a` | Select text in the focused field | Useful before replacing prompt text between samples. |
| `delete` | Delete selected text | Use after `cmd+a`; Claude Code's `key` tool uses the macOS-native name `delete` for the backspace key. |
| `cmd+comma` | Open Settings window | Standard macOS convention; the app uses it. |

The runbook prefers `cmd+Return` over hunting for a Generate button.

### Driving SwiftUI `Picker` menus

**Gotcha:** SwiftUI `Picker` menus open **anchored to the currently-selected item**, not to a fixed top position. Fixed menu-item click coordinates only work for the *first* selection in a session; every subsequent open re-anchors the menu around whatever was just selected, so fixed coordinates land on the wrong item.

Two reliable patterns:

1. **Keyboard navigation (preferred).**
   - Click the picker once to open the menu (focus the dropdown).
   - Press `key(text: "down")` N times (or `"up"` N times) to step from the currently-selected item to the target. The selection highlight moves with each press, and there's no menu-geometry dependency.
   - Press `key(text: "return")` to commit.
   - Track the *currently-selected* item in shell state so you can compute N for the next change.

2. **Screenshot-verify-after.** Take a fresh `screenshot()` after each pick and confirm the picker's displayed value matches the target before continuing. Slower per cell but useful for one-off picks.

The fixed-coordinate approach is only reliable for the very first menu open after a fresh launch (because the initial selection — usually the first item — anchors the menu at a known position). Anything beyond that needs the keyboard pattern.

This affects every Picker in the app today: the Delivery preset (`delivery_tonePicker`), Delivery intensity (`delivery_intensityPicker`), Voice Cloning saved-voice picker (`voiceCloning_savedVoicePicker`), and the model-variant pickers. The saved-voice picker happens to work with the visual-click pattern in `bench-voice-cloning.md` because it gets clicked exactly once per cold sample; pickers that get changed multiple times per session must use keyboard navigation.

## Standard smoke skeleton

Every smoke runbook follows the same five-phase flow. The per-mode runbooks only document **deltas** (sidebar AX id, output subfolder, fixed inputs, extra steps before generate). Everything below is the universal scaffolding — keep it in your head once and don't re-read the per-mode files looking for it.

### Phase 1 — Precondition

```sh
[ -d build/Debug/Vocello.app ] || scripts/build.sh debug
scripts/uitest.sh smoke-check <mode>      # exits non-zero if the mode's prerequisites are missing
```

For Voice Cloning the prerequisite includes the `UITestRef` saved-voice fixture (see [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md)).

### Phase 2 — Setup (artifact dir + log capture + launch)

```sh
ART=$(scripts/uitest.sh artifacts-dir)
(scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)
LOG_PID=$!
scripts/uitest.sh reset                   # quit Vocello, wipe generations + outputs
scripts/uitest.sh prep                    # relaunch into a fresh window; prints PID
```

### Phase 3 — Front the app + record screenshot dimensions

```text
mcp__computer-use__request_access(apps: ["Vocello"], reason: "Run <mode> smoke")
mcp__computer-use__open_application(app: "Vocello")
SHOT = mcp__computer-use__screenshot()    # record IW × IH (image-pixel dims) for scaled-locate
```

`request_access` only prompts once per session — subsequent calls no-op for already-granted apps. Claude Code's screenshot is downsampled, **not** Retina-native — on a 1280×720 logical screen it returns 1456×819. Pass those dimensions to every `scaled-locate` call. See "Locating an element" below for the canonical numbers.

`/usr/sbin/screencapture -x "$ART/pre.png"` is optional for the artifact bundle (the agent's screenshot already has the visual state).

### Phase 4 — Drive the UI (mode-specific deltas)

The per-mode runbook documents this phase exclusively. Every flow boils down to:

1. Click `sidebar_<mode>` via `scaled-locate <id> $IW $IH` → `mcp__computer-use__left_click(coordinate: [cx, cy])`.
2. Confirm the right screen is mounted: `scripts/uitest.sh locate screen_<mode>` (exit 0).
3. Mode-specific setup (Voice Design: fill the description field; Voice Cloning: pick the saved voice; Custom Voice: leave the default speaker).
4. Click `textInput_textEditor`, type the fixed script text, fire `cmd+Return`. Batch in one round-trip:
   ```text
   mcp__computer-use__computer_batch([
     {action:"left_click", coordinate:[cx, cy]},
     {action:"type", text:"<fixed script>"},
     {action:"key", text:"cmd+Return"}
   ])
   ```
5. Capture `T0` **just before** the `cmd+Return` lands:
   ```sh
   T0="$(/usr/bin/python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])')"
   ```

### Phase 5 — Verify + teardown

One command does the wait + WAV-search + DB-check + `result.json`:

```sh
scripts/uitest.sh verify-generation <mode> \
    --artifacts-dir "$ART" --since "$T0" --text "<fixed script>"
```

Exits 0 on pass, non-zero on fail; either way `$ART/result.json` is written with the canonical shape (`pass`, `mode`, `final_file_ready_ts`, `audio_path`, `audio_bytes`, `db_id`, `db_mode`, `db_duration`, `text`, `timestamp`). Then:

```sh
/usr/sbin/screencapture -x "$ART/post.png"
kill "$LOG_PID" 2>/dev/null || true
```

Report `$ART/result.json`'s `pass` field + the recorded latency to the user.

## Standard bench skeleton

The bench runbooks loop 24 samples through one matrix per mode: 2 variants × (3 cold/medium + 3 warm short + 3 warm medium + 3 warm long). The per-mode bench runbooks only document the mode-specific nav + variant-select + (clone) saved-voice-bind steps. Everything below is universal.

### Phase 0 — Setup

```sh
ART=$(scripts/uitest.sh artifacts-dir)
echo "$ART"
```
```text
mcp__computer-use__request_access(apps: ["Vocello"], reason: "<mode> bench")
mcp__computer-use__open_application(app: "Vocello")
SHOT = mcp__computer-use__screenshot()    # record IW × IH for the scaled-locate calls below
```

### Phase 1 — Per-variant loop

For each `variant` in `[speed, quality]`:

#### 1a. Fresh launch (resets engine warm state)

```sh
scripts/uitest.sh reset
scripts/uitest.sh prep
scripts/uitest.sh activate
```

#### 1b. Mode-specific: nav + variant select + (clone) saved-voice bind

Documented in the per-mode bench runbook. Variant-select uses this canonical three-fallback ladder:

1. **Direct button id** — try `scaled-locate <mode>_speedVariantButton $IW $IH` (or `…_qualityVariantButton`). Click via `left_click`.
2. **Container anchor** — if direct IDs aren't queryable, `scaled-locate <mode>_modelVariantPicker $IW $IH` (or `…_modelVariantSelector`) as a positional anchor; click visually inside that control.
3. **Pure visual** — screenshot, find the gold-highlighted Speed / Quality buttons at the top-right of the Configuration card, click visually. Record the coordinates in the run notes.

**Always verify after clicking.** Take a screenshot; the desired button should be gold-highlighted. Abort the bench if the visual doesn't match.

#### 1c. Initial T0 (before the first generation in this variant)

```sh
python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0
```

#### 1d. Cold samples (n=3, medium prompt only)

For each of three cold samples:

1. (Skip on the first iteration — the fresh launch from 1a counts.) `scripts/uitest.sh reset && scripts/uitest.sh prep && scripts/uitest.sh activate`.
2. Re-do step 1b (re-nav + re-select variant + (clone) re-bind saved voice). Visual verification still required.
3. Drive the UI for one generation: click `textInput_textEditor`, type the medium prompt, fire `cmd+Return` — batched via `computer_batch`.
4. Record the sample:
   ```sh
   scripts/uitest.sh bench-step <mode> "$variant" cold medium --artifacts-dir "$ART" --timeout 180
   ```

`bench-step` reads `/tmp/uitest_bench_t0`, waits for `Final File Ready`, calls `bench-record`, and writes a fresh T0 for the next call. No manual `date` capture between samples.

#### 1e. Warm samples (n=3 per bucket)

For each `bucket` in `[short, medium, long]`, repeat 3 times:

Click `textInput_textEditor` → `cmd+a` → `delete` → type the bucket's prompt → `cmd+Return` (batched).

```sh
scripts/uitest.sh bench-step <mode> "$variant" warm "$bucket" --artifacts-dir "$ART"
```

For Voice Cloning specifically: **do not** touch the saved-voice picker between warm samples — that re-primes the reference and makes every warm sample look cold.

### Phase 2 — Summarize + compare

```sh
scripts/uitest.sh bench-summarize "$ART"      # writes $ART/bench-result.json
scripts/uitest.sh bench-compare "$ART"        # Markdown table; exit 1 if any ±15 % breach
```

#### Reading the bench-compare output — `ms` vs `rtf` as paired signals

`bench-compare` flags both `ms_engine_start_to_final` and `rtf` independently at ±15 %, but they are not independent metrics. When investigating a flag, read them together:

- **Both `ms` AND `rtf` drift in the SAME direction (one slower, one faster)** → real engine throughput change. A regression (or improvement) worth taking seriously.
- **`ms` flagged but `rtf` within gate** → the latency change is driven by **LM output-length variance** (the model occasionally emitted a longer/shorter take for the same prompt), not engine slowdown. Inspect `audio_duration_s` in the per-sample JSONL for outliers. The `rtf` metric (audio-seconds per generation-second) normalizes out output-length, so it's the correct gate for engine throughput.
- **`rtf` flagged but `ms` within gate** → unusual; almost always real. Investigate.

Concrete example (May 18, 2026 follow-up bench): `design/quality/cold/medium` flagged with `ms_engine_start_to_final` +25 % at n=10, but `rtf` stayed within ±15 %. Inspection of the per-sample JSONL showed one outlier where the model emitted 12.24 s of audio for the same medium prompt that produced 4.8–6.5 s in the other 9 samples — pure LM sampling variance, no engine regression.

The ±15 % gate on raw `ms_engine_start_to_final` is deliberately conservative for catching obvious regressions, but it's noisy at n=3. For a "confirmed regression" verdict, prefer `rtf` and require n≥10 samples.

### Phase 3 — Promote to baseline (only when intentional)

```sh
scripts/uitest.sh bench-update-baselines      # overwrites docs/reference/benchmark-baselines.json
git diff docs/reference/benchmark-baselines.json
git commit -m "Update bench baselines: <reason>"
```

The committed baseline is source-of-truth. Update only when the new numbers are intentional (faster path, expected regression with a known cause).

## Standard perceptual-review handoff

For any generation that produced a WAV, the perceptual layer adds subjective dimensions the bench's RMS/peak gates can't catch (naturalness, emotion match, pronunciation, pacing, artifacts):

```sh
scripts/uitest.sh gemini-review <audio_path>
```

Auto-fills mode/text/speaker/delivery from `history.sqlite` by matching the WAV's `audioPath`. Writes a bundle to `build/Debug/voice-reviews/<UTC-ts>-<mode>-<basename>/` containing `review.md`, `metadata.json`, the exact prompt sent, and the raw/clean Gemini response. Full procedure in [`gemini-voice-review.md`](gemini-voice-review.md). When to run it vs the smoke/bench is in [`testing-overview.md`](testing-overview.md)'s decision table.

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
| `textInput_textEditor` | text field | The script text area. Click center, then `type(text: "...")` to populate. |
| `textInput_generateButton` | button | Generate (Claude Code `key(text: "cmd+Return")`; equivalent to macOS Cmd+Return). |
| `textInput_cancelButton` | button | Cancel active generation. Visible only while the shared active-generation state is true. |
| `textInput_batchButton` | button | Batch generation mode toggle. |
| `textInput_charCount` | label | Character count display. |

This is the most useful identifier for autonomous driving — the script field finally has an AX id (it was the visual-fallback gap in element 1's smoke test). During generation, the variant selector and generation controls are disabled and a fresh `mcp__computer-use__screenshot()` should show `textInput_cancelButton` instead of an enabled Generate button.

#### Custom Voice fields

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_customVoice` | container | Custom Voice screen container |

Variant toggle IDs in source are `customVoice_speedVariantButton`, `customVoice_qualityVariantButton`, `customVoice_modelVariantPicker`, and `customVoice_modelVariantSelector`.

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

Variant toggle uses `GenerationVariantSelector` with prefix `voiceDesign`: `voiceDesign_speedVariantButton`, `voiceDesign_qualityVariantButton`, `voiceDesign_modelVariantPicker`, and `voiceDesign_modelVariantSelector`.

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

**Saved-voice store is filesystem-canonical**: `~/Library/Application Support/QwenVoice-Debug/voices/<name>.wav` (+ optional `<name>.txt`). There is no SQLite table — `MLXTTSEngine.listPreparedVoices` just enumerates the directory. The autonomous test rollout uses one well-known fixture named **`UITestRef`**, created by [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md) via the Voice Design → Save to Saved Voices flow (no file picker). `scripts/uitest.sh smoke-check clone` verifies this exact file at `voices/UITestRef.wav`.

### History

`<id>` below is a generation row id from `history.sqlite` (`SELECT id FROM generations`). Read the latest id with `scripts/uitest.sh db "SELECT id FROM generations ORDER BY createdAt DESC LIMIT 1"`.

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_history` | container | History screen container |
| `history_searchField` | text field | Filter history rows |
| `history_sortPicker` | picker | Newest / oldest order |
| `historyRow_<id>` | row | One generation row (keyed by generation id) |
| `historyRow_play_<id>` | button | Play the generated audio |
| `historyRow_saveAs_<id>` | button | Export the audio to a chosen path |
| `historyRow_delete_<id>` | button | Delete the row + audio |
| `historyRow_saveVoice_<id>` | button | Save this generation as a new saved voice (only present for modes that can produce one) |

### Saved Voices

`<voiceID>` below is the saved voice's name-derived id (e.g. `UITestRef`) — same value `enrollPreparedVoice` returns as `PreparedVoice.id`.

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_voices` | container | Saved Voices screen container |
| `voices_enrollButton` | button | Add a new saved voice |
| `voices_retryButton` | button | Retry after a load failure |
| `voicesRow_<voiceID>` | row | One saved voice row |
| `voicesRow_use_<voiceID>` | button | Use this voice in cloning |
| `voicesRow_play_<voiceID>` | button | Play a preview |
| `voicesRow_delete_<voiceID>` | button | Delete this voice |
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
| `settings_preferSpeedEverywhere` | toggle | Pin all modes to Speed (4-bit) variant — RAM-saver for low-RAM Macs |
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

`mcp__computer-use__screenshot` returns a full-screen image of the primary display (allowlist-filtered at the compositor). Click coordinates passed to `left_click` are in that image's pixel space. The harness has three coord helpers; pick by what you're feeding into Claude Code:

- **`scaled-locate <ax-id> <image-w> <image-h>`** — the Claude Code path. Pre-scales `locate`'s logical-point output into the screenshot's image-pixel space. `image-w` and `image-h` are the actual dimensions of the image `mcp__computer-use__screenshot` returned — **read them from the screenshot's metadata, do not assume Retina 2×**. On a 1280×720 logical screen, Claude Code's `screenshot` tool returns a 1456×819 image (it's downsampled for context efficiency, not delivered at the display's native pixel resolution).

   ```sh
   # Logical screen is 1280×720; Claude Code's screenshot is 1456×819.
   scripts/uitest.sh scaled-locate sidebar_customVoice 1456 819
   # 470 251 230 39   (already in screenshot-pixel space)
   ```

   Pass directly: `mcp__computer-use__left_click(coordinate: [470, 251])`.

- **`locate <ax-id>`** — raw logical-points from System Events. Useful for AX-id presence checks: exit code 0 means "this id resolved on the front window," even when you don't need coordinates.

   ```sh
   scripts/uitest.sh locate sidebar_customVoice
   # 413 221 202 34   (logical-points — what System Events reports)
   ```

- **`window-locate <ax-id> [image-w image-h]`** — legacy window-relative helper from the Codex era. Codex's `get_app_state` returned a window-scoped screenshot, so window-relative coords matched. Preserved for backward compatibility with older runbooks; new Claude Code runbooks should prefer `scaled-locate`.

`screen-size` returns the logical screen dimensions (`1280 720` on this Mac); `scaled-locate` internally does `cx * image_w / screen_w` and the equivalent for y.

If a notification or another app stole focus before a click, call `mcp__computer-use__open_application(app: "Vocello")` (or `scripts/uitest.sh activate`) and re-take the screenshot — image coordinates can shift if the window position changed.

### When `locate` won't find an element

Some elements aren't queryable even though they have `accessibilityIdentifier(...)` in source:

- The Speed/Quality variant toggle buttons are `customVoice_speedVariantButton`, `customVoice_qualityVariantButton`, `voiceDesign_speedVariantButton`, `voiceDesign_qualityVariantButton`, `voiceCloning_speedVariantButton`, and `voiceCloning_qualityVariantButton`. Try `scaled-locate` on those exact IDs first. If the current SwiftUI accessibility tree still hides them, use the outer `<mode>_modelVariantPicker` / `<mode>_modelVariantSelector` as an anchor and click visually within that control.

- Saved-voice dropdown menu items (`UITestRef` etc.) similarly aren't exposed once the dropdown is open — click visually.

If `locate` exits non-zero ("accessibility identifier not found"), either the screen isn't mounted yet (give SwiftUI another half-second and retry), the identifier doesn't exist on the current screen, or the element is hidden behind one of the AX-tree-collapsing modifiers above.

## Completion signals

Four independent ways to confirm a generation finished. Use at least two — they cross-check each other.

### 1. Log signposts

Subsystem `com.qwenvoice.app`. The key milestones are `OSSignposter` events (not regular `os.log` messages) — they only appear with `--signpost` enabled, which `scripts/uitest.sh logs` already passes to `log stream`. If you call `log stream` directly, include `--signpost` or the events will be silently dropped.

Sample line:

```
2026-05-13 21:33:06.295 Sp Vocello[93368:53c81] [com.qwenvoice.app:performance] [spid excl, process, event] Final File Ready
```

Stable substrings emitted by `AppPerformanceSignposts` (`Sources/Services/AppPerformanceSignposts.swift`) plus the engine-side signposter (`NativeStreamingSignposts`, different subsystem):

**XPC layer (`com.qwenvoice.app:xpc`):**

| Substring | Meaning |
|---|---|
| `XPC Engine Command` begin/end | One round-trip to the engine XPC service (begin/end pair) |

**Engine-side streaming (`com.qwenvoice.engine:generation` — a DIFFERENT subsystem than the app's; query separately):**

| Substring | Meaning |
|---|---|
| `Native Generation Stream` begin/end | Outer interval wrapping one streaming generation in the XPC service |
| `Native First Audio Chunk` | First audio chunk emitted by the engine (`NativeStreamingSynthesisSession.swift:1052`) — measure cold-start engine latency by diffing this against the surrounding `Native Generation Stream` begin |

**App-side streaming state machine (`com.qwenvoice.app:performance`)** — Phase 4 + 5 instrumentation. Each event lands in `Sources/SharedSupport/ViewModels/AudioPlayerViewModel.swift`. Reading them in chronological order reconstructs the streaming-preview state machine for any generation:

| Substring | Meaning | Source |
|---|---|---|
| `Chunk Received` | Engine chunk arrived at `handleGenerationChunk` (broker delivery confirmed) | `AudioPlayerViewModel` |
| `Chunk Dropped Completed` | Chunk rejected because its sessionID is in `completedLiveSessionIDs` (stale-session guard) | `AudioPlayerViewModel` |
| `Chunk Dropped Preview Disabled` | Chunk rejected because an earlier malformed/gapped preview chunk disabled live playback for this session | `AudioPlayerViewModel` |
| `Live Session Start` | `startLiveSession` ran — new live-preview session is being set up | `AudioPlayerViewModel` |
| `Chunk Decoded` | `AVAudioPCMBuffer` decoded successfully from a chunk; buffer is about to be scheduled | `AudioPlayerViewModel` |
| `Should Start Reject Autoplay` | `shouldStartLivePlayback` returned false because `autoplayEnabled == false` | `AudioPlayerViewModel` |
| `Should Start Reject Buffer` | `shouldStartLivePlayback` returned false because the adaptive no-estimate fallback threshold was not met | `AudioPlayerViewModel` |
| `Live Engine Play` | `livePlayerNode.play()` fired — live engine actually started playing buffered audio. **Key streaming-engagement signal** | `AudioPlayerViewModel` |
| `Live Preview Underrun` | The AVAudioEngine queue drained before the final file was ready. Treat as a preview-smoothness failure. | `AudioPlayerViewModel` |
| `Live Preview Chunk Gap` | Preview PCM continuity failed (gap, overlap, zero-length, or malformed payload). Live preview is stopped and the final WAV is still awaited. | `AudioPlayerViewModel` |
| `Stale Completion Dropped` | Buffer-completion callback from a previous session rejected by the sessionID guard | `AudioPlayerViewModel` |
| `Session Completed Recorded` | Session ID burnt to `completedLiveSessionIDs` (preview ended, stragglers will now be dropped) | `AudioPlayerViewModel` |
| `Switch To File Playback` | Live→file handoff: `switchToFinalFilePlayback` ran (preview's done; playing the final WAV instead) | `AudioPlayerViewModel` |
| `Autoplay Start` | Playback actually began. Fires from BOTH paths — streaming live engine after `play()` and file playback after final handoff. In streaming, this fires **before** `Final File Ready`; in file playback, **after** | `AudioPlayerViewModel` |

**Dead-code signposts (defined but currently unreachable in production):**

| Substring | Notes |
|---|---|
| `Preview To First Chunk` (interval), `First Chunk Received` (event) | Both gated on `prepareStreamingPreview` running, which has no production caller. Streaming auto-init via `handleGenerationChunk`'s call to `startLiveSession` bypasses these. Bench `bench-record` still captures `first_chunk_ts` for forensics if it fires, but `ms_engine_start_to_first_chunk` is consequently always `None` in current bench output. |

**Final completion:**

| Substring | Meaning |
|---|---|
| `Final File Ready` | The on-disk `.wav` is fully written (emitted in `Sources/SharedSupport/Services/GenerationPersistence.swift`) — canonical "generation complete" marker for both streaming and non-streaming paths |

**Querying engine-side signposts requires a separate `log show` invocation** with a different predicate. The app subsystem `com.qwenvoice.app` does NOT see engine signposts:

```sh
# App-side state machine:
/usr/bin/log show --signpost --predicate 'subsystem == "com.qwenvoice.app"' \
    --last 5m --style compact

# Engine-side timing anchors (Native First Audio Chunk, etc.):
/usr/bin/log show --signpost --predicate 'subsystem CONTAINS "qwenvoice"' \
    --last 5m --style compact
```

**Streaming-engagement diagnostic recipe.** When triaging a failed streaming sample (autoplay fires AFTER `Final File Ready` instead of before), capture the app-side trace and read it as a state-machine narrative. The healthy trace for a streaming sample is approximately: `Chunk Received` (×N) ∪ `Chunk Decoded` (×N) ∪ `Live Session Start` (×1, first chunk only) → smooth-first buffering threshold met → `Live Engine Play` (×1) → `Autoplay Start` (×1) → … more chunks … → `Final File Ready` → `Session Completed Recorded` → `Switch To File Playback`. There should be zero `Live Preview Underrun` and zero `Live Preview Chunk Gap` events. Any deviation (e.g., `Live Engine Play` never firing despite many `Chunk Decoded` events; `Stale Completion Dropped` firing during a fresh session) pins down the failure mode.

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

Default mode is the right choice between every test run. `--full` is exceptional because Debug intentionally shares this persistent development store across rebuilds; deleting it removes installed models and saved harness fixtures.

## Artifact conventions

Every UI-driven run should anchor on a single directory from `scripts/uitest.sh artifacts-dir`:

```sh
ART=$(scripts/uitest.sh artifacts-dir)
# returns: /Users/.../build/Debug/uitest/20260513-201500
```

Convention for what to drop in `$ART/`:

- `pre.png` — screenshot before the test action
- `post.png` — screenshot after completion
- `log.txt` — captured `log stream` output for the run window
- `result.json` — structured outcome (pass/fail booleans, timings, paths, db row ids)

The `build/Debug/uitest/` parent is wiped by `scripts/build.sh clean` along with the rest of `build/`. Don't put anything load-bearing in there.

## Session flow (typical)

```
1. mcp__computer-use__request_access(apps: ["Vocello"], reason: "...")
2. scripts/build.sh debug                 # if Debug build is stale or missing
3. scripts/uitest.sh smoke-check          # confirm prerequisites
4. scripts/uitest.sh reset                # known-clean baseline
5. ART=$(scripts/uitest.sh artifacts-dir)
6. (scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)   # background, signpost-aware
7. scripts/uitest.sh prep                 # launch app
8. mcp__computer-use__open_application(app: "Vocello")   # ensure frontmost
9. SHOT=mcp__computer-use__screenshot()    # IW × IH for scaling; also the agent's visual state
10. /usr/sbin/screencapture -x "$ART/pre.png"   # archive copy for the artifact bundle
11. read CX CY W H < <(scripts/uitest.sh scaled-locate <ax-id> $IW $IH)
12. mcp__computer-use__computer_batch([     # batched click → type → key, one round-trip
        {action:"left_click", coordinate:[CX, CY]},
        {action:"type", text:"..."},
        {action:"key", text:"cmd+Return"}
    ])
13. scripts/uitest.sh bench-wait --since "$T0" --timeout 90   # waits for "Final File Ready"
14. scripts/uitest.sh db "SELECT ..."     # verify DB row
15. /usr/sbin/screencapture -x "$ART/post.png"
16. kill the background log PID; write $ART/result.json
17. Report $ART path + pass/fail + measured timings to the user.
```

That flow is the structure every future test runbook should follow. The `computer_batch` step in 12 is the prime cost-saver — predictable click+type+key sequences should always batch.

## Recovery: when clicks miss or focus is stolen

Real macOS sessions throw curve balls. Handle them, don't fight them.

- **macOS notification appeared and stole focus.** `left_click` returns an error naming `UserNotificationCenter` (or another non-allowed app) as frontmost. Recovery: take a fresh `mcp__computer-use__screenshot()` to confirm the notification has self-dismissed, then `mcp__computer-use__open_application(app: "Vocello")` (or `scripts/uitest.sh activate`) to re-front Vocello, and retry the click.
- **`left_click` returns "access denied" mentioning Vocello.** The session allowlist doesn't include Vocello (or it expired). Call `mcp__computer-use__request_access(apps: ["Vocello"], reason: "...")` first; this only needs to happen once per session.
- **Click landed but nothing happened.** Usually means Vocello wasn't frontmost (gray traffic lights in the screenshot are the giveaway — focused windows show red/yellow/green). Run `mcp__computer-use__open_application(app: "Vocello")` or `scripts/uitest.sh activate` and retry.
- **`locate` returns coords but the click misses.** You passed logical-point coords into Claude Code's image-pixel space. Use `scaled-locate <ax-id> <image-w> <image-h>` with the actual screenshot pixel dimensions.
- **App opened to the wrong tab (Settings instead of Custom Voice).** Expected — Vocello restores the last-selected sidebar tab from a previous session. Just `locate sidebar_customVoice` and click; the smoke runbook already handles this.
- **`locate` itself fails with "no front window for Vocello".** Either the app hasn't laid out its window yet (wait 500 ms, retry), or Vocello is hidden behind another window (run `activate` first).

## Benchmark anchors

For multi-sample timing across cold/warm × variant × prompt-length, see [`bench-custom-voice.md`](bench-custom-voice.md). Per-sample metrics now extend beyond timing into audio quality and memory footprint (`schema_version: 3`):

- `ms_engine_start_to_final`, `ms_engine_start_to_autoplay`, `audio_duration_s`, `rtf` — timing and pipeline anchors. `bench-compare`'s ±15% flagging logic uses `ms_engine_start_to_final` and `rtf`.
- `audio_rms_dbfs`, `audio_peak_dbfs` — loudness metrics computed from the WAV via stdlib `wave` + `audioop`. Catches clipping, silent-output, or major level regressions. Informational only — not auto-flagged.
- `peak_rss_mb` — sum of resident-set-size for Vocello + the `QwenVoiceEngineService` XPC process at the moment `Final File Ready` fires. Captures the real footprint of an active generation (the model lives in the XPC service, not the main app). Per-process breakdown is also retained as `peak_rss_mb_app` and `peak_rss_mb_xpc` for forensics. Informational only.

The harness includes signpost+DB helpers for both benchmark timing and streaming-preview health:

| Subcommand | Purpose |
|---|---|
| `bench-wait [--since <ts>] [--timeout <sec>]` | Block until the next `Final File Ready` signpost after `<ts>`. |
| `bench-record <mode> <variant> <coldwarm> <bucket> --artifacts-dir <dir>` | Append one sample (timings, audio file, DB row, RTF) to `<dir>/bench-samples.jsonl`. |
| `streaming-preview-check [--since <ts>] [--timeout <sec>] [--artifacts-dir <dir>]` | Wait for `Final File Ready`, then assert live playback and autoplay began before final handoff, no preview underrun/gap fired, and the latest DB row points at a valid WAV. Appends JSONL to `<dir>/streaming-preview-checks.jsonl` when an artifact dir is provided. |
| `bench-summarize <artifacts-dir>` | Group samples and emit `<dir>/bench-result.json` with count/mean/median/p95/min/max/stdev per (variant, phase, bucket, metric). |
| `bench-compare <artifacts-dir> [--baseline <path>]` | Diff a result against `docs/reference/benchmark-baselines.json`; emit a Markdown table; exit 1 on ±15 % breach. |
| `bench-update-baselines [--from <path>]` | Overwrite the committed baseline with the latest summary (review `git diff` before committing). |

The primary metrics tracked across runs are `ms_engine_start_to_final` (wall-clock from XPC engine-begin to `Final File Ready`) and `rtf` (audio seconds per generation second — higher is better). These helpers are pure shell + `python3` + `sqlite3` — no new dependencies.

## Debug build internals (for symbol/string introspection)

In Debug builds, Xcode extracts most of the app's compiled code into a separate dylib for faster incremental linking. The on-disk layout is:

```
build/Debug/Vocello.app/Contents/MacOS/
  Vocello                  # ~60 KB stub that loads the dylib
  Vocello.debug.dylib      # all the actual Swift code, strings, and symbols
```

If you need to verify whether new code landed (e.g. `strings`, `nm`, `otool -L`), inspect `Vocello.debug.dylib`, not the `Vocello` binary. Release builds collapse this back into a single executable.
