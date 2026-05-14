# Smoke Runbook: Custom Voice generate → verify

End-to-end check that exercises the autonomous-UI foundation: launch the Debug build, drive Custom Voice through one short generation via computer-use, and verify completion three ways (log signpost, output `.wav`, history DB row).

Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

- Vocello Debug build exists at `build/DerivedData/Build/Products/Debug/Vocello.app`. If not, run `scripts/build.sh debug`.
- At least one Custom Voice model variant is installed (the runbook checks via `scripts/uitest.sh smoke-check`).
- macOS Accessibility permission granted to Claude.

## Fixed inputs

| Field | Value |
|---|---|
| Speaker | the app default (Aiden) — do not change |
| Script text | `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.` |
| Variant | whichever variant is the app default for this Mac |

The runbook does not adjust pickers — it tests the minimum-effort generate path.

## Steps

1. **Precondition: build present, models installed.**
   - If `[ -d build/DerivedData/Build/Products/Debug/Vocello.app ]` is false → `scripts/build.sh debug`.
   - `scripts/uitest.sh smoke-check` — abort the run if it exits non-zero.

2. **Reset to a known-clean state.**
   - `scripts/uitest.sh reset` (default mode — keep models and saved voices).

3. **Create the artifacts directory and start log capture.**
   - `ART=$(scripts/uitest.sh artifacts-dir)`
   - `scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &`
   - `LOG_PID=$!`
   - Remember `$LOG_PID` so step 13 can stop the capture.

4. **Launch the app.**
   - `scripts/uitest.sh prep` — prints the Vocello PID once the window is up.

5. **Computer-use: grant access and screenshot.**
   - `mcp__computer-use__request_access(applications: ["Vocello"])`
   - `mcp__computer-use__screenshot` — save bytes to `$ART/pre.png`.

6. **Navigate to Custom Voice.**
   - `scripts/uitest.sh locate sidebar_customVoice` → parse `cx cy w h` (logical-points).
   - `read SW SH < <(scripts/uitest.sh screen-size)`.
   - From the most recent screenshot, get its image width `IW` and height `IH`.
   - Compute `sx = cx * IW / SW`, `sy = cy * IH / SH`.
   - `mcp__computer-use__left_click(x=sx, y=sy)`.
   - If Vocello isn't frontmost, the click won't dispatch — call `mcp__computer-use__open_application(app: "Vocello")` first, then retry.

7. **Confirm Custom Voice screen is mounted.**
   - `scripts/uitest.sh locate screen_customVoice` — exit code 0 means the screen is up. If non-zero, screenshot, wait 500 ms, retry once.

8. **Enter the script text.**
   - The script-text field has accessibility identifier `textInput_textEditor` (shared across all three generation modes via `TextInputView`).
   - `scripts/uitest.sh locate textInput_textEditor` → scale → `mcp__computer-use__left_click`.
   - `mcp__computer-use__type` with the fixed script text.

9. **Trigger Generate.**
   - The app accepts **Cmd+Return** while the script field is focused — that's the simplest reliable trigger and matches the SwiftUI convention. There is no dedicated "Generate" button visible in the default Custom Voice viewport on a 1280×720 display.
   - Record `T_CLICK=$(date +%s%3N)` immediately before sending `mcp__computer-use__key(text: "cmd+return")`.

10. **Wait for `Final File Ready`.**
    - Poll `$ART/log.txt` (up to 60 s, 250 ms interval) for the substring `Final File Ready`. As soon as it appears, record `T_DONE=$(date +%s%3N)` and compute `MS_CLICK_TO_FINAL=$((T_DONE - T_CLICK))`.
    - The log capture must include `--signpost` for these events to show; `scripts/uitest.sh logs` does this. The signpost line format is:
      `<ts> Sp Vocello[pid:tid] [com.qwenvoice.app:performance] [...] Final File Ready`.
    - On timeout: stop the log capture, save the post-state screenshot, write `result.json` with `pass=false` and reason `"timeout waiting for Final File Ready"`, and abort.

11. **Verify the output file.**
    - The Custom Voice output subfolder is **`CustomVoice/`** (PascalCase — `TTSModel.outputSubfolder`), not `custom_voice/`.
    - `find "$HOME/Library/Application Support/QwenVoice-Debug/outputs/CustomVoice" -type f -name '*.wav' -newer "$ART/pre.png"` should print exactly one path. Record it as `AUDIO_PATH`. Confirm `[ -s "$AUDIO_PATH" ]` (file exists and is non-empty). Expected format: RIFF WAVE, 16-bit, mono, 24000 Hz.

12. **Verify the database row.**
    - `scripts/uitest.sh db "SELECT id, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"` should print one CSV line. Parse `DB_ID` (first field), `DB_AUDIO_PATH` (second), `DB_DURATION` (third). Assert `DB_AUDIO_PATH == AUDIO_PATH` and `DB_DURATION > 0`.

13. **Final screenshot, stop log capture.**
    - `mcp__computer-use__screenshot` → save bytes to `$ART/post.png`.
    - `kill "$LOG_PID" 2>/dev/null || true`.

14. **Write the result file.**
    - Compose `$ART/result.json` with this shape:
      ```json
      {
        "pass": true,
        "ms_click_to_final": <number>,
        "audio_path": "<path>",
        "audio_bytes": <number>,
        "db_id": "<uuid>",
        "db_duration": <number>,
        "fixed_script": "This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.",
        "vocello_pid": <number>,
        "timestamp": "<iso8601>"
      }
      ```
    - On any failed assertion, set `"pass": false` and add a `"reason": "<short string>"` field.

15. **Report.**
    - Print to the conversation: pass/fail, `MS_CLICK_TO_FINAL` in ms, `AUDIO_PATH`, `$ART/` for follow-up inspection.

## Notes

- This runbook is the contract for "the smoke test works." When any step changes — new accessibility identifiers, a different completion signal, a UI restructure — update both this file and `ui-test-surface.md`.
- `MS_CLICK_TO_FINAL` here is a single number. It's not yet a benchmark (no statistics, no comparison baseline). Element 2 of the autonomous-testing rollout will formalize benchmarking.
- The runbook deliberately does not navigate Settings or download models — `smoke-check` enforces the "models are already installed" precondition so the smoke test stays focused on the generate path.
