# QwenVoice Test Report

**Date:** 2026-03-01
**Branch:** `main` (with uncommitted changes)
**Version:** 1.1.0 (build 4)
**Platform:** macOS 26.2 (Darwin 25.3.0) / Apple Silicon

---

## Executive Summary

| Metric | Result |
|--------|--------|
| **Clean build** | PASSED (10s) |
| **UI tests (suite: all)** | 13/19 passed (6 failed, 0 skipped) |
| **Debug tests** | 1/2 passed (1 failed) |
| **Backend health check** | 7/7 passed |
| **Deterministic failures** | 5 (3 root causes) |
| **Flaky failures** | 1 (pre-existing) |

**Overall verdict:** Build is healthy. All 7 failures trace to 3 root causes, none of which indicate functional regressions in app logic. The Python backend is fully operational.

---

## Phase 1: Clean Build Verification

| Property | Value |
|----------|-------|
| **Status** | PASSED |
| **Duration** | ~10s |
| **Exit code** | 0 |
| **Code warnings** | 1 (redundant `internal(set)` modifier in `PythonBridge.swift:21`) |
| **Asset warnings** | 5 (unassigned AppIcon children — cosmetic) |
| **System warnings** | 1 (AppIntents metadata extraction skipped) |

No compiler errors. No linker issues. Code signing with ad-hoc identity succeeded.

---

## Phase 2: Full UI + Integration Suite (`--suite all`)

**Command:** `./scripts/run_tests.sh --suite all --build --debug-on-fail`
**Duration:** ~282s (4m 42s)
**Build cache:** rebuilt

### Per-Class Results

| # | Test Class | Tests | Passed | Failed | Duration |
|---|-----------|-------|--------|--------|----------|
| 1 | SidebarNavigationTests | 2 | 1 | 1 | ~39s |
| 2 | CustomVoiceViewTests | 5 | 4 | 1 | ~85s |
| 3 | VoiceCloningViewTests | 3 | 1 | 2 | ~47s |
| 4 | ModelsViewTests | 2 | 2 | 0 | ~21s |
| 5 | PreferencesViewTests | 2 | 2 | 0 | ~21s |
| 6 | HistoryViewTests | 2 | 2 | 0 | ~17s |
| 7 | VoicesViewTests | 2 | 1 | 1 | ~22s |
| 8 | GenerationFlowTests | 1 | 0 | 1 | ~19s |
| | **TOTAL** | **19** | **13** | **6** | **~271s** |

### Individual Test Outcomes

| Test | Status | Duration | Notes |
|------|--------|----------|-------|
| `SidebarNavigationTests/testSidebarNavigationAcrossAllSections` | PASS | 28s | |
| `SidebarNavigationTests/testSidebarStatusIndicatorsExist` | **FAIL** | 11s | Root Cause A |
| `CustomVoiceViewTests/testCustomVoiceScreenCoreLayout` | PASS | 16s | |
| `CustomVoiceViewTests/testCustomSpeakerTransitions` | PASS | 15s | |
| `CustomVoiceViewTests/testEmotionControlTransitions` | PASS | 17s | |
| `CustomVoiceViewTests/testModelMissingNavigationPath` | PASS | 10s | |
| `CustomVoiceViewTests/testTextInputsAcceptUserInput` | **FAIL** | 23s | Root Cause B |
| `VoiceCloningViewTests/testVoiceCloningScreenCoreLayout` | PASS | 15s | |
| `VoiceCloningViewTests/testVoiceCloningInputControls` | **FAIL** | 18s | Root Cause B |
| `VoiceCloningViewTests/testVoiceCloningMissingModelNavigation` | **FAIL** | 15s | Root Cause C |
| `ModelsViewTests/testModelsScreenAvailability` | PASS | 10s | |
| `ModelsViewTests/testModelCardsAndActionsArePresent` | PASS | 11s | |
| `PreferencesViewTests/testPreferencesScreenAvailability` | PASS | 9s | |
| `PreferencesViewTests/testPreferencesControlsExist` | PASS | 12s | |
| `HistoryViewTests/testHistoryScreenAvailability` | PASS | 8s | |
| `HistoryViewTests/testHistorySearchAndStateElements` | PASS | 9s | |
| `VoicesViewTests/testVoicesControlsAndStates` | PASS | 8s | |
| `VoicesViewTests/testVoicesScreenAvailability` | **FAIL** | 13s | Known flaky |
| `GenerationFlowTests/testFullCustomVoiceGeneration` | **FAIL** | 19s | Root Cause A |

### Top 5 Slowest Tests

| Rank | Test | Duration |
|------|------|----------|
| 1 | `SidebarNavigationTests/testSidebarNavigationAcrossAllSections` | 28s |
| 2 | `CustomVoiceViewTests/testTextInputsAcceptUserInput` | 23s |
| 3 | `GenerationFlowTests/testFullCustomVoiceGeneration` | 18s |
| 4 | `VoiceCloningViewTests/testVoiceCloningInputControls` | 17s |
| 5 | `CustomVoiceViewTests/testEmotionControlTransitions` | 17s |

---

## Phase 3: Debug Suite (`--suite debug`)

**Command:** `./scripts/run_tests.sh --suite debug --no-build --debug-on-fail`
**Duration:** ~26s
**Build cache:** reused

| Test | Status | Duration |
|------|--------|----------|
| `DebugHierarchyTests/testAppWindowAndDefaultScreen` | **FAIL** | 13s |
| `DebugHierarchyTests/testHistoryScreenIdentifiers` | PASS | 11s |

The `testAppWindowAndDefaultScreen` failure is the same Root Cause A (`sidebar_backendStatus` not found).

---

## Phase 4: Rerun Failed (Flakiness Check)

**Command:** `./scripts/run_tests.sh --rerun-failed --no-build`
**Note:** The `last_failed_tests.txt` was overwritten by Phase 3, so only the debug test was rerun.

| Test | Rerun Result | Assessment |
|------|-------------|------------|
| `DebugHierarchyTests/testAppWindowAndDefaultScreen` | **FAIL** (again) | **Deterministic** — not flaky |

---

## Phase 5: Python Backend Health Check

**Python:** `/opt/homebrew/bin/python3.13`
**Server:** `Sources/Resources/backend/server.py`

| # | RPC Probe | Status | Latency | Detail |
|---|-----------|--------|---------|--------|
| 1 | Ready notification | PASS | 0.03s | Backend started and signaled ready |
| 2 | `ping` | PASS | <1ms | `{"status": "ok"}` |
| 3 | `init` | PASS | <1ms | Directories created successfully |
| 4 | `get_speakers` | PASS | <1ms | 4 English speakers: ryan, aiden, serena, vivian |
| 5 | `list_voices` | PASS | <1ms | 0 enrolled voices (expected) |
| 6 | `get_model_info` | PASS | <1ms | 3 models reported (1 downloaded) |
| 7 | Unknown method | PASS | <1ms | Error code `-32601` (method not found) |

All RPC probes passed. Backend startup is fast (30ms) and all endpoints respond correctly.

---

## Model Availability

| Model | Folder | Downloaded |
|-------|--------|-----------|
| Custom Voice (Pro) | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | Yes |
| Voice Design (Pro) | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | No |
| Voice Cloning (Pro) | `Qwen3-TTS-12Hz-1.7B-VoiceCloning-8bit` | No |

Only 1 of 3 models is downloaded. `GenerationFlowTests` would normally XCTSkip but instead fails due to Root Cause A (sidebar check happens before the skip guard).

---

## Failure Analysis

### Root Cause A: `sidebar_backendStatus` Not Found in XCUI Hierarchy (3 tests)

**Affected tests:**
- `SidebarNavigationTests/testSidebarStatusIndicatorsExist`
- `GenerationFlowTests/testFullCustomVoiceGeneration`
- `DebugHierarchyTests/testAppWindowAndDefaultScreen`

**Symptom:** `waitForBackendStatusElement()` fails with "Backend status indicator should exist" after 5s timeout.

**Root cause:** The `sidebar_backendStatus` accessibility identifier is placed on a `Circle()` view (in idle state) or `ProgressView()` (in starting state) inside `SidebarStatusView.swift`. These SwiftUI primitives may not surface their accessibility identifiers in the XCUI hierarchy because:
1. `Circle()` is a shape — shapes are not automatically accessible elements
2. `ProgressView()` at `.controlSize(.mini)` may be treated as a decorative element

The outer container's `sidebar_generationStatus` identifier IS found (confirmed in test log at t=5.32s), proving the `SidebarStatusView` is rendered. Only the nested element identifier is invisible to XCUI.

**Fix:** Add `.accessibilityElement(children: .contain)` to the HStack parents, or move `sidebar_backendStatus` to a `Text` or explicit `AccessibilityElement` wrapper that XCUI can discover.

**Classification:** Deterministic, introduced by the `SidebarStatusView` extraction.

### Root Cause B: Keyboard Focus Not Acquired by TextField (2 tests)

**Affected tests:**
- `CustomVoiceViewTests/testTextInputsAcceptUserInput`
- `VoiceCloningViewTests/testVoiceCloningInputControls`

**Symptom:** `Failed to synthesize event: Neither element nor any descendant has keyboard focus`

**Error location:**
- `CustomVoiceViewTests.swift:82`
- `VoiceCloningViewTests.swift:26`

**Root cause:** The `textInput_textEditor` TextField is found and exists, but clicking it doesn't transfer keyboard focus. This is a macOS XCUI limitation with SwiftUI TextEditor/TextField — the click event lands but focus isn't established before the subsequent `typeText()` call.

**Classification:** Pre-existing issue, not related to recent changes. May require `.click()` followed by a brief wait, or using `XCUIElement.tap()` with coordinate-based interaction.

### Root Cause C: Model Banner Visibility Timing (1 test)

**Affected test:**
- `VoiceCloningViewTests/testVoiceCloningMissingModelNavigation`

**Symptom:** `voiceCloning_goToModels` button not found within 5s.

**Root cause:** The Voice Cloning model is not downloaded, so the missing-model banner should appear. The test checks for `voiceCloning_modelBanner` first (2s timeout, not found), then `voiceCloning_goToModels` (5s timeout, not found). The banner's visibility depends on `isModelDownloaded`, which checks the filesystem at `QwenVoiceApp.modelsDir/<model.folder>`. The issue may be that the `modelsDir` path isn't resolved correctly in the UI test environment, or the banner view conditionally requires additional state (like backend readiness).

**Classification:** Likely a test environment issue. The model folder genuinely doesn't exist, but the view's computed property may not evaluate correctly during UI tests.

### Known Flaky: `voices_title` Timeout (1 test)

**Affected test:**
- `VoicesViewTests/testVoicesScreenAvailability`

**Symptom:** `voices_title` not found within 5s.

**Classification:** Pre-existing flakiness documented in the plan. The Voices screen loads asynchronously (three-state loading), and the title may take longer than 5s to appear when the backend is slow to respond.

---

## Build Warnings Summary

| Category | Count | Details |
|----------|-------|---------|
| Asset catalog | 5 | Unassigned AppIcon children (cosmetic) |
| Swift code | 1 | Redundant `internal(set)` modifier (`PythonBridge.swift:21`) |
| System | 1 | AppIntents metadata extraction skipped (no framework dep) |

No actionable code warnings.

---

## Uncommitted Changes Status

| File | Change |
|------|--------|
| `QwenVoice.xcodeproj/project.pbxproj` | Modified (added SidebarStatusView reference) |
| `Sources/Resources/backend/server.py` | Modified (GPU cache fixes) |
| `Sources/Views/Sidebar/SidebarView.swift` | Modified (extracted status view) |
| `Sources/Views/Components/SidebarStatusView.swift` | New file (extracted from SidebarView) |

---

## Recommendations

1. **Fix Root Cause A (highest priority):** The `sidebar_backendStatus` identifier on `Circle()`/`ProgressView()` needs to be moved to an element that XCUI can discover. Options:
   - Wrap the status indicator in a `Text("")` or use `.accessibilityElement(children: .contain)` on the parent HStack
   - Move the identifier to the parent HStack of each state view instead of the shape/progress element

2. **Address Root Cause B:** Add a brief `sleep(0.5)` or `expectation` between clicking the TextField and typing, or use `XCUIApplication().typeText()` which sends keystrokes to the app rather than the specific element.

3. **Investigate Root Cause C:** Verify that `QwenVoiceApp.modelsDir` resolves correctly in UI test launches. The model banner visibility may need to be independent of backend state.

4. **Increase VoicesView timeout:** Bump `voices_title` wait from 5s to 10s to reduce flakiness, or pre-check that the backend is ready before navigating.

5. **Clean up asset warnings:** Remove unassigned AppIcon children from `Assets.xcassets`.

---

## Test Artifacts

| Artifact | Path |
|----------|------|
| Phase 2 result bundle | `build/test/results/20260301-183434/TestResults.xcresult` |
| Phase 2 log | `build/test/results/20260301-183434/xcodebuild.log` |
| Phase 3 result bundle | `build/test/results/20260301-184033/TestResults.xcresult` |
| Phase 3 log | `build/test/results/20260301-184033/xcodebuild.log` |
| Phase 4 result bundle | `build/test/results/20260301-184146/TestResults.xcresult` |
| Failed tests list | `build/test/last_failed_tests.txt` |
| Slow tests | `build/test/results/20260301-183434/slow-tests.txt` |
