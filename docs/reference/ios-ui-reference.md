# iOS UI reference

This is the compact screen and accessibility map for physical-device Vocello UI tests. XCUITest is
the sole autonomous driver and runs on a paired physical iPhone; the iOS Simulator is unsupported.

Related sources:

- [`ios-app-guide.md`](ios-app-guide.md) — architecture and implementation map.
- [`ios-device-testing.md`](ios-device-testing.md) — physical-device lanes and gates.
- [`testing-runbook.md`](testing-runbook.md) — shared smoke/benchmark policy.

## Navigation hierarchy

Vocello opens on the Studio tab in Custom mode. The root tabs are:

| Surface | Purpose | Stable identifier family |
| --- | --- | --- |
| Studio | Custom, Design, and Clone generation | `rootTab_studio`, `screen_studio`, `studio*`, `textInput_*` |
| Voices | Saved voices and built-in speakers | `rootTab_voices`, `screen_voices`, `voicesRow_*` |
| History | Generated takes, playback, export, deletion | `rootTab_history`, `screen_history`, `historyRow_*` |
| Settings | Models, preferences, storage, permissions, About | `rootTab_settings`, `screen_settings`, `iosSettings_*`, `iosModel*` |

The Studio selector changes the composer in place. Cold launch selects Custom mode; explicit
handoffs may change the in-session Studio mode.

## Studio states

### Custom Voice

- Script editor and count: `textInput_textEditor`, `textInput_lengthCount`.
- Voice, delivery, language, and variation controls.
- Generate: `textInput_generateButton`.
- Inline progress and completed player.

Generate remains unavailable until the script and Custom model are ready. Smoke requires the
completed player and matching History row; the benchmark validator adds readable-audio and exact
telemetry evidence per take.

### Voice Design

Design requires a voice brief, entered directly or from a starter, before generation. The benchmark
lane exercises Design when that mode is selected; the minimal smoke only verifies the mode is
navigable before performing its single Custom generation. A missing Design model must present the
install state instead of Generate.

### Voice Cloning

Clone requires a reference clip from a saved voice, the physical-device recording flow, or an
imported WAV, MP3, AIFF, or M4A file. Automated smoke and benchmark tests use a prepared non-PII
saved reference. Recording, Files-picker import, and permission enrollment are separate explicit
product-acceptance scenarios.

## Voices and History

Voices exposes saved rows (`voicesRow_saved_*`), built-in speakers, separate row and preview
actions, search, filters, and two visible Save a New Voice actions. `voices_saveNewVoice` records a
reference; `voices_importAudioFile` opens the native Files picker. Imported audio is materialized
into app-owned storage, an adjacent `.txt` sidecar can prefill `saveVoice_transcriptEditor`, and
`saveVoice_nameField` plus `saveVoice_saveButton` complete enrollment. Opening a supported audio
document from Files routes through the same sheet. A saved/imported voice hands off to Studio Clone;
a built-in speaker hands off to Studio Custom.

History supports search, mode filtering, sorting, playback, export, saving a take as a voice, and
deletion. Destructive History actions are outside the minimal smoke and benchmark lanes.

## Settings

iOS has one Speed model for each generation mode. Rows expose stable install, progress, cancel,
ready, repair, and delete states. Normal smoke and benchmark lanes do not install or delete models;
they visibly assert that Custom, Design, and Clone Speed are ready before generation.

The minimal smoke and benchmark lanes inspect model readiness without changing preferences. System
permission enrollment is attended setup.

## Sheets and accessibility

Important transient surfaces include voice and clone-reference pickers, the Design brief editor,
delivery/language controls, the player, History actions, model confirmations, and system pickers.

All controls used by autonomous tests retain stable `accessibilityIdentifier` values. Tests use
condition-based waits and assert the visible enabled/readiness/completion state needed by the active
scenario. Named screenshots are attached at important states and failures; labels and coordinates
are not selector fallbacks. VoiceOver, Dynamic Type, Reduce Motion, and Reduce Transparency remain
product accessibility requirements, but are not claimed as coverage of the minimal lanes.

## Test routing

| Goal | Command |
| --- | --- |
| Device/environment readiness | `scripts/ios_device.sh preflight` |
| Physical-device UI regression | `scripts/ui_test.sh ios smoke` |
| Full UI generation matrix | `scripts/ui_test.sh ios benchmark` |
| Physical-device deterministic/runtime diagnostic | `scripts/ios_device.sh gate` |

Never use an iOS Simulator, Simulator Browser, alternate desktop/mobile UI driver, or committed
coordinate table.
