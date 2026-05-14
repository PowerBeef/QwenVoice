# Smoke Runbook: Voice Cloning generate → verify

Single-pass functional check for Voice Cloning. Mirrors [`smoke-custom-voice.md`](smoke-custom-voice.md) and [`smoke-voice-design.md`](smoke-voice-design.md). Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites — important

Voice Cloning needs a **pre-existing saved voice** as its reference. The autonomous session can't drive the file-picker dialog (NSOpenPanel) without computer-use modal handling, so it picks from the Saved Voices list instead. If no saved voice exists, `scripts/uitest.sh smoke-check clone` fails with an actionable message.

To bootstrap once (one-time setup, then the smoke/bench runs are autonomous):

1. `scripts/build.sh run` (launch Vocello manually).
2. Generate one Custom Voice (or Voice Design) take with a clear, well-recorded sample. The output lands under `~/Library/Application Support/QwenVoice-Debug/outputs/CustomVoice/` (or `VoiceDesign/`).
3. Click "Save to Saved Voices" / use the Saved Voices library's enrollment flow to register that take as a saved voice. Give it a recognizable name (e.g., `SmokeTest`).
4. Verify with `scripts/uitest.sh smoke-check clone` — should now exit 0.

A future element can automate this bootstrap (programmatic saved-voice creation requires either an env-var hook the app doesn't expose today or modeling the file picker; both are out of scope here).

Also required:

- Debug build present (`scripts/build.sh debug` if missing).
- macOS Accessibility permission granted to Claude.

## Fixed inputs

| Field | Value |
|---|---|
| Saved voice | The first one returned by the Saved Voices picker (whichever you bootstrapped). |
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
   mcp__computer-use__request_access(applications: ["Vocello"])
   ```
   Then `/usr/sbin/screencapture -x "$ART/pre.png"`.
6. **Navigate to Voice Cloning**:
   - `read SW SH < <(scripts/uitest.sh screen-size)`
   - `scripts/uitest.sh locate sidebar_voiceCloning` → scale → `left_click`.
   - Verify with `scripts/uitest.sh locate screen_voiceCloning` (exit 0).
7. **Select a saved voice**:
   - `scripts/uitest.sh locate voiceCloning_savedVoicePicker` → scale → `left_click` to open the dropdown.
   - Screenshot to see the open menu. Click the first menu item (visual — the menu items themselves don't have stable AX ids).
   - Confirm by re-running `scripts/uitest.sh locate voiceCloning_activeReference` — exit 0 means a reference is now bound.
8. **Fill the script text**:
   - `scripts/uitest.sh locate textInput_textEditor` → scale → `left_click`.
   - `mcp__computer-use__type` with the fixed script.
9. **Trigger Generate**: `T_CLICK=$(date +%s%3N)` then `mcp__computer-use__key(text: "cmd+return")`.
10. **Wait for completion**: poll `$ART/log.txt` for `Final File Ready` (250 ms interval, 90 s timeout — clone priming adds a few seconds vs. Custom Voice). On match, record `MS_CLICK_TO_FINAL`.
11. **Verify output file**:
    - `find "$HOME/Library/Application Support/QwenVoice-Debug/outputs/Clones" -type f -name '*.wav' -newer "$ART/pre.png"` should print exactly one path (note: the subfolder is `Clones/`, not `VoiceCloning/`). Confirm non-zero size.
12. **Verify DB row**: `scripts/uitest.sh db "SELECT id, mode, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"`. Assert `audioPath` matches the file from step 11, `mode` ∈ {`clone`, `cloning`, app's canonical value — record what you see}, `duration > 0`.
13. **Post-screenshot + tear down**: `/usr/sbin/screencapture -x "$ART/post.png"`, then `kill "$LOG_PID" 2>/dev/null || true`.
14. **Write `$ART/result.json`** with: `pass`, `ms_click_to_final`, `audio_path`, `audio_bytes`, `db_id`, `db_duration`, `db_mode`, the fixed script text, `saved_voice_name` (whatever the picker showed), `vocello_pid`, `timestamp`.
15. **Report** $ART/, pass/fail, and `MS_CLICK_TO_FINAL` to the user.

## Notes

- The Voice Cloning output subfolder is **`Clones/`** (not `VoiceCloning/`) — `TTSModel.outputSubfolder` for the clone model resolves to "Clones".
- `Final File Ready` signpost is emitted identically to the other modes. The `VoiceCloningCoordinator` adds a clone-priming step (`ensureCloneReferencePrimed`) which slightly increases latency on the first generation after a reference change — the smoke test's first generation will reflect that.
- If the saved-voice dropdown shows a quality-warning badge (`voiceCloning_referenceWarning`), the saved voice may produce a degraded take but generation still succeeds; record the badge presence in `result.json`.
