# Project health scorecard

> Generated inventory and evidence-freshness snapshot. It is not a release verdict and does not
> execute models, devices, UI tests, signing, or network checks.

- Current source identity and dirty state: local JSON report only (kept out of the tracked snapshot to avoid self-referential drift)
- Swift tests: 387 cases in 46 files
- Python tests: 594 cases in 47 files
- Required-step assurance: 31 steps across 7 workflows, all covered by forced-failure fixtures
- Unsafe-concurrency annotations: 50 (50 registered with owner and invariant; contract complete)

## Canonical hardware evidence

| Platform | Latest canonical run | Captured |
| --- | --- | --- |
| macos | `macos-xcui-benchmark-20260720-172920-591696d1` | 2026-07-20T17:43:59Z |
| ios | `ios-xcui-benchmark-20260720-174441-16fc128c` | 2026-07-20T18:02:12Z |

## Critical-domain coverage and freshness

| Domain | Owner | Production files | Direct test files / cases | Hardware evidence |
| --- | --- | ---: | ---: | --- |
| generation-terminal | backend | 4 | 2 / 16 | macos: fresh, ios: fresh |
| clone-conditioning | backend | 30 | 2 / 31 | macos: fresh, ios: fresh |
| event-delivery | backend | 3 | 2 / 10 | macos: stale, ios: stale |
| memory-policy | backend-platform | 6 | 2 / 25 | macos: fresh, ios: fresh |
| model-delivery | backend-platform | 17 | 2 / 35 | macos: fresh, ios: fresh |
| xpc-transport | macos | 3 | 3 / 15 | macos: fresh |
| benchmark-validation | release-qa | 4 | 3 / 94 | macos: stale, ios: stale |
| orchestration-assurance | release-qa | 3 | 1 / 12 | not hardware-gated |
| release-supply-chain | release-qa | 6 | 3 / 51 | macos: stale |
| persistence-privacy | platform-release-qa | 4 | 2 / 7 | not hardware-gated |
| runtime-hardening | backend-release-qa | 5 | 2 / 17 | not hardware-gated |

## Interpretation

- `stale` means a production path owned by that domain changed after the latest canonical hardware record; it does not block ordinary development publishing.
- Test inventory proves discoverable direct coverage, not that those tests passed in this invocation.
- Dependency age and open P0/P1 issue state require authoritative online sources and are intentionally not guessed offline.
- Run `python3 scripts/project_health.py report --output build/artifacts/project-health/` for the complete local JSON inventory.
