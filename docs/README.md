# QwenVoice Documentation

This folder contains the current repo-authored documentation for QwenVoice.

## Maintained Reference Docs

- [`reference/current-state.md`](reference/current-state.md) — shared current repo facts
- [`reference/engineering-status.md`](reference/engineering-status.md) — current strengths, caveats, and validation posture
- [`reference/backend-freeze-gate.md`](reference/backend-freeze-gate.md) — release-readiness gate run entirely on Mac mini M2 via `scripts/` tooling (CI retired May 2026)
- [`reference/frontend-backend-contract.md`](reference/frontend-backend-contract.md) — app-facing backend state, delivery state, and gate
- [`reference/release-readiness.md`](reference/release-readiness.md) — macOS-first release-track policy, proof status, public-homepage freeze rules, and the tier→workflow mapping table
- [`reference/privacy-storage.md`](reference/privacy-storage.md) — local model, output, history, saved-voice, App Group, and deletion-path reference
- [`reference/foundation-projects-audit.md`](reference/foundation-projects-audit.md) — upstream model/runtime/database foundations, current pins, freshness, and local customization status
- [`reference/vendoring-runtime.md`](reference/vendoring-runtime.md) — runtime, vendoring, and packaging boundaries
- [`reference/mlx-audio-swift-patching.md`](reference/mlx-audio-swift-patching.md) — vendor delta under `third_party_patches/mlx-audio-swift/`, rebase procedure, and post-rebase build checklist

### Autonomous UI testing & bench

The Debug build is drivable by a Codex session via the computer-use MCP. The harness lives in `scripts/uitest.sh`; runbooks under `reference/` capture the per-scenario flow:

- [`reference/ui-test-surface.md`](reference/ui-test-surface.md) — agent's reference: accessibility-identifier vocabulary by screen, completion signals (signposts + DB + file), per-sample bench metrics, scaling caveats
- [`reference/bootstrap-saved-voice.md`](reference/bootstrap-saved-voice.md) — one-time autonomous setup of the `UITestRef` saved-voice fixture via Voice Design (no file picker required)
- Smoke runbooks (one happy-path scenario each):
  - [`reference/smoke-custom-voice.md`](reference/smoke-custom-voice.md) — Custom Voice generation
  - [`reference/smoke-voice-design.md`](reference/smoke-voice-design.md) — Voice Design generation
  - [`reference/smoke-voice-cloning.md`](reference/smoke-voice-cloning.md) — Voice Cloning (uses the `UITestRef` fixture)
  - [`reference/smoke-settings.md`](reference/smoke-settings.md) — Settings screen renders + model packages show "Ready"
  - [`reference/smoke-history.md`](reference/smoke-history.md) — History list renders + search filters + row plays
  - [`reference/smoke-saved-voices.md`](reference/smoke-saved-voices.md) — Saved Voices lists the fixture + row plays
- Bench runbooks (multi-sample timing + audio quality + memory across cold/warm × variant × prompt-length):
  - [`reference/bench-custom-voice.md`](reference/bench-custom-voice.md)
  - [`reference/bench-voice-design.md`](reference/bench-voice-design.md)
  - [`reference/bench-voice-cloning.md`](reference/bench-voice-cloning.md)
- [`reference/benchmark-baselines.json`](reference/benchmark-baselines.json) — committed regression baselines, schema v3, regression-ready (24 cells × n=3 on Apple M2, May 2026). `bench-compare` flags timing/RTF drift past ±15 %; depth metrics (audio RMS/peak dBFS, peak RSS combined + app/XPC split) are stored for forensic comparison.

Useful local diagnostics can be exported with:

```sh
./scripts/export_diagnostics.sh
```

These are the maintained source-of-truth docs for contributor and repository behavior. When prose disagrees, trust the repo code, manifests, scripts, and workflows first, then these reference docs.

## Product And Public Docs

- [`../README.md`](../README.md) — public GitHub landing page and end-user overview
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — contributor workflow, source-of-truth order, and validation entrypoints

The public landing page leads with `Vocello` as the next Mac identity while making `QwenVoice v1.2.3` the safe current download. See [`reference/release-readiness.md`](reference/release-readiness.md) for the public-messaging rules.

## Supplemental Guides

- [`qwen_tone.md`](qwen_tone.md) — supplemental tone and prompt-writing guidance

Supplemental guides are useful, but they are not the primary source of truth for current repo structure or shipped-product behavior.

## Historical Docs

- [`releases/`](releases/) — checked-in release notes for past published versions

## Notes

- Maintained contributor guidance in this checkout lives in `CONTRIBUTING.md` and the maintained reference docs listed above.
- This repo does not maintain project-scoped QwenVoice skills; contributor guidance lives in the maintained docs above.
- Current automation surfaces live in `scripts/`. There are no GitHub workflows and no XCTest target — both were retired in May 2026. Builds, packaging, signing, notarization, and TestFlight prep run **locally on Mac mini M2** via `scripts/check_project_inputs.sh`, `scripts/build_foundation_targets.sh`, `scripts/release.sh`, and `scripts/release_ios_testflight.sh`. Behavioral verification is twofold: (a) manual — launch the app and exercise the affected paths by hand, and (b) agent-driven — a Codex session can drive `Vocello.app` via the computer-use MCP, following the smoke and bench runbooks above. The agent-driven harness lives in `scripts/uitest.sh` plus the runbooks under `reference/`; it's distinct from the XCTest / CI / Python-benchmark harnesses `check_project_inputs.sh` actively bans.
- Generated or vendored dependency documentation is intentionally out of scope for the repo docs.
