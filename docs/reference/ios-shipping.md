# iPhone shipping — MLX, memory, and entitlement

Entry point for on-device Qwen3-TTS on iPhone. **Simulator does not run MLX** ([`ios-simulator-testing.md`](ios-simulator-testing.md) is UI-only). Real hardware flows through [`ios-device-screen-mirror-testing.md`](ios-device-screen-mirror-testing.md) and `scripts/ios_device.sh`.

Policy context for the macOS-first milestone: [`release-readiness.md`](release-readiness.md) § iPhone Shipping Plan.

## Reading order

| Step | Document | When |
|---|---|---|
| 1 | [`ios-mlx-jetsam-feasibility.md`](ios-mlx-jetsam-feasibility.md) | Understand verdict, Jetsam posture, and what “smooth” means |
| 2 | [`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md) | Copy for Apple’s Capability Requests form |
| 3 | [`ios-increased-memory-entitlement-tracker.md`](ios-increased-memory-entitlement-tracker.md) | Track submission, approval, and profile regen |
| 4 | [`ios-device-proof-matrix.md`](ios-device-proof-matrix.md) | Run validation before/after entitlement (`scripts/ios_device_proof_matrix.sh`) |
| 5 | [`ios-memory-admission-policy.md`](ios-memory-admission-policy.md) | Release vs Debug admission and user-visible errors |

## Entitlements (two build flavors)

| Build | App entitlements | Extension entitlements |
|---|---|---|
| **Local device Debug** (default `ios_device.sh`) | `Sources/iOS/VocelloiOSLocalDevice.entitlements` | `Sources/iOSEngineExtension/VocelloEngineExtensionLocalDevice.entitlements` |
| **Shipping / TestFlight** (after Apple approval) | `Sources/iOS/VocelloiOS.entitlements` | `Sources/iOSEngineExtension/VocelloEngineExtension.entitlements` |

Both shipping entitlements files declare `com.apple.developer.kernel.increased-memory-limit`. Local device variants **omit** it so ordinary Debug installs still sign. Enable it only when profiles include the approved capability:

```sh
scripts/ios_device.sh build --enable-increased-memory-limit
scripts/ios_device.sh verify-entitlements --enable-increased-memory-limit
```

Capability matrix: `config/apple-platform-capability-matrix.json`.

## Critical path (maintainer checklist)

1. **Preflight** — `./scripts/ios_device_proof_matrix.sh --phase preflight` (doctor + catalog; fix DDI/Xcode pairing if build fails).
2. **Unentitled evidence** — `./scripts/ios_device_proof_matrix.sh --phase baseline` → attach `entitlements-check.json` + diagnostics showing safe `model_admission_blocked` / `likelyEntitlementBlocked` (not UI Jetsam).
3. **Submit entitlement** — Account Holder requests increased-memory for `com.patricedery.vocello` and `com.patricedery.vocello.engine-extension`; update tracker.
4. **Entitled verify** — `./scripts/ios_device_proof_matrix.sh --phase entitled` → `status: entitlement-ready`.
5. **Generation proof** — Custom, Design, Clone on **iPhone 17 Pro**, then **iPhone 15 Pro** (minimum); `scripts/ios_device.sh pull` after runs.
6. **TestFlight** — `scripts/release_ios_testflight.sh` after distribution profiles include the entitlement.

## Scripts

| Script | Role |
|---|---|
| `scripts/ios_device.sh` | Build, install, launch, mirror, pull, verify entitlements |
| `scripts/ios_device_proof_matrix.sh` | Phases: `preflight`, `baseline`, `entitled`, `stress` |
| `scripts/check_ios_catalog.sh` | Validates `qwenvoice_ios_model_catalog.json` |
| `scripts/release_ios_testflight.sh` | Archive/export (manual until CI job exists) |

## Code touchpoints

- Admission and messaging: `Sources/iOS/TTSEngineStore.swift`, `Sources/QwenVoiceCore/IOSMemorySnapshot.swift`
- Tier policy: `Sources/QwenVoiceCore/NativeMemoryPolicyResolver.swift`
- Extension host: `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift`
- Device diagnostics: `Sources/iOSSupport/Services/IOSDeviceDiagnosticsRecorder.swift`

## Deferred work (do not start early)

- **0.6B Speed on iOS catalog** — only if entitled 1.7B proof still fails ([`ios-device-proof-matrix.md`](ios-device-proof-matrix.md) § Phase 6). Internal note: `scratch/ios-06b-eval-deferred-2026-05-27.md`.
