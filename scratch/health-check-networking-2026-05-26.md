# Networking Audit — QwenVoice (2026-05-26)

## Summary

**Health: MODERN** — no deprecated reachability/socket APIs; HuggingFace traffic uses HTTPS `URLSession` only. iOS model delivery is the stronger path (`waitsForConnectivity`, background session, host allowlist, transient retry). macOS `HuggingFaceDownloader` is functional but less resilient (no connectivity wait, no transient retry, weaker user-facing errors).

| Severity | Count |
|----------|------:|
| CRITICAL | 0 |
| HIGH     | 1 |
| MEDIUM   | 6 |
| LOW      | 3 |

**Top actions:** Add HTTP status checks to iOS download completion; align macOS downloader with iOS connectivity/retry settings; map `NSURLError` codes to actionable copy on failure.

---

## Networking Architecture Map

- **Primary stack:** `URLSession` only — no `NWConnection`, `SCNetworkReachability`, BSD sockets, or legacy stream APIs in `Sources/`.
- **macOS:** `HuggingFaceDownloader` — default foreground session + `URLSessionDownloadDelegate`; sequential per-file downloads to `https://huggingface.co` with Range/resume-data support; API tree listing via `session.data(from:)`.
- **iOS:** `IOSModelDeliveryActor` — ephemeral catalog session + **background** download session (`URLSessionConfiguration.background`); delegate bridged to actor via `[weak self]` closures; persisted install state + resume data on disk.
- **Background delivery:** `IOSAppDelegate.handleEventsForBackgroundURLSession` → `IOSModelDeliveryBackgroundEventRelay` → `IOSModelInstallerViewModel.handleBackgroundEventsCompletion` → `resumeBackgroundEventsIfNeeded()` / `completeIfPending()`.
- **Reachability:** None pre-connect. iOS uses `waitsForConnectivity = true` (correct modern pattern). macOS does not.
- **TLS:** All production endpoints HTTPS; iOS validates host allowlist (`huggingface.co` + overrides) in `IOSModelDeliverySupport`.

---

## Networking Health Score

| Metric | Value |
|--------|-------|
| Deprecated API count | 0 |
| Anti-pattern count | 0 CRITICAL, 1 HIGH, 6 MEDIUM, 3 LOW |
| Network transition coverage | iOS ~90% (waitsForConnectivity + retry codes); macOS ~20% (resume/range only) |
| TLS coverage | 100% production (HTTPS + iOS host allowlist) |
| Connection cleanup | Both platforms cancel tasks; iOS completes background handler when idle |
| **Health** | **MODERN** (macOS resilience gap vs iOS) |

---

## Issues by Severity

### HIGH / HIGH — iOS download completion ignores HTTP status codes

**File:** `Sources/iOS/IOSModelDeliveryActor.swift:219-233`, `663-682`

**Phase:** 2 (Detection) + 3 (Completeness)

**Issue:** `IOSModelDeliveryDownloadDelegate.urlSession(_:downloadTask:didFinishDownloadingTo:)` moves the temp file and calls `onFinished` without inspecting `HTTPURLResponse.statusCode`. macOS `HuggingFaceDownloader` rejects non-200/206 in the same delegate method (`921-930`).

**Impact:** 403/404/500 responses can be staged as model artifacts; failure surfaces late at SHA-256 verify as `fileHashMismatch`, wasting bandwidth/time and showing a confusing integrity error instead of a network/server message.

**Fix:**

```swift
func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
) {
    if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
       !(200...299).contains(status), status != 206 {
        onCompleted?(downloadTask.taskIdentifier, downloadTask.taskDescription,
            IOSModelDeliveryError.invalidCatalog("Download failed with HTTP \(status)."))
        return
    }
    // ... existing move + onFinished
}
```

---

### MEDIUM / HIGH — macOS downloader lacks transient network retry

**File:** `Sources/Services/HuggingFaceDownloader.swift:646-728`, `951-969`

**Phase:** 3 (Completeness) + 4 (Compound with missing waitsForConnectivity)

**Issue:** Per-file failures propagate immediately. iOS `shouldRetry` (`775-792`) retries `NSURLErrorNetworkConnectionLost`, timeouts, offline, DNS, etc. (max 3/file). macOS has resume-data on cancel but no automatic retry on transient errors.

**Impact:** Brief Wi‑Fi/cellular drops fail entire multi-GB repo downloads on macOS; iOS recovers automatically.

**Fix:** Port iOS retry policy into `downloadTemporaryFile` or outer file loop — catch retryable `URLError` codes, backoff, retry with resume data when present:

```swift
private func shouldRetry(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .networkConnectionLost, .timedOut, .notConnectedToInternet,
         .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
         .cannotLoadFromNetwork, .internationalRoamingOff, .callIsActive:
        return true
    default:
        return false
    }
}
```

---

### MEDIUM / HIGH — macOS session missing `waitsForConnectivity`

**File:** `Sources/Services/HuggingFaceDownloader.swift:481-483`

**Phase:** 3 (Completeness)

**Issue:** Default `URLSessionConfiguration` fails fast when offline. iOS sets `waitsForConnectivity = true` on both catalog and background sessions (`276`, `282`).

**Impact:** macOS Settings → Model Downloads can show immediate failure in Airplane Mode or flaky Wi‑Fi instead of waiting/resuming when connectivity returns.

**Fix:**

```swift
config.waitsForConnectivity = true
config.timeoutIntervalForRequest = 60
config.allowsExpensiveNetworkAccess = true
config.allowsConstrainedNetworkAccess = true
```

---

### MEDIUM / MEDIUM — Failure paths expose raw system error strings

**File:** `Sources/iOS/IOSModelDeliveryActor.swift:808`, `Sources/ViewModels/ModelManagerViewModel.swift:578-583`, `Sources/Services/HuggingFaceDownloader.swift:41-42`

**Phase:** 3 (Completeness)

**Issue:** `failActiveInstall` publishes `error.localizedDescription` (often `"The Internet connection appears to be offline."` or POSIX text). macOS `fileDownloadFailed` wraps underlying `localizedDescription`. Interrupted/retry phases have friendly copy; terminal `.failed` does not.

**Impact:** Support noise and poor UX on App Store review scenarios (network errors are common).

**Fix:** Map `URLError` / retry exhaustion to stable product copy:

```swift
private func userFacingMessage(for error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "No internet connection. Check your network and try again."
        case .timedOut:
            return "The download timed out. Try again on a stable connection."
        // ...
        default: break
        }
    }
    if error is IOSModelDeliveryError { return error.localizedDescription }
    return "Download failed. Try again."
}
```

---

### MEDIUM / MEDIUM — Background session identifier not validated in app delegate

**File:** `Sources/iOS/IOSModelDeliveryBackgroundEvents.swift:20-33`

**Phase:** 3 (Completeness)

**Issue:** `handleEventsForBackgroundURLSession identifier:` forwards all identifiers to the model-delivery relay without comparing to `IOSModelDeliveryConfiguration.backgroundSessionIdentifier`.

**Impact:** If another background session is added later, wrong handler may run or completion may fire prematurely. Low risk today (single session) but violates background-session contract.

**Fix:**

```swift
func application(..., handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    let expected = IOSModelDeliveryConfiguration.default().backgroundSessionIdentifier
    guard identifier == expected else {
        completionHandler()
        return
    }
    // existing relay logic
}
```

---

### MEDIUM / MEDIUM — macOS lacks download host allowlist (iOS has one)

**File:** `Sources/Services/HuggingFaceDownloader.swift:471-472`, `Sources/iOSSupport/Services/IOSModelDeliverySupport.swift:351-372`

**Phase:** 3 (Completeness)

**Issue:** macOS trusts contract/repo strings and builds URLs directly to `huggingface.co`. iOS restricts catalog and artifact hosts via `allowedHosts` and rejects non-HTTPS URLs.

**Impact:** Compromised contract or env override on macOS could point downloads at arbitrary HTTPS endpoints. SHA-256 catches wrong bytes but not exfiltration to attacker CDN if hashes were also compromised.

**Fix:** Add optional host allowlist to `HuggingFaceDownloader` init (default `["huggingface.co"]`); validate resolve/API URLs before task creation.

---

### MEDIUM / LOW — macOS API listing has no retry

**File:** `Sources/Services/HuggingFaceDownloader.swift:610-619`

**Phase:** 3 (Completeness)

**Issue:** `listFiles` single-shot `session.data(from:)`; transient failure aborts entire repo download before any files start.

**Fix:** Wrap in small retry loop with backoff for retryable `URLError` codes (same set as iOS).

---

### LOW / HIGH — macOS request timeout not configured

**File:** `Sources/Services/HuggingFaceDownloader.swift:482`

**Phase:** 3 (Completeness)

**Issue:** Only `timeoutIntervalForResource = 3600` set; `timeoutIntervalForRequest` defaults to 60s but not explicit. iOS sets request timeouts explicitly (60 catalog / 300 background).

**Fix:** Set `timeoutIntervalForRequest` explicitly alongside resource timeout for predictable stall behavior.

---

### LOW / MEDIUM — iOS background session missing resource timeout

**File:** `Sources/iOS/IOSModelDeliveryActor.swift:281-288`

**Phase:** 3 (Completeness)

**Issue:** Background config sets `timeoutIntervalForRequest = 300` but not `timeoutIntervalForResource`. Large model files may rely on system defaults.

**Fix:** `backgroundConfig.timeoutIntervalForResource = 86_400` (or app-appropriate ceiling) for multi-hour model downloads.

---

### LOW / LOW — Persisted install state write failures only logged in DEBUG

**File:** `Sources/iOS/IOSModelDeliveryActor.swift:913-922`

**Phase:** 3 (Completeness)

**Issue:** `savePersistedState` swallows errors except `#if DEBUG` print. Crash mid-download could lose resume metadata silently in Release.

**Fix:** Surface persistence failure to snapshot (`.failed`) or retry with OSLog signpost in Release.

---

## Phase 4 — Compound Findings

| Combination | Severity | Notes |
|-------------|----------|-------|
| macOS no `waitsForConnectivity` + no transient retry | **MEDIUM→HIGH** | Double penalty on flaky networks vs iOS |
| iOS missing HTTP check + SHA-256 verify only | **HIGH** | Wrong artifact staged before integrity gate |
| Raw `localizedDescription` on failure + no reachability pre-check | **MEDIUM** | Users see system strings; iOS interrupted copy is good but terminal failure is not |

No CRITICAL compounds (no deprecated reachability, blocking sockets, missing TLS, or hardcoded IPs).

---

## Positive Findings

- **No legacy APIs:** Zero `SCNetworkReachability`, `CFSocket`, `NSStream`, BSD sockets, manual DNS.
- **No reachability-before-connect anti-pattern:** Downloads start directly; iOS defers via `waitsForConnectivity`.
- **iOS background pipeline:** Relay stores early completion handlers; actor calls `completeIfPending()` only when idle (`842-849`); stale task errors filtered (`714-735`).
- **iOS supply-chain boundary:** HTTPS + host allowlist on catalog and artifact URLs (`351-372`).
- **Resume support:** Both platforms persist URLSession resume data / partial files.
- **Cancellation:** macOS `TaskCancellationBox` writes resume data on cancel; iOS cancels matching tasks by model ID.
- **Integrity:** SHA-256 verification on both platforms after download.
- **Delegate retain cycles:** iOS uses `[weak self]` in all delegate closures (`290-319`).

---

## Recommendations

### Immediate
1. Add HTTP status validation to iOS `IOSModelDeliveryDownloadDelegate` (HIGH).
2. Set `waitsForConnectivity = true` on macOS `HuggingFaceDownloader` session config.

### Short-term
3. Port iOS transient-error retry policy to macOS per-file download loop.
4. Replace raw `localizedDescription` in failure snapshots with mapped user copy.
5. Validate background session identifier in `IOSAppDelegate`.

### Long-term
6. Shared `ModelDownloadNetworkPolicy` (retry codes, timeouts, host allowlist) used by macOS and iOS paths.
7. Consider `URLSessionConfiguration.background` on macOS for very large downloads if app backgrounding during Settings downloads is common (optional; macOS less constrained).

---

## Files Reviewed

| File | Role |
|------|------|
| `Sources/Services/HuggingFaceDownloader.swift` | macOS HuggingFace repo downloader |
| `Sources/iOS/IOSModelDeliveryActor.swift` | iOS background model delivery actor |
| `Sources/iOS/IOSModelDeliveryBackgroundEvents.swift` | Background URLSession app delegate wiring |
| `Sources/iOSSupport/Services/IOSModelDeliverySupport.swift` | Catalog validation, URLs, host allowlist |
| `Sources/iOS/IOSModelInstallerViewModel.swift` | UI bridge + background completion handler |
| `Sources/iOS/IOSAppBootstrap.swift` | Registers background event relay at launch |
| `Sources/ViewModels/ModelManagerViewModel.swift` | macOS download orchestration + error surfacing |
