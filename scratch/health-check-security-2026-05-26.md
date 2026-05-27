# Vocello Security & Privacy Audit — 2026-05-26

## Summary

| Metric | Result |
|--------|--------|
| **App Store readiness** | **NOT READY** (iOS TestFlight / App Store Connect) |
| **Security posture** | **GAPS** (no hardcoded secrets; local-first design is sound; compliance artifacts missing) |
| CRITICAL | 2 |
| HIGH | 4 |
| MEDIUM | 6 |
| LOW | 3 |
| Hardcoded credentials | 0 |
| Privacy Manifest | **MISSING** (0 / 4 required first-party manifests) |
| Token storage | N/A — no auth tokens; `@AppStorage` / `UserDefaults` hold UI prefs only |
| Network transport | **HTTPS-only** (no ATS overrides; iOS catalog enforces HTTPS) |
| ATT | N/A (not used) |
| Export compliance | **MISSING** (`ITSAppUsesNonExemptEncryption` absent despite CryptoKit use) |

**Intentional design (not defects):** macOS App Sandbox is **disabled** in `Sources/QwenVoice.entitlements` (`com.apple.security.app-sandbox = false`) together with `allow-unsigned-executable-memory` and `disable-library-validation` — required for MLX runtime on Apple Silicon. iOS uses an App Group (`group.com.patricedery.vocello.shared`) so the UI app and `VocelloEngineExtension` share models, history, outputs, and voice assets on-device. No cloud analytics, no ATT, no Keychain tokens — appropriate for a local TTS product.

**Immediate blockers before iOS submission:** add `PrivacyInfo.xcprivacy` to every shipping target (app + engine extension; macOS app + XPC if Mac App Store), declare all Required Reason APIs in use, and add `ITSAppUsesNonExemptEncryption`.

---

## Security & Privacy Map

- **Privacy Manifest:** None found under `Sources/` or repo root. Code uses `UserDefaults`, `ProcessInfo.systemUptime`, file `modificationDate`, `volumeAvailableCapacityForImportantUsage`, and `FileManager.contentsOfDirectory` — all require manifest declarations since May 2024.
- **Entitlements:** macOS main + XPC share sandbox-off MLX entitlements. iOS app + extension share App Group + `increased-memory-limit` (production entitlements) or App Group only (local-device variants).
- **Credentials:** No Keychain, no HF token, no API keys in source. Model downloads hit public `https://huggingface.co` repos.
- **Persistence:** User prompts and metadata in plaintext `history.sqlite` under App Group / Application Support. Preferences via `@AppStorage` (autoplay, sidebar, reduce motion) — non-sensitive.
- **Network:** HTTPS defaults; `IOSModelDeliverySupport` rejects non-HTTPS catalog/artifact URLs in Release. No ATS plist exceptions.
- **Logging:** Engine paths use `Logger` with explicit `privacy: .public` for IDs/paths. Many `#if DEBUG` `print()` calls; no token/password logging found.
- **iOS App Group:** `Sources/iOSSupport/Services/AppPaths.swift` roots data at shared container `…/Vocello/`; real-device bootstrap fails fast if container missing (`IOSAppBootstrap.swift:124-128`).

---

## Security Posture

| Metric | Value |
|--------|-------|
| Hardcoded credentials | 0 |
| Privacy Manifest status | **MISSING** (0 declared, ≥4 API categories used) |
| Token storage | N/A (prefs only in UserDefaults) |
| Network transport | HTTPS_ONLY |
| Logging hygiene | **MIXED** (Logger redaction in engine; ~50 DEBUG `print()` elsewhere) |
| ATT compliance | N/A |
| Export compliance | **MISSING** |
| Entitlement scope | **BROAD** (intentional MLX macOS exceptions; iOS App Group justified) |
| **Posture** | **GAPS** |

---

## Issues by Severity

### CRITICAL — Missing Privacy Manifest (App Store rejection)

**Files:** all shipping targets — `Sources/Info.plist`, `Sources/iOS/Info.plist`, `Sources/iOSEngineExtension/Info.plist`, `Sources/QwenVoiceEngineService/Info.plist`; `project.yml` (no `PrivacyInfo.xcprivacy` resource)

**Issue:** No `PrivacyInfo.xcprivacy` exists anywhere in the repo. Apple requires a first-party manifest for apps/extensions using Required Reason APIs.

**Evidence (undeclared APIs in use):**

| API category | Example locations |
|--------------|-------------------|
| UserDefaults | `Sources/Services/AppPaths.swift:109`, `Sources/iOSSupport/Services/IOSAppDefaults.swift:6`, `@AppStorage` in `SettingsView.swift`, `RootView.swift` |
| System boot time | `Sources/QwenVoiceCore/NativeTelemetry.swift:23`, `MLXTTSEngine.swift:1507`, `HuggingFaceDownloader.swift:177` |
| File timestamp | `Sources/QwenVoiceCore/AudioPreparation.swift:688`, `DocumentIO.swift:183` |
| Disk space | `Sources/iOSSupport/Services/IOSModelDeliverySupport.swift:312-313` |

**Impact:** App Store Connect rejects iOS (and Mac App Store) uploads; privacy report incomplete.

**Fix:** Add `Sources/PrivacyInfo.xcprivacy` (and copy/link into each target via `project.yml`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>CA92.1</string></array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategorySystemBootTime</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>35F9.1</string></array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>C617.1</string></array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>E174.1</string></array>
        </dict>
    </array>
</dict>
</plist>
```

Embed in `VocelloiOS`, `VocelloEngineExtension`, `QwenVoice`, and `QwenVoiceEngineService`. Verify bundled SPM frameworks (GRDB, MLXSwift, SwiftHuggingFace) ship their own manifests at archive time.

---

### CRITICAL — Required Reason APIs used without declaration (compound)

**Phase:** 4 (compound with missing manifest)

**Issue:** Same as above — guaranteed Connect rejection when combined with active Required Reason API usage.

**Fix:** Same manifest work; validate with `xcodebuild -exportArchive` privacy report or App Store Connect “Privacy” tab after upload.

---

### HIGH — Missing export compliance declaration

**Files:** `Sources/Info.plist`, `Sources/iOS/Info.plist`, `Sources/iOSEngineExtension/Info.plist`

**Issue:** `CryptoKit` is imported for SHA-256 integrity checks (`HuggingFaceDownloader.swift:1`, `DocumentIO.swift:1`, `ModelAssets.swift:1`, `IOSModelDeliverySupport.swift:1`, others) but no `ITSAppUsesNonExemptEncryption` key is set.

**Impact:** App Store Connect blocks submission pending manual export questionnaire (2–3 day delay).

**Fix:** Add to each app/extension Info.plist (hashing-only = exempt):

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

---

### HIGH — iOS user content not excluded from iCloud backup

**Files:** `Sources/iOS/QVoiceiOSApp.swift:331-333`, `Sources/iOSSupport/Services/DatabaseService.swift:23`

**Issue:** Model download directories call `excludeFromBackup`, but `outputs/`, `voices/`, `history.sqlite`, and `cache/` under the App Group do not. `history.sqlite` stores full generation `text` (user prompts) in plaintext.

**Impact:** User prompts, cloned voice metadata, and generated audio may enter encrypted iCloud device backups — conflicts with “stays on your iPhone” marketing and privacy nutrition expectations.

**Fix:** After creating App Group directories, mark user-data paths:

```swift
for url in [AppPaths.outputsDir, AppPaths.voicesDir, AppPaths.appSupportDir.appendingPathComponent("history.sqlite")] {
    try? IOSModelDeliverySupport.excludeFromBackup(url)
}
```

Document in App Store privacy labels that data is on-device only and not collected by the developer.

---

### HIGH — App Group shared container lacks explicit file protection

**Files:** `Sources/iOSSupport/Services/AppPaths.swift:31-35`, `Sources/iOSSupport/Services/DatabaseService.swift:25`

**Issue:** Sensitive data (prompts, reference audio, outputs) lives in the shared App Group accessible to both `VocelloiOS` and `VocelloEngineExtension`. No `NSFileProtectionComplete` (or `completeUntilFirstUserAuthentication`) is applied at directory creation.

**Impact:** Data readable while device is locked if another entitled process in the group is compromised; broader exposure than single-process storage.

**Fix:** Apply protection when creating directories:

```swift
try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
```

Keep App Group (required for extension architecture); tighten protection instead of removing sharing.

---

### HIGH — macOS sandbox disabled (accepted risk — document for review)

**File:** `Sources/QwenVoice.entitlements:5-10`

**Issue:** `com.apple.security.app-sandbox = false` plus unsigned-memory and library-validation bypass.

**Impact:** macOS app has full user-process privileges — expected for MLX but increases blast radius vs sandboxed apps. Not an App Store Mac sandbox app profile.

**Fix:** No code change required for MLX. For distribution: document in privacy policy; keep hardened runtime; avoid loading untrusted dylibs; consider notarization + Gatekeeper as primary gate (already in release pipeline).

---

### MEDIUM — NSLog emits filesystem paths (macOS DEBUG migration)

**File:** `Sources/Services/AppPaths.swift:90-92`

**Issue:** `NSLog("AppPaths: migrated legacy data folder %@ -> %@", legacyURL.path, newURL.path)` logs full Application Support paths.

**Impact:** Paths visible in Console / sysdiagnose; may reveal username layout.

**Fix:** Gate behind `#if DEBUG`, switch to `Logger` with `privacy: .private` for path components, or log only folder names.

---

### MEDIUM — DEBUG `print()` logging without privacy annotations

**Files:** ~50 occurrences, e.g. `ExtensionEngineCoordinator.swift:282`, `QVoiceiOSApp.swift:108-112`, `DatabaseService.swift:33`, `IOSModelDeliveryActor.swift:644-741`

**Issue:** Many `#if DEBUG` prints duplicate structured `Logger` output without `privacy:` levels. Not leaking tokens today, but paths and error strings are public in Console.

**Impact:** Debug/device runs may expose internal paths in sysdiagnose attachments.

**Fix:** Prefer existing `Logger` calls; remove redundant `print()` or wrap paths with `privacy: .private`. Keep performance prints behind DEBUG (already mostly gated).

---

### MEDIUM — DEBUG diagnostic JSONL writes filesystem paths

**File:** `Sources/QwenVoiceCore/MLXTTSEngine.swift:332-374, 1462-1524`

**Issue:** `#if DEBUG` `NativeDiagnosticEventJSONLWriter` records `preparedDirectory.path`, `sourceDirectory.path`, etc. Does **not** log user prompt text (diagnostics use `textLength` only — `NativeEngineRuntime.swift:997`).

**Impact:** Local diagnostic pulls may contain paths; acceptable for dev if run-id gated, but treat artifacts as sensitive.

**Fix:** Redact path prefixes to relative components under App Support; ensure Release/TestFlight strips writer (already `#if DEBUG` gated).

---

### MEDIUM — No certificate pinning for Hugging Face downloads

**Files:** `Sources/Services/HuggingFaceDownloader.swift:470-483`, `Sources/iOS/IOSModelDeliveryActor.swift:275-288`

**Issue:** `URLSession` uses system trust store only; no `URLSessionDelegate` pinning.

**Impact:** MITM could substitute model weights on hostile networks (supply-chain risk for ML artifacts, not user credentials).

**Fix:** Optional hardening: pin Hugging Face ISRG / Let’s Encrypt roots or use certificate/public-key pinning for `huggingface.co` in model delivery paths. Lower priority than manifest work.

---

### MEDIUM — Prompt prefix in streaming chunk metadata

**Files:** `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:163-164, 1130`, `Sources/SharedSupport/Services/GenerationPersistence.swift:52`

**Issue:** First 40 characters of user text used as `previewTitle` / chunk `title`.

**Impact:** Short prompt snippets may appear in in-memory events, UI, or crash reports if chunk metadata is serialized.

**Fix:** Use non-content title (e.g. mode + request ID) in engine events; keep text preview UI-only from local DB.

---

### MEDIUM — Incomplete backup exclusion on macOS user data

**File:** `Sources/Services/AppPaths.swift` (no backup exclusion)

**Issue:** macOS Debug/Release stores prompts and voices under `~/Library/Application Support/QwenVoice*` with no `NSURLIsExcludedFromBackupKey`.

**Impact:** Time Machine / iCloud Backup may include TTS history and voice clones.

**Fix:** Mirror iOS `excludeFromBackup` helper for macOS subtrees or document that macOS backups include local data.

---

### LOW — No app-switcher snapshot hardening for composer

**File:** `Sources/iOS/QVoiceiOSApp.swift:119-135`

**Issue:** `scenePhase` handler manages memory/runtime only; no `.privacySensitive()` or overlay when inactive.

**Impact:** Multitasking snapshot may show in-progress prompts.

**Fix:** Apply `.privacySensitive()` to composer / or blur content on `.inactive` if product requires it.

---

### LOW — macOS entitlements broaden code-injection surface

**File:** `Sources/QwenVoice.entitlements:7-10`, `Sources/QwenVoiceEmbeddedRuntime.entitlements:5-8`

**Issue:** `allow-unsigned-executable-memory` + `disable-library-validation` paired with sandbox off.

**Impact:** Expected for MLX JIT; increases reviewer scrutiny.

**Fix:** Document justification in App Review notes; keep entitlements minimal (already scoped to MLX targets).

---

### LOW — iOS Simulator fallback writes outside App Group

**File:** `Sources/iOSSupport/Services/AppPaths.swift:55`

**Issue:** When App Group unavailable (Simulator), falls back to `managedAppSupportDir` (`Library/Application Support/Q-Voice`).

**Impact:** Simulator-only; real device bootstrap rejects missing container (`IOSAppBootstrap.swift:124-128`). No production issue.

**Fix:** None required; keep fail-fast on device.

---

## Privacy Manifest Checklist

| API Category | Found in Code | Declared in Manifest | Status |
|--------------|---------------|----------------------|--------|
| UserDefaults | Yes | No | **MISSING** |
| FileTimestamp | Yes | No | **MISSING** |
| SystemBootTime | Yes | No | **MISSING** |
| DiskSpace | Yes | No | **MISSING** |
| ActiveKeyboards | No | — | OK |
| IDFV / tracking | No | — | OK |

---

## @AppStorage / UserDefaults Review

| Key / usage | File | Sensitive? | Verdict |
|-------------|------|------------|---------|
| `autoPlay`, `outputDirectory` | `SettingsView.swift:32-33` | No | OK |
| `QwenVoice.PreferSpeedEverywhere`, per-mode variant | `TTSModel.swift:111-153` | No | OK |
| Sidebar / cloning voice ID | `ContentView.swift:126-129` | No | OK |
| Onboarding, reduce motion/transparency | `IOSAppDefaults.swift`, `RootView.swift` | No | OK |

No tokens, passwords, or API keys in `@AppStorage` or `UserDefaults`.

---

## Entitlements Review

| File | Notable keys | Notes |
|------|--------------|-------|
| `Sources/QwenVoice.entitlements` | sandbox **false**, unsigned memory, no library validation, user-selected RW | **Intentional for MLX** |
| `Sources/QwenVoiceEmbeddedRuntime.entitlements` | unsigned memory, no library validation | XPC helper |
| `Sources/iOS/VocelloiOS.entitlements` | App Group, increased-memory-limit | Production iOS |
| `Sources/iOS/VocelloiOSLocalDevice.entitlements` | App Group only | Local device debug |
| `Sources/iOSEngineExtension/VocelloEngineExtension.entitlements` | App Group, increased-memory-limit | Matches app |
| `Sources/iOSEngineExtension/VocelloEngineExtensionLocalDevice.entitlements` | App Group only | Local device debug |

App Group identifier: `group.com.patricedery.vocello.shared` (`project.yml:270,319`). UI and extension entitlements align.

---

## ATS / Network

- No `NSAppTransportSecurity` entries in any Info.plist — system default (HTTPS required).
- All Hugging Face URLs use `https://` (`HuggingFaceDownloader.swift:471-472`, `qwenvoice_ios_model_catalog.json`).
- `IOSModelDeliverySupport.validateCatalogURL` / `validateArtifactURL` reject non-HTTPS when `allowsInsecureTransport == false` (default).

---

## iOS App Group Usage

| Concern | Status |
|---------|--------|
| Shared ID in app + extension entitlements | OK |
| Fail-fast if container missing on device | OK (`IOSAppBootstrap.swift:124-128`) |
| Data scoped to `Vocello/` subtree | OK (`AppPaths.swift`) |
| No parallel shared UserDefaults for model state | OK (per `docs/reference/privacy-storage.md`) |
| User content backup / file protection | **Gaps** (see HIGH issues) |
| Microphone permission | OK — `NSMicrophoneUsageDescription` in `Sources/iOS/Info.plist:39-40`; recording in main app only |

---

## Recommendations

### Immediate (submission blockers)

1. Add `PrivacyInfo.xcprivacy` to all four shipping targets with reason codes for UserDefaults, system uptime, file timestamps, and disk space.
2. Set `ITSAppUsesNonExemptEncryption = false` in iOS app, extension, and macOS Info.plists.
3. Verify SPM dependency privacy manifests in archive export before TestFlight upload.

### Short-term (privacy hardening)

4. Exclude `outputs/`, `voices/`, and `history.sqlite` from iCloud backup on iOS (and consider macOS).
5. Apply `FileProtectionType.completeUntilFirstUserAuthentication` to App Group data directories.
6. Reduce DEBUG path logging (`NSLog` / `print`) or migrate to `Logger` with `.private` privacy.

### Long-term (defense in depth)

7. Optional TLS pinning for Hugging Face model delivery.
8. Replace prompt-derived chunk titles with non-content identifiers in engine events.
9. Consider `.privacySensitive()` on iOS composer for multitasking snapshots.

---

*Audit scope: `Sources/**/*.swift`, `Sources/**/*.entitlements`, `Sources/**/Info.plist`. Excluded tests, previews, mocks, docs, third-party examples. Sandbox-off macOS entitlements noted as intentional MLX requirement.*
