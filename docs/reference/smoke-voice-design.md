# Smoke Runbook: Voice Design generate → verify

Single-pass functional check that exercises the Voice Design path end-to-end: launch the Debug build, drive Voice Design with a fixed description + script via computer-use, and verify completion three ways (signpost, output `.wav`, `generations` row).

Mirrors [`smoke-custom-voice.md`](smoke-custom-voice.md). Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

- Debug build present (`scripts/build.sh debug` if missing).
- `scripts/uitest.sh smoke-check design` exits 0 (Voice Design model variants installed).
- macOS Accessibility permission granted to Claude.

## Fixed inputs

| Field | Value |
|---|---|
| Voice description | `A calm, deep documentary narrator with a measured pace.` |
| Script text | `Voice Design smoke test. This is a one-sentence sample to verify the path.` |
| Variant | app default |

## Steps

1. **Precondition**: `scripts/build.sh debug` if missing, then `scripts/uitest.sh smoke-check design` — abort on non-zero.
2. **Reset**: `scripts/uitest.sh reset` (default mode).
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
6. **Navigate to Voice Design**:
   - `read SW SH < <(scripts/uitest.sh screen-size)`
   - `scripts/uitest.sh locate sidebar_voiceDesign` → scale by `(IW/SW, IH/SH)` from the most recent screenshot → `mcp__computer-use__left_click`.
   - Verify with `scripts/uitest.sh locate screen_voiceDesign` (exit 0 = on the right screen).
7. **Fill the voice description**:
   - `scripts/uitest.sh locate voiceDesign_voiceDescriptionField` → scale → `left_click` to focus.
   - `mcp__computer-use__type` with the fixed description.
8. **Fill the script text**:
   - `scripts/uitest.sh locate textInput_textEditor` → scale → `left_click` to focus.
   - `mcp__computer-use__type` with the fixed script.
9. **Trigger Generate**: `T_CLICK=$(date +%s%3N)` then `mcp__computer-use__key(text: "cmd+return")`. The shortcut works on all three generation screens.
10. **Wait for completion**: poll `$ART/log.txt` for `Final File Ready` (250 ms interval, 60 s timeout). On match, `T_DONE=$(date +%s%3N)` and `MS_CLICK_TO_FINAL=$((T_DONE - T_CLICK))`.
11. **Verify output file**:
    - `find "$HOME/Library/Application Support/QwenVoice-Debug/outputs/VoiceDesign" -type f -name '*.wav' -newer "$ART/pre.png"` should print exactly one path. Confirm non-zero size.
12. **Verify DB row**: `scripts/uitest.sh db "SELECT id, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"`. Assert `audioPath` matches the file from step 11, `duration > 0`.
13. **Post-screenshot + tear down**: `/usr/sbin/screencapture -x "$ART/post.png"`, then `kill "$LOG_PID" 2>/dev/null || true`.
14. **Write `$ART/result.json`** with: `pass`, `ms_click_to_final`, `audio_path`, `audio_bytes`, `db_id`, `db_duration`, the fixed description + script text, `vocello_pid`, `timestamp`. On any failed assertion, `pass=false` + a `reason`.
15. **Report** $ART/, pass/fail, and `MS_CLICK_TO_FINAL` to the user.

## Notes

- The Voice Design output subfolder is `VoiceDesign/` (PascalCase, from `TTSModel.outputSubfolder`).
- `Final File Ready` signpost is emitted by the shared `GenerationPersistence.persistAndAutoplay()` path, identical to Custom Voice — the runbook's completion-detection logic is unchanged.
- The variant toggle has accessibility-id prefix `voiceDesign` per `GenerationVariantSelector`; the smoke test leaves it at the app default, so we don't need to click it.
