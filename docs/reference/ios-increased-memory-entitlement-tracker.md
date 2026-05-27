# iOS increased-memory entitlement tracker

Status board for Apple's managed capability `com.apple.developer.kernel.increased-memory-limit`.

**Hub:** [`ios-shipping.md`](ios-shipping.md) · **Request copy:** [`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md) · **Proof:** [`ios-device-proof-matrix.md`](ios-device-proof-matrix.md)

## Current status (2026-05-27)

| Milestone | Status | Notes |
|---|---|---|
| Request packet ready | **Done** | Copy in entitlement-request doc |
| Submit `com.patricedery.vocello` | **Ready — Account Holder** | Portal: Identifiers → Capability Requests |
| Submit `com.patricedery.vocello.engine-extension` | **Ready — Account Holder** | Same form; extension is critical path |
| Apple case / approval | **Pending** | Record case number below when submitted |
| Enable capability on both App IDs | **Blocked** | After approval |
| Regenerate dev + distribution profiles | **Blocked** | Must include both bundle IDs + App Group |
| `verify-entitlements --enable-increased-memory-limit` | **Blocked** | Expect `entitlement-ready` |
| Unentitled baseline build (iPhone 17 Pro) | **Done** | Run `iphone17pro-unentitled-baseline` — `status: entitlement-missing` (expected) |
| Entitled device proof matrix | **Blocked** | Entitlement pending; then `./scripts/ios_device_proof_matrix.sh --phase entitled` |

### Submission log (fill in when submitted)

| Field | Value |
|---|---|
| Submitted by | |
| Submitted on (UTC) | |
| Apple case / reference | |
| App ID approved | ☐ `com.patricedery.vocello` |
| Extension ID approved | ☐ `com.patricedery.vocello.engine-extension` |
| Profiles regenerated on | |
| First `entitlement-ready` verify run | |

## Portal checklist (Account Holder)

1. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) → Team `FK2D8X36G2`.
2. Identifier `com.patricedery.vocello` → **Capability Requests** → request **Increased Memory Limit**.
3. Identifier `com.patricedery.vocello.engine-extension` → repeat.
4. After approval: **Capabilities** tab on each ID → enable **Increased Memory Limit**.
5. Regenerate provisioning profiles used by local device Debug and TestFlight distribution.
6. Verify locally:

```sh
scripts/ios_device.sh build --enable-increased-memory-limit --run-id entitlement-enabled-check
scripts/ios_device.sh verify-entitlements --enable-increased-memory-limit --run-id entitlement-enabled-check
```

Pass:

```text
app:       com.patricedery.vocello com.apple.developer.kernel.increased-memory-limit=true
extension: com.patricedery.vocello.engine-extension com.apple.developer.kernel.increased-memory-limit=true
status:    entitlement-ready
```

7. Run entitled baseline: `./scripts/ios_device_proof_matrix.sh --phase entitled`

## Evidence for the request (unentitled baseline)

Attach or quote from the latest unentitled run:

```sh
./scripts/ios_device.sh doctor --run-id entitlement-request-evidence
# After a successful device build (device must be available to Xcode):
./scripts/ios_device.sh verify-entitlements --run-id entitlement-request-evidence
cat build/Debug/ios-device/runs/entitlement-request-evidence/entitlements-check.json
```

Expected before approval: entitlement **absent** in signed products; diagnostics show `likelyEntitlementBlocked=true` and `model_admission_blocked` instead of Jetsam.

Latest unentitled evidence (2026-05-27, **iPhone 17 Pro**):

```sh
cat build/Debug/ios-device/runs/iphone17pro-unentitled-baseline/entitlements-check.json
# status: entitlement-missing (expected before Apple approval)
```

After one Studio generation attempt on device, attach `scripts/ios_device.sh pull` output showing `model_admission_blocked` and/or `likelyEntitlementBlocked=true` if present.

## What not to do

- Do not enable `--enable-increased-memory-limit` in local builds until profiles include the approved capability (signing fails).
- Do not claim every iPhone model receives extra memory — Apple documents supported devices only.
- Do not frame the request as a pure performance tweak; core on-device TTS is blocked without extension headroom.
