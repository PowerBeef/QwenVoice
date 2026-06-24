# iOS on-device testing — the hybrid method

The **automated/headless** on-device methods. They complement interactive UI review over
iPhone Mirroring for UI-driven operations + UI design/review. Two automated tools, neither of
which drives the UI by pixels:

1. **Headless generation harness** — the on-device analog of `vocello bench`. Launch
   the app over `devicectl` with an autorun spec; the in-app `IOSAutorunHarness` runs
   one generation with **no UI interaction**, writes telemetry + a completion sentinel
   into the App-Group container, and `scripts/ios_device.sh` pulls them back and
   summarizes. This is the real on-device entitlement/memory/RTF proof.
2. **Thin XCUITest UI-flow smoke** (`VocelloiOSUITests`) — asserts the app launches and
   the 4-tab IA + Studio composer/mode-control are reachable, off the stable
   `accessibilityIdentifier`s. Runs on a paired physical device only (the Simulator is retired
   for UI work; see §3).

Why this exists: on-device generation is the never-CI-tested path (real Jetsam, real
model download, the in-process engine + increased-memory entitlement). iPhone Mirroring is
**not** the right tool for *scripted generation* (focus races, disconnects, engine-busy
rejections, no headless trigger) — these automated tools are. See also: generation runs **in-process in the app** (since commit
`7822a8a`) — a non-UI ExtensionKit extension is Jetsam-capped at a tiny per-process budget
the entitlement does **not** raise, so it could never load the model; the app process *does*
get the raised limit. The dead extension target was removed entirely (it never ran on
hardware; git history preserves it).

---

## Prerequisites

- **Xcode 26** (`devicectl` / CoreDevice).
- **A paired iPhone 15 Pro or newer**, **Developer Mode ON**, Mac trusted (USB). Verify
  on the device itself the first time.
- `export QWENVOICE_DEVELOPMENT_TEAM=<your-apple-team-id>` — matches `project.yml`'s
  `$(QWENVOICE_DEVELOPMENT_TEAM)`. **Never commit the team id.**
- Optional `export QVOICE_IOS_DEVICE_ID=<id|name|udid>` to pin the target device;
  otherwise the driver auto-discovers the single connected device.
- The **Speed model must be downloaded on the device once** (Settings → Model
  Downloads, or just run the app and install it) — the harness loads it; it does not
  download. A missing model surfaces as a clean sentinel error, not a hang.

The increased-memory entitlement is enabled + verified on the app's App ID (the engine is
in-process — there is no extension App ID) — see
[`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md).

- **Screen mirroring (observation, on by default):** device commands auto-start macOS **iPhone Mirroring**
  so you watch the live app on the Mac while the phone stays **locked + screen-dark (OLED burn-in safe)**.
  iPhone Mirroring also keeps a *locked* device reachable to `devicectl` (a locked phone without mirroring
  goes "unavailable"). **Lock the phone once** per session (Apple exposes no Mac-side lock CLI; it then stays
  locked while mirroring) or rely on Auto-Lock — iPhone Mirroring reconnects when the phone auto-locks. Opt
  out with `QVOICE_IOS_NO_MIRROR=1`; start it manually with `scripts/ios_device.sh mirror`.

- **Unlock vs lock:** `bench`, `launch`, and `pull` work with a **locked** phone (mirroring
  keeps CoreDevice reachable). **`ui-test` requires the iPhone unlocked once** at the start of
  the run so XCUITest can complete the automation auth handshake (`Unlock iPhone … to Continue`
  / `SFAuthenticationErrorCodeApproveFailedToPost` when locked). Lock again after the handshake
  if you prefer; mirroring keeps the tunnel up.

---

## 1. Headless generation harness

### `scripts/ios_device.sh`

A small `devicectl` driver. The signing team comes from `$QWENVOICE_DEVELOPMENT_TEAM`;
the device is auto-discovered or pinned via `$QVOICE_IOS_DEVICE_ID` (neither committed).

Every device verb below first runs an **auto-mirror preflight** (`ensure_mirror`): it starts
macOS iPhone Mirroring and waits for the device to be `devicectl`-reachable, so you watch
on the Mac with the phone locked + screen-dark (OLED-safe). Opt out with `QVOICE_IOS_NO_MIRROR=1`.

| Verb | What it does |
|------|--------------|
| `doctor` | Environment + device preflight (Xcode, team env, device, built-app entitlement). |
| `build` | Signed device build, `-Onone`, automatic signing (`-allowProvisioningUpdates`) → `build/ios/…/Vocello.app` (one shared iOS tree). |
| `install` | `devicectl device install app` the built app. |
| `launch [spec]` | Launch via `devicectl`. With a spec → sets the autorun + telemetry env; prints the generated `runID` on stdout. Without → a plain launch. |
| `console [spec]` | Attached `--console` launch — streams the app's `[autorun]` stdout live (best for diagnosing a failed run). |
| `mirror` | Start macOS iPhone Mirroring + confirm the device is reachable (the preflight, runnable on its own). |
| `shot [path]` | `screencapture` the macOS iPhone Mirroring window → a real device screenshot (default `build/device-shot.png`). Brings Mirroring frontmost first. |
| `pull [dest]` | `devicectl device copy from --domain-type appDataContainer --source Library/Caches/Vocello/diagnostics` (the app's pullable mirror — the App-Group container is NOT devicectl-readable). Default dest `build/ios-diagnostics`. |
| `bench [spec] [--label "note"]` | The full loop: `build → install → launch-with-autorun → poll the sentinel → pull diagnostics → summarize`. Exits non-zero if the generation failed. |
| `ui-test [--all\|--cold] [target]` | Run `VocelloiOSUITests` on the device (see §2). **Default:** Smoke + Sheet + OnDeviceDownload. `--cold` runs cold generation only (skips when no model). `--all` runs every class (debug). Optional `target` scopes further, e.g. `VocelloiOSUITests/VocelloiOSSheetUITests`. |

```sh
export QWENVOICE_DEVELOPMENT_TEAM=<team-id>
scripts/ios_device.sh doctor
scripts/ios_device.sh bench "custom:speed:Hello from Vocello on device" --label "in-process engine"
```

`bench` prints the single-run headline (status / mode / model / audio-sec · wall · RTF /
finish / output path / device) from the sentinel, then the full
`summarize_generation_telemetry.py` table (engine decode breakdown, RTF, `audioQC`, RAM)
from the pulled `diagnostics/engine/generations.jsonl`.

### Autorun spec + environment

The harness (`Sources/iOS/IOSAutorunHarness.swift`) fires **only** when
`QVOICE_IOS_AUTORUN` is present and non-empty in the launch environment — a normal user
launch never sets it, so it ships completely inert (no `#if DEBUG` needed; it follows
the same runtime-gate philosophy as `TelemetryGate`).

`bench` / `launch <spec>` set three launch env vars (via
`devicectl device process launch -e '{…}'`):

| Env var | Purpose |
|---------|---------|
| `QVOICE_IOS_AUTORUN` | The spec: `<mode>:<variant>:<text>`. `mode ∈ custom\|design\|clone`, `variant ∈ speed\|quality` (iPhone resolves speed-only), text is everything after the 2nd `:`. Forgiving: bare `1`/`on`, a bare mode, or a partial spec fall back to defaults. |
| `QWENVOICE_DEBUG=1` | Lights up `TelemetryGate` so the engine appends its decode/RTF/`audioQC` row to `diagnostics/engine/generations.jsonl`. **Runtime-gated, not `#if DEBUG`** — works in the Release build the device runs. |
| `QVOICE_IOS_DEVICE_RUN_ID=<runID>` | Tags the run; the completion sentinel lands at `diagnostics/<runID>/autorun-done.json`. |

The harness drives the same in-process `TTSEngineStore.generate(_:)` the UI uses
(resolving the model the same way: `ModelDescriptor.model(for: mode)`), then writes the
sentinel:

```jsonc
// diagnostics/<runID>/autorun-done.json
{ "status": "ok", "mode": "custom", "variant": "speed", "modelID": "…",
  "generationID": "…", "durationSeconds": 5.1, "wallSeconds": 13.7,
  "realtimeFactor": 0.37, "finishReason": "…", "audioPath": "…",
  "deviceModel": "iPhone", "systemVersion": "26.x", … }
```

`clone` autorun needs a saved voice on the device (else a clean sentinel error). Note
clone generation in-app currently uses `.iOSProductionDefault` (= `withoutCloneEncoders`,
memory-conscious), so a clone autorun may fail until clone-in-process is enabled — that
failure is recorded, not crashed.

### Where the data lives + how it's pulled

At runtime the engine telemetry and the sentinel are written to the **App-Group container**
(`AppPaths.appSupportDir` = `group.com.patricedery.vocello.shared`), under `diagnostics/`. But
`devicectl` **cannot** read an app-group container, so the autorun harness also **mirrors** them into
the app's own data container at `Library/Caches/Vocello/diagnostics` (which `devicectl` *can* read).
`pull`/`bench` copy from that mirror:

```sh
xcrun devicectl device copy from --device <id> \
  --domain-type appDataContainer \
  --domain-identifier com.patricedery.vocello \
  --source Library/Caches/Vocello/diagnostics --destination build/ios-diagnostics
```

The summarizer reads the pulled tree directly:

```sh
python3 scripts/summarize_generation_telemetry.py build/ios-diagnostics/diagnostics --label "…"
```

On iOS (in-process, no XPC) only `engine/generations.jsonl` is populated — the summarizer
iterates engine rows and joins `app/` rows when present, so TTFC may be blank while RTF /
tokens/s / decode breakdown / `audioQC` / RAM all come through. `engine/generations.jsonl`
is append-only + size-capped (auto-pruned oldest-first), so it accumulates across runs;
the sentinel is the authoritative single-run record.

---

## 2. XCUITest on the device — the standing autonomous UI loop

**This is the standing automated UI-test method (maintainer decision, 2026-06-04 — the
Simulator is retired; see §3).** Run the device-safe UI suite on hardware with
**`scripts/ios_device.sh ui-test`** (`build-for-testing` → install host app →
`xcodebuild test-without-building`). Pass `[target]` to scope further, e.g.
`scripts/ios_device.sh ui-test VocelloiOSUITests/VocelloiOSSheetUITests`.

| Command | Classes | Notes |
|---------|---------|-------|
| `scripts/ios_device.sh ui-test` | Smoke, Sheet, OnDeviceDownload | Default (~1–2 min). One warm app session via `VocelloUITestObserver`. |
| `scripts/ios_device.sh ui-test --cold` | ColdGeneration | Real generation from cold launch; **skips** when Speed model not installed. |
| `scripts/ios_device.sh ui-test --all` | All classes | Debug/soak only. DownloadManager skips on device; cold gen skips without model. |
| `scripts/ios_sim.sh ui-test` | DownloadManager + sim flows | Simulator-only (`QVOICE_SIM_*` backend). |

**Preflight:** `ui-test` runs `ensure_device_ready` (mirroring up to 60s, devicectl
reachability, unlock guidance). Retries once on unlock/auth log patterns.

`Tests/VocelloiOSUITests/` (target `VocelloiOSUITests`, host `VocelloiOS`):
- `VocelloUITestApp.swift` — shared warm-app coordinator; resets to Studio between cases.
- `VocelloUITestObserver.swift` — target-level retain/release across the default trio.
- `VocelloiOSSmokeUITests` — launch + 4-tab reachability + Custom/Design/Clone segments.
- `VocelloiOSSheetUITests` — sheet regressions: voice select-and-close, preview-keeps-open,
  language select-and-close, brief confirm-closes.
- `VocelloiOSOnDeviceDownloadUITests` — real URLSession download cancel + pause/resume/cancel
  (short paths only; no full ~2.3 GB soak).
- `VocelloiOSDownloadManagerUITests` — **simulator-only** (simulated backend + `QVOICE_SIM_*`).
- `VocelloiOSColdGenerationUITests` — cold-launch real-generation test. Unlike the smoke suite,
  this one kills the warm session, launches a fresh app with the engine enabled, types in Custom
  mode, and waits for actual audio generation to complete (or skips when the model is missing).

The smoke/sheet suites do **not** generate audio (that's the harness above) — the IA + identifiers +
sheet behaviour are what's under test. The cold-generation suite is the exception: it proves a real
on-device generation still works from a cold start.

**Driving identifiers (important):** the screen-level `screen_generateStudio` identifier
propagates onto its descendants, **shadowing** the Studio selector pills' `studioChip_*` ids
and the composer's `textInput_*` ids — so tap the pills by their stable **label prefix**
(`"Voice: "`, `"Language:"`, `"Voice brief:"`), and assert the mode segments
(`generateSection_custom|design|clone`, which keep their ids) rather than the shadowed ones.
Inside the bottom-sheet overlays the elements keep their own ids
(`bottomSheet_close`, `voicePickerRow_*`, `voicePickerPreview_*`, `languagePicker_*`,
`voiceBrief_editor`, `voiceBrief_confirm`). Tab buttons (`rootTab_*`) expose an `isSelected`
trait. See `VocelloiOSSheetUITests.swift` for the helper patterns.

Run via the script (preferred) or directly — always pass `-derivedDataPath build/ios`:

Always pass `-derivedDataPath build/ios` so device + simulator builds share **one**
tree (one `SourcePackages`) and don't pollute the global `~/Library/Developer/Xcode/DerivedData`:

```sh
# Device (standing method) — default device-safe trio:
export QWENVOICE_DEVELOPMENT_TEAM=<team-id>
scripts/ios_device.sh ui-test
# Cold generation soak (skips when Speed model not installed):
scripts/ios_device.sh ui-test --cold
# Direct xcodebuild (after build-for-testing + install):
xcodebuild test-without-building -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'id=<device-udid>' -derivedDataPath build/ios -allowProvisioningUpdates
```

The UI-test target is wired into the `VocelloiOS` scheme's `test` action (and built only
for `test`, so the foundation compile-safety build stays focused on the app). On the
simulator the app uses `IOSSimulatorTTSEngine` (a fake), so the smoke needs no model and
no Metal — the IA + identifiers are what's under test.

`accessibilityIdentifier`s are stable surface area (AGENTS.md "Conventions") — keep them
through refactors; the smoke + any agent UI checks depend on them.

---

## 3. Simulator UI review (the fake engine) — RETIRED (kept in-tree, not used)

> **Retired (maintainer decision, 2026-06-04).** The Simulator path below — `scripts/ios_sim.sh`,
> the fake `IOSSimulatorTTSEngine`, the `QVOICE_SIM_*` seeding, and AXe (`scripts/install_axe.sh`)
> — is **kept in the repo (inert, reversible) but is no longer part of the workflow**. Do UI
> testing/control/review **on the device** via §2 (`scripts/ios_device.sh ui-test`). The text
> below is retained for reference only.

> **Do not follow the instructions below.** They document how the simulator path used to work
> and are left in place only so the retirement decision and historical setup are discoverable.

For **visual UI work** (layout, chrome, flows, keyboard behavior) the Simulator is the right
tool — no device, no signing, no models, no Metal/MLX. On the simulator the app swaps to
`IOSSimulatorTTSEngine` at compile time (`#if targetEnvironment(simulator)` in
`IOSAppBootstrap`), a fake that fabricates real per-mode WAV audio and drives the full
generation lifecycle. (Generation *quality* still needs the device harness above — the fake
is for exercising the UI, not the model.)

### `scripts/ios_sim.sh` — the simulator counterpart to `ios_device.sh`

No `QWENVOICE_DEVELOPMENT_TEAM` needed (unsigned). Shares the one `build/ios` tree.

| Verb | What it does |
|------|--------------|
| `doctor` | Xcode + simulator preflight; resolves the target sim; turns the **software keyboard on** (disconnects the hardware keyboard so the on-screen keyboard + the Studio "Done" accessory bar render). |
| `build` | Build for the `iphonesimulator` SDK (`-Onone`, `CODE_SIGNING_ALLOWED=NO`); greps the log for `** BUILD SUCCEEDED **`. |
| `install` | Boot the sim + `open -a Simulator` + `simctl install` the built app. |
| `run [--no-seed] [--rebuild]` | `build-if-stale → boot → install → launch SEEDED`, then open the Simulator window. **Seeded** = fake models installed (Studio shows "Generate", not "Install") + sample voices + history, so every surface is populated. `--no-seed` launches the empty / onboarding state. |
| `shot [path]` | `simctl io … screenshot` the booted sim (default `build/ios-sim-shot.png`). |
| `ui-test` | Run the `VocelloiOSUITests` smoke (§2) on the sim. |

```sh
scripts/ios_sim.sh run            # build + launch the seeded app; Simulator opens for clicking
scripts/ios_sim.sh shot out.png   # capture what's on screen
scripts/ios_sim.sh ui-test        # the launch/navigation smoke
```

Target a specific sim with `QVOICE_IOS_SIM=<name|udid>` (else it auto-picks a booted iPhone,
then the newest-iOS iPhone, preferring Pro). Tune the seed with the env the fake engine reads:

| Env var | Effect |
|---------|--------|
| `QVOICE_SIM_FAKE_MODELS` | `all` (default) / `custom` / `design` / `clone` / `<ids>` / `none` — which models report installed. |
| `QVOICE_SIM_SEED_DATA` | `voices,history` (default) — seed a saved voice + a History entry. |
| `QVOICE_SIM_BACKEND_SCENARIO` | `success` (default) / `slow` (watch progress UI) / `fail` (error-state UI). |
| `QVOICE_SIM_BACKEND_DELAY_MS` | Override the fake generation delay. |

**Software keyboard:** the `ConnectHardwareKeyboard=false` default takes effect on the next
Simulator launch — if Simulator is already open, quit + relaunch it (or toggle I/O ▸ Keyboard ▸
Connect Hardware Keyboard off) so the on-screen keyboard appears.

### Agent-driven UI checks (Claude)

To verify a UI change myself I can drive the sim three ways, all reusing `build/ios`:
- **CLI**: `scripts/ios_sim.sh run` then `scripts/ios_sim.sh shot <path>` and read the screenshot.
- **axiom `xcui` / `axe`**: `axe describe-ui --udid <sim>` (read the accessibility tree),
  `axe tap --label "…" --udid <sim>` / `axe tap -x … -y …`, `axe type`, `axe screenshot`. `axe`
  (the `xcui` dependency) installs **without Homebrew** via **`scripts/install_axe.sh`** (pinned +
  sha-verified; puts `axe` in `~/.local/bin`); confirm with `xcui doctor` (`"ok": true`).
- **`xcodebuildmcp` MCP**: `build_run_sim` → `screenshot` / `snapshot_ui` (the accessibility tree
  with `elementRef`s) → `tap` / `type_text` to drive a flow (note: the MCP's UI-automation tools
  may need enabling in XcodeBuildMCP's config).

Use real taps — the SwiftUI a11y tree is virtualized (e.g. `textInput_textEditor` only materializes
after a focus tap). **Note (2026-06-06): this Simulator path is retired** — don't use it for UI review.
Automated UI-flow tests run via the on-device XCUITest suite (§2); interactive UI review uses iPhone
Mirroring directly.

---

## Verification ladder

| Level | Command | Proves |
|-------|---------|--------|
| Compile (app) | `scripts/build_foundation_targets.sh ios` | the in-process engine + harness compile |
| Compile (UI test) | `xcodebuild build-for-testing -scheme VocelloiOS -destination 'platform=iOS,id=<udid>' -derivedDataPath build/ios` | the test target compiles + is wired for the device |
| UI smoke | `scripts/ios_device.sh ui-test` | launch + IA reachable on a real device |
| Interactive UI review | `scripts/ios_device.sh launch` + `scripts/ios_device.sh shot <path>` | the full UI renders over iPhone Mirroring for visual review |
| On-device proof | `scripts/ios_device.sh bench "custom:speed:…"` | real generation, entitlement/memory headroom, RTF/`audioQC` |

## Still deferred

A signed-IPA / TestFlight distribution lane (needs the iOS Distribution cert + an
`archive-ios` CI job). On-device proof is **not** a public-release blocker (macOS-first;
see AGENTS.md "Release & iPhone status").
