# QwenVoice Documentation

This folder contains the current repo-authored documentation for QwenVoice (public product: **Vocello**).

## Maintained Reference Docs

### Platform and release

- [`reference/current-state.md`](reference/current-state.md) — shared current repo facts
- [`reference/engineering-status.md`](reference/engineering-status.md) — current strengths, caveats, and validation posture
- [`reference/release-readiness.md`](reference/release-readiness.md) — macOS-first release-track policy, proof status, public-homepage freeze rules, and the tier→workflow mapping table
- [`reference/backend-freeze-gate.md`](reference/backend-freeze-gate.md) — local release-readiness gate via `scripts/` tooling, plus the scoped GitHub release workflow boundary
- [`reference/frontend-backend-contract.md`](reference/frontend-backend-contract.md) — app-facing backend state, delivery state, and gate

### Foundations and runtime

- [`reference/privacy-storage.md`](reference/privacy-storage.md) — local model, output, history, saved-voice, App Group, and deletion-path reference
- [`reference/foundation-projects-audit.md`](reference/foundation-projects-audit.md) — upstream model/runtime/database foundations, current pins, freshness, and local customization status
- [`reference/vendoring-runtime.md`](reference/vendoring-runtime.md) — runtime, vendoring, and packaging boundaries
- [`reference/mlx-audio-swift-patching.md`](reference/mlx-audio-swift-patching.md) — vendor delta under `third_party_patches/mlx-audio-swift/`, rebase procedure, and post-rebuild build checklist

### iPhone shipping (MLX, memory, entitlement)

iPhone is **compile-safe only**; on-device generation, memory proof, and TestFlight are deferred pending Apple's increased-memory entitlement, and the device-deploy / proof-matrix / Simulator-UI testing tooling was removed in the testing-harness cleanup. Start at [`reference/ios-shipping.md`](reference/ios-shipping.md), then:

| Doc | Role |
|---|---|
| [`reference/ios-mlx-jetsam-feasibility.md`](reference/ios-mlx-jetsam-feasibility.md) | Feasibility verdict and anti-Jetsam design |
| [`reference/ios-increased-memory-entitlement-request.md`](reference/ios-increased-memory-entitlement-request.md) | Apple request packet (copy-ready) |
| [`reference/ios-increased-memory-entitlement-tracker.md`](reference/ios-increased-memory-entitlement-tracker.md) | Submission and approval status |
| [`reference/ios-memory-admission-policy.md`](reference/ios-memory-admission-policy.md) | Release vs Debug admission policy |

### Behavioral testing (manual)

There is **no automated UI-driving, smoke, or benchmark harness**. Behavioral validation is manual local app acceptance: `./scripts/build.sh run`, then exercise the affected generation paths by hand and listen to the output. Compile-safety is the only automated gate (`./scripts/build.sh debug`, `./scripts/build_foundation_targets.sh ios`). Agent guidance lives in [`../CLAUDE.md`](../CLAUDE.md).

Useful local diagnostics can be exported with:

```sh
./scripts/export_diagnostics.sh
```

These are the maintained source-of-truth docs for contributor and repository behavior. When prose disagrees, trust the repo code, manifests, scripts, and workflows first, then these reference docs.

## Product And Public Docs

- [`../README.md`](../README.md) — public GitHub landing page and end-user overview
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — contributor workflow, source-of-truth order, and validation entrypoints
- [`../website/`](../website/) — public Vocello marketing site source, built with React + Vite and deployed through Vercel with `website/` as the project root

The public landing page leads with `Vocello 2.0.0` (stable) as the current Mac download, with `QwenVoice v1.2.3` retained as the legacy macOS 15 fallback. See [`reference/release-readiness.md`](reference/release-readiness.md) for the public-messaging rules.

## Supplemental Guides

- [`qwen_tone.md`](qwen_tone.md) — supplemental tone and prompt-writing guidance

Supplemental guides are useful, but they are not the primary source of truth for current repo structure or shipped-product behavior.

## Historical Docs

- [`releases/`](releases/) — checked-in release notes for past published versions

## Notes

- Maintained contributor guidance in this checkout lives in `CONTRIBUTING.md` and the maintained reference docs listed above.
- This repo does not maintain project-scoped QwenVoice skills or checked-in skill copies; contributor guidance lives in the maintained docs above. `CLAUDE.md` may reference installed user/plugin skills useful for this repo's workflow, but those skills remain outside the repository.
- Current automation surfaces live in `scripts/` and a single GitHub workflow (`.github/workflows/release.yml`) scoped to macOS release packaging plus iOS compile-safety — two jobs run in parallel on `release.published`: `package` (macOS DMG: sign, notarize, staple, attach to the Release) and `compile-ios` (iOS compile-safety only, no signing, no tests). Website deployment is owned by Vercel from `website/`. Local validation runs on Mac mini M2 via `scripts/check_project_inputs.sh`, `scripts/build_foundation_targets.sh`, and `scripts/release.sh`; behavioral validation is manual app acceptance (no automated UI/bench harness). iPhone MLX/memory planning: [`reference/ios-shipping.md`](reference/ios-shipping.md). `check_project_inputs.sh` actively bans the retired XCTest / Python-benchmark / UI-driving harness surfaces.
- Generated or vendored dependency documentation is intentionally out of scope for the repo docs.
