# Bootstrap Runbook: Saved-voice fixture (`UITestRef`) via Voice Design

One-time autonomous setup that produces the saved-voice fixture used by every Voice Cloning smoke + bench run. Generates a clean reference voice via Voice Design, then promotes it into a saved voice through the same `voicesEnroll_*` sheet — no file-picker dialog involved.

Follows the [Standard smoke skeleton](ui-test-surface.md#standard-smoke-skeleton) with extra steps for the save-to-voices promotion. This file documents the bootstrap-specific drive sequence.

## What this produces

```
~/Library/Application Support/QwenVoice-Debug/voices/UITestRef.wav     (required)
~/Library/Application Support/QwenVoice-Debug/voices/UITestRef.txt     (optional transcript)
```

After this runs, `scripts/uitest.sh smoke-check clone` exits 0 and the VC smoke + bench runbooks can proceed end-to-end without manual setup.

Wall-clock: ~1 minute.

## Idempotency

If `voices/UITestRef.wav` already exists, the bootstrap is a no-op:

```sh
FIXTURE="$HOME/Library/Application Support/QwenVoice-Debug/voices/UITestRef.wav"
if [ -f "$FIXTURE" ]; then
    echo "UITestRef fixture already present at $FIXTURE — nothing to do."
    exit 0
fi
```

If `scripts/uitest.sh reset --include-voices` ever wipes the voices directory, re-run this runbook to recreate the fixture.

## Mode-specific inputs

| Field | Value |
|---|---|
| Voice description | `A neutral, clear narrator voice for autonomous test reference. Steady pacing and even intonation.` |
| Script text | `This voice was generated as a reference fixture for autonomous Voice Cloning tests. Use it to verify the cloning pipeline end to end.` |
| Variant | app default (Speed) |
| Final saved-voice name | `UITestRef` |
| smoke-check arg | `design` (Voice Design model must be installed; the bootstrap generates via Voice Design) |

## Mode-specific deltas

Skeleton Phases 1–3 are unchanged.

### Phase 4 — Drive UI (extended)

1. **Generate the source audio via Voice Design** (matches [`smoke-voice-design.md`](smoke-voice-design.md) — sidebar `sidebar_voiceDesign`, fill `voiceDesign_voiceDescriptionField`, fill `textInput_textEditor`, `cmd+Return`).
2. **Wait for `Final File Ready`**:
   ```sh
   scripts/uitest.sh bench-wait --since "$T0" --timeout 120
   ```
3. **Click `voiceDesign_saveVoiceButton`** — the `SavedVoiceSheet` opens with `audioPath`, `nameField`, and `transcriptField` all pre-filled by the app (no file picker).
4. **Replace the suggested name with `UITestRef`**:
   - Click `voicesEnroll_nameField` (focus the field).
   - `cmd+a` (select pre-filled name) → `BackSpace` → `type` "UITestRef".
5. **Submit**: click `voicesEnroll_confirmButton`.
6. **Handle the quality-warning fallback (if it appears)**:
   - If the sheet just closes and `scripts/uitest.sh locate voiceDesign_saveVoiceCompleted` returns 0 → done.
   - If `scripts/uitest.sh locate voicesEnroll_keepDespiteWarning` returns 0 → click it. Then the sheet closes.
   
   Poll either AX id on a 250 ms interval, up to 10 s.

### Phase 5 — Verify

This runbook doesn't use `verify-generation` because the success criterion is fixture-presence, not a generation passing:

```sh
ls -la "$FIXTURE"             # must exist and be non-empty
scripts/uitest.sh smoke-check clone   # should exit 0 now
```

Write `$ART/result.json`:

```sh
cat > "$ART/result.json" <<JSON
{
  "pass": true,
  "fixture_path": "$FIXTURE",
  "fixture_bytes": $(stat -f%z "$FIXTURE"),
  "smoke_check_clone_passed": true,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
```

## Failure modes

- **`smoke-check design` fails**: install the Voice Design model variant via Settings → Model Downloads, then retry.
- **`bench-wait` times out**: the Voice Design generation never completed. Screenshot, check `$ART/log.txt`, retry or abort.
- **Duplicate-name error** (`voicesEnroll_errorMessage` shows "name already exists"): stale `UITestRef.wav` or `.txt` is on disk. Remove them and retry — easiest: `scripts/uitest.sh reset --include-voices` (wipes the entire `voices/` directory).
- **`SavedVoiceSheet` doesn't appear** after clicking `voiceDesign_saveVoiceButton`: confirm the button is visible. The save button only appears after a successful generation — verify step 2 saw `Final File Ready` first.
- **Engine quality-warning alert keeps re-firing**: the bootstrap voice produced a degraded reference. The fixture is still usable for end-to-end testing. Accept via `voicesEnroll_keepDespiteWarning`.

## Notes

- This is a one-shot setup. Subsequent VC smoke/bench runs reuse the same fixture for deterministic comparisons.
- A future iteration could automate the *bootstrap-or-skip* decision inside the VC runbooks themselves — for now they instruct the agent to run this runbook when `smoke-check clone` fails.
