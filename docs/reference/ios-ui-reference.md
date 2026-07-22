# iOS UI reference

This is the compact screen, identifier, and state map for the Vocello iOS app. It serves
interactive UI QA (agent-driven computer use through iPhone Mirroring,
[`interactive-ui-qa.md`](interactive-ui-qa.md)) and accessibility work: the stable
`accessibilityIdentifier` values below name the genuine visible controls a vision-driven QA agent
(and assistive technology) observes. All UI QA runs on a paired physical iPhone; the iOS Simulator
is unsupported.

Related sources:

- [`ios-app-guide.md`](ios-app-guide.md) — architecture and implementation map.
- [`ios-device-testing.md`](ios-device-testing.md) — physical-device lanes and gates.
- [`testing-runbook.md`](testing-runbook.md) — shared testing policy.

## Navigation hierarchy

Vocello opens on the Studio tab in Custom mode. The root tabs are:

| Surface | Purpose | Stable identifier family |
| --- | --- | --- |
| Studio | Custom, Design, and Clone generation | `rootTab_studio`, `generateSection_*`, `studio_*`, `textInput_*` |
| Voices | Saved voices and built-in speakers | `rootTab_voices`, `screen_voices`, `voicesRow_*` |
| History | Generated takes, playback, export, deletion | `rootTab_history`, `historyModeFilter*`, `historyRow_*` |
| Settings | Models, preferences, clone consent, storage, permissions, About | `rootTab_settings`, `iosSettings_*`, `iosModel*`, `voiceCloning_consentAcknowledgment` |

The Studio selector changes the composer in place. Cold launch selects Custom mode; explicit
handoffs may change the in-session Studio mode.

## Studio states

### Custom Voice

- Script editor and count: `textInput_textEditor`, `textInput_lengthCount`.
- Voice, delivery, language, and variation controls.
- Generate: `textInput_generateButton`.
- Inline progress and completed player.

Generate remains unavailable until the script and Custom model are ready. Interactive UI QA
requires the completed player and matching History row for a completed generation.

### Voice Design

Design requires a voice brief, entered directly or from a starter, before generation. The minimal
interactive-QA checklist verifies the mode is navigable and ready; a deeper session may exercise a
Design generation. A missing Design model must present the
install state instead of Generate.

### Voice Cloning

Clone requires a reference clip from a saved voice, the physical-device recording flow, or an
imported WAV, MP3, AIFF, or M4A file. Interactive UI QA uses a prepared non-PII
saved reference. Recording, Files-picker import, and permission enrollment are separate explicit
product-acceptance scenarios. The genuine visible
`voiceCloning_consentAcknowledgment` control lives in Settings; Clone reads that persistent choice
and keeps Generate disabled until it is enabled. A transcript is optional: supplied text selects
transcript-backed conditioning, while an empty transcript selects the distinct audio-only x-vector
path.

## Voices and History

Voices exposes saved rows (`voicesRow_saved_*`), built-in speakers, separate row and preview
actions, search, filters, and two visible Save a New Voice actions. `voices_saveNewVoice` records a
reference; `voices_importAudioFile` opens the native Files picker. Imported audio is materialized
into app-owned storage, an adjacent `.txt` sidecar can prefill `saveVoice_transcriptEditor`, and
`saveVoice_nameField` plus `saveVoice_saveButton` complete enrollment. Opening a supported audio
document from Files routes through the same sheet. A saved/imported voice hands off to Studio Clone;
a built-in speaker hands off to Studio Custom.

History supports search, mode filtering, sorting, playback, export, saving a take as a voice, and
deletion. A typed database failure presents `historyRetryButton` rather than an empty list and keeps
destructive actions disabled until a successful read. Destructive History actions are outside the
minimal interactive-QA checklist.

## Settings

iOS has one Speed model for each generation mode. Rows expose stable install, progress, cancel,
ready, repair, and delete states. The normal interactive-QA checklist does not install or delete
models; it visibly confirms that Custom, Design, and Clone Speed are ready before generation.

Settings also owns the persistent Clone consent row
`voiceCloning_consentAcknowledgment`. Interactive UI QA enables it through that visible row when
needed so Clone acceptance starts from an explicit consent state; this preference intentionally
remains enabled for later sessions. System permission enrollment is attended setup.

## Sheets and accessibility

Important transient surfaces include voice and clone-reference pickers, the Design brief editor,
delivery/language controls, the player, History actions, model confirmations, and system pickers.

All QA-relevant controls retain stable `accessibilityIdentifier` values. Interactive UI QA waits
for and observes the visible enabled/readiness/completion state needed by the active scenario.
Named screenshots are saved at important states and failures; hidden markers and coordinates are
not acceptable substitutes for visible controls. VoiceOver, Dynamic Type, Reduce Motion, and Reduce
Transparency remain product accessibility requirements, but are not claimed as coverage of the
minimal checklist.

## QA routing

| Goal | Route |
| --- | --- |
| Device/environment readiness | `scripts/ios_device.sh preflight` |
| Physical-device UI acceptance | Run the interactive UI QA checklist ([`interactive-ui-qa.md`](interactive-ui-qa.md)) through iPhone Mirroring |
| Physical-device deterministic/runtime diagnostic | `scripts/ios_device.sh gate` |

Never use an iOS Simulator, Simulator Browser, alternate scripted UI driver, or committed
coordinate table.
