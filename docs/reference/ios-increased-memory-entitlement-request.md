# iOS Increased Memory Entitlement Request Packet

This packet is the source of truth for requesting Apple's increased-memory entitlement for the iOS app and engine extension.

**Hub:** [`ios-shipping.md`](ios-shipping.md) · **Tracker (submission status):** [`ios-increased-memory-entitlement-tracker.md`](ios-increased-memory-entitlement-tracker.md)

> **Note:** the copy-ready request text, identifiers, and Apple-portal steps below are the enduring value of this packet and are unaffected. The on-device evidence-capture and verify recipes (which used the removed `ios_device.sh` / `ios_device_proof_matrix.sh` scripts) are **not currently runnable** — those scripts were removed in the testing-harness cleanup and a device deploy/proof path would need to be re-established before capturing fresh on-device evidence.

Apple capability: `com.apple.developer.kernel.increased-memory-limit`

Apple docs:

- [Request access to managed capabilities](https://developer.apple.com/help/account/capabilities/capability-requests)
- [Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)
- [Increased Memory Limit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
- [os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory)

## Apple Requirements We Need To Satisfy

Apple treats this as a managed capability: the entitlement must be assigned to the developer account before it can be enabled for an App ID. For an organization team, the Account Holder submits the request. After approval, enable the capability for each App ID and regenerate any provisioning profiles that use those App IDs.

Apple describes the entitlement as a Boolean value for apps whose core features may perform better with a higher memory limit on supported devices. Apple also says apps must behave correctly if extra memory is unavailable. Use `os_proc_available_memory()` as advisory process-headroom data; it reports bytes the current app process may allocate before hitting its current memory limit, not device-wide free RAM.

## Identifiers To Request

Request and enable the entitlement for both identifiers:

- iOS app: `com.patricedery.vocello`
- iOS engine extension: `com.patricedery.vocello.engine-extension`

The extension identifier is critical because real MLX generation runs in the ExtensionKit engine process, not only in the containing app.

Related identifier:

- App Group: `group.com.patricedery.vocello.shared`

## Copy-Ready Request Text

Use this as the main justification in Apple's Capability Requests form:

```text
Vocello is a private, on-device text-to-speech app for iPhone. Its core feature is local neural speech generation using Qwen3-TTS model packages with MLX on Apple Silicon. The app downloads user-selected model artifacts and performs speech generation locally; prompt text, reference audio, generated audio, and voice data are not uploaded to a server for generation.

We are requesting com.apple.developer.kernel.increased-memory-limit for both the containing iOS app (com.patricedery.vocello) and the engine ExtensionKit extension (com.patricedery.vocello.engine-extension). The engine extension is the process that hosts the MLX runtime and performs the app's core generation work.

Our current hardware diagnostics use os_proc_available_memory(), task_vm_info, and Metal allocation metrics for both the app and extension processes. Without the increased-memory entitlement, the engine extension reports critically low process headroom before model admission on supported iPhone hardware. The app correctly blocks model loading in this state rather than risking jetsam. This confirms that the blocker is the extension process memory limit, not lack of general device RAM.

Vocello already includes guardrails for responsible memory use: model admission checks, combined app-plus-extension diagnostics, streaming-first iOS generation, disabled inline PCM preview payloads by default, bounded extension event streams, explicit MLX/Qwen3 cache trimming, hard trim and full unload paths, active-generation cancellation under critical pressure, and fallback behavior when additional memory is unavailable.

The entitlement is needed so supported devices can run the app's core on-device speech generation feature reliably while preserving the privacy benefit of local inference. If additional memory is unavailable, Vocello still behaves safely: the app remains usable for UI, model downloads, diagnostics, and user data access, and generation is blocked with a user-visible memory error instead of forcing a risky allocation.
```

## Short Form Answers

Use these if Apple's form asks focused questions.

App or feature requiring entitlement:

```text
Vocello's on-device neural text-to-speech generation. The MLX runtime runs in the engine ExtensionKit extension com.patricedery.vocello.engine-extension.
```

Why the entitlement is necessary:

```text
The iOS model packages include large local Qwen3-TTS and speech-tokenizer artifacts. Even before model admission, diagnostics show the engine extension can have critically low os_proc_available_memory() headroom under the default process limit. The app therefore blocks generation to avoid jetsam. The entitlement is required for supported devices to run the core local generation feature.
```

How the app behaves without additional memory:

```text
The app does not bypass memory admission. It keeps UI, model download, ExtensionKit transport, and diagnostics usable, but blocks generation when extension process headroom is critical. During active generation, critical pressure cancels generation through the existing cancellation path and requests a full unload.
```

How memory is measured:

```text
Vocello samples app and engine-extension memory with os_proc_available_memory(), task_vm_info physical footprint/resident/compressed metrics, and Metal allocation metrics. Diagnostics compute implied process limit as physical footprint plus os_proc_available_memory() headroom.
```

How system impact is limited:

```text
iOS generation is streaming-first; inline PCM preview payloads are skipped by default; extension events are bounded; model admission blocks critical pressure; Qwen3 tokenizer, speech-tokenizer, prefix, and decoder caches are explicitly cleared on iPhone hard-trim/full-unload paths; active generation is canceled under critical memory pressure.
```

## Repo Evidence Map

Current identity and entitlement source of truth:

- `config/apple-platform-capability-matrix.json` declares both iOS bundle IDs, App Group, and the required increased-memory entitlement.
- `project.yml` signs `VocelloiOS` as `com.patricedery.vocello` and `VocelloEngineExtension` as `com.patricedery.vocello.engine-extension`.
- `Sources/iOS/VocelloiOS.entitlements` and `Sources/iOSEngineExtension/VocelloEngineExtension.entitlements` include `com.apple.developer.kernel.increased-memory-limit` for approved-profile builds.
- `Sources/iOS/VocelloiOSLocalDevice.entitlements` and `Sources/iOSEngineExtension/VocelloEngineExtensionLocalDevice.entitlements` intentionally omit the restricted entitlement for ordinary local Debug installs.

Process measurement and guardrails:

- `Sources/QwenVoiceCore/IOSMemoryMetricsBridge.m` calls `os_proc_available_memory()` on physical iOS.
- `Sources/QwenVoiceCore/IOSMemorySnapshot.swift` stores app/extension headroom, physical footprint, resident size, compressed memory, Metal allocation, and implied process limit.
- `Sources/iOSEngineExtension/VocelloEngineExtensionHost.swift` handles `captureMemorySnapshot` inside the extension process.
- `Sources/iOS/TTSEngineStore.swift` combines app and extension snapshots, blocks model admission under per-process critical or aggregate critical pressure, records peak generation context, cancels active generation under critical pressure, and requests full unload.
- `Sources/iOSSupport/Services/IOSDeviceDiagnosticsRecorder.swift` persists memory-context JSONL with app/extension headroom, footprint, implied process limit, aggregate pressure band, and `likelyEntitlementBlocked`.

Memory-reduction behavior already implemented:

- `Sources/iOS/IOSGenerationModeViews.swift` builds Custom, Design, and Clone generation requests with `shouldStream: true`.
- `Sources/QwenVoiceCore/SemanticTypes.swift` skips inline streaming preview PCM by default on physical iOS.
- `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift` emits `previewAudio: nil` when preview data is skipped.
- `Sources/QwenVoiceCore/NativeEngineRuntime.swift` clears Qwen3 caches on iPhone unload/hard-trim/full-unload paths.
- `third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` exposes `Qwen3TTSMemoryCaches.clearAll()`.

Validation scripts:

- Entitlement presence on the signed app + extension must be re-checked once a device deploy/verify path is re-established (the prior `ios_device.sh verify-entitlements` helper was removed in the testing-harness cleanup).
- `scripts/verify_ios_release_archive.sh` verifies archive/export entitlements for both app and extension (still in-repo; verifies a manually-produced archive).

## Evidence To Capture Before Submitting

Use one clean Debug run without `--enable-increased-memory-limit` to show the current safe-blocking behavior:

```sh
scripts/ios_device.sh start --run-id entitlement-request-evidence
# In iPhone Mirroring, attempt a short Custom generation so admission samples the extension.
scripts/ios_device.sh pull --run-id entitlement-request-evidence
scripts/ios_device.sh verify-entitlements --run-id entitlement-request-evidence
```

Extract the extension process evidence:

```sh
jq -r '
  select(.engineExtensionImpliedProcessLimitBytes != null)
  | [
      .recordedAt,
      .event,
      .reason,
      (.engineExtensionPhysFootprintMB | floor),
      (.engineExtensionAvailableHeadroomMB | floor),
      (.engineExtensionImpliedProcessLimitMB | floor),
      .pressureBand,
      .aggregatePressureBand,
      .likelyEntitlementBlocked,
      .entitlementBlockedReason
    ]
  | @tsv
' build/Debug/ios-device/runs/entitlement-request-evidence/pulled/diagnostics/memory-contexts.jsonl
```

Attach or quote the relevant rows showing:

- extension snapshot is present,
- extension available headroom is critically low,
- implied extension process limit is low,
- aggregate pressure is not the root cause,
- `likelyEntitlementBlocked=true`,
- `model_admission_blocked` is recorded instead of a crash.

Also attach or quote:

```sh
cat build/Debug/ios-device/runs/entitlement-request-evidence/entitlements-check.json
```

This should show the ordinary Debug build is missing the restricted entitlement, which is expected before Apple approval.

## Portal Steps

1. Sign in to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) as Account Holder.
2. Open `com.patricedery.vocello`.
3. Open the Capability Requests tab.
4. Request Increased Memory Limit / `com.apple.developer.kernel.increased-memory-limit`.
5. Repeat for `com.patricedery.vocello.engine-extension`.
6. After approval, open each App ID's Capabilities tab and enable Increased Memory Limit.
7. Regenerate development and distribution provisioning profiles for both identifiers.
8. Build and verify locally:

```sh
scripts/ios_device.sh build --enable-increased-memory-limit --run-id entitlement-enabled-check
scripts/ios_device.sh verify-entitlements --enable-increased-memory-limit --run-id entitlement-enabled-check
```

Pass condition:

```text
app:       com.patricedery.vocello com.apple.developer.kernel.increased-memory-limit=true
extension: com.patricedery.vocello.engine-extension com.apple.developer.kernel.increased-memory-limit=true
status:    entitlement-ready
```

Then run the first entitled baseline:

```sh
scripts/ios_device.sh start --run-id memory-entitled-baseline --enable-increased-memory-limit
```

Before attempting long Custom, Design, or Clone runs, verify the extension's initial `engineExtensionAvailableHeadroomMB` and `engineExtensionImpliedProcessLimitMB` increased materially versus the unentitled baseline.

## Things Not To Claim

- Do not claim the entitlement will be available on every iPhone or iPad model.
- Do not claim the app will use all available memory.
- Do not say generation will be attempted even under critical pressure.
- Do not submit the request only as a performance optimization. Frame it as enabling the core local generation feature on supported devices while preserving safe fallback behavior.
- Do not request only the containing app entitlement; the engine extension needs the entitlement too.
