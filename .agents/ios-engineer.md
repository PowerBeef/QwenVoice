# iOS Engineer

> Agent role for the `VocelloiOS` target, `Sources/iOS/`, `Sources/iOSSupport/`, and the
> iOS-side pieces of `Sources/SharedSupport`.

## Boundaries

**Owns:**
- `Sources/iOS/` (SwiftUI, sheets, studio canvas, coordinators, app bootstrap)
- `Sources/iOSSupport/`
- `Sources/SharedSupport/` when the change is iOS-specific (e.g. `IOSScrollView`, iOS player VM behavior)
- iOS entitlements, Info.plist, App Store submission materials

**Does NOT own:**
- macOS app / XPC service (`.agents/macos-engineer.md`)
- Engine core / MLX internals (`.agents/backend-mlx.md`)
- Build scripts / CI / release (`.agents/release-qa-engineer.md`)

**Consults:**
- `docs/ARCHITECTURE.md` §6 (iOS request lifecycle)
- `docs/reference/{ios-app-guide,ios-device-testing,ios-engine-optimization,ios-appstore-submission,ios-increased-memory-entitlement-request}.md`
- Root `AGENTS.md` (Hard rules) + [`.cursor/rules/project-structure.mdc`](../.cursor/rules/project-structure.mdc)

## Required pre-read

Before changing iOS UI or behavior, read:
1. `docs/reference/ios-app-guide.md` — app map + how to drive it in tests.
2. `docs/reference/ios-device-testing.md` § Daily workflow + § Lane map — on-device lanes and burn-in safety.
3. `docs/ARCHITECTURE.md` §6 — iOS request lifecycle, cooperative cancel, memory posture (batch was removed from iOS 2026-07-02).
4. `docs/reference/ios-engine-optimization.md` if the change affects generation performance or memory.

## Tools and skills (Cursor)

- **Apple framework APIs / iOS 26 / post-cutoff APIs** → **`user-axiom`** MCP
  (`axiom_get_catalog` → `axiom_read_skill` for `axiom-apple-docs`, `axiom-swiftui`,
  `axiom-concurrency`, …).
- **Crash / profile / test debugging** → **`user-axiom`** MCP tools and agents:
  `axiom_xcsym_crash`, `axiom_xcprof_analyze`, `axiom_xclog_*`; or `axiom_get_agent` for
  `crash-analyzer`, `performance-profiler`, `test-runner`, `test-debugger`.
- **Shell tool / scripts** — the only way to build/test/run real-engine iOS work on device:
  - `scripts/ios_device.sh preflight`
  - `scripts/ios_device.sh models check`
  - `scripts/ios_device.sh test` / `ui-test`
  - `scripts/ios_device.sh profile [spec]`
  - `scripts/ios_device.sh crashes`
  - `scripts/ios_device.sh review [--baseline]`
  - `scripts/ios_device.sh gate`
- **Read-only investigation** → Task tool with `subagent_type: "explore"`.
- **On-device only** — `user-xcodebuildmcp` profile `ios-device` + runtime `deviceId`, but prefer
  `scripts/ios_device.sh`. See [`.xcodebuildmcp/config.yaml`](../.xcodebuildmcp/config.yaml).

## Build / test commands

```sh
# On-device only. Never use the iOS Simulator.
scripts/ios_device.sh preflight
scripts/ios_device.sh models check    # tier matrix (install all Speed models on device once)
scripts/ios_device.sh test            # default: Smoke + Sheet + ColdGeneration
scripts/ios_device.sh ui-test --download  # opt-in OnDeviceDownload (uninstalls pro_custom)
scripts/ios_device.sh gate

# Foundation compile-safety (compile only, no simulator launch)
./scripts/build_foundation_targets.sh ios
```

## Invariants (do not regress)

- **All iOS work is on-device only.** The MLX engine runs in-process on Metal, which the
  iOS Simulator cannot host — all UI tests, generation, and download validation happen on a
  paired physical device via `scripts/ios_device.sh`.
- **Cooperative cancel.** iOS does not conform to `ActiveGenerationCancellable`. The generate
  flow must discard the result on `Task.isCancelled` so cancelled takes never land in History.
- **Use `IOSScrollView`.** iOS vertical scroll surfaces use `IOSScrollView`, not raw `ScrollView`.
- **Mode color pairs with icon/label/position.** No color-only signal.
- **Honor Reduce Motion / Reduce Transparency.** Animations route through `appAnimation` /
  `AppLaunchConfiguration.performAnimated`; Liquid Glass falls back to solid fills when reduced
  transparency is enabled.
- **`increased-memory-limit` entitlement.** Required for model load headroom. Do not remove.
- **Supported hardware gate.** `IOSDeviceSupport.isSupportedHardware` enforces iPhone 15 Pro+.
- **No batch on iOS** (removed 2026-07-02, maintainer decision — dead UI, native engine unsupported, Jetsam risk; macOS batch unaffected). Re-adding requires a sequential-streaming design validated on device.
- **Clone load profile.** Respect `.fullCapabilities` vs `.iOSProductionDefault`
  (`.withoutCloneEncoders`) depending on the entitled memory limit.
- **`accessibilityIdentifier`s are stable.** Values like `voicesRow_*`, `textInput_*`,
  `studioChip_*` must survive refactors.

## Common mistakes

- Running **any** iOS work on the Simulator. All iOS tests and real generation/download must
  run on a paired device.
- Rethrowing `CancellationError` early inside `MLXTTSEngine.generate`.
- Using raw `ScrollView` instead of `IOSScrollView`.
- Making color the only indicator for mode or state.
- Forgetting that the iOS app deliberately does **not** link the macOS XPC stack.
