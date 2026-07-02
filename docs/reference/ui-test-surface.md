# UI test surface — accessibilityIdentifier catalog

**GENERATED — do not edit by hand.** Regenerate after UI changes:

```sh
python3 scripts/generate_ui_test_surface.py
```

These identifiers are **stable test surface area** (AGENTS.md §7) and must survive
refactors. They are the semantic reference for what to look for on screen — used by
XCUITest suites, the Peekaboo/mirroir exploratory loops, and the review runbooks.
Dynamic ids show their Swift interpolation pattern (e.g. `voicesRow_\(id)`).

## macOS (Vocello.app) — 136 identifiers

| Identifier | Declared in |
|---|---|
| `\(accessibilityPrefix)_\(kind.rawValue)VariantButton` | `GenerationWorkflowView.swift` |
| `\(accessibilityPrefix)_emotionValue` | `EmotionPickerView.swift` |
| `\(accessibilityPrefix)_intensityPicker` | `EmotionPickerView.swift` |
| `\(accessibilityPrefix)_languageHelp` | `GenerationWorkflowView.swift` |
| `\(accessibilityPrefix)_languageHint` | `GenerationWorkflowView.swift` |
| `\(accessibilityPrefix)_languagePicker` | `GenerationWorkflowView.swift` |
| `\(accessibilityPrefix)_languageSetup` | `GenerationWorkflowView.swift` |
| `\(accessibilityPrefix)_toneField` | `EmotionPickerView.swift` |
| `\(accessibilityPrefix)_tonePicker` | `EmotionPickerView.swift` |
| `batch_cancelButton` | `BatchGenerationSheet.swift` |
| `batch_deliverySummary` | `BatchGenerationSheet.swift` |
| `batch_doneButton` | `BatchGenerationSheet.swift` |
| `batch_generateAllButton` | `BatchGenerationSheet.swift` |
| `batch_itemStatusList` | `BatchGenerationSheet.swift` |
| `batch_segmentationMode` | `BatchGenerationSheet.swift` |
| `batch_textEditor` | `BatchGenerationSheet.swift` |
| `customVoice_deliveryUnsupported` | `CustomVoiceView.swift` |
| `customVoice_languageHint` | `CustomVoiceView.swift` |
| `customVoice_languageSetup` | `CustomVoiceView.swift` |
| `customVoice_readiness` | `CustomVoiceView.swift` |
| `customVoice_script` | `CustomVoiceView.swift` |
| `customVoice_selectedSpeaker` | `CustomVoiceView.swift` |
| `customVoice_speakerPicker` | `CustomVoiceView.swift` |
| `customVoice_toneSpeed` | `CustomVoiceView.swift` |
| `customVoice_voiceSetup` | `CustomVoiceView.swift` |
| `historyRow_\(item.id)` | `HistoryView.swift` |
| `historyRow_delete_\(itemID)` | `HistoryView.swift` |
| `historyRow_play_\(item.id)` | `HistoryView.swift` |
| `historyRow_saveAs_\(itemID)` | `HistoryView.swift` |
| `historyRow_saveVoice_\(itemID)` | `HistoryView.swift` |
| `history_clearDeleteFiles` | `ContentView.swift` |
| `history_clearKeepFiles` | `ContentView.swift` |
| `history_clearMenu` | `ContentView.swift` |
| `history_searchField` | `ContentView.swift` |
| `history_sortPicker` | `ContentView.swift` |
| `preferences_autoPlayToggle` | `SettingsView.swift` |
| `preferences_browseButton` | `SettingsView.swift` |
| `preferences_openFinderButton` | `SettingsView.swift` |
| `preferences_outputDirectory` | `SettingsView.swift` |
| `preferences_outputDirectoryIssue` | `SettingsView.swift` |
| `preferences_outputDirectoryWarning` | `SettingsView.swift` |
| `preferences_outputResetButton` | `SettingsView.swift` |
| `recordClip_cancel` | `RecordReferenceClipSheet.swift` |
| `recordClip_record` | `RecordReferenceClipSheet.swift` |
| `recordClip_retake` | `RecordReferenceClipSheet.swift` |
| `recordClip_reviewToggle` | `RecordReferenceClipSheet.swift` |
| `recordClip_status` | `RecordReferenceClipSheet.swift` |
| `recordClip_stop` | `RecordReferenceClipSheet.swift` |
| `recordClip_timer` | `RecordReferenceClipSheet.swift` |
| `recordClip_use` | `RecordReferenceClipSheet.swift` |
| `screen_customVoice` | `CustomVoiceView.swift` |
| `screen_history` | `HistoryView.swift` |
| `screen_settings` | `SettingsView.swift` |
| `screen_voiceCloning` | `VoiceCloningView.swift` |
| `screen_voiceDesign` | `VoiceDesignView.swift` |
| `settings_cancelRecommendedSetup` | `SettingsView.swift` |
| `settings_cancel_\(model.id)` | `SettingsView.swift` |
| `settings_checking_\(model.id)` | `SettingsView.swift` |
| `settings_downloadProgress_\(model.id)` | `SettingsView.swift` |
| `settings_downloadRecommendedModels` | `SettingsView.swift` |
| `settings_download_\(model.id)` | `SettingsView.swift` |
| `settings_generationVariation` | `SettingsView.swift` |
| `settings_manage_\(model.id)` | `SettingsView.swift` |
| `settings_mode_\(mode.rawValue)` | `SettingsView.swift` |
| `settings_modelDownloadsSummary` | `SettingsView.swift` |
| `settings_packageStatus_\(model.id)` | `SettingsView.swift` |
| `settings_package_\(model.id)` | `SettingsView.swift` |
| `settings_preferSpeedEverywhere` | `SettingsView.swift` |
| `settings_recommendedSetupProgress` | `SettingsView.swift` |
| `settings_repair_\(model.id)` | `SettingsView.swift` |
| `sidebarPlayer_bar` | `SidebarPlayerView.swift` |
| `sidebarPlayer_dismiss` | `SidebarPlayerView.swift` |
| `sidebarPlayer_error` | `SidebarPlayerView.swift` |
| `sidebarPlayer_liveBadge` | `SidebarPlayerView.swift` |
| `sidebarPlayer_liveProgress` | `SidebarPlayerView.swift` |
| `sidebarPlayer_liveStatus` | `SidebarPlayerView.swift` |
| `sidebarPlayer_playPause` | `SidebarPlayerView.swift` |
| `sidebarPlayer_time` | `SidebarPlayerView.swift` |
| `sidebarPlayer_waveform` | `SidebarPlayerView.swift` |
| `sidebar_backendStatus` | `SidebarStatusView.swift` |
| `sidebar_backendStatus_active` | `SidebarStatusView.swift` |
| `sidebar_backendStatus_crashed` | `SidebarStatusView.swift` |
| `sidebar_backendStatus_error` | `SidebarStatusView.swift` |
| `sidebar_backendStatus_idle` | `SidebarStatusView.swift` |
| `sidebar_backendStatus_standby` | `SidebarStatusView.swift` |
| `sidebar_backendStatus_starting` | `SidebarStatusView.swift` |
| `sidebar_generationStatus` | `SidebarStatusView.swift` |
| `startupDiagnostics_copyButton` | `StartupDiagnosticsView.swift` |
| `startupDiagnostics_retryButton` | `StartupDiagnosticsView.swift` |
| `startupDiagnostics_view` | `StartupDiagnosticsView.swift` |
| `textInput_batchButton` | `TextInputView.swift` |
| `textInput_charCount` | `TextInputView.swift` |
| `voiceCloning_activeReference` | `VoiceCloningView.swift` |
| `voiceCloning_consentNotice` | `VoiceCloningView.swift` |
| `voiceCloning_importButton` | `VoiceCloningView.swift` |
| `voiceCloning_readiness` | `VoiceCloningView.swift` |
| `voiceCloning_recordReferenceButton` | `VoiceCloningView.swift` |
| `voiceCloning_referenceWarning` | `VoiceCloningView.swift` |
| `voiceCloning_savedVoicePicker` | `VoiceCloningView.swift` |
| `voiceCloning_savedVoicesWarning` | `VoiceCloningView.swift` |
| `voiceCloning_script` | `VoiceCloningView.swift` |
| `voiceCloning_transcriptField` | `VoiceCloningView.swift` |
| `voiceCloning_transcriptInput` | `VoiceCloningView.swift` |
| `voiceCloning_transcriptWarning` | `VoiceCloningView.swift` |
| `voiceCloning_transcriptionUnavailable` | `VoiceCloningView.swift` |
| `voiceCloning_voiceSetup` | `VoiceCloningView.swift` |
| `voiceDesign_briefCharCount` | `VoiceBriefEditor.swift` |
| `voiceDesign_briefStarter_\(index)` | `VoiceBriefEditor.swift` |
| `voiceDesign_briefStarters` | `VoiceBriefEditor.swift` |
| `voiceDesign_languageSetup` | `VoiceDesignView.swift` |
| `voiceDesign_readiness` | `VoiceDesignView.swift` |
| `voiceDesign_saveVoiceButton` | `VoiceDesignView.swift` |
| `voiceDesign_saveVoiceCompleted` | `VoiceDesignView.swift` |
| `voiceDesign_script` | `VoiceDesignView.swift` |
| `voiceDesign_toneSpeed` | `VoiceDesignView.swift` |
| `voiceDesign_voiceDescriptionValue` | `VoiceDesignView.swift` |
| `voiceDesign_voiceSetup` | `VoiceDesignView.swift` |
| `voicesEnroll_audioPathField` | `SavedVoiceSheet.swift` |
| `voicesEnroll_browseButton` | `SavedVoiceSheet.swift` |
| `voicesEnroll_cancelButton` | `SavedVoiceSheet.swift` |
| `voicesEnroll_confirmButton` | `SavedVoiceSheet.swift` |
| `voicesEnroll_errorMessage` | `SavedVoiceSheet.swift` |
| `voicesEnroll_nameField` | `SavedVoiceSheet.swift` |
| `voicesEnroll_recordButton` | `SavedVoiceSheet.swift` |
| `voicesEnroll_speechSettingsButton` | `SavedVoiceSheet.swift` |
| `voicesEnroll_speechUnavailable` | `SavedVoiceSheet.swift` |
| `voicesEnroll_transcribeStatus` | `SavedVoiceSheet.swift` |
| `voicesEnroll_transcriptField` | `SavedVoiceSheet.swift` |
| `voicesRow_\(voiceID)` | `VoicesView.swift` |
| `voicesRow_\(voiceID)_qualityWarning` | `VoicesView.swift` |
| `voicesRow_\(voiceID)_replaceReference` | `VoicesView.swift` |
| `voicesRow_delete_\(voiceID)` | `VoicesView.swift` |
| `voicesRow_play_\(voiceID)` | `VoicesView.swift` |
| `voicesRow_use_\(voiceID)` | `VoicesView.swift` |
| `voices_enrollButton` | `ContentView.swift` |
| `voices_retryButton` | `VoicesView.swift` |

## iOS (VocelloiOS) — 86 identifiers

| Identifier | Declared in |
|---|---|
| `bottomSheet_close` | `IOSDesignSystemPrimitives.swift` |
| `deleteModelSheet_confirm` | `IOSBottomSheets.swift` |
| `deliveryPickerIntensity_\(level)` | `IOSBottomSheets.swift` |
| `deliveryPickerPreset_\(preset.id)` | `IOSBottomSheets.swift` |
| `deliveryPickerSheet_customTone` | `IOSBottomSheets.swift` |
| `deliveryPickerSheet_customTone_back` | `IOSBottomSheets.swift` |
| `deliveryPickerSheet_customTone_charCount` | `IOSBottomSheets.swift` |
| `deliveryPickerSheet_customTone_editor` | `IOSBottomSheets.swift` |
| `deliveryPickerSheet_customTone_examples` | `IOSBottomSheets.swift` |
| `deliveryPicker_confirm` | `IOSBottomSheets.swift` |
| `design_savedVoice_useInClone` | `IOSGenerationModeViews.swift` |
| `engineLifecycleToast_\(descriptor.identifier)` | `IOSEngineLifecycleToast.swift` |
| `generate_miniPlayer_seekRail` | `IOSGenerationSharedViews.swift` |
| `historyClearDeleteFiles` | `IOSLibraryViews.swift` |
| `historyClearKeepFiles` | `IOSLibraryViews.swift` |
| `historyClearMenu` | `IOSLibraryViews.swift` |
| `historyModeFilter` | `IOSLibraryViews.swift` |
| `historyRetryButton` | `IOSLibraryViews.swift` |
| `historyRowDeleteConfirm_\(item.historyAccessibilityID)` | `IOSLibraryViews.swift` |
| `historyRowMenu_\(item.historyAccessibilityID)` | `IOSLibraryViews.swift` |
| `historyRowTap_\(item.historyAccessibilityID)` | `IOSLibraryViews.swift` |
| `historyRow_\(item.historyAccessibilityID)` | `IOSLibraryViews.swift` |
| `historySearchField` | `IOSLibraryViews.swift` |
| `iosModelCancelDownloadConfirmButton` | `IOSSettingsViews.swift` |
| `iosModelCancel_\(model.id)` | `IOSSettingsViews.swift` |
| `iosModelDelete_\(model.id)` | `IOSSettingsViews.swift` |
| `iosModelDownload_\(model.id)` | `IOSSettingsViews.swift` |
| `iosModelProgress_\(model.id)` | `IOSSettingsViews.swift` |
| `iosModelRepair_\(model.id)` | `IOSSettingsViews.swift` |
| `iosModelResume_\(model.id)` | `IOSSettingsViews.swift` |
| `iosModelRetry_\(model.id)` | `IOSSettingsViews.swift` |
| `iosModelRow_\(model.id)` | `IOSSettingsViews.swift` |
| `iosPlayer_download` | `IOSPlayerSheet.swift` |
| `iosPlayer_playPause` | `IOSPlayerSheet.swift` |
| `iosPlayer_save` | `IOSPlayerSheet.swift` |
| `iosPlayer_scrubber` | `IOSPlayerSheet.swift` |
| `iosPlayer_transcript` | `IOSPlayerSheet.swift` |
| `iosRecord_close` | `IOSRecordingOverlay.swift` |
| `iosRecord_retake` | `IOSRecordingOverlay.swift` |
| `iosRecord_start` | `IOSRecordingOverlay.swift` |
| `iosRecord_stop` | `IOSRecordingOverlay.swift` |
| `iosRecord_use` | `IOSRecordingOverlay.swift` |
| `iosSettingsOpenSystemSettings` | `IOSSettingsViews.swift` |
| `iosSettings_autoPlayToggle` | `IOSSettingsViews.swift` |
| `iosSettings_openIOSSettingsRow` | `IOSSettingsViews.swift` |
| `iosSettings_openSourceRow` | `IOSSettingsViews.swift` |
| `iosSettings_privacyPolicyRow` | `IOSSettingsViews.swift` |
| `iosSettings_reduceMotionToggle` | `IOSSettingsViews.swift` |
| `iosSettings_reduceTransparencyToggle` | `IOSSettingsViews.swift` |
| `iosSettings_savedOutputsRow` | `IOSSettingsViews.swift` |
| `iosSettings_storageRow` | `IOSSettingsViews.swift` |
| `iosSettings_variationRow` | `IOSSettingsViews.swift` |
| `iosSettings_versionLabel` | `IOSSettingsViews.swift` |
| `languagePicker_\(language.rawValue)` | `IOSBottomSheets.swift` |
| `languagePicker_confirm` | `IOSBottomSheets.swift` |
| `onboarding_cta` | `IOSOnboardingFlow.swift` |
| `onboarding_firstRunCard` | `IOSOnboardingCard.swift` |
| `onboarding_openSettings` | `IOSOnboardingCard.swift` |
| `onboarding_skip` | `IOSOnboardingFlow.swift` |
| `preview-root` | `IOSPreviewSupport.swift` |
| `recordVoice_cancelOnWarning` | `IOSRecordVoiceSheet.swift` |
| `recordVoice_discardOnWarning` | `IOSRecordVoiceSheet.swift` |
| `recordVoice_keepDespiteWarning` | `IOSRecordVoiceSheet.swift` |
| `referenceClipRow_\(option.id)` | `IOSBottomSheets.swift` |
| `rootTab_\(tab.rawValue)` | `TabDock.swift` |
| `savedVoiceDeleteConfirm_\(voice.id)` | `IOSLibraryViews.swift` |
| `savedVoiceMenu_\(voice.id)` | `IOSLibraryViews.swift` |
| `screen_…` | `IOSAccessibility.swift` |
| `studio_inlinePlayer_dismissConfirm` | `IOSStudioInlinePlayerCard.swift` |
| `studio_inlinePlayer_saveAsVoice` | `IOSStudioInlinePlayerCard.swift` |
| `studio_livePreview_cancel` | `IOSStudioInlinePlayerCard.swift` |
| `textInput_generationError` | `IOSStudioCanvas.swift` |
| `textInput_installModelButton` | `IOSStudioCanvas.swift` |
| `textInput_lengthCount` | `IOSStudioCanvas.swift` |
| `voiceBrief_charCount` | `IOSVoiceDesignBriefSheet.swift` |
| `voiceBrief_confirm` | `IOSVoiceDesignBriefSheet.swift` |
| `voiceBrief_editor` | `IOSVoiceDesignBriefSheet.swift` |
| `voiceBrief_starter_\(index)` | `IOSVoiceDesignBriefSheet.swift` |
| `voicePickerFilterChip_\(label)` | `IOSBottomSheets.swift` |
| `voicePickerPreview_\(option.id)` | `IOSBottomSheets.swift` |
| `voicePickerRow_\(option.id)` | `IOSBottomSheets.swift` |
| `voicePicker_confirm` | `IOSBottomSheets.swift` |
| `voicesRow_\(speaker.id)` | `IOSVoicesView.swift` |
| `voicesRow_saved_\(voice.id)` | `IOSVoicesView.swift` |
| `voicesSearchField` | `IOSVoicesView.swift` |
| `voices_saveNewVoice` | `IOSVoicesView.swift` |

## Shared (both platforms) — 8 identifiers

| Identifier | Declared in |
|---|---|
| `screen_voices` | `VoicesView.swift`, `IOSVoicesView.swift` |
| `textInput_cancelButton` | `TextInputView.swift`, `IOSStudioCanvas.swift` |
| `textInput_generateButton` | `TextInputView.swift`, `IOSStudioCanvas.swift` |
| `textInput_textEditor` | `TextInputView.swift`, `IOSStudioCanvas.swift`, `IOSFlexibleTextEditor.swift` |
| `voiceDesign_voiceDescriptionField` | `VoiceDesignView.swift`, `IOSGenerationSetupCards.swift` |
| `voicesEnroll_cancelOnWarning` | `SavedVoiceSheet.swift`, `IOSGenerationModeViews.swift` |
| `voicesEnroll_discardOnWarning` | `SavedVoiceSheet.swift`, `IOSGenerationModeViews.swift` |
| `voicesEnroll_keepDespiteWarning` | `SavedVoiceSheet.swift`, `IOSGenerationModeViews.swift` |

## Conventions

- `screen_*` — screen presence markers (leaf elements; never shadow children).
- `sidebar_*` / `rootTab_*` — primary navigation (macOS sidebar / iOS tab dock).
- `textInput_*` — script composer surfaces; `textInput_textEditor` is the main editor.
- `generateSection_*` / `studioChip_*` — iOS Studio mode segments and setup chips.
- `voicesRow_*`, `iosModel*` — dynamic per-item ids (interpolated).
- `*_readiness` markers carry `ready=true/false` in their value for wait-loops.
- `mainWindow_*` markers (macOS) expose app state to UI tests (see MacUITestSurfaceMarkers).
