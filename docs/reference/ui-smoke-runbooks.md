# UI smoke runbooks — Codex frontend routes

macOS frontend acceptance is gate-bearing and uses the repository-owned
`$vocello-macos-ui-qa` Computer Use skill. iOS remains on its existing split: physical-device
XCUITest for gates and mirroir for exploratory smokes.

The shared rule is unchanged: screen observation never proves generation. Deterministic success
comes from typed telemetry joined by `generationID`, `history.sqlite`, and the readable WAV.

Identifier reference: [`ui-test-surface.md`](ui-test-surface.md).

---

## macOS — Computer Use frontend acceptance

Use [`macos-testing.md`](macos-testing.md) for the complete contract. The short route is:

```sh
./scripts/build.sh build
scripts/macos_agent_ui.sh doctor --suite quick --json
scripts/macos_agent_ui.sh impact
# Invoke $vocello-macos-ui-qa quick|full|benchmark as selected.
scripts/macos_test.sh ui-report --suite quick|full|benchmark
```

The skill launches only the exact `build/Vocello.app`, observes fresh accessibility state before
and after every action, resolves fresh element indices, and records coordinate/screenshot fallbacks
as automation warnings. It always finishes with `verify-generation`, `verify-history`,
`verify-probes`, cleanup, report validation, and a compact attestation.

Quick covers Custom generation/playback/history plus semantic layout and accessibility. Full adds
Design, Clone, batch, controls, History/Saved Voices, reversible Settings, reference import, and
XPC kill/recovery. Benchmark covers the full mode × length × cold/warm matrix. Destructive work is
never selected automatically and requires explicit authorization plus action-time confirmation.

Do not use the removed Peekaboo, `uitest_measure.sh`, macOS XCUITest, runner-signing, `journey`, or
`uitest-doctor` workflows for new macOS work.

---

## iOS — procedure index

| Need | Doc / script |
| --- | --- |
| **Exploratory smokes (agent)** | This file § mirroir Studio smoke + [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix B |
| **9-clip multi-mode smoke** | This file § multi-mode below + pilot log §10.3 |
| **Driving invariants (always on)** | [`.cursor/rules/agent-ui-driving.mdc`](../../.cursor/rules/agent-ui-driving.mdc) |
| **App map + XCTest ids** | [`ios-app-guide.md`](ios-app-guide.md) |
| **Device lanes / gates** | [`ios-device-testing.md`](ios-device-testing.md) Playbooks 1–3 |
| **Preflight** | `scripts/ios_mirroir_preflight.sh --native-only` |
| **Full UI matrix** | XCUITest `scripts/ios_device.sh bench-ui` only |
| **Agent smoke verify** | `measure-prep` → mirroir drive → `measure-now` → Generate → `measure-verify` |
| **mobile-mcp (WDA)** | **Deferred** — [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) |

---

## iOS — mirroir Studio smoke (primary)

Preflight:

```sh
scripts/install_mirroir_user_config.sh --merge-settings   # once; restart Cursor
scripts/ios_mirroir_preflight.sh --native-only              # skip vision-bridge when native OCR works
scripts/ios_device.sh launch
```

Drive via **mirroir MCP** (not Peekaboo on the mirror) — **Appendix B.5–B.8** in
[`ios-agent-ui-tour.md`](ios-agent-ui-tour.md):

1. `check_health` — must pass (Screen Recording + Accessibility for Cursor.app).
2. **`describe_screen`** — observe OCR + window-relative coords.
3. **One action** — `tap` / `type_text` / `measure`.
4. **`describe_screen`** — verify transition. Repeat (O-A-V loop).
5. **Stay on Studio** for multi-clip smokes — **Custom**, **Design**, or **Clone** segment @ y ≈ 84 (218×486 window) or y ≈ 108 (326×720) — see tour doc calibration table; chip row for params. **Never Voices tab** mid-block.
6. End-of-session: **History** tab to verify rows (also allowed **History → Studio** for Design dismiss recovery — B.7).

**Custom generate smoke:** OCR **Generate** → verify **`N / 150` N > 0** (B.8) → `tap` → poll / `measure` until
*Just now • Custom* → **DISMISS_POLL** for **X** (B.7) → next clip or RESET.

**Design generate smoke:** segment **Design** → **`+`** brief chip → type brief → **Confirm** → script → Generate → poll *Just now • Design* → dismiss per B.7 (may need **History → Studio**). Optional **Save as voice** to enroll for Clone.

**Clone generate smoke:** segment **Clone** → **`+`** reference chip → pick **SAVED VOICES** row (once) → script → Generate → poll *Just now • Clone* → **X + Dismiss**. Reuse same reference chip for multi-clip.

**Multi-mode 9-clip smoke (exploratory):** 3× Custom → 3× Design → 3× Clone; `launch` RESET between blocks; History verify 9 TODAY rows. Validated [`computer-use-mcp-pilot-log.md`](computer-use-mcp-pilot-log.md) §10.3.

**iOS script entry (mirror):** type-only on `0/150`; replace uses cmd+a → **delete** (×3 if `150/150` corruption) → type — **not** macOS Peekaboo rules.

**Evidence:** `scripts/ios_device.sh shot` **only** when `describe_screen` fails or the user asks.

**Generation proof (deterministic):** capture `SINCE=$(scripts/ios_device.sh measure-now)` **before** Generate, then:

```sh
ART=$(scripts/ios_device.sh measure-artifacts-dir --run-id "$RUN_ID")
scripts/ios_device.sh measure-verify --run-id "$RUN_ID" --since "$SINCE" --artifacts-dir "$ART"
```

Expect `pass: true` in `$ART/result.json`. Pre-merge gates stay `ios_device.sh gate` / `test --cold` / headless `bench`. **Full UI matrix:** XCUITest `bench-ui` only.

Legacy Peekaboo + `ios_vision_bridge.sh` — fallback only when `describe_screen` fails.

---

## iOS — archived procedures (do not use for new smokes)

<details>
<summary>Deprecated — mirroir agent UI bench matrix (retired 2026-07)</summary>

Full matrix = XCUITest `bench-ui` only. Historical `bench-ui-mirroir` procedure:
[`computer-use-mcp-pilot-log.md`](computer-use-mcp-pilot-log.md) §Archived agent bench.

</details>

<details>
<summary>RETIRED hybrid mirroir + Peekaboo (Jul 2026) — superseded by native mirroir above</summary>

Device prep: `ios_device.sh build && install && launch && mirror`. Same O-A-V loop but
Peekaboo clicked mirror-window coords via `ios_vision_bridge.sh` — higher error rate.
Use native **`tap`/`type_text`** from `describe_screen` coords instead.

</details>

<details>
<summary>mobile-mcp exploratory (deferred — WDA signing blocked)</summary>

Use [mirroir smoke](#ios--mirroir-studio-smoke-primary) for exploratory QA. When WDA unblocks,
see [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) and Playbook 3 in
[`ios-device-testing.md`](ios-device-testing.md).

</details>

---

## iOS — mobile-mcp bench-ui matrix (deferred)
> **Deferred 2026-07** — use XCUITest `bench-ui` for matrix; mirroir for exploratory smokes.
> Retained for when WDA signing unblocks.

### Session prep

```sh
scripts/ios_device.sh device-state
scripts/ios_mobile_mcp.sh preflight
scripts/ios_device.sh bench-ui-mcp --agent-drive \
  --warm 1 --lengths medium --modes custom --label "mcp-pilot"
```

The driver prints `MCP_BENCH_TAKE_BEGIN` blocks and waits for `take-N.done` after each take.

### Hybrid MCP loop (every take)

1. **Preflight once:** `scripts/ios_mobile_mcp.sh preflight` + `lock` (driver acquires lock)
2. **Perceive:** `mobile_list_elements_on_screen` — find `generateSection_*`, `textInput_*`
3. **Act:** element tap / `mobile_type_keys` — **not** mirror coordinates
4. **Measure:** `SINCE=$(scripts/ios_device.sh vision-now)` before Generate; after tap,
   `scripts/ios_device.sh vision-bench-wait --run-id … --since "$SINCE"`
5. **Signal:** `touch build/ios/bench-ui-mcp-<runID>/take-N.done`

Workflow map: [`ios-app-guide.md`](ios-app-guide.md).

---

## iOS — vision bench-ui matrix (DEPRECATED — historical reference)

> **Deprecated 2026-07 — do not run for new work.** Superseded by XCUITest `bench-ui`. Kept only so agents recognize the old lane name if it appears in logs.

Human-like full-matrix bench: **mirroir sees**, **Peekaboo clicks/types** on the Mac-side
Mirroring window, **shell proves** via pulled `generations.jsonl`.

### Session prep

```sh
scripts/ios_device.sh device-state          # exit 0
scripts/ios_device.sh models check --strict
scripts/ios_device.sh bench-ui-vision --agent-drive \
  --warm 1 --lengths medium --modes custom --label "vision-pilot"
```

The driver prints `VISION_BENCH_TAKE_BEGIN` blocks and waits for `take-N.done` after each take.

### Hybrid MCP loop (every take)

1. **Calibrate once** (driver does this): `scripts/lib/ios_vision_bridge.sh calibrate`
2. **Perceive:** mirroir `check_health` → `describe_screen` (OCR + window-relative tap coords)
3. **Transform:** `scripts/lib/ios_vision_bridge.sh to-global X Y` → screen coords for Peekaboo
4. **Act:** Peekaboo `window` focus (Mirroring app name from `mirror-app-name`) → `click coords:` with `foreground: true` → `type` for script text
5. **Confirm:** `describe_screen` again — verify tab/mode/keyboard state before Generate
6. **Measure:** capture `SINCE=$(scripts/ios_device.sh vision-now)` **before** Generate; after tap,
   `scripts/ios_device.sh vision-bench-wait --run-id … --since "$SINCE" --timeout …`
7. **Signal:** `touch build/ios/bench-ui-vision-<runID>/take-N.done`

Workflow map: [`ios-app-guide.md`](ios-app-guide.md) (tabs, `generateSection_*`, chips, sheets).

### Per-mode preparation (semantic)

| Mode | Vision check | Steps |
| --- | --- | --- |
| **custom** | OCR: `Custom` segment + composer | Tap Custom → clear script → type corpus text |
| **design** | `Voice brief:` chip | Tap chip → starter row or type brief once per warm session → type script |
| **clone** | Saved voice on device (`models check` → `cloneVoicesEnrolled`) | Voices tab → first saved card → handoff to Clone (no mic over mirror) |

### Clear composer

- OCR tap **`bench clear script`** (`QWENVOICE_UI_TEST_HOOKS=1` — driver sets via `vision-launch`)
- Fallback: tap editor → Peekaboo `hotkey cmd,a` + delete, then type

### Keyboard + Generate

- Tap composer → Peekaboo `type` with `foreground: true`, human `--wpm 120`
- Press `{return}` / Done to dismiss keyboard (**required** before Generate)
- Tap `Generate` via transformed coords; never tap while keyboard is visible

### Coordinate bridge

```sh
scripts/lib/ios_vision_bridge.sh calibrate build/ios/vision-bridge.json
scripts/lib/ios_vision_bridge.sh to-global 120 450   # → gx,gy for Peekaboo click
```

Recalibrate if taps miss (window moved/resized). French macOS: `~/.mirroir-mcp/settings.json` →
`mirroringProcessName`.

### Pilot vs full matrix

| Scope | Command | Takes (approx) |
| --- | --- | --- |
| Pilot | `--warm 1 --lengths medium --modes custom` | 2 (cold + warm medium) |
| Full | default flags | ~29 |

Gate: same `scripts/check_ios_ui_bench.py` as XCUITest `bench-ui` (driver runs at end).

---

## Failure triage

| Symptom | Do |
| --- | --- |
| macOS generation timeout | Inspect the run's `events.jsonl`, app/service logs, and `generation-*.json`; record a functional/environment issue before continuing independent scenarios |
| macOS WAV/DB mismatch | Re-run `scripts/macos_agent_ui.sh verify-generation` / `verify-history`; the deterministic assertion names the missing row, path, duration, or WAV failure |
| macOS probe gap/duplicate/mismatch | Inspect `probe-verdict.json` and layer JSONL; escalate to macOS + backend owners |
| macOS focus stolen | Re-observe with Computer Use and act once on the fresh tree; never reuse the prior element index |
| mirroir taps landing wrong | Re-run `describe_screen`; `scripts/lib/ios_vision_bridge.sh calibrate`; Peekaboo `window` focus Mirroring app |
| vision-bench-wait timeout | `ios_device.sh pull`; grep `engine/generations.jsonl` for `benchRunID`; check mirror still active (`device-state`) |
| Run died mid-flight for no code reason | `scripts/ios_device.sh device-state` — phone in use / call / mirror paused are named verdicts; bench sentinels also carry `interruptions` events |
