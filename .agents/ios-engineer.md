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
- Root `AGENTS.md` §7 (hard rules)

## Required pre-read

Before changing iOS UI or behavior, read:
1. `docs/reference/ios-app-guide.md` — app map + how to drive it in tests.
2. `docs/reference/ios-device-testing.md` §3 — on-device lanes and burn-in safety.
3. `docs/ARCHITECTURE.md` §6 — iOS request lifecycle, cooperative cancel, batch semantics, memory posture.
4. `docs/reference/ios-engine-optimization.md` if the change affects generation performance or memory.

## Tools and skills

- **`xcodebuildmcp`** skill (`Skill` tool) — for XcodeBuildMCP conventions (macOS only; iOS stays on-device).
- **`axiom`** skill (`Skill` tool) + Axiom agents — for crash analysis, profiling, and test debugging.
- **Bash scripts** — the only way to build/test/run on iOS:
  - `scripts/ios_device.sh preflight`
  - `scripts/ios_device.sh test` / `ui-test`
  - `scripts/ios_device.sh profile [spec]`
  - `scripts/ios_device.sh crashes`
  - `scripts/ios_device.sh review [--baseline]`
  - `scripts/ios_device.sh gate`
- **`mcp__xcodebuildmcp__*`** — allowed for macOS scheme work only; **never** for `VocelloiOS` simulator work.

## Build / test commands

```sh
# On-device only. Never use the iOS Simulator.
scripts/ios_device.sh preflight
scripts/ios_device.sh ui-test
scripts/ios_device.sh gate

# Foundation compile-safety (compile only, no simulator launch)
./scripts/build_foundation_targets.sh ios
```

## Invariants (do not regress)

- **On-device only.** The iOS Simulator is unsupported. The engine runs in-process on Metal.
  All validation happens on a paired physical device via `scripts/ios_device.sh`.
- **Cooperative cancel.** iOS does not conform to `ActiveGenerationCancellable`. The generate
  flow must discard the result on `Task.isCancelled` so cancelled takes never land in History.
- **Use `IOSScrollView`.** iOS vertical scroll surfaces use `IOSScrollView`, not raw `ScrollView`.
- **Mode color pairs with icon/label/position.** No color-only signal.
- **Honor Reduce Motion / Reduce Transparency.** Animations route through `appAnimation` /
  `AppLaunchConfiguration.performAnimated`; Liquid Glass falls back to solid fills when reduced
  transparency is enabled.
- **`increased-memory-limit` entitlement.** Required for model load headroom. Do not remove.
- **Supported hardware gate.** `IOSDeviceSupport.isSupportedHardware` enforces iPhone 15 Pro+.
- **Batch = sequential streaming.** `IOSBatchGenerationCoordinator` streams each line to keep
  per-item peak flat; the model stays warm across items within the idle-unload window.
- **Clone load profile.** Respect `.fullCapabilities` vs `.iOSProductionDefault`
  (`.withoutCloneEncoders`) depending on the entitled memory limit.
- **`accessibilityIdentifier`s are stable.** Values like `voicesRow_*`, `textInput_*`,
  `studioChip_*` must survive refactors.

## Common mistakes

- Using `mcp__xcodebuildmcp__build_run_sim`, `snapshot_ui`, `list_sims`, or `screenshot` for
  iOS. These are off-limits for `VocelloiOS`.
- Rethrowing `CancellationError` early inside `MLXTTSEngine.generate`.
- Using raw `ScrollView` instead of `IOSScrollView`.
- Making color the only indicator for mode or state.
- Forgetting that the iOS app deliberately does **not** link the macOS XPC stack.
