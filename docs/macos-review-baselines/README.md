# macOS UI review baselines

Legacy committed PNG references for macOS UI review. They remain useful for historical visual
context, but pixel comparison is diagnostic only. Current semantic review is performed by
`$vocello-macos-ui-qa full`; there is no macOS XCUITest screenshot catalog.

## Workflow

```sh
# Invoke $vocello-macos-ui-qa full, which records named semantic reviews and screenshots.
scripts/macos_test.sh review --report <full-run>
```

The report gates layout, copy, truncation, visibility, enabled state and accessibility semantics.
Screenshots live in the ignored run directory and can be compared with these references manually,
but a pixel delta is never the merge verdict.

## Capture keys

**Resting subset** (`--subset resting`):

- `review-custom-resting`
- `review-design-ready` (brief filled)
- `review-voices-list`
- `review-settings-models`

**Full catalog** (adds post-generation / populated states):

- `review-custom-ready` — script typed, readiness `ready=true`
- `review-custom-postgen` — player visible after generation
- `review-clone-reference` — handoff from `A_warm_elderly_woman`
- `review-history-populated` — history after at least one generation

Legacy keys (`review-custom`, `review-design`, …) from the old sidebar-only tour may still
exist in older baselines; re-seed with `--baseline` after intentional UI changes.

## Rules

- macOS is the host, so screenshots contain no iPhone Mirroring chrome or OLED concern.
- `accessibilityIdentifier`s are stable surface area. Computer Use observes the real tree and the
  static catalog validator rejects scenario targets that disappear.
