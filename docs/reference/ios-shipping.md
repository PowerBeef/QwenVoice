# iPhone shipping — MLX, memory, and entitlement

Planning hub for on-device Qwen3-TTS on iPhone. **This work is deferred.** iPhone is compile-safe only on the current macOS-first track; the on-device deploy/proof/Simulator-UI testing tooling (`ios_device.sh`, `ios_device_proof_matrix.sh`, `release_ios_testflight.sh`, and the device/simulator/proof-matrix runbooks) was **removed in the testing-harness cleanup**. The command recipes those docs used no longer exist in the repo — resuming on-device iPhone work means re-establishing a device deploy/proof workflow first.

Policy context for the macOS-first milestone: [`release-readiness.md`](release-readiness.md) § iPhone Shipping Plan.

## Reading order

| Step | Document | When |
|---|---|---|
| 1 | [`ios-mlx-jetsam-feasibility.md`](ios-mlx-jetsam-feasibility.md) | Understand verdict, Jetsam posture, and what "smooth" means |
| 2 | [`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md) | Copy for Apple's Capability Requests form |
| 3 | [`ios-increased-memory-entitlement-tracker.md`](ios-increased-memory-entitlement-tracker.md) | Track submission, approval, and profile regen |
| 4 | [`ios-memory-admission-policy.md`](ios-memory-admission-policy.md) | Release vs Debug admission and user-visible errors |

## Entitlements (two build flavors)

The `.entitlements` files remain in the repo; only the device-driving scripts were removed.

| Build | App entitlements | Extension entitlements |
|---|---|---|
| **Local device Debug** | `Sources/iOS/VocelloiOSLocalDevice.entitlements` | `Sources/iOSEngineExtension/VocelloEngineExtensionLocalDevice.entitlements` |
| **Shipping / TestFlight** (after Apple approval) | `Sources/iOS/VocelloiOS.entitlements` | `Sources/iOSEngineExtension/VocelloEngineExtension.entitlements` |

Both shipping entitlements files declare `com.apple.developer.kernel.increased-memory-limit`. Local device variants **omit** it so ordinary Debug installs still sign. It can only be enabled once Apple approves the capability and profiles include it. Capability matrix: `config/apple-platform-capability-matrix.json`.

## Critical path (deferred — conceptual)

The on-device proof workflow below is **not currently runnable** (its scripts were removed). It is retained as the intended sequence to re-establish when iPhone on-device work resumes:

1. Re-establish a device build/install/launch + diagnostics path.
2. Capture **unentitled** evidence on device showing safe `model_admission_blocked` / `likelyEntitlementBlocked` (not UI Jetsam).
3. Submit the increased-memory entitlement request for `com.patricedery.vocello` and `com.patricedery.vocello.engine-extension` (Account Holder); update the tracker.
4. After approval, regenerate profiles and verify both signed products carry the entitlement.
5. Generation proof — Custom, Design, Clone on **iPhone 17 Pro**, then **iPhone 15 Pro** (minimum).
6. TestFlight, after a distribution profile + archive/export path is re-established.

## Remaining iPhone scripts

| Script | Role |
|---|---|
| `scripts/build_foundation_targets.sh ios` | Compile-safety build (the only automated iOS gate) |
| `scripts/check_ios_catalog.sh` | Validates `qwenvoice_ios_model_catalog.json` |

## Code touchpoints

- Admission and messaging: `Sources/iOS/TTSEngineStore.swift`, `Sources/QwenVoiceCore/IOSMemorySnapshot.swift`
- Tier policy: `Sources/QwenVoiceCore/NativeMemoryPolicyResolver.swift`
- Extension host: `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift`
- Device diagnostics: `Sources/iOSSupport/Services/IOSDeviceDiagnosticsRecorder.swift`

## Deferred work (do not start early)

- **Re-establish the device deploy/proof workflow** before any on-device validation claim.
- **0.6B Speed on iOS catalog** — only if entitled 1.7B proof still fails.
