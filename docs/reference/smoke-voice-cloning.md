# Smoke Runbook: Voice Cloning generate → verify

Single-pass functional check for Voice Cloning. Mirrors [`smoke-custom-voice.md`](smoke-custom-voice.md) and [`smoke-voice-design.md`](smoke-voice-design.md). Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

Voice Cloning requires the **`UITestRef`** saved-voice fixture as its reference. If `scripts/uitest.sh smoke-check clone` fails because the fixture is missing, run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md) first — it takes ~1 minute and produces `voices/UITestRef.wav` autonomously via Voice Design (no file-picker dialog).

Also required:

- Debug build present (`scripts/build.sh debug` if missing).
- macOS Accessibility permission granted to Codex.

## Fixed inputs

| Field | Value |
|---|---|
| Saved voice | `UITestRef` (created by the bootstrap runbook). |
| Transcript | leave empty |
| Script text | `Voice Cloning smoke test. This is a one-sentence sample to verify the path.` |
| Variant | app default |

## Steps

1. **Precondition**: `scripts/uitest.sh smoke-check clone` — abort on non-zero.
2. **Reset**: `scripts/uitest.sh reset` (default mode — keeps saved voices and models).
3. **Artifacts + log capture**:
   ```sh
   ART=$(scripts/uitest.sh artifacts-dir)
   (scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)
   LOG_PID=$!
   ```
4. **Launch**: `scripts/uitest.sh prep`.
5. **Access + pre-screenshot**:
   ```
   mcp__computer_use__get_app_state(app: "Vocello")
   ```
   Then `/usr/sbin/screencapture -x "$ART/pre.png"`.
6. **Navigate to Voice Cloning**:
   - `scripts/uitest.sh window-locate sidebar_voiceCloning` → `mcp__computer_use__click`.
   - Verify with `scripts/uitest.sh locate screen_voiceCloning` (exit 0).
7. **Select the `UITestRef` saved voice**:
   - `scripts/uitest.sh window-locate voiceCloning_savedVoicePicker` → `mcp__computer_use__click` to open the dropdown.
   - Screenshot to see the open menu. Click the menu item labeled `UITestRef` (visual — menu items don't have stable AX ids).
   - Confirm by re-running `scripts/uitest.sh locate voiceCloning_activeReference` — exit 0 means a reference is now bound.
8. **Fill the script text**:
   - `scripts/uitest.sh window-locate textInput_textEditor` → `mcp__computer_use__click`.
   - `mcp__computer_use__type_text(app: "Vocello", text: "<fixed script>")`.
9. **Trigger Generate**: record `T0="$(/usr/bin/python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])')"` then `mcp__computer_use__press_key(app: "Vocello", key: "super+Return")`. `super+Return` maps to macOS Cmd+Return.
10. **Wait for completion**: `scripts/uitest.sh bench-wait --since "$T0" --timeout 120` (clone priming adds a few seconds vs. Custom Voice). The printed timestamp is the matching `Final File Ready` event.
11. **Verify output file**:
    - `find "$HOME/Library/Application Support/QwenVoice-Debug/outputs/Clones" -type f -name '*.wav' -newer "$ART/pre.png"` should print exactly one path (note: the subfolder is `Clones/`, not `VoiceCloning/`). Confirm non-zero size.
12. **Verify DB row**: `scripts/uitest.sh db "SELECT id, mode, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"`. Assert `audioPath` matches the file from step 11, `mode` ∈ {`clone`, `cloning`, app's canonical value — record what you see}, `duration > 0`.
13. **Post-screenshot + tear down**: `/usr/sbin/screencapture -x "$ART/post.png"`, then `kill "$LOG_PID" 2>/dev/null || true`.
14. **Write `$ART/result.json`** with: `pass`, `final_file_ready_ts`, `audio_path`, `audio_bytes`, `db_id`, `db_duration`, `db_mode`, the fixed script text, `saved_voice_name` (whatever the picker showed), `vocello_pid`, `timestamp`.
15. **Report** $ART/, pass/fail, and `MS_CLICK_TO_FINAL` to the user.

## Notes

- The Voice Cloning output subfolder is **`Clones/`** (not `VoiceCloning/`) — `TTSModel.outputSubfolder` for the clone model resolves to "Clones".
- `Final File Ready` signpost is emitted identically to the other modes. The `VoiceCloningCoordinator` adds a clone-priming step (`ensureCloneReferencePrimed`) which slightly increases latency on the first generation after a reference change — the smoke test's first generation will reflect that.
- If the saved-voice dropdown shows a quality-warning badge (`voiceCloning_referenceWarning`), the saved voice may produce a degraded take but generation still succeeds; record the badge presence in `result.json`.
