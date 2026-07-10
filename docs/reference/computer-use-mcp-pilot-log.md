# Computer-use MCP pilot log (2026-07-01)

> **Reopened 2026-07-04 (evening):** **Peekaboo** + **mirroir** restored in `~/.cursor/mcp.json`
> (Option 3 — macOS Peekaboo + iPhone mirroir). **mobile-mcp** deferred (WDA signing blocked).
> §7 closure below is historical; current validation is §8.

Pilot for **Option 1**: user-scoped **Peekaboo** (macOS) + **mirroir-mcp** (iPhone Mirroring) in `~/.cursor/mcp.json`, launched via `~/.cursor/bin/mcp_stdio_wrapper.sh`.

**Regression gates unchanged:** `scripts/macos_test.sh gate`, `scripts/ios_device.sh gate`. Exploratory agent QA only — not CI.

---

## 1. User config installed

| Item | Status |
| --- | --- |
| `~/.cursor/bin/mcp_stdio_wrapper.sh` | Created, executable (`exec npx -y "$@"`) |
| `~/.cursor/mcp.json` → `peekaboo` | Added (wrapper → `@steipete/peekaboo mcp`) |
| `~/.cursor/mcp.json` → `mirroir` | Added (wrapper → `mirroir-mcp`) |
| `~/.mirroir-mcp/settings.json` | **`mirroringProcessName` override for French macOS** (see §5) |
| Existing `context7`, `xcodebuildmcp` | Preserved |

---

## 2. TCC + Cursor MCP panel (2026-07-01, post-restart)

| Check | Result |
| --- | --- |
| Screen Recording + Accessibility for **Cursor.app** | **Granted** (System Settings; initial repeat-prompt quirk resolved after grant + restart) |
| Cursor → Settings → Tools & MCP | **Connected** (green) for all servers |
| **peekaboo** tools enabled | **27** |
| **mirroir** tools enabled | **11** (curated MCP subset; full catalog is larger) |
| **context7** / **xcodebuildmcp** | Unchanged (2 / 59+4 tools) |

**TCC note:** Cursor may prompt for Screen Recording even when “Cursor” is already ON in Settings — the MCP child chain (`npx` → Node → Peekaboo/mirroir) can need a fresh Allow from an in-app tool call. See [`computer-use-mcp-alternatives-cursor.md`](computer-use-mcp-alternatives-cursor.md) troubleshooting.

---

## 3. Wrapper + stdio validation (initial probe)

| Check | Result |
| --- | --- |
| Wrapper → `peekaboo permissions status` | Pass — Screen Recording, Accessibility, Event Synthesizing granted (terminal probe) |
| Live validation | **Superseded by §2** — Cursor MCP panel green after TCC + restart |

---

## 4. macOS Vocello — FULL generate loop via Peekaboo MCP (2026-07-01 evening)

**Validated end to end in Agent chat**, paired with the restored measurement shell
[`scripts/uitest_measure.sh`](../../scripts/uitest_measure.sh):

| Step | Result |
| --- | --- |
| `uitest_measure.sh reset` + `prep` (debug-data mode, single-instance guard) | Pass |
| Peekaboo `see` on Vocello | Pass — **291 AX elements** incl. all `accessibilityIdentifier`s (`sidebar_*`, `textInput_*`, `customVoice_readiness`, …) |
| `click` editor + `type` 126-char script | Pass — `textInput_charCount` = “126 characters”, readiness → ready |
| `hotkey cmd,return` (app-targeted) | Pass — generation started |
| `uitest_measure.sh verify-generation custom` | **Pass** — WAV (365 KB, 7.52 s) + `history.sqlite` row matched, `result.json` written |
| `uitest_measure.sh streaming-preview-check` | **Pass** — Live Engine Play + Autoplay Start before final; 0 underruns, 0 chunk gaps |
| `uitest_measure.sh finish` | Pass — debug flag cleared |

**Hard-won operational rules (encoded in the shell):**

1. **Never** `tell application "Vocello" to activate` / `open -na` while a measured
   session runs — LaunchServices can spawn a **second instance without debug mode**
   whose takes land in the user's real library. `prep` writes the persisted DebugMode
   flag + enforces a single instance; `activate` targets the PID via System Events;
   `finish` clears the flag.
2. **Signpost store lag:** `log show` exposes fresh `os_signpost` events only after a
   multi-minute logd flush. `bench-wait` therefore waits on the **history.sqlite row**
   (written at the same instant as “Final File Ready”) and uses the signpost store as
   fallback; `streaming-preview-check` queries with `--start <since>` (not `--last Nm`).
3. Peekaboo `type`/`hotkey`: click the field first (`foreground: true`), then type at
   focus; target hotkeys at the app (`app: "Vocello"`).

Per-mode procedures: [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md).

---

## 5. iOS mirroir — blocked on localized window name, fix staged

| Step | Result |
| --- | --- |
| `scripts/ios_device.sh build` + `install` + `launch` | Pass (app on device, foreground) |
| iPhone Mirroring up (`ios_device.sh mirror`) | Pass — window present |
| mirroir `status` / `describe_screen` | **FAIL — “'iphone' is not open”** |
| Root cause | mirroir-mcp looks up the Mirroring window by process name **“iPhone Mirroring”**; French macOS names it **“Recopie de l’iPhone”** |
| Fix | `~/.mirroir-mcp/settings.json` → `{"mirroringProcessName": "Recopie de l’iPhone"}` ([config reference](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/configuration.md)) |
| Status | **Settings written; requires Cursor restart** (mirroir reads settings at server startup) — re-run the Studio tour after restart |

**Planned tour after restart:** `check_health` → `describe_screen` → Studio tab smoke
(Custom/Design/Clone segments) → Settings → Model Downloads (drive the one-time
Voice Design (Speed) install the hardened gate needs) → evidence via `ios_device.sh shot`.

---

## 6. Summary

| Goal | Status |
| --- | --- |
| Peekaboo connected + full macOS generate loop | ✅ **Done** (verified WAV + DB + streaming health) |
| Deterministic measurement decoupled from driving | ✅ `uitest_measure.sh` restored |
| mirroir connected | ✅ (11 tools) |
| mirroir driving Vocello iOS | ⏳ blocked on Cursor restart for the localization fix |
| Gates | Unchanged — XCUITest + script lanes remain authoritative |

---

## 7. Closure (2026-07-04) — **historical / superseded by §8**

> **Do not treat this section as current.** Same-day evening work in **§8** restored Peekaboo +
> mirroir for exploratory QA; mobile-mcp `bench-ui-mcp` remains **deferred**. Current lanes:
> [`testing-runbook.md`](testing-runbook.md) harness matrix.

| Action | Status |
| --- | --- |
| Remove `peekaboo` + `mirroir` from `~/.cursor/mcp.json` | Done |
| Add `mobile-mcp` (`@mobilenext/mobile-mcp@0.0.61`, telemetry off, stdio wrapper) | Done |
| iOS agent UI | **mobile-mcp** + `bench-ui-mcp` — see [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) |
| macOS agent UI | Script gates + `uitest_measure.sh` + Axiom (Peekaboo no longer in MCP config) |

---

## 8. Full re-validation (2026-07-04 evening)

After restoring **Peekaboo** + **mirroir** in `~/.cursor/mcp.json` (stdio wrapper unchanged).

### Phase 1 — connectivity smoke

| Check | Result |
| --- | --- |
| Peekaboo `permissions` | **Pass** — Screen Recording + Accessibility granted |
| mirroir `check_health` | **Pass** — mirroring window 326×720, capture OK |
| mirroir `status` | **Pass** — connected, mirroring active (not paused) |

### Phase 2 — macOS full generate loop (Peekaboo)

| Step | Result |
| --- | --- |
| `uitest_measure.sh prep` (debug-data mode) | Pass |
| Peekaboo `see` (`PID:77904`) | Pass — **291 AX elements** (`screen_customVoice`, `textInput_*`, …) |
| `click` editor + `type` 117-char script | Pass — `customVoice_readiness` → `ready=true` |
| `hotkey cmd,return` (`app: Vocello`) | Pass |
| `verify-generation custom` | **Pass** — WAV 392 KB, 8.08 s, `db_id=307` |
| `streaming-preview-check` | **Pass** — 1 Live Engine Play, 0 underruns, 0 chunk gaps |
| `finish` | Pass |

### Phase 3 — iOS Studio tour (mirroir + Peekaboo mirror clicks)

| Step | Result |
| --- | --- |
| `ios_device.sh device-state` | Pass |
| `build` + `install` + `launch` | Pass |
| `ios_vision_bridge.sh calibrate` | Pass — `Recopie de l'iPhone` rect 919,30,326,720 (2026-07-04); **1062,132,218,486** left-edge compact window (2026-07-06). Policy: any fixed position per session + mandatory `calibrate` after move/resize — not centered. |
| mirroir `describe_screen` (Studio / Custom) | Pass — segments + composer OCR |
| Segment taps (Custom / Design / Clone) | **Pass** — distinct OCR per segment |
| Tab: Settings (`to-global` + Peekaboo click y≈690) | **Pass** — VOICE MODELS, Storage, … |
| Tab: Studio (label y≈619) | **Pass** — returned to composer |
| Tab: History (label y≈618) | **Pass** — search + generation rows |
| Tab: Voices | **Partial** — tab tap did not switch screen in this session |
| `ios_device.sh shot` | Pass — `build/ios/mcp-tour-20260704-1910.png` |

**iOS hybrid rule confirmed:** mirroir `describe_screen` → `ios_vision_bridge.sh to-global` → Peekaboo
`click coords:` with `foreground: true`. Segment controls (top bar) are reliable; bottom tab bar may
need label coords (y≈619–690) — icon-only taps at y≈719 were inconsistent.

### Phase 3 summary

| Goal | Status |
| --- | --- |
| Peekaboo + mirroir connected | ✅ |
| macOS generate loop | ✅ (reproduced Jul 1 pilot) |
| iOS mirroir perception + hybrid navigation | ✅ (segments + Settings/History; Voices flaky) |
| Gates | Unchanged |

---

## 9. mirroir hardening (2026-07-04 evening)

Research: [mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) docs + failed agent generate session (0/3 clips).

### Root causes (agent session)

| Issue | Cause |
| --- | --- |
| `describe_screen` / `check_health` capture fail | TCC / cross-Space / paused mirror — while `ios_device.sh shot` still worked |
| Only ~11 mirroir tools | **fail-closed** default — no `permissions.json` → `tap`/`type_text` hidden |
| Peekaboo hybrid coord miss | Generate tap hit **NE** chip (~30–40 px) — no OCR anchor |
| Bottom **Studio** tab taps | Flaky — **Aiden row** shortcut worked |

### Repo changes (implemented)

| Artifact | Purpose |
| --- | --- |
| [`.mirroir-mcp/permissions.json`](../../.mirroir-mcp/permissions.json) | Expose tap/type/measure; skip destructive labels |
| [`.mirroir-mcp/settings.json`](../../.mirroir-mcp/settings.json) | Force OCR mode, `en-US` |
| [`.mirroir-mcp/skills/apps/Vocello/APP.md`](../../.mirroir-mcp/skills/apps/Vocello/APP.md) | mirroir exploration context |
| [`scripts/install_mirroir_user_config.sh`](../../scripts/install_mirroir_user_config.sh) | Copy permissions + merge settings to `~/.mirroir-mcp/` |
| [`scripts/ios_mirroir_preflight.sh`](../../scripts/ios_mirroir_preflight.sh) | device-state, mirror, bridge calibrate |
| [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix B | Native driving loop (preferred over Peekaboo hybrid) |

### Operator steps (once per machine)

```bash
scripts/install_mirroir_user_config.sh --merge-settings
# Cmd+Q Cursor → reopen
scripts/ios_mirroir_preflight.sh --doctor
# In Agent: mirroir check_health → describe_screen on Studio/Custom
```

**Driving rule:** `describe_screen` → **`mirroir tap`** (not Peekaboo on mirror). Peekaboo stays **macOS Vocello only**.

### Next validation

| Step | Expected |
| --- | --- |
| mirroir tool count | ~25+ after permissions + Cursor restart |
| `check_health` | Pass — window 326×720, capture OK |
| Custom generate smoke | OCR **Generate** coords → tap → `measure` until player |
| 3 funny clips retry | Native loop only |

---

## 10. Anti-patterns and efficiency remediation (2026-07-04 night)

Follow-up to the **post-restart 3-clip Custom smoke** (3/3 success, ~20–30% wasted actions).
Invariants codified in [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix **B.5–B.6** and
[`.cursor/rules/agent-ui-driving.mdc`](../../.cursor/rules/agent-ui-driving.mdc).

### Observed anti-patterns (Jul 4 run)

| Anti-pattern | Cost | Fix |
| --- | --- | --- |
| Tap coords without OCR (e.g. guessed dismiss) | Wrong state / recovery taps | **OCR-only** — B.5 |
| **Voices tab ×2** mid-Studio between clips | +4–6 taps | **Stay on Studio** — B.5 / B.6 |
| **130 s fixed sleep** after 5 s clip | ~125 s wasted | **Poll / measure** every 5–8 s |
| Duplicate `ios_device.sh mirror` | Redundant setup | Preflight once |
| Screenshot + read image unprompted | Context noise | Evidence only on OCR fail |
| `press_key` without Auto-review approval | Failed round-trip | `requestSmartModeApproval` upfront |

### Validation acceptance (3-clip Custom smoke, native mirroir)

Re-run under B.5–B.6 rules and record:

| Metric | Target |
| --- | --- |
| Illegal transitions | **0** (see B.6 table) |
| UI actions per clip | **≤15** (describe_screen + tap/type + dismiss) |
| Idle wait per generate | **<30 s** wall-clock beyond actual TTS (poll, don't sleep) |
| Voices tab opens mid-session | **0** |

Results: see **§10.1** below after validation rerun.

### §10.1 Validation rerun results (2026-07-04, B.5–B.6 rules)

**Session:** `ios_mirroir_preflight.sh --native-only`; mirror active; commit `3b7fc12`.

#### First rerun (pre-commit, partial)

| Metric | Clip 1 | Clip 2 | Clip 3 | Target |
| --- | --- | --- | --- | --- |
| Illegal transitions | 0 | 0 | — | 0 |
| Voices tab opens | 0 | 0 | — | 0 |
| Outcome | **PASS** | **BLOCKED** (X OCR) | — | 3/3 |

#### Second rerun (post-commit push, 22:00 session)

| Clip | Voice / delivery | Script (abbrev) | Duration | Notes |
| --- | --- | --- | --- | --- |
| 1 | Aiden / NE | houseplant Wi-Fi | ~5 s | Generate → 8 s poll → **X + Dismiss** worked once |
| 2 | Ryan / Happy | GPS → furniture store | ~5 s | Clean relaunch; type-only (no Cmd+A); 0 illegal transitions |
| 3 | Ono Anna / Excited | smart fridge / salad | ~7 s | Relaunch between clips; History verified |

| Metric | Result | Target |
| --- | --- | --- |
| Illegal transitions | **0** | 0 |
| Voices tab opens mid-session | **0** | 0 |
| Poll wait per generate | **8–10 s** (not fixed 130 s) | <30 s idle |
| History top-3 rows | ono_anna 6.6s, ryan 4.6s, aiden 4.7s | match |

**Practical workarounds validated:**

- **Dismiss immediately** when **X** appears in OCR after generate (B.5).
- **`ios_device.sh launch`** between clips when **X** drops from OCR and inline player blocks **Generate**.
- **Type-only** on empty composer (`0/150`) — avoid Cmd+A replace on iOS mirror (mangles text).
- **Custom segment tap** sometimes resets to IDLE; unreliable when player persists — prefer relaunch.

**Remaining friction (G1–G4, addressed in B.7–B.8):**

| Gap | Symptom | Doc fix |
| --- | --- | --- |
| **G1** | **X** dismiss label intermittent in OCR | B.7 DISMISS_POLL (3×) then RESET |
| **G2** | Script mangling / type_text not sticking | B.7 script protocol; composer tap after sheets |
| **G3** | Generate tapped at `0/150` | B.8 gate: N > 0 before Generate |
| **G4** | Custom segment / Design hop recovery sprawl | B.7 RESET only; illegal transitions table |

Remove **Custom segment tap** from recommended recovery (§10.1 workaround retired).

### §10.2 Third validation (B.7–B.8)

**Session:** `ios_mirroir_preflight.sh --native-only`; mirror 326×720; French macOS **Recopie de l'iPhone**; uncommitted B.7–B.8 docs; 22:13–22:16 local.

| Clip | Voice / delivery | Script (abbrev) | Duration | Notes |
| --- | --- | --- | --- | --- |
| 1 | Aiden / NE | houseplant Wi-Fi | ~6 s | SCRIPT_VERIFY 85/150 → Generate; DISMISS_POLL **no X** → **`launch` RESET** |
| 2 | Ryan / Happy | GPS → furniture store | ~5 s | **X + Dismiss** worked; type-only on prior 74/150 script (no Cmd+A) |
| 3 | Ono Anna / Excited | smart fridge / salad | ~8 s | Cmd+A→delete **still mangled** 150/150 → **`launch` RESET**; Excited missed once → extra generate tap |

| Metric | Clip 1 | Clip 2 | Clip 3 | Session | Target |
| --- | --- | --- | --- | --- | --- |
| Illegal transitions | 0 | 0 | 0 | **0** | 0 |
| Voices tab opens | 0 | 0 | 0 | **0** | 0 |
| Resets (`launch`) | 1 | 0 | 1 | **2** | ≤2 |
| Empty Generate (`0/150`) | 0 | 0 | 0 | **0** | 0 |
| UI actions (tap/type/describe, approx.) | ~11 | ~12 | ~18 | — | ≤12/clip |
| Poll wait per generate | 8 s | 8 s | 8 s (+12 s retry) | — | <30 s idle |

**History verified (top TODAY rows):** `ono_anna` 8.5 s, `ryan` 4.7 s, `aiden` 6.1 s.

**B.7 outcomes:**

- **DISMISS_POLL → RESET** when **X** absent (clip 1) — no Custom-segment / Voices detours.
- **X + Dismiss** path when OCR shows **X** (clip 2) — preferred; leaves non-empty composer (acceptable before RESET or type-only if short).
- **Script replace:** `command+a` → `delete` → `type_text` **still corrupts** on mirror (clip 3) — **RESET** after failed SCRIPT_VERIFY is correct; prefer **`0/150` type-only** between clips.
- **`reset_app` name=`Vocello`:** failed pre-run (*Cannot locate 'Vocello' card in App Switcher unambiguously*). **`scripts/ios_device.sh launch`** (~3 s) used for all RESETs — document as **primary** on this mirror setup until `reset_app` is re-tested.

**Remaining friction (post B.7–B.8):**

| Issue | Mitigation |
| --- | --- |
| Delivery **Confirm** → Generate too fast | B.8: re-OCR after Confirm; chip must show new delivery (e.g. `EX ^`) before Generate |
| Non-empty composer between clips without RESET | Use **RESET** or accept type-only append risk — do not Cmd+A replace on mirror |

### §10.3 Nine-clip multi-mode validation (B.5–B.8)

**Session:** 2026-07-04, ~22:57–23:15 local; `ios_mirroir_preflight.sh --native-only` **PASS**; mirror **326×720**; French macOS **Recopie de l'iPhone**; `scripts/ios_device.sh device-state` **PASS** (MIRROR_ACTIVE); `models check --strict` **PASS** (pro_custom / pro_design / pro_clone Speed; **5** clone voices enrolled). Clone reference: first saved voice **AD** (*A deep, low-pitched*) — pre-enrolled, not Design-saved this session.

#### Results

| # | Mode | Voice / brief / ref | Script (abbrev) | Duration | Pass |
| --- | --- | --- | --- | --- | --- |
| C1 | Custom | Aiden / NE | houseplant Wi-Fi independence | 5 s | **PASS** |
| C2 | Custom | Ryan / Happy | GPS → furniture store | 6 s | **PASS** |
| C3 | Custom | Ono Anna / Excited | smart fridge / salad wallpaper | 5 s | **PASS** |
| D1 | Design | grumpy pirate brief | treasure map → parking lot | 6 s | **PASS** |
| D2 | Design | sports announcer brief | laundry turn / folding table | 5.5 s | **PASS** |
| D3 | Design | meditation guru brief | breathe / toaster enlightenment | 4.9 s | **PASS** |
| CL1 | Clone | **AD** (*A deep, low-pitched*) | elevator stand-up comedy warning | 5.0 s | **PASS** |
| CL2 | Clone | **AD** (same ref) | clone answers emails / meeting invites | 7.4 s | **PASS** |
| CL3 | Clone | **AD** (same ref) | rock-paper-scissors identity dispute | 6.5 s | **PASS** |

**History verified (TODAY, top 9 session rows):** three Clone (`A deep, lo…` 6.5 s / 7.4 s / 5.0 s), three Design (`A calm m…` 4.9 s, `An overen…` 5.5 s, `A grumpy…` 6.2 s), three Custom (`ono_anna` 5.4 s, `ryan` 5.7 s, `aiden` 5.2 s) — **9/9** with transcripts + durations.

#### Metrics vs targets (B.7)

| Metric | Result | Target |
| --- | --- | --- |
| Clips completed | **9/9** | 9/9 |
| Illegal transitions | **0** | 0 |
| Voices-tab detours (mid-block param changes) | **0** | 0 |
| Resets (`launch` / `launch_app`) | **3** (1× `ios_device.sh launch` failed; 2× mirroir `launch_app` Vocello) | ≤4 |
| Empty Generate (`0/150`) | **0** | 0 |
| Avg actions per clip (approx.) | Custom ~12; Design ~16; Clone ~14 | ≤15 |

#### What went well

- **Custom block** end-to-end with **X → Dismiss confirm** when OCR shows **X**; voice/delivery sheet **Confirm** + SCRIPT_VERIFY before Generate.
- **Mode segment switches** (Custom / Design / Clone @ y ≈ 108) without leaving **Studio** tab.
- **Design brief sheet:** type brief → **Confirm** → chip abbrev (e.g. `AN`, `A`) + script → Generate.
- **Clone reference reuse:** pick **AD** once in Reference clip sheet; chip persisted for CL2–CL3 without re-opening sheet.
- **History → Studio tab hop** surfaces **X** on Design inline player when **Save as voice** row hides dismiss affordance.
- **Triple-delete recovery** after G2 corruption restored `0/150` without full app relaunch (D3, CL2).

#### What didn't / friction (G1–G4 + new)

| Gap | Symptom | Mapping |
| --- | --- | --- |
| **G1** | **X** absent on Design complete card when **Save as voice** visible | DISMISS_POLL miss → **History → Studio** then **X @ (276, 574)** |
| **G2** | `command+a` → `delete` → `type_text` merges old + new script (`150/150`) | D3 prep, CL2 — use **triple-delete** or **`launch_app` RESET**; type-only on `0/150` |
| **G3** | — | No empty Generate taps this session |
| **G4** | — | No Custom-segment / Voices-tab recovery sprawl |
| **G5 (new)** | Design player **share** icon OCR `*` @ ~(240, 534) opens **iOS share sheet** — not dismiss | Avoid; use **X** coord only |
| **G6 (new)** | Tap **(277, 574)** while **Save as voice** prominent opened **Save Generated Voice** sheet | Close **X @ (286, 121)**; do not confuse with dismiss |
| **G7 (new)** | `type_text` skipped em dash (—) in D2 sports script | Use ASCII hyphen or verify counter after type |
| **Ops** | `ios_device.sh launch` failed once (mirror disconnect); `reset_app` Vocello still refuses App Switcher card | **`launch_app` Vocello** via Spotlight worked as fallback RESET |

**User note (Design → Clone):** persist a designed voice for Clone reuse via inline **Save as voice** (not share/export). This session used a **pre-enrolled** clone reference (**AD**); no Design voices were saved.

#### Per-mode notes

| Mode | Relative difficulty | Notes |
| --- | --- | --- |
| **Custom** | Lowest | Familiar from §10.1–§10.2; dismiss path reliable when **X** in OCR |
| **Design** | Highest | Brief sheet + dual readiness; post-generate UI differs (**Save as voice** vs bookmark/dismiss); dismiss needs tab hop or patience for **X** |
| **Clone** | Medium | Reference pick once; generation ~5–7 s; G2 on script replace between clips |

#### Recommendations

1. **Appendix B.7:** add Design-specific dismiss — when **Save as voice** @ y ≈ 576 and **X** missing, **History → Studio** then **X @ (276, 574)** before next clip.
2. **Appendix B.8 / OCR table:** mark Design **share** (`*`) and **Save as voice** as **non-dismiss** targets; document **Save as voice** → enrolled voice for Clone (§5.4 pool).
3. **Script protocol:** prefer **triple-delete** over single delete after Cmd+A when corruption detected; **`launch_app`** when counter stuck at `150/150`.
4. Re-test **`reset_app` Vocello** and **`ios_device.sh launch`** mirror-disconnect recovery on owner device.

### §10.4 mirroir agent UI bench pilot (`bench-ui-mirroir`)

**Session:** 2026-07-05, ~12:08–12:17 local; implementation + infrastructure validation pass; **full agent-driven take loop not completed** in this Cursor agent session (mirroir MCP could not attach to mirror window).

#### Infrastructure validated

| Check | Result |
| --- | --- |
| `scripts/ios_device.sh bench-ui-mirroir --agent-drive` wired | **PASS** — dispatches `_ios_agent_bench_ui mirroir` |
| Matrix manifest (custom/medium/warm 1) | **PASS** — 2 takes (`custom/medium/cold#0`, `custom/medium/warm#0`) in `manifest.json` |
| `models check --strict` | **PASS** — all Speed tiers + 5 clone voices |
| `vision-launch --run-id … --force-cold 1` | **PASS** — sets `QWENVOICE_UI_TEST_HOOKS=1` + bench runID |
| iOS build + install (Clear script hook) | **PASS** — `IOSStudioBenchHooks` OCR **Clear script** capsule @ top-leading |
| Docs (B.6d, §4.7c, Playbook G, runbooks) | **PASS** — committed with lane |

#### Agent session blocker

| Tool | Result |
| --- | --- |
| `mirroir check_health` (MCP) | **FAIL** — `'iphone' process is not running`; screen capture failed |
| `mirroir list_targets` (MCP) | `iphone (active): notRunning (no window)` |
| `mirroir describe_screen` (MCP) | **FAIL** — `Target 'iphone' is not running` |
| `mirroir doctor` (CLI) | **PASS** — 326×720 portrait, permissions OK |
| `ios_device.sh device-state` | **PASS** — MIRROR_ACTIVE |

**Likely cause:** Cursor mirroir MCP server stale vs French macOS process name (**Recopie de l'iPhone**). Added `mirroringProcessName` to repo `.mirroir-mcp/settings.json`; **Cursor MCP restart** required before agent can drive. Same macOS Space as mirror window also required.

#### Bench driver observation

Shell reached **2 planned takes — agent drive begins** and wrote `manifest.json` + `session.env` under `build/ios/bench-ui-mirroir-ios-bench-ui-mirroir-20260705-121207/`. **`MIRROIR_BENCH_TAKE_BEGIN` blocks were not consumed** — agent could not tap/type; background shell sessions terminated before take loop output when run from agent tooling (attended owner session recommended).

#### Gate parity (deferred → **completed 2026-07-05 ~12:28**)

Full **2/2 take PASS** with `check_ios_ui_bench.py`:

```sh
scripts/ios_device.sh device-state
scripts/ios_mirroir_preflight.sh --native-only
# Restart Cursor MCP if describe_screen still fails
scripts/ios_device.sh bench-ui-mirroir --agent-drive \
  --warm 1 --lengths medium --modes custom --label mirroir-bench-pilot
```

Per take: B.6d loop → `vision-bench-wait` → `touch take-N.done`. Optional compare: matching subset via XCUITest `bench-ui` (Phase C).

#### Pilot results (2026-07-05 ~12:27–12:29)

**Session:** mirroir MCP healthy after reconnect; `runID=ios-bench-ui-mirroir-20260705-122747`. Agent drove B.6d manually (orchestrator shell blocked in background during xcodebuild — same per-take steps).

| Take | Mode | Warm | Clear script | Generate | vision-bench-wait | Gate |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | custom/medium | cold | n/a (empty launch) | PASS (111/150) | PASS ~4.7 s | — |
| 2 | custom/medium | warm | **PASS** (0/150, player dismissed) | PASS | PASS ~4.5 s | — |

**Gate:** `check_ios_ui_bench.py --run-id ios-bench-ui-mirroir-20260705-122747 --expected 2` → **PASS** (custom medium cold n=2 QC=pass).

**Validated:** OCR **Clear script** @ ~(64, 106); warm take reset without dismiss poll or `vision-launch` fallback; telemetry proof via `vision-bench-wait` (not OCR "Just now").

#### Phase B multi-mode pilot (2026-07-05 ~12:36–12:48)

**Session:** `runID=ios-bench-ui-mirroir-20260705-123609`; `--modes custom,design,clone --lengths medium --warm 1` → **5 takes** (clone block warm-only per matrix).

| Take | Label | Mode prep | Clear script | Generate | Telemetry |
| --- | --- | --- | --- | --- | --- |
| 0 | custom/medium/cold#0 | Custom (cold launch) | n/a | PASS | PASS |
| 1 | custom/medium/warm#0 | — | PASS | PASS | PASS |
| 2 | design/medium/cold#0 | Design + STARTING POINTS brief | n/a | PASS (~7 s UI) | PASS (row poll; `vision-bench-wait` hung — no timestamps on rows) |
| 3 | design/medium/warm#0 | brief chip retained | PASS | PASS | PASS (row poll) |
| 4 | clone/medium/warm#0 | Clone + **AD** reference | n/a | PASS | PASS (row poll) |

**Gate:** `check_ios_ui_bench.py --run-id ios-bench-ui-mirroir-20260705-123609 --expected 5` → **PASS** (custom n=2, design n=2, clone n=1; QC=pass).

**Friction:** Design take 2 — `vision-bench-wait` timed out when row count >1 and `createdAt` missing on telemetry rows; row-count poll workaround used for takes 2–4. Clone reference pick: first tap landed on Custom; re-open sheet + tap row body → **AD ^** chip staged correctly.

---

## Archived agent bench (deprecated 2026-07-07)

> **Retired.** Full UI matrix = XCUITest `scripts/ios_device.sh bench-ui` only. Agent smokes use
> mirroir 1-clip + `measure-*` (`docs/reference/ui-smoke-runbooks.md`). Content below is
> historical reference for the removed `bench-ui-mirroir` lane.

### B.6d procedure (historical)

Entry (removed):

```sh
scripts/ios_device.sh bench-ui-mirroir --agent-drive \
  --warm 1 --lengths medium --modes custom --label mirroir-bench-pilot
```

Per-take loop: shell printed `MIRROIR_BENCH_TAKE_BEGIN` → agent mode prep → Clear script →
type corpus → `vision-now` before Generate → `vision-bench-wait` → `touch take-N.done`.

Pilot PASS artifacts: `ios-bench-ui-mirroir-20260705-122747` (2/2), `ios-bench-ui-mirroir-20260705-123609` (5/5).

**Why retired:** duplicated XCUITest `bench-ui` with OCR fragility (window size, Generate vs chip Y,
permission restarts). See iOS UI testing simplification plan (2026-07-07).

