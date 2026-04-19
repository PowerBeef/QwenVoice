# Release Readiness

This document tracks the current release-readiness program and the intentional split between conservative public messaging and the actual merged repo state.

## Public Homepage Freeze

The public GitHub landing-page surfaces are intentionally locked until the repo owner explicitly changes that instruction.

Locked public surfaces:

- `README.md`
- GitHub repo description
- GitHub homepage URL should remain blank

Public messaging rules:

- Present the repo as the currently shipped macOS QwenVoice product.
- Keep the message close to the `1.2.3` public release posture.
- Add only a short note that a major internal refactor is underway.
- Add only a small tease about what comes next.
- Do not advertise the not-yet-shipped merged Apple-platform product as publicly available.

## Proof Matrix

### macOS

- Official minimum hardware: `Mac mini M1, 8 GB RAM`
- Supported default path on minimum hardware: 4-bit `Speed`
- Current local source gates: maintained
- Current hosted release path: signed and notarized DMG on GitHub Releases

### iPhone

- Official minimum hardware: `iPhone 15 Pro`
- Currently available owned validation device: `iPhone 17 Pro`
- Supported iPhone install path: App Store / TestFlight

Two-track proof policy:

- owned-device proof on `iPhone 17 Pro` is valid for active development and release-path hardening
- official minimum-device proof on `iPhone 15 Pro` remains a separate requirement
- do not claim the iPhone minimum hardware is fully proven until `iPhone 15 Pro` evidence is recorded

## Current Status

- Public homepage freeze: active
- macOS source and packaging surfaces: maintained in-repo
- iPhone archive/export/TestFlight tooling: maintained in-repo
- iPhone owned-device proof: `iPhone 17 Pro` path is the active validation target
- iPhone official minimum-device proof: pending until `iPhone 15 Pro` evidence is recorded

## Release Evidence Expectations

Release-facing metadata and docs should record:

- the real device used for owned-device iPhone validation
- the official minimum iPhone device
- whether minimum-device proof is `pending`, `recorded`, or `not_applicable`
- whether the TestFlight path was exported locally or uploaded to App Store Connect

## Program Priorities

The current execution order is:

1. keep public homepage messaging frozen to shipped-product reality
2. maintain separate owned-device and official-minimum iPhone proof states
3. harden the iPhone TestFlight/App Store path
4. harden engine-extension interruption and recovery behavior
5. add resumable iPhone model delivery and keep the validation tracker current
