# Smoke Runbook: Saved Voices surface lists and plays `UITestRef`

Lightweight functional smoke that exercises the Saved Voices library: the screen mounts, the `UITestRef` fixture is listed, and clicking its play button triggers playback.

Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

- Debug build present.
- macOS Accessibility permission granted to Claude.
- The `UITestRef` saved-voice fixture exists. `scripts/uitest.sh smoke-check clone` should exit 0. If not, run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md) first.

## Fixed inputs

| Field | Value |
|---|---|
| Saved voice name asserted | `UITestRef` |
| Expected list state | ≥ 1 row (the fixture); voice quality warning may be present (short reference) |

## Steps

1. **Precondition**: `scripts/uitest.sh smoke-check clone`. Abort on non-zero.
2. **Reset**: `scripts/uitest.sh reset` (keeps voices/ — the fixture survives).
3. **Artifacts + log capture**:
   ```sh
   ART=$(scripts/uitest.sh artifacts-dir)
   (scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)
   LOG_PID=$!
   ```
4. **Launch**: `scripts/uitest.sh prep`.
5. **Access**: `mcp__computer-use__request_access(applications: ["Vocello"])`.
6. **Navigate to Saved Voices**:
   - `read SW SH < <(scripts/uitest.sh screen-size)`.
   - `scaled-locate sidebar_voices 1456 816` → `mcp__computer-use__left_click`.
   - Verify with `scripts/uitest.sh locate screen_voices` (exit 0).
   - `/usr/sbin/screencapture -x "$ART/pre.png"`.
7. **Verify the `UITestRef` row is present**:
   - The row's accessibility id is keyed by voice ID — `voicesRow_<uuid>` per the surface doc. The bootstrap doesn't expose the uuid externally, so the agent locates the row visually by reading the row text in the screenshot. Confirm `UITestRef` text is visible.
   - Optionally try `locate voicesRow_UITestRef` (if the id is keyed by name rather than uuid — possible variation across builds). Record what works.
   - The list MAY show a quality-warning badge (short reference clip; expected for the bootstrap fixture).
8. **Click the row's play affordance**:
   - Per the surface doc, the per-row play button uses id `voicesRow_<id>_play`. Try `locate voicesRow_UITestRef_play` first; fall back to visual click on the play icon adjacent to the `UITestRef` row.
   - Confirm playback by inspecting the sidebar Player section (the reference audio should start playing; takes ~1 s to render).
9. **Use the voice in cloning** (optional bonus check):
   - The row's "Use" affordance routes to Voice Cloning with the reference bound. Try `locate voicesRow_UITestRef_use`. If clicking it switches the sidebar selection to Voice Cloning AND `voiceCloning_savedVoicePicker` shows `UITestRef`, that confirms the "use" flow.
10. **Post-screenshot + tear down**: `/usr/sbin/screencapture -x "$ART/post.png"`, then `kill "$LOG_PID" 2>/dev/null || true`.
11. **Write `$ART/result.json`** with:
    - `pass`: true if (a) `UITestRef` row visible, (b) row's play affordance can be located/clicked, (c) playback started
    - `screen`: `voices`
    - `rows_visible`: count of saved-voice rows visible
    - `quality_warning_present`: bool
    - `discovered_ax_ids`: any concrete row/play/use identifiers observed
    - `timestamp`
12. **Report** $ART/, pass/fail, and any new AX IDs.

## Notes

- This runbook does NOT enroll a new voice or delete the fixture — both would corrupt the test fixture used by Voice Cloning. Those flows can be exercised by separate runbooks if needed.
- The "quality warning" present on `UITestRef` is expected — the bootstrap reference is shorter than the 10-second recommendation. This isn't a failure; it's a warning the saved-voice library surfaces and we acknowledge.
