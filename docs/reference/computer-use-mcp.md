# Computer-use driving (native, vision-first)

Canonical guide for driving the Vocello **Debug build** with the **native `computer-use` MCP** (`mcp__computer-use__*`) plus the agent's own vision. Pair with [`ui-test-surface.md`](ui-test-surface.md) for element labels, smoke/bench skeletons, and verification commands.

The driving model is deliberately thin: **the agent looks at a screenshot, finds the element by sight, and clicks its pixel — no AX-id resolution, no coordinate scaling, no System-Events AppleScript.** All *measurement* stays in the harness (OSSignpost + SQLite), so timing accuracy never depends on how the UI was driven.

## What changed vs. the legacy flow

| Legacy (Cursor `user-computer-use` + osascript) | Native vision-first |
|---|---|
| `CallMcpTool` server `user-computer-use`, tool `computer`, `action:` dispatch | `mcp__computer-use__screenshot` / `left_click` / `type` / `key` |
| `scripts/uitest.sh screen-locate <ax-id> $IW $IH` → scaled pixel coords | Look at the screenshot, click the element's pixel directly |
| `scripts/uitest.sh locate <ax-id>` (System Events) for presence checks | Read the screenshot; the element is either visible or it isn't |
| System Events Accessibility grant required for driving | Only the computer-use access grant for `Vocello` |
| `super` = Command | `cmd` = Command |

`locate` / `screen-locate` still exist in `scripts/uitest.sh` as an **optional fallback** (see "When vision is ambiguous"), but they are no longer on the happy path.

## Access (once per session)

`mcp__computer-use__request_access` for application `Vocello`. Vocello is a normal native app → **full tier** (clicks and typing both work). Run every shell command (`scripts/uitest.sh …`, builds, DB queries) through the **Bash tool**, never through computer-use — Terminal/IDE apps are restricted tiers where typing is blocked.

## Tool mapping

| Intent | Native call |
|---|---|
| Capture screen | `mcp__computer-use__screenshot` (you see the image; pick coordinates by sight) |
| Click | `mcp__computer-use__left_click`, `coordinate: [x, y]` (screenshot pixel space) |
| Type into focused field | `mcp__computer-use__type`, `text: "..."` (click the field first) |
| Key / chord | `mcp__computer-use__key`, `text: "cmd+Return"` |
| Scroll | `mcp__computer-use__scroll` |

Common chords: `cmd+Return` (Generate), `cmd+a` (select all), `BackSpace`, `Down`, `Up`, `Return`.

## Per-turn ritual

1. `scripts/uitest.sh activate` (Bash) — bring Vocello to the front.
2. `mcp__computer-use__screenshot` — look at the current state.
3. Decide the target **by sight** and `left_click` its pixel; or skip straight to a keyboard chord when one exists (preferred — see below).
4. Re-`screenshot` to confirm the result before the next step.

**Window focus:** clicking an unfocused window may only raise it. If an action had no visible effect in the verifying screenshot, click the same target once more — the window is now focused and the second click registers.

## Keyboard-first driving (fewer clicks = faster + less flaky)

Prefer keys over hunting for buttons. The app exposes:

| Chord | Effect |
|---|---|
| `cmd+Return` | Generate on the current generation screen (Custom / Design / Cloning) |
| `cmd+a` | Select all in the focused field |
| `BackSpace` | Delete the selection (use after `cmd+a`) |
| `cmd+comma` | Open Settings |

The only unavoidable clicks are: switching the sidebar mode, selecting the Speed/Quality variant, and focusing the script field. Everything else is keyboard.

## Standard generate sequence

For any mode that uses the script composer:

1. `screenshot` → click the script text area (the large multi-line field).
2. Optional clear: `key` `cmd+a` → `key` `BackSpace`.
3. `type` the fixed prompt.
4. Capture `T0` **immediately before** Generate (search anchor only — not the measured value):
   ```sh
   T0="$(/usr/bin/python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])')"
   ```
5. `key` `cmd+Return`.
6. Verify + record via the harness (`bench-step` for timing, or `verify-generation` for smoke). Timing comes from OSSignposts, so it is independent of your click/type latency.

## Driving SwiftUI Picker menus

SwiftUI `Picker` menus open **anchored to the currently-selected item**, not a fixed position — so a remembered pixel only works for the first open in a session. Drive them by **keyboard**, which vision-verify confirms:

1. Click the picker to open it.
2. `key` `Down` (or `Up`) N times from the current selection to the target.
3. `key` `Return` to commit.
4. Re-`screenshot` and confirm the displayed value; track the current selection so you can compute N next time.

Affected pickers: delivery tone, delivery intensity, saved-voice picker, model-variant pickers.

## When vision is ambiguous (optional fallback)

Vision handles every element directly, including the ones the AX tree hides (variant Speed/Quality buttons, open picker rows) — those used to require a "pure visual" fallback anyway. If two controls are visually identical and you cannot disambiguate from the screenshot, you may fall back to:

- `scripts/uitest.sh locate <ax-id>` — exit 0 confirms the element is on the front window (a presence check; needs System-Events Accessibility granted to the terminal). Useful to assert "the right screen is mounted" before driving.
- `scripts/uitest.sh screen-locate <ax-id> <img-w> <img-h>` — returns screenshot-pixel coords for that id. Only needed when sight genuinely can't separate two controls.

Treat both as escape hatches, not the default.

## Harness commands (shell — measurement & lifecycle)

These are the accurate backend and stay exactly as-is. Run via Bash.

| Command | Purpose |
|---|---|
| `scripts/uitest.sh prep` | Build-launch + fresh window |
| `scripts/uitest.sh reset` | Clear generations + outputs (resets warm state for a cold sample) |
| `scripts/uitest.sh activate` | Front Vocello |
| `scripts/uitest.sh smoke-check <mode>` | Precondition gate |
| `scripts/uitest.sh verify-generation <mode> …` | Post-generate WAV + DB check |
| `scripts/uitest.sh bench-step <mode> <variant> <coldwarm> <bucket> …` | One bench sample (wait on signpost + record) |
| `scripts/uitest.sh bench-summarize <dir>` / `bench-compare <dir>` | Summarize / diff against baselines |
| `scripts/uitest.sh db "<sql>"` | Read-only history query |

Full list: `scripts/uitest.sh help`.

## Forbidden paths

- **`user-automation-mcp`** and **osascript `keystroke` / `click at`** — global coords hit whatever window has focus; never use for Vocello UI.
- **Remembered Picker menu-item coordinates** after the first open in a session — use the keyboard pattern above.
- **`window-locate` / `scaled-locate`** — dead legacy coordinate helpers; ignore.

## Permissions

- **computer-use access** — grant `Vocello` via `mcp__computer-use__request_access` (full tier).
- **Screen Recording** — only if `screenshot` returns black/empty.
- **System-Events Accessibility** — *only* needed if you use the optional `locate` / `screen-locate` fallback; the vision-first path does not require it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Text typed into wrong app | `scripts/uitest.sh activate`, re-`screenshot`, click the field, retry `type` |
| Click had no effect | Window was unfocused — click the same target again |
| Click landed off-target | Re-`screenshot`, pick the corrected pixel by sight |
| Screen looks stale after an action | Re-`screenshot`; SwiftUI may need ~500 ms to settle, then retry |
| Readiness line unchanged after type | Editor wasn't focused — click the script field before `type` |

## Agent bench gate (6-cell review)

For targeted backend reviews (e.g. streaming regression), see [`bench-agent-gate.md`](bench-agent-gate.md).
