# Smoke Runbook: History surface renders, searches, plays

Lightweight functional smoke that exercises the History screen: at least one row visible after a seed generation, search-filter narrows the visible rows, and clicking the row's play affordance triggers playback.

Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

- Debug build present.
- macOS Accessibility permission granted to Claude.
- At least one row in `history.sqlite` `generations` table. This runbook seeds one if empty, so no external setup needed.

## Seed strategy

Before testing, ensure ≥ 1 generation row exists. The runbook does this by running one short Custom Voice generation inline (~3 s) if needed.

## Fixed inputs

| Field | Value |
|---|---|
| Seed prompt (if needed) | `Hello world.` (short — fast to generate) |
| Search fragment | `Hello` (matches the seed) |

## Steps

1. **Precondition**: `scripts/uitest.sh smoke-check custom`. Abort on non-zero — we can't seed without a Custom Voice model.
2. **Reset**: `scripts/uitest.sh reset` (clears existing generations + outputs so this run is repeatable).
3. **Artifacts + log capture**:
   ```sh
   ART=$(scripts/uitest.sh artifacts-dir)
   (scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)
   LOG_PID=$!
   ```
4. **Launch**: `scripts/uitest.sh prep`.
5. **Access**: `mcp__computer-use__request_access(applications: ["Vocello"])`.
6. **Seed one generation** via Custom Voice:
   - `read SW SH < <(scripts/uitest.sh screen-size)`.
   - `scaled-locate sidebar_customVoice 1456 816` → click.
   - `scaled-locate textInput_textEditor 1456 816` → click → type `Hello world.` → `cmd+return`.
   - `python3 -c "import datetime as dt; ..." > /tmp/uitest_bench_t0` is not needed here; the alternative is `bench-wait --since <ts>` but for this smoke we just sleep ~5 s and verify the DB row.
   - Wait ~5 s, then `scripts/uitest.sh db "SELECT count(*) FROM generations"` should be ≥ 1. If not, retry the generation once.
7. **Navigate to History**:
   - `scaled-locate sidebar_history 1456 816` → click.
   - Verify with `scripts/uitest.sh locate screen_history` (exit 0).
   - `/usr/sbin/screencapture -x "$ART/pre.png"`.
8. **Verify a row is visible**:
   - Screenshot inspection: at least one row in the list (text matching `Hello world.` should be visible).
   - The row-level accessibility id pattern isn't catalogued yet. Try `locate history_row_0` or `historyRow_0` and add what you find to `ui-test-surface.md`. Fall back to visual click otherwise.
9. **Use the search field**:
   - `scaled-locate history_searchField 1456 816` → click.
   - Type `Hello` (no `cmd+return` — search filters live).
   - Wait 1 s, screenshot — the row should still be visible (search matched).
10. **Clear search and verify all rows return**:
    - Click search field → `cmd+a` → `delete`.
    - Screenshot — all rows should be back.
11. **Click play on the (first) row**:
    - Row play affordance ID not yet catalogued; visually find and click the play icon.
    - Verify playback by checking the Player section in the sidebar shows the seeded prompt text.
12. **Post-screenshot + tear down**: `/usr/sbin/screencapture -x "$ART/post.png"`, then `kill "$LOG_PID" 2>/dev/null || true`.
13. **Write `$ART/result.json`** with:
    - `pass`: true if (a) at least one row visible after seed, (b) search-filter narrows visible rows, (c) play affordance launches the audio player
    - `screen`: `history`
    - `rows_before_search`, `rows_after_search`: counts (from screenshot or DB query)
    - `discovered_ax_ids`: any new identifiers found for history rows / play buttons / search affordance
    - `timestamp`
14. **Report** $ART/, pass/fail, and any new AX IDs to add to the surface doc.

## Notes

- The seeded generation uses Custom Voice for speed/simplicity. If Custom Voice models aren't installed, the runbook aborts at step 1.
- This is a happy-path smoke. It does NOT test delete, multi-row sorting under load, or rapid filtering edge cases.
- The History row AX id pattern may need code-side instrumentation to be queryable. Document findings; visual fallback is acceptable.
