# Interactive UI QA (agent-driven computer use)

Interactive UI quality acceptance for Vocello is performed by an AI agent driving the genuine app
with computer use — screenshots, vision, and clicks on real visible controls — instead of a
scripted UI-automation stack. macOS is driven directly; iOS is driven through **iPhone Mirroring**
on the paired physical iPhone (never a Simulator). This replaced the retired XCUITest lanes on
2026-07-22 by explicit maintainer decision.

**Status: advisory acceptance QA.** These checklists never run in CI and are never a commit,
push, merge, packaging, signing, notarization, or upload prerequisite. Deterministic scripts
remain the only publishing gates. For a release candidate, run the applicable checklist and record
the run ID and per-item verdicts — or a deliberate skip with its reason — in that release's
`docs/releases/<version>.md` entry.

## Method rules

- Observe and operate only genuine visible controls; never coordinate tables, hidden markers, or
  seeded state. The stable `accessibilityIdentifier` values in
  [`ios-ui-reference.md`](ios-ui-reference.md) name the controls this document refers to.
- Launch the app under test with `./scripts/build.sh run` (macOS). For recording QA on a mic-less
  machine, launch with the registered virtual-microphone knob:
  `QWENVOICE_DEBUG=1 QWENVOICE_FAKE_MIC_WAV=/tmp/<clip>.wav ./scripts/build.sh run`
  (see [`macos-permissions.md`](macos-permissions.md)).
- Evidence: save a screenshot per checklist item (plus any failure state) under
  `build/artifacts/diagnostics/interactive-qa/<run-id>/` (untracked), and write a short per-item
  verdict list. `<run-id>` = `interactive-qa-<platform>-<UTC timestamp>`.
- System permission dialogs (TCC) are answered by the human operator, never by the agent. If a
  dialog appears mid-run, pause, let the operator settle it, note it in the verdict, and continue.
- A failed item is reported with its screenshot and stops the checklist only if later items depend
  on it. QA findings become issues or fixes; they never retroactively alter benchmark history.

## macOS checklist

1. **Navigation and readiness** — visit Custom Voice, Voice Design, Voice Cloning, History,
   Saved Voices, Settings via the sidebar. In Settings, confirm the Custom, Design, and Clone
   Speed packages visibly read Ready and the Clone consent toggle is on (enable it if not).
2. **Completed generation and History** — on Custom Voice, enter a script containing a unique
   nonce (e.g. `qa-complete-<8 hex>`), Generate, wait for the completed player in the sidebar, and
   confirm no error or crash badge. In History, search the nonce: exactly one matching row.
3. **Mid-generation cancellation** — enter a long script with a fresh nonce, Generate, then click
   the visible Cancel while generation is running. Confirm the UI resets cleanly (Generate
   re-enabled, no error badge). In History, search the nonce: zero rows — a user-cancelled take
   never persists.
4. **Recording flow** (virtual-mic launch) — on Voice Cloning, open Record; confirm the sheet's
   timer, level meter, and Record control; start capture and watch the meter move; after auto-stop
   past 10 s, confirm the review stage (Play, Retake, Use enabled); **Cancel** at review. Accepting
   the clip starts transcript auto-fill and may raise the speech-recognition TCC prompt — accept
   only when the operator is present to answer it.
5. **Library surfaces** — History search field and sort control respond; Settings shows the model
   downloads summary.

## iOS checklist (iPhone Mirroring, paired physical device)

Open iPhone Mirroring, unlock the phone, launch Vocello, then:

1. **Navigation and readiness** — visit the Studio, Voices, History, and Settings tabs; select the
   Custom, Design, and Clone modes in Studio. In Settings, confirm the three Speed models read
   Active with no download/repair/retry controls visible.
2. **Generation with live preview** — enter a nonced script, Generate, confirm the live preview
   appears with its play/pause and cancel controls, and let it complete to the inline player.
   History shows the nonce exactly once.
3. **Cancellation** — start a second nonced generation and cancel from the live preview. Confirm
   the Studio returns to a reusable Generate state with no error, and History shows zero rows for
   that nonce.
4. **Player dismissal** — dismiss the completed inline player and confirm Generate is ready again.

Keep runs burn-in-safe: a handful of generations per session; headless engine evidence stays with
`scripts/ios_device.sh` (bench, diagnostics, telemetry pulls), which remains the deterministic
device lane.

## What this does not replace

- **Deterministic verification** — `scripts/macos_test.sh test`, foundation compiles, and the
  contract gates are unchanged and remain the publishing bar.
- **Benchmark evidence** — engine benchmarks run headless via
  `QWENVOICE_DEBUG=1 ./build/vocello bench …` (macOS) and `scripts/ios_device.sh bench` (device),
  publishing PASS-only records under `benchmarks/runs/`. The retired UI-driven
  `benchmarks/runs/ui-generation/` records remain immutable history.
- **Crash and profile lanes** — `scripts/macos_test.sh crashes|profile|memory` and their
  `ios_device.sh` counterparts are unchanged.
