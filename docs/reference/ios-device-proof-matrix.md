# iOS device proof matrix (MLX / memory)

Structured validation for on-device Qwen3-TTS. **Simulator does not run MLX.**

**Hub:** [`ios-shipping.md`](ios-shipping.md) · **Tracker milestones:** [`ios-increased-memory-entitlement-tracker.md`](ios-increased-memory-entitlement-tracker.md)

Orchestration: `./scripts/ios_device_proof_matrix.sh`

## Hardware matrix

| Device | Role | Status |
|---|---|---|
| iPhone 17 Pro (owned) | Active development / first entitled proof | Baseline build OK 2026-05-27 (`iphone17pro-unentitled-baseline`, `entitlement-missing`); entitled runs blocked on Apple approval |
| iPhone 15 Pro | Official minimum from shipping plan | **Not started** |

## Phases

### Phase 0 — Preflight (any time)

```sh
./scripts/ios_device.sh doctor
./scripts/check_ios_catalog.sh
```

Record run under `build/Debug/ios-device/runs/<run-id>/`.

**2026-05-27 notes (iPhone 17 Pro):**

- iOS 26.5 (23F77); signing team from `APPLE_TEAM_ID` / `QWENVOICE_DEVELOPMENT_TEAM` / `QVOICE_IOS_TEAM_ID`.
- Baseline build + verify OK: run `iphone17pro-unentitled-baseline` → `entitlement-missing` in `entitlements-check.json`.
- App installed/launched: run `iphone17pro-unentitled-ui` via `scripts/ios_device.sh start`.
- iPhone 15 Pro: not paired — repeat phases 3–4 on minimum hardware when available.

### Phase 1 — Unentitled baseline (expected safe block)

Prereq: successful `scripts/ios_device.sh build` (no `--enable-increased-memory-limit`).

```sh
./scripts/ios_device_proof_matrix.sh --phase baseline
```

Manual UI (iPhone Mirroring): Settings → confirm model **Ready** → Studio → Custom → generate once.

Pass criteria:

- `model_admission_blocked` in diagnostics **or** generation error with memory copy (not Jetsam of UI app).
- `likelyEntitlementBlocked=true` when extension headroom is low before load.
- `entitlements-check.json` shows increased-memory **false** or absent.

### Phase 2 — Entitled signing

Prereq: Apple approval + regenerated profiles.

```sh
scripts/ios_device.sh build --enable-increased-memory-limit --run-id entitlement-enabled-check
scripts/ios_device.sh verify-entitlements --enable-increased-memory-limit --run-id entitlement-enabled-check
```

Pass: `status: entitlement-ready` for app and extension.

### Phase 3 — Entitled generation matrix (iPhone 17 Pro)

```sh
./scripts/ios_device_proof_matrix.sh --phase entitled
scripts/ios_device.sh start --run-id memory-entitled-baseline --enable-increased-memory-limit
```

For each mode (Custom, Design, Clone) with installed Speed package:

1. Cold: force idle unload or fresh install → one medium prompt generation.
2. Warm: second generation within 30 s idle window.
3. `scripts/ios_device.sh pull` → inspect memory JSONL, `likelyEntitlementBlocked`, peak footprints.

Pass criteria (initial):

- No UI-process Jetsam during normal single-mode use.
- `model_admission_blocked` **absent** at idle after entitlement with background apps closed.
- `engineExtensionAvailableHeadroomMB` materially higher than unentitled baseline at admission time.
- Generation completes to history/output (streaming or final file per iOS playback policy).

### Phase 4 — Minimum device (iPhone 15 Pro)

Repeat phase 3 on **iPhone 15 Pro** before public “minimum device proven” claims.

```sh
./scripts/ios_device.sh start --device-name "iPhone 15 Pro" --enable-increased-memory-limit --run-id memory-15pro-baseline
```

### Phase 5 — Stress probes (Debug)

```sh
scripts/ios_device.sh start --force-band guarded
scripts/ios_device.sh start --force-band critical
```

Release build: confirm aggregate **guarded** blocks without env override ([`ios-memory-admission-policy.md`](ios-memory-admission-policy.md)).

## Phase 6 — 0.6B evaluation (conditional)

**Deferred (2026-05-27):** Do not add 0.6B to `qwenvoice_ios_model_catalog.json` until phase 3 fails on entitled 1.7B Speed after tuning.

If triggered:

1. Add Speed 0.6B entries per contract (mirror macOS artifact pins).
2. Re-run phase 3 cells; compare extension peak RSS and admission events.
3. Document quality tradeoff in `release-readiness.md`.

See `scratch/ios-06b-eval-deferred-2026-05-27.md` for rationale snapshot.

## Artifacts checklist

After each phase, archive under `build/Debug/ios-device/runs/<run-id>/`:

- [ ] `doctor.txt` / `run-manifest.json`
- [ ] `entitlements-check.json` (when built)
- [ ] `pull/` memory diagnostics + native events
- [ ] Mirroring screenshots for UI regressions (optional)

## Bench parity (optional, post-entitlement)

macOS uses `scripts/uitest.sh bench-step`; iOS has no Simulator MLX bench. For regression timing/RSS on device, define a small subset (e.g. custom cold/medium Speed) in a future maintainer script — not a CI gate.
