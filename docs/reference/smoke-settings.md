# Smoke Runbook: Settings surface renders correctly

Lightweight functional smoke that exercises the Settings screen end-to-end without doing any model download. Verifies the screen mounts, the recommended-models status renders, and at least one Custom Voice model package shows as "Ready".

Mirrors the structure of [`smoke-custom-voice.md`](smoke-custom-voice.md). Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

- Debug build present (`scripts/build.sh debug` if missing).
- macOS Accessibility permission granted to Claude.
- At least one Custom Voice variant installed (`scripts/uitest.sh smoke-check custom` exits 0). This is the smoke test's anchor — without it, Settings will show "not installed" instead of "Ready" and the assertion fails.

## Fixed inputs

| Field | Value |
|---|---|
| Section to land on | top of Settings → Model downloads |
| Model id asserted | `pro_custom` (Custom Voice) |
| Expected status | At least one of `Speed (4-bit)` or `Quality (8-bit)` rows shows "Ready" |

## Steps

1. **Precondition**: `scripts/uitest.sh smoke-check custom`. Abort on non-zero.
2. **Reset**: `scripts/uitest.sh reset` (default mode — keep voices/models).
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
6. **Navigate to Settings**:
   - `read SW SH < <(scripts/uitest.sh screen-size)`
   - `scripts/uitest.sh scaled-locate sidebar_settings 1456 816` → `mcp__computer-use__left_click(coordinate=[cx,cy])`.
   - Verify with `scripts/uitest.sh locate screen_settings` (exit 0 = on the right screen).
7. **Verify Custom Voice model package renders**:
   - `scripts/uitest.sh locate settings_packageStatus_pro_custom` should succeed.
   - `scripts/uitest.sh locate settings_package_pro_custom` should also succeed.
   - Cross-check via screenshot — Custom Voice section shows "Speed (4-bit)" and "Quality (8-bit)" sub-rows; at least one shows "Ready".
8. **Verify variant-package status**:
   - The Speed variant's row should expose `settings_packageStatus_pro_custom_speed` (or `…_quality` for the quality variant). The exact id pattern matches `settings_packageStatus_<modelID>` and `settings_packageStatus_<variantID>`. If unsure, screenshot and read the visible "Ready" / "Repair" / "Download" badge per row.
9. **Post-screenshot + tear down**: `/usr/sbin/screencapture -x "$ART/post.png"`, then `kill "$LOG_PID" 2>/dev/null || true`.
10. **Write `$ART/result.json`** with:
    - `pass`: true if step 7 returned non-empty for `settings_packageStatus_pro_custom` and at least one variant shows "Ready" visually
    - `screen`: `settings`
    - `installed_variants`: list of variant labels visible as "Ready" (from screenshot reading)
    - `vocello_pid`, `timestamp`
11. **Report** $ART/, pass/fail, and what variant(s) you saw as "Ready" to the user.

## What this run will NOT do

- Will not trigger a model download (multi-GB; would skew the artifact dir and burn network).
- Will not exercise the repair/delete/manage flows. Those are out of scope; element-4-breadth covers happy-path only.
- Will not modify any installed models or saved voices.

## Failure handling

- **Settings screen doesn't mount**: `locate screen_settings` fails. Take a screenshot — did the sidebar click land on something else? Retry once with a fresh `prep` if so.
- **No models show as Ready**: the smoke-check prerequisite was probably stale (or models were deleted between the check and the run). Re-run `smoke-check custom` outside the runbook to confirm; if it still passes there's likely a UI rendering bug — capture the screenshot and report.
