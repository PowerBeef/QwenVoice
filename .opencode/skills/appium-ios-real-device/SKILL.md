---
name: appium-ios-real-device
description: Drive the Vocello iOS app on a physical iPhone via the appium-mcp MCP server. Use when an agent needs to tap, type, scroll, screenshot, or assert on the live iOS UI (real-device flows that XCUITest can't reach or that are flaky). Triggers: "appium", "real device UI test", "drive iPhone", "tap on device", "WDA", "WebDriverAgent".
---

# Appium iOS Real-Device UI Driving (Vocello)

Use this skill whenever you drive the live Vocello iPhone app through the
`appium-mcp` MCP server. Vocello's XCUITest suite is the deterministic backbone;
Appium is the tool when an agent needs to interact with the live UI — exploratory
checks, ad-hoc flows, screenshot evidence, or flows that are flaky in XCUITest.

## Constants

- App bundle ID: `com.patricedery.vocello`
- Device: iPhone 17 Pro, paired via `devicectl` (CoreDevice), Developer Mode ON
- macOS/Xcode: 26.5 / 26.5
- alt path (non-Appium): `scripts/ios_device.sh ui-test` (XCUITest backbone)

## One-time setup: sign WebDriverAgent (WDA)

Real iOS devices require a signed WDA runner. Use `appium_prepare_ios_real_device`
in **two steps**:

1. Call without `provisioningProfileUuid` → it lists `.mobileprovision` profiles
   available to your Apple Developer team.
2. Call again with the chosen `provisioningProfileUuid` and `isFreeAccount` flag
   → it downloads the matching WDA release, packages as IPA, and re-signs.
   Result is cached per WDA-version + profile.

Pass the returned `capabilitiesHint` to `appium_session_management action=create`
so Appium installs and launches WDA on device.

## Canonical first-session sequence

1. `select_device` → auto-selects the iPhone 17 Pro if only one device is connected
2. (first run only) `appium_prepare_ios_real_device` → sign WDA per the two-step above
3. `appium_session_management` with `action=create`, `platform=ios`,
   `capabilities={ "appium:bundleId": "com.patricedery.vocello",
                   "appium:automationName": "XCUITest",
                   "appium:udid": "<from select_device>" }`
4. `appium_app_lifecycle action=activate` with `bundleId` if the app is installed
   but not running
5. Drive via `appium_find_element` (preferred) → `appium_gesture action=tap`
6. `appium_screenshot` for evidence (saves to `SCREENSHOTS_DIR` or cwd)

## Identifier-shadowing caveat (Vocello-specific)

The iOS app's Studio screen propagates `screen_generateStudio` onto descendants,
shadowing their `textInput_*` and `studioChip_*` accessibility identifiers. When
`appium_find_element strategy="accessibility id"` fails to reach a child, fall
back to:

- `-ios predicate string`: `"label BEGINSWITH 'Voice: '"`
- `-ios class chain`: `"/XCUIElementTypeButton[\`label BEGINSWITH 'Voice: '\`]"`

Sheet-level IDs (`voicePickerRow_*`, `voicePickerPreview_*`, `voicePicker_confirm`,
`languagePicker_*`, `voiceBrief_editor`, `voiceBrief_confirm`, `bottomSheet_close`)
are NOT shadowed because sheets are separate overlays — use those directly.

Tab IDs: `rootTab_studio`, `rootTab_voices`, `rootTab_history`, `rootTab_settings`.

## Session-lifecycle rule (MANDATORY)

`APPIUM_MCP_ON_CLIENT_DISCONNECT=skip` is set in the opencode config so Appium
sessions survive MCP reconnects. Therefore:

- **Always** call `appium_session_management action=delete` when a flow completes
  to avoid orphaned WDA runners on device.
- `appium_session_management action=list` shows all sessions including ownership.
- Owned sessions are deleted on disconnect; attached/remote sessions are not.

## When NOT to use this skill

- Building/archiving the iOS app → use `scripts/ios_device.sh build` or
  `xcodebuildmcp` (faster, native).
- Deterministic regression tests → use `VocelloiOSUITests` via
  `scripts/ios_device.sh ui-test` (XCUITest is more stable for known flows).
- Headless generation benchmarks → use `scripts/ios_device.sh bench`
  (`IOSAutorunHarness`, `QVOICE_IOS_AUTORUN`).
- Marketing-site browser checks → use `chrome-devtools` MCP.
