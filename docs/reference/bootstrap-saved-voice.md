# Bootstrap Runbook: Saved-voice fixture (`UITestRef`) via Voice Design

One-time autonomous setup that produces the saved-voice fixture used by all Voice Cloning tests. Generates a clean reference voice via Voice Design, then promotes it into a saved voice through the same `voicesEnroll_*` sheet — no file-picker dialog involved.

Companion docs: [`ui-test-surface.md`](ui-test-surface.md), [`smoke-voice-cloning.md`](smoke-voice-cloning.md), [`bench-voice-cloning.md`](bench-voice-cloning.md).

## What this produces

```
~/Library/Application Support/QwenVoice-Debug/voices/UITestRef.wav   (required)
~/Library/Application Support/QwenVoice-Debug/voices/UITestRef.txt   (optional, transcript)
```

After this runs, `scripts/uitest.sh smoke-check clone` exits 0 and the VC smoke + bench runbooks can proceed end-to-end without manual setup.

Wall-clock: ~1 minute.

## Idempotency

If `voices/UITestRef.wav` already exists, the bootstrap is a no-op. Steps 1 and 2 are the explicit guard. If `scripts/uitest.sh reset --include-voices` ever wipes the voices directory, re-run this runbook to recreate the fixture.

## Fixed inputs

| Field | Value |
|---|---|
| Voice description | `A neutral, clear narrator voice for autonomous test reference. Steady pacing and even intonation.` |
| Script text | `This voice was generated as a reference fixture for autonomous Voice Cloning tests. Use it to verify the cloning pipeline end to end.` |
| Variant | app default (Speed) |
| Final saved-voice name | `UITestRef` |

## Steps

### 1. Idempotency check

```sh
FIXTURE="$HOME/Library/Application Support/QwenVoice-Debug/voices/UITestRef.wav"
if [ -f "$FIXTURE" ]; then
    echo "UITestRef fixture already present at $FIXTURE — nothing to do."
    exit 0
fi
```

### 2. Preflight

`scripts/uitest.sh smoke-check design` — Voice Design model variants must be installed. Abort with a clear message if not (the bootstrap can't proceed without the VD model).

### 3. Setup

```sh
ART=$(scripts/uitest.sh artifacts-dir)
(scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)
LOG_PID=$!
scripts/uitest.sh reset
scripts/uitest.sh prep
scripts/uitest.sh activate
mcp__computer_use__get_app_state(app: "Vocello")
```

### 4. Navigate to Voice Design

- `scripts/uitest.sh window-locate sidebar_voiceDesign` → `mcp__computer_use__click`.
- Verify with `scripts/uitest.sh locate screen_voiceDesign` (exit 0 = on the right screen).

### 5. Fill voice description

- `scripts/uitest.sh window-locate voiceDesign_voiceDescriptionField` → `mcp__computer_use__click` to focus.
- `mcp__computer_use__type_text(app: "Vocello", text: "<fixed description>")` with the fixed description string from above.

### 6. Fill the script

- `scripts/uitest.sh window-locate textInput_textEditor` → `mcp__computer_use__click` to focus.
- `mcp__computer_use__type_text(app: "Vocello", text: "<fixed script>")` with the fixed script string from above.

### 7. Trigger generate

```sh
T0=$(date +"%Y-%m-%d %H:%M:%S.%3N")
```

`mcp__computer_use__press_key(app: "Vocello", key: "super+Return")`.

### 8. Wait for Final File Ready

```sh
scripts/uitest.sh bench-wait --since "$T0" --timeout 120
```

### 9. Click "Save to Saved Voices"

- `scripts/uitest.sh window-locate voiceDesign_saveVoiceButton` → `mcp__computer_use__click`.
- The `SavedVoiceSheet` opens with `audioPath`, `nameField`, and `transcriptField` all pre-filled by the app — no file picker.

### 10. Replace the suggested name with `UITestRef`

- `scripts/uitest.sh window-locate voicesEnroll_nameField` → `mcp__computer_use__click` (focus the field).
- `mcp__computer_use__press_key(app: "Vocello", key: "super+a")` (select the pre-filled name).
- `mcp__computer_use__press_key(app: "Vocello", key: "BackSpace")`.
- `mcp__computer_use__type_text(app: "Vocello", text: "UITestRef")`.

### 11. Submit

- `scripts/uitest.sh window-locate voicesEnroll_confirmButton` → `mcp__computer_use__click`.

### 12. Handle the quality-warning fallback (if it appears)

The engine runs a quality heuristic on the saved reference. For test-fixture purposes we accept either outcome:

- If the sheet just closes and `scripts/uitest.sh locate voiceDesign_saveVoiceCompleted` eventually returns exit 0 → done.
- If `scripts/uitest.sh window-locate voicesEnroll_keepDespiteWarning` returns exit 0 → `mcp__computer_use__click`. The sheet then closes.

Poll either of those AX ids on a 250 ms interval, up to 10 s.

### 13. Verify the fixture file

```sh
ls -la "$FIXTURE"   # must exist and be non-empty
```

The optional transcript may also be present at `voices/UITestRef.txt`.

### 14. Re-run `smoke-check clone`

```sh
scripts/uitest.sh smoke-check clone
```

Should exit 0 with `smoke-check OK: clone fixture present at …`. If it doesn't, something went wrong in step 11 or 12 — inspect `$ART/log.txt` for engine errors.

### 15. Tear down

```sh
kill "$LOG_PID" 2>/dev/null || true
```

Report: fixture path, total wall-clock from step 7 to step 13, the bootstrap artifact directory ($ART).

## Failure modes

- **`smoke-check design` fails**: install the Voice Design model variant via the app's Settings → Model Downloads, then retry.
- **`bench-wait` times out**: the Voice Design generation never completed. Screenshot, check `$ART/log.txt`, retry or abort.
- **Duplicate-name error** (`voicesEnroll_errorMessage` appears with a "name already exists" message): a stale `UITestRef.wav` or `.txt` is on disk. Remove them and retry. Easiest way: `scripts/uitest.sh reset --include-voices` (wipes the entire voices/ directory).
- **`SavedVoiceSheet` doesn't appear** after clicking `voiceDesign_saveVoiceButton`: take a screenshot to confirm the button is visible. The save button only appears after a successful generation — verify step 8 actually saw `Final File Ready` first.
- **Engine quality-warning alert keeps re-firing**: the bootstrap voice produced a degraded reference. The fixture is still usable for end-to-end testing (cloning will produce audio, even if it's not pristine). Accept via `voicesEnroll_keepDespiteWarning`.

## Notes

- This is a one-shot setup. After it runs, every subsequent VC smoke/bench run uses the same fixture and benefits from a stable, deterministic reference.
- A future iteration could automate the *bootstrap-or-skip* decision inside the VC runbooks themselves — for now they just instruct the agent to run this runbook when `smoke-check clone` fails.
