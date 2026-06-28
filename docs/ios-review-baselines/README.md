# iOS UI review baselines

Committed PNG baselines for on-device UI review (Phase 5 of the testing overhaul). Each
file is a screenshot of one canonical screen, captured by
`VocelloiOSReviewTourUITests.testCaptureReviewScreens` and named with a stable key.

## Workflow

```sh
# 1. Capture the current on-device UI into build/ios/review-shots/<run>/ (XCUITest tour).
scripts/ios_device.sh review

# 2. Seed/update the committed baselines from a known-good run, then review + commit.
scripts/ios_device.sh review --baseline
git add docs/ios-review-baselines && git commit
```

On a normal `review` run, the verb prints each capture with its baseline pair (or `NEW`
when no baseline exists yet). The **perceptual diff** is a vision-MCP step — run it on
each `(baseline, actual)` pair:

- `mcp__zai-mcp-server__ui_diff_check` (expected baseline, actual capture), or
- the `axiom:screenshot-validator` agent / `impeccable` skill for a deeper UI pass.

Update a baseline only when the UI change is intentional; a diff that flags an
unintended delta is the signal that caught a regression.

## Capture keys

`review-studio-custom`, `review-studio-design`, `review-studio-clone`, `review-sheet-voice`,
`review-settings`, `review-history`, `review-voices`.

## Rules

- **On-device only** (the iOS Simulator is unsupported; see AGENTS.md).
- **Burn-in aware:** the tour opens each sheet only long enough to capture, then dismisses
  it (capture-and-dismiss) — never dwell on a static high-contrast screen.
- **Accessibility:** the tour is also a reachability pass — every screen/sheet is reached
  by tapping a real, hittable, identified control, so a green capture run implies the
  surface is navigable with assistive tech. Dynamic Type at the largest content size is a
  future addition (needs app-side `preferredContentSizeCategory` plumbing).
- Screenshots include only Vocello UI (XCUITest `app.screenshot()` — no Mirroring chrome).
