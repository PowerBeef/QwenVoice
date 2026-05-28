# Smoke Runbook: History surface renders, searches, plays

Lightweight functional smoke for the History screen: at least one row visible after a seed generation, search-filter narrows the visible rows, clicking the row's play affordance triggers playback.

Follows the [Standard smoke skeleton](ui-test-surface.md#standard-smoke-skeleton) for setup + teardown. This file documents the History-specific drive sequence (skeleton Phase 4) and verify steps (skeleton Phase 5 doesn't apply — this smoke doesn't trigger a fresh generation through the standard verify path).

## Mode-specific inputs

| Field | Value |
|---|---|
| Seed prompt (if no rows exist) | `Hello world.` (short — fast to generate) |
| Search fragment | `Hello` (matches the seed) |
| smoke-check arg | `custom` (the seed uses Custom Voice; this smoke aborts if Custom Voice models aren't installed) |

## Mode-specific deltas

This smoke has two unusual properties vs the generate-mode smokes:

1. It **seeds** a generation inline if `history.sqlite` has no rows (since the History screen needs at least one row to assert against).
2. It **verifies UI behavior** (search filter, play button), not just a generation's WAV + DB row.

### Drive sequence

Skeleton Phases 1–3 are unchanged. In Phase 4:

1. **Seed if needed** — run one short Custom Voice generation:
   - Click `sidebar_customVoice` → click `textInput_textEditor` → type `Hello world.` → `cmd+Return`.
   - Sleep ~5 s, then `scripts/uitest.sh db "SELECT count(*) FROM generations"` should be ≥ 1.
2. **Navigate to History**: click `sidebar_history`. Confirm with `scripts/uitest.sh locate screen_history` (exit 0).
3. **Verify a row is visible**:
   - `GEN_ID=$(scripts/uitest.sh db "SELECT id FROM generations ORDER BY createdAt DESC LIMIT 1")`
   - `scripts/uitest.sh locate historyRow_$GEN_ID` should return non-empty coords.
4. **Search filter**: click `history_searchField`, type `Hello`, wait 1 s, screenshot — the row should still be visible.
5. **Clear search**: click search field, `cmd+a` → `BackSpace`, refresh state — all rows back.
6. **Play**: click `historyRow_play_$GEN_ID`. Verify by inspecting the sidebar Player section for the seeded prompt text.

### Skipping `verify-generation`

This smoke doesn't end with `verify-generation`. Instead it writes its own `result.json` in Phase 5:

```sh
cat > "$ART/result.json" <<JSON
{
  "pass": true,
  "screen": "history",
  "rows_before_search": <count>,
  "rows_after_search": <count>,
  "gen_id": "$GEN_ID",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
```

Set `"pass": false` and add `"reason"` on any failed assertion.

## Notes

- Row-level + per-row-action AX ids are canonical (`historyRow_<id>`, `historyRow_play_<id>`, `historyRow_saveAs_<id>`, `historyRow_delete_<id>`, `historyRow_saveVoice_<id>`). Visual fallback is no longer expected — if `locate` fails for a known id, treat that as a regression.
- This is the happy-path smoke. It does NOT exercise delete, multi-row sorting under load, or rapid filtering edge cases.
- Perceptual review doesn't apply here (no new audio characteristics to evaluate — just a UI behavior check).
