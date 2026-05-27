# Storage Audit — Vocello (QwenVoice)

**Date:** 2026-05-26  
**Scope:** `AppPaths` (macOS `Sources/Services/`, iOS `Sources/iOSSupport/`), App Group `group.com.patricedery.vocello.shared`, models/outputs/voices/cache trees, backup exclusions, file protection, Debug vs Release app-support roots.

## Summary

| Severity | Count |
|----------|------:|
| CRITICAL | 1 |
| HIGH | 4 |
| MEDIUM | 5 |
| LOW | 2 |

**Storage health: FRAGILE**

One CRITICAL data-loss path (iOS clone reference recordings in `tmp/`). macOS has no `isExcludedFromBackup` anywhere — multi-GB model weights and download staging will inflate iCloud/device backups. iOS excludes models/downloads/staging only; regenerable `cache/` subtrees under the App Group are still backed up. File protection is never set explicitly (system default only). macOS Debug/Release/local-Release isolation is solid; iOS shares one App Group container across build configs.

**Strengths:** App Group entitlements wired for app + engine extension; iOS model delivery applies backup exclusion and disk-space checks; macOS legacy `QwenVoice` → `QwenVoice-Debug` migration; history/voice deletion removes associated audio and clone-prompt dirs; MLX scratch dirs use defer cleanup.

---

## Storage Map

| Platform | Root | Subtrees |
|----------|------|----------|
| **macOS Debug** | `~/Library/Application Support/QwenVoice-Debug/` | `models/`, `outputs/{mode}/`, `voices/`, `cache/stream_sessions`, `history.sqlite`, `.qwenvoice-downloads/` (sibling of each model folder) |
| **macOS Release (installed)** | `~/Library/Application Support/QwenVoice/` | same |
| **macOS Release (repo-local)** | `~/Library/Application Support/QwenVoice-Release-Local/<release-data-id>/` | same + isolated `UserDefaults` suite |
| **Override (both)** | `QWENVOICE_APP_SUPPORT_DIR` env var | replaces root |
| **iOS (primary)** | App Group `group.com.patricedery.vocello.shared` → `Vocello/` | `models/`, `downloads/`, `outputs/`, `voices/`, `cache/*`, `history.sqlite`, `diagnostics/` (Debug) |
| **iOS (fallback)** | `~/Library/Application Support/Q-Voice/` | used when App Group container is nil |

**Backup exclusion:** iOS only — `models/`, `downloads/`, `staging/` via `IOSModelDeliverySupport.excludeFromBackup`. macOS: none.  
**File protection:** none explicit; all writes use `.atomic` or default.  
**Secrets:** no auth tokens on disk; UserDefaults holds small scalars only.  
**App Group:** required and present for iOS engine extension; app passes `AppPaths.appSupportDir.path` to extension initialize.

---

## Issues by Severity

### CRITICAL — Recorded clone reference clips live in `tmp/`

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/Overlays/IOSRecordingOverlay.swift:369-375` |
| **Also** | `Sources/iOS/IOSGenerationModeViews.swift:1117-1129`, `1327-1353` |
| **Issue** | `IOSReferenceClipRecorder.makeOutputURL()` writes user recordings to `FileManager.default.temporaryDirectory/voice-clone-references/`. `applyRecordedReferenceAudio(at:)` stores the tmp path in `draft.referenceAudioPath` without copying to `AppPaths.importedReferenceAudioDir`. Generation reads the tmp path directly. Imported files *do* materialize via `LocalDocumentIO.importReferenceAudio`. |
| **Impact** | iOS purges `tmp/` on low storage, updates, and between sessions. A user who records a 10–20 s reference clip and returns later (or backgrounds under storage pressure) can lose the clip silently; generation fails or clones the wrong/missing audio. |
| **Fix** | Materialize recordings immediately on "Use this clip", mirroring the file-importer path: |

```swift
// IOSGenerationModeViews.swift — applyRecordedReferenceAudio
private func applyRecordedReferenceAudio(at url: URL) {
    do {
        let imported = try ttsEngine.importReferenceAudio(from: url)
        draft.referenceAudioPath = imported.materializedPath
        // … clear saved voice, reset transcript as today …
    } catch {
        coordinator.fail("Couldn't save the reference audio: \(error.localizedDescription)")
    }
}
```

Or copy inside `IOSReferenceClipRecorder.stopAndSave()` to `AppPaths.importedReferenceAudioDir` before returning the URL.

---

### HIGH — macOS model weights not excluded from iCloud backup

| Field | Detail |
|-------|--------|
| **File** | `Sources/Services/AppStartupCoordinator.swift:7-26` |
| **Also** | `Sources/Services/AppPaths.swift:59-61` |
| **Issue** | `models/` (multi-GB Hugging Face artifacts) lives under Application Support with no `isExcludedFromBackup`. macOS has zero calls to `isExcludedFromBackup` in `Sources/`. |
| **Impact** | Re-downloadable model files consume iCloud backup quota; can block device backups on constrained plans. |
| **Fix** | After `createDirectory` in `setupAppSupport()`, exclude regenerable trees: |

```swift
private static func excludeFromBackup(_ url: URL) {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = url
    try? mutable.setResourceValues(values)
}

// In setupAppSupport(), after mkdir:
excludeFromBackup(QwenVoiceApp.appSupportDir.appendingPathComponent("models"))
excludeFromBackup(QwenVoiceApp.appSupportDir.appendingPathComponent("cache"))
// Also exclude .qwenvoice-downloads parent when present
```

---

### HIGH — macOS HF download staging (`.qwenvoice-downloads/`) not excluded from backup

| Field | Detail |
|-------|--------|
| **File** | `Sources/Services/HuggingFaceDownloader.swift:875-879`, `496-502` |
| **Issue** | Staging root is `models/../.qwenvoice-downloads/<model-folder>/` under Application Support. Partial files and resume data are regenerable but backed up. |
| **Impact** | Active or interrupted downloads can add hundreds of MB–GB to backups unnecessarily. |
| **Fix** | Set `isExcludedFromBackup = true` on the `.qwenvoice-downloads` directory at creation time (same helper as above). |

---

### HIGH — iOS regenerable `cache/` subtrees under App Group not excluded from backup

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOS/QVoiceiOSApp.swift:307-333` |
| **Also** | `Sources/iOSSupport/Services/AppPaths.swift:82-100` |
| **Issue** | `setupAppSupport()` excludes `models/`, `downloads/`, `staging/` only. `cache/imported_references`, `cache/prepared_audio`, `cache/normalized_clone_refs`, `cache/stream_sessions`, `cache/native_mlx` are created but not excluded. These live in App Group Application Support (not system `Caches/`), so they participate in backup. |
| **Impact** | MLX hub cache, stream-session scratch, and prepared-audio intermediates inflate iCloud backup size; some are recomputable. |
| **Fix** | Extend startup exclusions: |

```swift
let regenerable = [
    AppPaths.appSupportDir.appendingPathComponent("cache"),
    AppPaths.importedReferenceAudioDir,
    AppPaths.preparedAudioDir,
    AppPaths.normalizedCloneReferenceDir,
    AppPaths.streamSessionsDir,
    AppPaths.nativeMLXCacheDir,
]
for dir in regenerable { try? IOSModelDeliverySupport.excludeFromBackup(dir) }
```

**Note:** `imported_references` holds user-imported clips — exclude only if product policy treats them as re-importable; otherwise leave backed up.

---

### HIGH — Compound: macOS models + staging + no backup exclusion

| Field | Detail |
|-------|--------|
| **Phase** | Compound (Pattern 2 + auto-growing cache) |
| **Issue** | Installed models (1.7B × 2 variants × 3 modes possible) plus active `.qwenvoice-downloads` staging, all in backed-up Application Support, no exclusion. |
| **Impact** | Silent iCloud quota exhaustion; failed device backups. |
| **Fix** | Apply HIGH fixes above; consider moving download staging under `Library/Caches/` instead. |

---

### MEDIUM — No explicit file protection on disk writes

| Field | Detail |
|-------|--------|
| **File** | Representative: `Sources/QwenVoiceCore/MLXTTSEngine.swift:1535`, `Sources/iOS/IOSModelDeliveryActor.swift:876`, `Sources/Services/HuggingFaceDownloader.swift` (all `.atomic` writes) |
| **Issue** | No use of `.completeFileProtection`, `FileProtectionType`, or `URLResourceValues.fileProtectionKey`. Default is `.completeUntilFirstUserAuthentication`. |
| **Impact** | Clone reference WAVs, saved voices, and generated outputs are readable after first unlock; acceptable for most TTS use, but weaker than Keychain for sensitive voice biometrics. |
| **Fix** | For clone reference and saved-voice writes, add `.completeFileProtection` where device-locked confidentiality matters: |

```swift
try data.write(to: url, options: [.atomic, .completeFileProtection])
```

Prefer Keychain only for true secrets (tokens); file protection is sufficient for local audio artifacts.

---

### MEDIUM — macOS model downloads lack disk-space preflight

| Field | Detail |
|-------|--------|
| **File** | `Sources/Services/HuggingFaceDownloader.swift:488-509` |
| **Also** | `Sources/iOSSupport/Services/IOSModelDeliverySupport.swift:307-323` (iOS *has* check) |
| **Issue** | iOS `ensureSufficientDiskSpace` runs before model delivery; macOS `HuggingFaceDownloader.downloadRepo` creates staging dirs and downloads without checking available capacity. |
| **Impact** | Mid-download `ENOSPC` failures leave partial staging state; poor UX on full disks. |
| **Fix** | Port `ensureSufficientDiskSpace` (or equivalent) to macOS before `downloadRepo`, using `totalBytes` from the file list. |

---

### MEDIUM — iOS App Group fallback leaves orphan data in `Q-Voice/`

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOSSupport/Services/AppPaths.swift:20-28`, `45-55` |
| **Issue** | When `sharedContainerDir` is nil (misconfigured entitlements, pre-group builds), data lands in `Application Support/Q-Voice/`. When App Group later works, app reads the group container; old `Q-Voice/` data is invisible. |
| **Impact** | Silent "lost" models/history after entitlement fix; extension still can't see fallback data. |
| **Fix** | On first successful App Group resolution, one-shot migrate `managedAppSupportDir` → `sharedContainerDir/Vocello/` if group was empty and fallback has content (mirror macOS `migrateLegacyDataIfNeeded`). |

---

### MEDIUM — iOS has no Debug/Release app-support split (unlike macOS)

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOSSupport/Services/AppPaths.swift:41-56` vs `Sources/Services/AppPaths.swift:7-57` |
| **Issue** | macOS uses `QwenVoice-Debug` / `QwenVoice` / `QwenVoice-Release-Local/<id>`. iOS Debug and Release share the same App Group container (`Vocello/`). |
| **Impact** | Debug builds on device pollute TestFlight/user data; no clean signoff sandbox on iPhone. Documented for macOS only in `docs/reference/privacy-storage.md`. |
| **Fix** | Optional: append `-Debug` segment under App Group for `#if DEBUG` builds, or document as intentional. Low urgency if device testing uses env override `QVOICE_APP_SUPPORT_DIR`. |

---

### MEDIUM — No bounded eviction policy for on-disk cache directories

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOSSupport/Services/AppPaths.swift:94-100`, `Sources/QwenVoiceCore/NativeEngineRuntime.swift` (memory trim only) |
| **Issue** | Memory-pressure trim clears MLX/runtime state but no file-system cap on `cache/stream_sessions`, `cache/native_mlx`, or macOS `cache/stream_sessions`. |
| **Impact** | Container grows until OS low-storage events; unpredictable purge timing. |
| **Fix** | Add LRU or age-based cleanup for stream-session dirs (macOS host already removes on teardown — verify idle sessions). Cap `native_mlx` hub cache size if vendor API allows. |

---

### LOW — iOS Debug diagnostics under App Group not excluded from backup

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOSSupport/Services/IOSDeviceDiagnosticsRecorder.swift:58-60`, `Sources/QwenVoiceCore/MLXTTSEngine.swift:1500-1522` |
| **Issue** | `diagnostics/<run-id>/` written under App Group app support (Debug only). No backup exclusion. |
| **Impact** | Negligible in Release; Debug device runs may add JSONL to backups. |
| **Fix** | `try? IOSModelDeliverySupport.excludeFromBackup(diagnosticsDirectory)` in recorder init. |

---

### LOW — User-generated outputs/voices intentionally backed up

| Field | Detail |
|-------|--------|
| **File** | `Sources/iOSSupport/Services/AppPaths.swift:74-79`, `Sources/Services/AppPaths.swift:63-68` |
| **Issue** | `outputs/` and `voices/` have no backup exclusion. |
| **Impact** | User TTS artifacts count against iCloud quota — likely desired for data portability. |
| **Fix** | None unless product policy changes. Document in `privacy-storage.md`. |

---

## Storage Health Score

| Metric | Value |
|--------|-------|
| Locations in use | App Support (both), App Group (iOS), tmp (iOS recordings), no Documents/iCloud Drive |
| Backup-exclusion coverage | iOS: 3/8+ regenerable dirs (~38%); macOS: 0/N (0%) |
| File-protection coverage | 0/N writes explicit (0%) |
| Sensitive data in Keychain | N/A — no credentials on disk |
| App Group usage | Required ✓ / present ✓ |
| tmp/ usage | Mixed — MLX scratch OK; iOS recordings persistence-intent ✗ |
| UserDefaults discipline | Small scalars only ✓ |
| **Health** | **FRAGILE** |

---

## Recommendations

### Immediate (CRITICAL)

1. Materialize iOS recorded reference clips out of `tmp/` into `cache/imported_references/` (or call `importReferenceAudio`) before storing `referenceAudioPath`.

### Short-term (HIGH)

2. Add macOS `isExcludedFromBackup` for `models/`, `cache/`, and `.qwenvoice-downloads/`.
3. Extend iOS startup backup exclusions to regenerable `cache/` subtrees (policy decision on `imported_references`).
4. Consider moving macOS HF staging from Application Support to `Library/Caches/`.

### Long-term (MEDIUM)

5. Add macOS disk-space preflight to `HuggingFaceDownloader`.
6. iOS one-shot migration from `Q-Voice/` fallback to App Group container.
7. Evaluate iOS Debug storage isolation for device signoff.
8. Add optional `.completeFileProtection` on voice/reference audio writes.
9. Document backup intent for `outputs/` and `voices/` in `privacy-storage.md`.

### Test plan

- Record iOS clone reference → force-quit → relaunch → verify path still exists and generation succeeds.
- Install macOS model → inspect `NSURLIsExcludedFromBackupKey` on `models/` and `.qwenvoice-downloads/`.
- Fill disk to &lt;256 MB free → verify macOS download fails gracefully before partial staging.
- Delete history row and saved voice → confirm WAV, transcript, and `.clone_prompt` dirs removed.
- Debug macOS build → confirm data under `QwenVoice-Debug/`; repo-local Release → fresh `QwenVoice-Release-Local/<id>/`.

---

## Cross-Auditor Notes

- **icloud-auditor:** No `forUbiquityContainerIdentifier` usage — local-only storage ✓.
- **security-privacy-scanner:** No tokens/passwords written to files ✓.
- **database-schema-auditor:** `history.sqlite` lives in app support root (backed up); GRDB migrations present ✓.
