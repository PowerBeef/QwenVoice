# Backend Hardening Validation Evidence

This note records the minimum proof expected for source-level backend hardening patches that touch trust policy, cross-process transport, audio preparation, or native runtime boundaries. It is intentionally local and script-oriented; signed/notarized distribution proof remains part of the final macOS release workflow.

## Required Local Gates

Run these gates before treating a backend hardening patch as reviewable:

```sh
git diff --check
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
./scripts/qa.sh test --layer contract
./scripts/qa.sh test --layer swift
./scripts/qa.sh test --layer native
```

Before build proof, clear repo-local build products:

```sh
./scripts/clean_build_caches.sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

## Current Hardening Class

This proof set applies to patches that change:

- Developer ID release verification and Team ID trust metadata
- XPC or iPhone extension wire-envelope encoding/decoding
- remote error redaction across process boundaries
- audio-preparation input limits, timeout, cancellation, and cleanup behavior
- native runtime boundary comments or tests

Do not count iPhone simulator/device proof, live model generation, or signed/notarized release proof as required for this source-level class unless the release track explicitly asks for it.
