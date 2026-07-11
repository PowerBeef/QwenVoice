# macOS Engineer

> Agent role for the macOS app target `QwenVoice`, the XPC stack
> (`QwenVoiceNative`, `QwenVoiceEngineService`, `QwenVoiceEngineSupport`), and the
> macOS SwiftUI/AppKit layers.

## Boundaries

**Owns:**
- `Sources/QwenVoiceNative/`
- `Sources/QwenVoiceEngineService/`
- `Sources/QwenVoiceEngineSupport/`
- `Sources/Services/` (macOS app-level services)
- `Sources/ViewModels/`, `Sources/Views/`, `Sources/Models/` (macOS SwiftUI)
- `Sources/QwenVoiceApp.swift`, `Sources/ContentView.swift`
- macOS entitlements and `Sources/Info.plist`

**Does NOT own:**
- Engine core / MLX internals (`.agents/backend-mlx.md`)
- iOS app (`.agents/ios-engineer.md`)
- Build scripts / CI / release (`.agents/release-qa-engineer.md`)

**Consults:**
- `docs/ARCHITECTURE.md` §3 (runtime architecture), §5 (macOS request lifecycle), §8 (macOS app surfaces)
- `docs/reference/{macos-app-guide,macos-testing,macos-release-qa,macos-permissions,privacy-storage}.md`
- Root `AGENTS.md` (Hard rules) + [`docs/project-map.html`](../docs/project-map.html)

## Required pre-read

Before changing macOS app or XPC code, read:
1. `docs/reference/macos-app-guide.md` — app map + test driving.
2. `docs/reference/macos-testing.md` — macOS lanes and the XPC dimension.
3. `docs/ARCHITECTURE.md` §5 — macOS request lifecycle and XPC wire protocol.
4. `docs/reference/privacy-storage.md` if the change touches on-disk data locations.

## Tools and skills (Codex)

- **Shell tool / scripts** (the source of truth for the local loop):
  - `./scripts/build.sh build|run|cli`
  - `scripts/macos_test.sh test|gate|crashes|debug|logs|profile`
  - `scripts/macos_test.sh models check|ensure|install`
  - `scripts/ui_test.sh macos smoke|benchmark`
  - `./scripts/regenerate_project.sh` after `project.yml` changes
- Use OpenAI Build macOS Apps skills for SwiftUI/AppKit structure, build/run/debug, test triage,
  telemetry, signing, and packaging after reading the selected skill. Shell scripts remain the
  source of truth for gates.
- Build iOS Apps supplies the one shared XcodeBuildMCP server. Build macOS Apps may consume it for
  optional macOS project discovery, build, run, and debug operations: call
  `session_show_defaults`, select the `macos` profile, and return to repository scripts for final
  verification. Never configure a second XcodeBuildMCP server.
- Use authoritative Apple documentation where current framework behavior matters and the GitHub
  integration for repository/CI context.
- XCUITest is the sole autonomous macOS app UI driver. Run the smoke and benchmark lanes
  only for explicitly requested frontend acceptance. Missing UI evidence never blocks committing,
  pushing, opening a pull request, merging, ordinary CI, or release packaging.

## Build / test commands

```sh
# Fast local loop
./scripts/build.sh build
./scripts/build.sh run

# macOS smoke tests (models ensure symlinks QwenVoice-Debug/models → canonical store)
scripts/macos_test.sh models ensure   # one-time per machine
scripts/macos_test.sh test
# Explicit frontend acceptance only:
scripts/ui_test.sh macos smoke
scripts/ui_test.sh macos benchmark
scripts/macos_test.sh gate            # deterministic macOS platform gate

# XPC lifecycle / crash isolation is included in the deterministic test and gate lanes.
scripts/macos_test.sh test

```

## Invariants (do not regress)

- **XPC event forwarding drains `engine.events` off `MainActor`.** In `EngineServiceHost`,
  drain on `Task.detached(.utility)`; only `lastPublishedEvent` hops to `MainActor`.
- **Service retirement is expected.** When `shutdownWhenIdle` retires the service, the client
  marks it `expectedRetirement` — no error UI, no auto-reconnect. It lazily relaunches on next use.
- **Terminating sessions remain terminating.** `EngineServiceHost.isStillTerminatingSession`
  must treat `activeSession == nil` as still terminating so teardown cleanup cannot be skipped
  after the active session clears.
- **Single envelope method.** The XPC wire protocol is one `perform(_:withReply:)` carrying an
  `EngineCommand`. Do not add ad-hoc XPC methods.
- **Liquid Glass is gated.** `QW_UI_LIQUID` compilation condition controls Liquid Glass surfaces.
- **Reduce Motion / Reduce Transparency.** All animation routes through `appAnimation` /
  `AppLaunchConfiguration.performAnimated`; reduced-transparency fallback uses solid fills.
- **No color-only signal.** Mode colors pair with icon, label, or position cue.
- **`accessibilityIdentifier`s are stable.** Values like `voicesRow_*`, `textInput_*`,
  `studioChip_*` must survive refactors.
- **No hidden test UI.** XCUITest observes genuine visible controls. Put test-only code in the UI
  test target; do not add invisible state markers, seeded app state, or generic `#if DEBUG` app
  behavior.
- **App sandbox disabled.** `Sources/QwenVoice.entitlements` keeps sandbox off for MLX; do not
  re-enable it.

## Common mistakes

- Editing `QwenVoice.xcodeproj/project.pbxproj` directly. Always edit `project.yml` and run
  `./scripts/regenerate_project.sh`.
- Performing XPC event draining on `MainActor`.
- Showing error UI when the XPC service retires normally.
- Blocking the main thread during model load or generation.
- Adding a generic `#if DEBUG` behavior fork instead of runtime `DebugMode.isEnabled` or a narrowly
  named test-target condition.
