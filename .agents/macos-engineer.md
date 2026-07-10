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
  - `scripts/macos_test.sh models check|ensure|test|gate|crashes|debug|logs|profile|ui-report|review|xpc`
  - `scripts/macos_agent_ui.sh doctor|impact|verify-probes|validate-report|attest`
  - `./scripts/regenerate_project.sh` after `project.yml` changes
- Use relevant installed macOS Codex skills for SwiftUI/AppKit structure, builds, test triage,
  telemetry, performance, signing, or packaging after reading the selected skill. Shell scripts
  remain the source of truth for gates.
- Use authoritative Apple documentation where current framework behavior matters and the GitHub
  integration for repository/CI context.
- For macOS frontend work, invoke the repository skill `$vocello-macos-ui-qa` for every suite
  listed by `scripts/macos_agent_ui.sh impact`. Requirements are independent sets, not a rank.
  Computer Use is the sole UI driver; the skill's
  structured report and typed probes are the gate evidence. Never add a macOS XCUITest target.

## Build / test commands

```sh
# Fast local loop
./scripts/build.sh build
./scripts/build.sh run

# macOS smoke tests (models ensure symlinks QwenVoice-Debug/models → canonical store)
scripts/macos_test.sh models ensure   # one-time per machine
scripts/macos_test.sh test
scripts/macos_agent_ui.sh impact
# Invoke $vocello-macos-ui-qa quick|full|benchmark when required.
scripts/macos_test.sh gate

# XPC lifecycle / crash isolation
scripts/macos_test.sh xpc status

# UI capture + baseline diff
scripts/macos_test.sh review [--report <run>]
```

## Invariants (do not regress)

- **XPC event forwarding drains `engine.events` off `MainActor`.** In `EngineServiceHost`,
  drain on `Task.detached(.utility)`; only `lastPublishedEvent` hops to `MainActor`.
- **Service retirement is expected.** When `shutdownWhenIdle` retires the service, the client
  marks it `expectedRetirement` — no error UI, no auto-reconnect. It lazily relaunches on next use.
- **Single envelope method.** The XPC wire protocol is one `perform(_:withReply:)` carrying an
  `EngineCommand`. Do not add ad-hoc XPC methods.
- **Liquid Glass is gated.** `QW_UI_LIQUID` compilation condition controls Liquid Glass surfaces.
- **Reduce Motion / Reduce Transparency.** All animation routes through `appAnimation` /
  `AppLaunchConfiguration.performAnimated`; reduced-transparency fallback uses solid fills.
- **No color-only signal.** Mode colors pair with icon, label, or position cue.
- **`accessibilityIdentifier`s are stable.** Values like `voicesRow_*`, `textInput_*`,
  `studioChip_*` must survive refactors.
- **App sandbox disabled.** `Sources/QwenVoice.entitlements` keeps sandbox off for MLX; do not
  re-enable it.

## Common mistakes

- Editing `QwenVoice.xcodeproj/project.pbxproj` directly. Always edit `project.yml` and run
  `./scripts/regenerate_project.sh`.
- Performing XPC event draining on `MainActor`.
- Showing error UI when the XPC service retires normally.
- Blocking the main thread during model load or generation.
- Adding `#if DEBUG` forks instead of using runtime `DebugMode.isEnabled`.
