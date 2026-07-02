# UI smoke runbooks — agent-driven exploratory loops

Per-mode smoke procedures for **agent-driven** UI validation in Cursor, pairing the
exploratory MCPs (**Peekaboo** on macOS, **mirroir** on iOS — see
[`computer-use-mcp-alternatives-cursor.md`](computer-use-mcp-alternatives-cursor.md)) with the
**deterministic measurement shell** [`scripts/uitest_measure.sh`](../../scripts/uitest_measure.sh).

Successor to the per-mode smoke runbooks deleted at `6d1cca4`. The core design rule
survives: **measurement never depends on how the agent clicked.** Pass/fail comes from
OSSignposts + `history.sqlite` + the WAV on disk via `verify-generation` — the MCP only
drives the UI like a human.

**These runbooks are exploratory QA, not gates.** Regression gates stay
`scripts/macos_test.sh gate` and `scripts/ios_device.sh gate`.

Identifier reference: [`ui-test-surface.md`](ui-test-surface.md) (generated catalog).

---

## macOS — shared skeleton

Every macOS smoke follows the same lifecycle:

```sh
scripts/build.sh build                       # if build/Vocello.app is stale
scripts/uitest_measure.sh smoke-check <mode> # models (+ clone voice) present?
scripts/uitest_measure.sh reset              # clean generations + outputs
scripts/uitest_measure.sh prep               # fresh launch, QWENVOICE_DEBUG=1
ART=$(scripts/uitest_measure.sh artifacts-dir)
T0=$(scripts/uitest_measure.sh now)          # capture BEFORE clicking Generate
# … agent drives the UI via Peekaboo (see per-mode steps) …
scripts/uitest_measure.sh verify-generation <mode> --artifacts-dir "$ART" --since "$T0"
scripts/uitest_measure.sh streaming-preview-check --since "$T0" --artifacts-dir "$ART"  # optional
```

Peekaboo driving pattern (precision-first, vision to confirm):

1. `see` with `app: Vocello` — AX map with element ids; Vocello's
   `accessibilityIdentifier`s appear on the mapped elements.
2. Prefer clicking by element id from `see`; fall back to `image` + click-by-sight for
   visually ambiguous controls.
3. Keyboard-first where possible: `Cmd+Return` = Generate, `Cmd+A` + `Delete` to replace
   script text. SwiftUI Picker menus re-anchor after the first open — re-`see` before the
   second interaction with any picker.
4. Re-`see` (or `image`) after each step to confirm state; watch `*_readiness` markers
   (`ready=true` in the element value).

## macOS — Custom Voice smoke

1. Skeleton above with `<mode> = custom`.
2. `see` → click `sidebar_customVoice` → confirm `screen_customVoice`.
3. Click `textInput_textEditor`, type a short script (≥ a full sentence).
4. Wait for `customVoice_readiness` value to contain `ready=true`.
5. Capture `T0`, then `Cmd+Return`.
6. `verify-generation custom …` — expect `pass: true` in `$ART/result.json`.
7. Evidence: `see`/`image` of the player bar (`sidebarPlayer_bar`).

## macOS — Voice Design smoke

1. Skeleton with `<mode> = design`.
2. Click `sidebar_voiceDesign`.
3. Fill the brief: click `voiceDesign_briefStarters` → pick `voiceDesign_briefStarter_0`
   (or type a custom brief into the brief field).
4. Type script text into `textInput_textEditor` — **readiness needs BOTH brief and text**.
5. Wait for `voiceDesign_readiness` → `ready=true`; capture `T0`; `Cmd+Return`.
6. `verify-generation design …`.

## macOS — Voice Cloning smoke

1. Skeleton with `<mode> = clone` (smoke-check also asserts a saved voice exists —
   `scripts/macos_test.sh models ensure` seeds `A_warm_elderly_woman`).
2. Navigate to Voices (`sidebar_voices`), open the saved voice's "use in clone" action
   (row ids `voicesRow_*`), which hands off to the Clone screen with the reference staged.
3. Type script text; wait for readiness; capture `T0`; `Cmd+Return`.
4. `verify-generation clone …` (default timeout 120 s — clone prefill is slower).

## macOS — settings / download UX tour (no generation)

1. `prep`, then `see` → `sidebar_settings` → confirm `settings_modelDownloadsSummary`.
2. Tour model rows; screenshot evidence per state. Do **not** start real downloads in a
   smoke unless the run is explicitly about download UX (bandwidth + state mutation).

---

## iOS — mirroir Studio smoke (real device over iPhone Mirroring)

Device prep (phone **unlocked**, Mirroring connected):

```sh
scripts/ios_device.sh build && scripts/ios_device.sh install
scripts/ios_device.sh launch          # plain launch, no autorun spec
scripts/ios_device.sh mirror          # ensure Mirroring is up/foreground
```

Drive via mirroir MCP:

1. `check_health` / `status` — session sanity.
2. `describe_screen` — OCR + tap coordinates for the current screen.
3. Tour: Studio (`Custom` / `Design` / `Clone` segments) → Voices → History → Settings
   tabs; `describe_screen` after each tap to confirm the transition.
4. Evidence: `scripts/ios_device.sh shot build/<name>.png` (observation lane) or the
   mirroir screenshot tool.

**Generation verification on iOS** is NOT done by mirror-driving — use the deterministic
lanes: `scripts/ios_device.sh gate` (headless autorun step) or
`scripts/ios_device.sh test --cold` (ColdGeneration XCUITest). Mirror taps are for
exploratory UX review only; the sentinel/telemetry files are the ground truth.

---

## Failure triage

| Symptom | Do |
| --- | --- |
| `verify-generation` timeout | `scripts/uitest_measure.sh logs` (signpost stream); check `sidebar_backendStatus_error` via `see` |
| WAV/DB mismatch | Inspect `$ART/result.json` reason; `scripts/uitest_measure.sh db "SELECT id,mode,audioPath,duration FROM generations ORDER BY createdAt DESC LIMIT 3"` |
| Preview underrun/chunk gap | `streaming-preview-check` output names the failing signpost; escalate to the backend-mlx role |
| Focus stolen mid-run | `scripts/uitest_measure.sh activate`, re-`see`, continue |
| mirroir taps landing wrong | Re-run `describe_screen` (window may have moved); check Mirroring window wasn't resized |
| Run died mid-flight for no code reason | `scripts/ios_device.sh device-state` — phone in use / call / mirror paused are named verdicts; bench sentinels also carry `interruptions` events |
