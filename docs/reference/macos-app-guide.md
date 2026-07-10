# Vocello for Mac — app guide + test-driving reference

A consolidated map of the Vocello macOS app: what every screen/element/option does (user
view) and how Codex Computer Use drives it like a human (identifier → action → expected).
Use this to maintain the repository macOS UI scenarios and stable accessibility surface.

> **Where this fits:** the canonical "macOS app + driving" reference. Running the tests
> lives in [`macos-testing.md`](macos-testing.md); the engine/XPC internals live in
> [`../ARCHITECTURE.md`](../ARCHITECTURE.md); the iOS counterpart is
> [`ios-app-guide.md`](ios-app-guide.md).

---

## 1. Overview

A `NavigationSplitView` with a **sidebar** (6 items) + a detail pane. The engine runs
**out-of-process in an XPC service** — the app talks to it over XPC; the service can crash
or retire independently.

| Sidebar | Identifier | Shortcut |
|---------|------------|----------|
| Custom Voice | `sidebar_customVoice` | Cmd+1 |
| Voice Design | `sidebar_voiceDesign` | Cmd+2 |
| Voice Cloning | `sidebar_voiceCloning` | Cmd+3 |
| History | `sidebar_history` | Cmd+4 |
| Saved Voices | `sidebar_voices` | Cmd+5 |
| Settings | `sidebar_settings` | Cmd+6 (labeled "Models" in the Navigate menu, opens the unified Settings/Models surface) |

Three generation modes (Custom / Design / Clone) — same engine contract as iOS, but macOS
has **both Speed (4-bit) and Quality (8-bit)** variants.

---

## 2. Screen-by-screen element + identifier map

### Semantic state surfaces

Computer Use inspects the real accessibility state. Destination containers use `screen_*`, primary
controls expose stable identifiers, and `{mode}_readiness` values report `ready=true/false`.
Hidden `mainWindow_*` markers and `QWENVOICE_UI_TEST_HOOKS` are intentionally absent on macOS.

### Custom Voice (`sidebar_customVoice` → `screen_customVoice`)

| Element | Identifier |
|---|---|
| Speaker picker | `customVoice_speakerPicker` (menu) / `customVoice_selectedSpeaker` (value) |
| Language picker | `customVoice_languageSetup` |
| Delivery (tone) | `customVoice_toneSpeed` |
| Script editor | `textInput_textEditor` / `textInput_charCount` |
| Generate CTA | `textInput_generateButton` |
| Cancel | `textInput_cancelButton` |
| Batch | `textInput_batchButton` |

### Voice Design (`sidebar_voiceDesign` → `screen_voiceDesign`)

| Element | Identifier |
|---|---|
| Voice brief field | `voiceDesign_voiceDescriptionField` / `voiceDesign_voiceDescriptionValue` |
| Brief starters | `voiceDesign_briefStarter_<n>` |
| Brief char count | `voiceDesign_briefCharCount` |
| Language + delivery | `voiceDesign_toneSpeed` / `voiceDesign_languageSetup` |
| Save voice | `voiceDesign_saveVoiceButton` / `voiceDesign_saveVoiceCompleted` |
| Script + CTAs | `textInput_*` (shared) |

### Voice Cloning (`sidebar_voiceCloning` → `screen_voiceCloning`)

| Element | Identifier |
|---|---|
| Reference picker | `voiceCloning_savedVoicePicker` (saved voices menu) |
| Import | `voiceCloning_importButton` |
| Record | `voiceCloning_recordReferenceButton` |
| Active reference | `voiceCloning_activeReference` / `voiceCloning_referenceWarning` |
| Transcript | `voiceCloning_transcriptInput` |
| Record clip sheet | `recordClip_record` / `_stop` / `_retake` / `_use` / `_cancel` / `_timer` |
| Script + CTAs | `textInput_*` (shared) |

### History (`sidebar_history` → `screen_history`)

| Element | Identifier |
|---|---|
| Search | `history_searchField` (toolbar) |
| Sort | `history_sortPicker` (menu) |
| Clear | `history_clearMenu` → `history_clearKeepFiles` / `history_clearDeleteFiles` |
| Row | `historyRow_<genID>` / `historyRow_play_<genID>` / `historyRow_saveAs_<genID>` / `historyRow_delete_<genID>` |

### Saved Voices (`sidebar_voices` → `screen_voices`)

| Element | Identifier |
|---|---|
| Enroll | `voices_enrollButton` (toolbar) |
| Row | `voicesRow_<voiceID>` / `voicesRow_play_<voiceID>` / `voicesRow_use_<voiceID>` / `voicesRow_delete_<voiceID>` |
| Enrollment sheet | `voicesEnroll_nameField` / `_audioPathField` / `_browseButton` / `_recordButton` / `_transcriptField` / `_confirmButton` / `_cancelButton` |

### Settings (`sidebar_settings` → `screen_settings`)

| Element | Identifier |
|---|---|
| Model summary | `settings_modelDownloadsSummary` |
| Mode row | `settings_mode_<mode>` |
| Package row | `settings_package_<modelID>` / `settings_packageStatus_<modelID>` |
| Download / cancel / repair | `settings_download_<id>` / `settings_cancel_<id>` / `settings_repair_<id>` / `settings_manage_<id>` |
| Auto-play | `preferences_autoPlayToggle` |
| Variation | `settings_generationVariation` (segmented: Expressive/Balanced/Consistent) |
| Output dir | `preferences_outputDirectory` / `preferences_browseButton` / `preferences_openFinderButton` |
| Version label | tap 7× → toggles `QWENVOICE_DEBUG` mode |

### Sidebar player + engine status

| Element | Identifier |
|---|---|
| Player bar | `sidebarPlayer_bar` / `sidebarPlayer_playPause` / `sidebarPlayer_waveform` / `sidebarPlayer_time` / `sidebarPlayer_dismiss` |
| Live badge | `sidebarPlayer_liveBadge` / `sidebarPlayer_liveProgress` |
| Engine status | `sidebar_backendStatus_idle` / `_standby` / `_starting` / `_active` / `_error` / `_crashed` |

### Batch generation

| Element | Identifier |
|---|---|
| Segmentation | `batch_segmentationMode` |
| Editor | `batch_textEditor` |
| Generate all | `batch_generateAllButton` / `batch_cancelButton` / `batch_doneButton` |

---

## 3. Model download management

macOS has **both Speed (4-bit) and Quality (8-bit)** variants (unlike iOS Speed-only).
Settings → Voice Models shows per-mode packages. Download via `settings_download_<id>`;
cancel via `settings_cancel_<id>`; repair via `settings_repair_<id>`.

The Studio's Generate CTA (`textInput_generateButton`) appears only when the mode's model
is installed — otherwise the app prompts to download from Settings.

---

## 4. What each option means

Same engine as iOS. See [`ios-app-guide.md`](ios-app-guide.md) §4 for the full reference
(modes, 9 speakers + native languages, 10 delivery presets × Subtle/Normal/Strong, custom
tone, 10 languages, reproducible takes). macOS adds the **Quality (8-bit)** variant for
higher-fidelity output.

---

## 5. Driving the macOS UI like a human

### Test infrastructure (Codex Computer Use)

`$vocello-macos-ui-qa` is the sole macOS frontend driver. It consumes the semantic scenarios in
[`config/macos-ui-scenarios.json`](../../config/macos-ui-scenarios.json), launches the exact
`build/Vocello.app`, and re-observes the accessibility tree before and after each logical action.
There is no macOS XCUITest target or hidden test-marker surface.

The shell harness owns deterministic proof and evidence:

| Lane | Purpose |
|------|---------|
| `scripts/macos_test.sh test` | Core, XPC transport, runtime and harness tests; no UI driving |
| `$vocello-macos-ui-qa quick\|full` | Semantic UI journeys and review |
| `$vocello-macos-ui-qa benchmark` | UI-driven generation matrix |
| `scripts/macos_test.sh ui-report --suite …` | Validate report, typed probes, fingerprints and cleanup |
| `scripts/macos_test.sh review` | Require a valid full report |
| `scripts/macos_test.sh bench-ui` | Require a valid benchmark report and merged telemetry matrix |

### macOS-specific patterns (vs iOS)

- **NavigationSplitView sidebar** — not a tab bar. Use `sidebar_*` identifiers or Cmd+1..6,
  then re-observe the real destination identifier such as `screen_customVoice`.
- **Menus + popovers** — sort pickers, model "Manage" menus, language/delivery pickers use
  macOS menus (NSMenu), not iOS-style sheets. Re-observe after opening before selecting.
- **Keyboard shortcuts** — Cmd+1..6 for sidebar (Cmd+6 is labeled "Models" in the Navigate menu but opens the unified Settings/Models surface); Cmd+, for the Settings window.
- **File pickers** — reference import uses NSOpenPanel. The full suite chooses the tracked
  non-PII fixture and follows Computer Use action-time confirmation policy.
- **Coordinates/screenshots** — use only when accessibility cannot expose the control and record
  the fallback as an automation warning.

### Canonical flow

1. Launch → observe `sidebar_customVoice` and `screen_customVoice`.
2. Navigate by `sidebar_<mode>` → re-observe the destination screen identifier.
3. Compose through `textInput_textEditor` → re-observe the changed semantic value/state.
4. Generate through `textInput_generateButton` → observe `sidebarPlayer_bar`, then run
   `verify-generation`, `verify-history`, and `verify-probes`.
5. History: `sidebar_history` → `historyRow_play_<id>`.
6. Settings: `sidebar_settings` → `settings_download_<id>`.

### Gotchas

- **Menu items** — sort/manage menu items without identifiers are selected by semantic label and
  recorded as catalog gaps when the accessibility tree is insufficient.
- **NSOpenPanel** — re-observe the system sheet and select the known fixture; do not use hidden
  mocks or AppleScript as frontend proof.
- **XPC service retirement** — the engine may be idle/retired; a generation auto-relaunches
  it. The `sidebar_backendStatus_*` markers reflect the state.
- **First responder** — after navigating, the text editor may need one explicit action before
  typing; re-observe instead of assuming focus.

---

## 6. Identifier gaps

macOS controls without stable identifiers (label/coordinate-driven):
- Individual delivery/language menu items (drive by label).
- Model "Manage" popover menu items.
- Batch item rows (derived from `BatchGenerationItemState`, no per-item id).
- History context menu items ("Reveal in Finder").
- History context menu items ("Reveal in Finder").
