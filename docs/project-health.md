# Project health scorecard

> Generated inventory and evidence-freshness snapshot. It is not a release verdict and does not
> execute models, devices, UI tests, signing, or network checks.

- Current source identity and dirty state: local JSON report only (kept out of the tracked snapshot to avoid self-referential drift)
- Swift tests: 232 cases in 39 files
- Python tests: 527 cases in 40 files
- Required-step assurance: 55 steps across 12 workflows, all covered by forced-failure fixtures
- Unsafe-concurrency annotations: 50 (50 registered with owner and invariant; contract complete)

## Canonical hardware evidence

| Platform | Latest canonical run | Captured |
| --- | --- | --- |
| macos | `macos-xcui-benchmark-20260716-181853-b4c2e299` | 2026-07-16T18:35:18Z |
| ios | `ios-xcui-benchmark-20260716-184106-48e3a3a6` | 2026-07-16T19:00:05Z |

## Critical-domain coverage and freshness

| Domain | Owner | Production files | Direct test files / cases | Hardware evidence |
| --- | --- | ---: | ---: | --- |
| generation-terminal | backend | 4 | 2 / 11 | macos: fresh, ios: fresh |
| clone-conditioning | backend | 27 | 2 / 31 | macos: fresh, ios: fresh |
| event-delivery | backend | 3 | 2 / 8 | macos: fresh, ios: fresh |
| memory-policy | backend-platform | 6 | 2 / 25 | macos: fresh, ios: fresh |
| model-delivery | backend-platform | 14 | 3 / 36 | macos: fresh, ios: fresh |
| xpc-transport | macos | 3 | 2 / 12 | macos: fresh |
| benchmark-validation | release-qa | 6 | 4 / 111 | macos: fresh, ios: fresh |
| orchestration-assurance | release-qa | 3 | 1 / 12 | not hardware-gated |
| release-supply-chain | release-qa | 6 | 3 / 39 | macos: stale |
| persistence-privacy | platform-release-qa | 4 | 2 / 7 | not hardware-gated |
| runtime-hardening | backend-release-qa | 5 | 2 / 10 | not hardware-gated |

## Interpretation

- `stale` means a production path owned by that domain changed after the latest canonical hardware record; it does not block ordinary development publishing.
- Test inventory proves discoverable direct coverage, not that those tests passed in this invocation.
- Dependency age and open P0/P1 issue state require authoritative online sources and are intentionally not guessed offline.
- Run `python3 scripts/project_health.py report --output build/artifacts/project-health/` for the complete local JSON inventory.
