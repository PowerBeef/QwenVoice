---
name: vocello-macos-ui-qa
description: Run blocking macOS frontend acceptance for Vocello through Codex Computer Use, with deterministic history, WAV, XPC transport, backend telemetry, report, and attestation checks. Use for macOS UI journeys, semantic visual/accessibility review, XPC UI recovery, UI-driven generation benchmarks, release UI acceptance, or whenever scripts/macos_agent_ui.sh impact requires quick, full, or benchmark evidence.
---

# Vocello macOS UI QA

Drive the frontend only through the installed `computer-use` skill. Use
`scripts/macos_agent_ui.sh` for lifecycle and truth below the UI.

## Select the suite

- Use `quick` for ordinary macOS view, copy, or layout changes.
- Use `full` for generation coordination, playback, persistence, XPC,
  accessibility, models, the QA harness, or release work.
- Use `benchmark` for the UI-driven generation matrix.
- Use `destructive` only when explicitly requested. Pass
  `--allow-destructive` and still obtain action-time confirmations required by
  the Computer Use policy.

Inspect the requirement when uncertain:

```sh
scripts/macos_agent_ui.sh impact
```

## Start safely

1. Read `config/macos-ui-scenarios.json` completely.
2. Run `scripts/build.sh build` if `build/Vocello.app` is stale or absent.
3. Run `scripts/macos_agent_ui.sh doctor --suite <suite> --json`.
4. Run `scripts/macos_agent_ui.sh start --suite <suite>` and retain its
   `runID`, `runDirectory`, and exact `appPath`.
5. Use the exact absolute `build/Vocello.app` path for every Computer Use call.
   Never target `Vocello` by name or `com.qwenvoice.app` by bundle ID; multiple
   registered builds may share those values.

If the run is interrupted, call `scripts/macos_agent_ui.sh cleanup` before any
new start.

## Drive each scenario

For every logical action:

1. Call `get_app_state` for the exact app path.
2. Find the target by current accessibility identifier and derive a fresh
   `element_index`.
3. Perform one logical action.
4. Call `get_app_state` again and verify the expected semantic state.
5. Never reuse an element index obtained before the latest observation.

Prefer accessibility-element actions. Use screenshot or coordinate fallback
only when the accessibility tree cannot expose the control, then record a minor
automation issue:

```sh
scripts/macos_agent_ui.sh issue --scenario <id> --severity minor \
  --category automation --summary "Coordinate fallback" \
  --expected "Accessible target" --actual "Target absent from AX tree"
```

Record scenario progress with `checkpoint`. Continue independent scenarios after
minor or note findings. Stop dependent work after blocker or major findings. Stop
the run after an environment-wide blocker.

For the benchmark suite, obtain the harness-owned take definitions and run them
in order:

```sh
scripts/macos_agent_ui.sh benchmark-manifest
scripts/macos_agent_ui.sh benchmark-take --index <n> --phase begin
# Drive the returned mode and exact fixture text through Computer Use.
scripts/macos_agent_ui.sh verify-generation --since "<returned since>" \
  --mode <returned mode> --text "<returned text>"
scripts/macos_agent_ui.sh benchmark-take --index <n> --phase complete
```

`begin` stamps the run ID and take metadata used by durable telemetry and relaunches the
exact app path for the two cold cells. `complete` refuses to advance without a
matching database row and readable WAV assertion. Never manufacture the matrix
or edit `/tmp/vocello-bench-current-take.json` outside the harness. A failed
attempt may be begun again at the same index; later cells remain locked until
that take passes.

## Verify generated results

Capture the timestamp immediately before activating Generate:

```sh
SINCE="$(scripts/macos_agent_ui.sh now)"
```

After the visible player state appears, prove the generation outside the UI:

```sh
scripts/macos_agent_ui.sh verify-generation \
  --since "$SINCE" --mode custom --text "<exact fixture text>"
scripts/macos_agent_ui.sh verify-probes
```

Do not accept a player, History row, app marker, or screenshot alone as backend
completion. `verify-generation` requires a matching database row and readable
WAV. `verify-probes` requires correlated engine and engine-service rows with
compatible terminal state and no transport gaps.

For XPC recovery, invoke `xpc-kill` only after a generation has spawned the
service, verify the app remains present, drive another generation, then require
both visible recovery and passing probes.

## Review semantically

At each named review state, inspect both the accessibility tree and screenshot.
Check clipping, truncation, copy, hierarchy, enabled state, focusability, labels,
and error presentation. Pixel equality is not a gate.

Save screenshots beneath the run's `screenshots/` directory and reference their
paths in checkpoints or issues. Never include user content or real library data;
the harness launches the debug-data sandbox.

## Finish and attest

Always execute cleanup, even after failure:

```sh
scripts/macos_agent_ui.sh verify-probes
scripts/macos_agent_ui.sh finish --status pass
scripts/macos_agent_ui.sh validate-report --suite <suite>
scripts/macos_agent_ui.sh attest --suite <suite>
```

Use `fail` or `blocked` instead of `pass` when appropriate. `finish` converts a
requested pass to failure if probes, cleanup, or blocker or major severity fails.
Only attest a passing, current report. Full evidence stays under
`build/macos/agent-ui/`; the compact non-sensitive attestation is tracked.
