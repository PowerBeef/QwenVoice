# Driving UI tests, reviews, and benchmarks

> **For headless generation + benchmarks/perf tests, use the `vocello` CLI, not this.** The CLI
> (`./scripts/build.sh cli …` → `build/vocello`) drives `generate` and the `bench` matrix in-process,
> deterministically — it replaced computer-use UI-driving because computer-use is flaky for *driving
> generation* (MCP disconnects, focus races, engine-busy rejections). See `telemetry-and-benchmarking.md`
> §11 + `vocello bench --help`. **computer-use here is for what the CLI can't do: visual/UX review**
> (layout, tints, Liquid Glass + Reduce Motion/Transparency fallbacks) and **iOS via iPhone Mirroring**.

How Claude exercises the Vocello UI directly — **macOS via the native `computer-use` MCP** (mouse +
keyboard + vision), **iOS via the iPhone Mirroring window**. This is live agent-driving, **not** an
XCUITest bundle (`scripts/uitest.sh` / `QwenVoiceTests` stay retired — `scripts/check_project_inputs.sh`
still bans those). The agent drives the app and reads results. (Benchmark/QC scripts, baselines, and
summaries under `benchmarks/` are permitted — they're no longer guard-banned.)

## Principle

**Drive with computer-use; observe results by sight; capture timing out-of-band.** Take a
`screenshot`, find the control **by sight**, click its pixel (or use a keyboard chord). Confirm
outcomes from the screen (the Player appears with a clip duration, readiness flips to "Ready"). For
benchmark *timing*, do not time wall-clock around clicks — capture it from the engine instead (see
**Benchmark flow**; note that the unified `log` does **not** surface these signposts — verified).

## Availability (check first, every session)

Computer use is available to **Claude Code and Cowork** in the Claude Desktop app (Pro/Max) once
**Settings → General → Computer use** is on — verified working end-to-end here. The tools are
`mcp__computer-use__*`. Per session: load the toolkit (one `ToolSearch` with query `computer-use`,
`max_results: 30`), call `mcp__computer-use__request_access` for `Vocello` (resolves to **full** tier
— clicks + typing both work), then `screenshot`. They are action tools, so they're hidden while in
plan mode; a normal session exposes them. Screen Recording is already granted.

Run all shell work (builds, `log`, Instruments, DB queries) through the **Bash tool**, never through
computer-use — Terminal/IDE are restricted tiers where typing is blocked.

**Isolate test data:** launch with `QWENVOICE_DEBUG=1` (or flip the in-app toggle) so generated
takes land in `QwenVoice-Debug/` instead of polluting the real `QwenVoice/` History. **Launch via
`QWENVOICE_DEBUG=1 ./scripts/build.sh run`** — its `open -na` propagates the shell env to the app.
**Do NOT direct-exec the bundle binary** (`build/Vocello.app/Contents/MacOS/Vocello`): LaunchServices
re-launches it and drops the env, so debug mode/telemetry silently won't engage. For ad-hoc env on an
already-running session, use `launchctl setenv KEY VALUE` then `open` (and `launchctl unsetenv` after).
To reuse the real app's weights from a debug-isolated run without a re-download, **copy** the package
into `QwenVoice-Debug/models/` — do **not** symlink or point a models-dir override at the real dir: the
prepared-cache overlay lives inside the model dir, so the debug run would rebuild it in place and mutate
your real model data.

## Tool mapping + gotchas

| Intent | Call |
|---|---|
| Capture screen | `mcp__computer-use__screenshot` (locate elements by sight) |
| Click a pixel | `mcp__computer-use__left_click`, `coordinate: [x, y]` |
| Type into focused field | `mcp__computer-use__type` (click the field first) |
| Key / chord | `mcp__computer-use__key` — `cmd+Return` (Generate), `cmd+a`, `BackSpace`, `Down`/`Up`/`Return` |

- **Re-front if focus is stale:** clicking an unfocused window may only raise it — re-`screenshot`
  and click again.
- **SwiftUI Picker menus** open *anchored to the current selection*, so a remembered pixel only works
  for the first open. Drive them by keyboard: click to open → `Down`/`Up` N times from the current
  index → `Return`; track the index to compute N. (Affected: delivery tone, intensity, saved-voice,
  model-variant pickers.)
- Forbidden: AppleScript `keystroke` / `click at` global coordinates for the Vocello UI — they hit
  whatever window has focus and are fragile. Use computer-use.

## macOS surface reference (what to look for)

Stable `accessibilityIdentifier`s — semantic anchors, not coordinate sources. Keep them when
refactoring views.

- **Launch marker:** `mainWindow_ready` (window mounted), `mainWindow_activeScreen`.
- **Sidebar nav:** `sidebar_customVoice` / `sidebar_voiceDesign` / `sidebar_voiceCloning` /
  `sidebar_history` / `sidebar_voices` / `sidebar_settings`; each screen is `screen_*`.
- **Composer (all three generate screens):** `textInput_textEditor` (script field),
  `textInput_generateButton` (**Generate = `cmd+Return`**), `textInput_cancelButton` (during a run),
  `textInput_charCount`.
- **Per mode:** variant Speed/Quality + delivery controls under `customVoice_*` / `voiceDesign_*` /
  `voiceCloning_*` (e.g. `customVoice_speakerPicker`, `voiceDesign_voiceDescriptionField`,
  `voiceCloning_savedVoicePicker`, `*_toneSpeed`); readiness/completion shows as a `*_readiness`
  status ("Ready" → inline player; Design/Clone expose a save-to-Saved-Voices button).
- **Model variant (benchmarking):** `{mode}_speedVariantButton` / `{mode}_qualityVariantButton`
  (e.g. `customVoice_speedVariantButton`, `customVoice_qualityVariantButton`) select Speed (4-bit) vs
  Quality (8-bit). Click the button (or `Left`/`Right` arrow the picker). **Switching variant or mode
  forces the next generation to be a cold load** (the prior package unloads). For an accurate cold
  measurement also launch with `QWENVOICE_SUPPRESS_WARMUP=1` (skips proactive prewarm/clone-priming so
  the cold generation records its own load) — see the benchmark procedure in
  [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md).
- **Constrained-tier / memory-pressure runs:** launch with `QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac`
  to make the engine run the 8 GB code paths (pressure monitor on, tight caches) so memory pressure is
  measurable on this Mac — induce real pressure with `sudo memory_pressure -l warn` (Bash tool) during a
  take. See the "Memory & pressure pass" in [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md).
- **Settings:** model rows `settings_package_<id>` + `settings_download_<id>` / `settings_repair_<id>`;
  `preferences_autoPlayToggle`; `settings_preferSpeedEverywhere`; `preferences_openFinderButton`.
  The **version label** carries the hidden **7-tap debug-mode toggle** (`appVersion` Text).
- **History / Voices:** `history_searchField`, `historyRow_<id>` (+ `_play_` / `_delete_`);
  `voices_enrollButton`, `voicesRow_<id>` (+ `_play_` / `_use_` / `_delete_`).

## Functional test flow (per mode)

1. `screenshot`; click `sidebar_<mode>`; confirm the `screen_<mode>` mounted.
2. Click the script field (`textInput_textEditor`); optional `cmd+a` → `BackSpace`; `type` the fixed
   prompt. (Clone needs a reference/saved voice first; Design needs a voice description.)
3. `cmd+Return` to generate.
4. Detect completion by `screenshot`: the inline **Player** appears (with a clip duration, e.g.
   `0:04`) and readiness shows "Ready". This screen signal is the reliable completion check (verified).
5. Verify the output landed (History row, or the played audio).

## Visual / UX review flow

Screenshot-driven inspection: layout at representative window sizes, the mode tints, chips/cards, and
the **Reduce Motion / Reduce Transparency** fallbacks (Liquid Glass must fall back to solid fills).
Toggle those in System Settings, relaunch, and compare screenshots.

## Audio listening review (output-quality gate)

The mandatory perceptual gate before merging a backend change (the objective `QC` tool is a
tripwire, not a substitute — see "Guarding output quality" in
[`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md)). Per fixed-corpus take:
1. Generate it (functional flow above), then click the inline **Player** play control to audition.
2. Listen for: clicks/pops (chunk-boundary discontinuities), dropouts/gaps, clipping/distortion, wrong or
   garbled words, unnatural prosody/pacing, timbre drift vs the known-good baseline.
3. First check the summarizer: any `QC=fail` is a hard stop — investigate before the
   listen. Record the listen verdict (pass/fail + notes) in the benchmark snapshot / `HISTORY.md` note.
Note: computer-use can drive playback and confirm the Player state by sight, but **a human ear is the
judge of subtle quality** — agent runs surface the objective flags; sign-off on "sounds great" is yours.

## Benchmark flow (timing)

Drive Generate via computer-use, then capture timing **out-of-band**. Note: `log show` / `log stream`
do **not** surface the engine's `OSSignposter` signposts — verified here (three driven generations
produced zero `com.qwenvoice` log/signpost entries). These signposts go to the Activity-Tracing
buffer that only Instruments reads, not the unified log. So don't try to read timing from `log`.

- **Coarse, zero setup:** the inline Player shows the generated clip's duration in each `screenshot`
  (e.g. `0:04`) — enough to confirm a take and compare audio length, not latency.
- **Latency milestones (ad-hoc):** capture the always-on signposts with Instruments —
  `xctrace record --instrument os-signpost --attach Vocello --output run.trace`, drive the
  generation, then read the os_signpost track. Subsystems `com.qwenvoice.engine`
  (`generation`/`runtime`) and `com.qwenvoice.app`/`performance`. Milestones: `Native Prepare
  Generation` / `Native Model Load` (intervals), `Native First Audio Chunk` / `First Chunk Received`
  (time-to-first-audio), `Live Engine Play`, `Final File Ready`, `Autoplay Start`, `Native Prewarm
  Cache Hit`.
- **Recommended (durable):** the structured per-generation telemetry — file-based, readable via
  Bash, no Instruments — gated by `TelemetryGate` (env `QWENVOICE_DEBUG=1`, or the app's 7-tap
  DebugMode flag, which is relayed to the engine process over the `initialize` IPC handshake). Each
  layer appends one JSON line keyed by the shared `generationID`:
  - `diagnostics/app/generations.jsonl` — frontend: `submitToFirstChunkMS`, `submitToFirstAudibleMS`,
    `submitToCompletedMS`, plus the rescued `summary` (peak/headroom/GPU memory, time-to-peak).
  - `diagnostics/engine-service/generations.jsonl` — middle (XPC) transport: `chunkForwardingSpanMS`,
    `chunksForwarded`, `chunkGaps`.
  - `diagnostics/engine/generations.jsonl` — backend: the full stage timeline + memory `summary`.
  - `diagnostics/generations-merged.jsonl` — all three layers joined by `generationID` (one row per
    run). This is the intended benchmark source; read it directly.
  (The legacy `native-events.jsonl` still carries chunk-gap / encode-drop events.) Under
  `QwenVoice-Debug/` when DebugMode is on. iOS engine-extension rows are deferred with the rest of iOS.

Cold vs warm: force cold by switching the model id (unloads) or letting idle-unload fire; warm =
back-to-back runs. Commit compact snapshots/baselines under `benchmarks/` if useful (≤256 KB, no raw
`*.jsonl`) — comparison stays manual (`git diff`), with no auto-compared build gate.

## iOS via iPhone Mirroring (with caveats)

Open the macOS **iPhone Mirroring** app (mirrors the paired physical iPhone); computer-use drives
that window like any native app (full tier). Drive the bottom tabs `rootTab_studio` /
`rootTab_voices` / `rootTab_history` / `rootTab_settings`, the Studio composer, and the
Custom/Design/Clone mode segmented control.

**Two preconditions right now:**
1. The app must already be installed and running on the device — deploy via **Xcode** (the in-repo
   `ios_device.sh` was removed in the harness cleanup).
2. Real on-device MLX generation is blocked until Apple's increased-memory entitlement
   ([`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md)).
   Until then, Mirroring runs are **UI / flow / visual review** only — generation will block at model
   admission.
