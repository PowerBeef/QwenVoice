# AGENTS.md — RETIRED (2026-06-25)

> **This file is retired.** Vocello's main agent guide is now
> [`CLAUDE.md`](CLAUDE.md). It is kept only as a redirect so existing links keep
> resolving; its original body has been removed and folded into `CLAUDE.md`,
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), and [`docs/reference/`](docs/reference/).
> The cross-agent handoff (`AGENT_HANDOFF.md`) was also retired — a single agent
> now works this repo.

## Where the former content moved

| Former AGENTS.md section | Now lives in |
| --- | --- |
| Overview, hard rules, commands, conventions, agent routing | [`CLAUDE.md`](CLAUDE.md) |
| Architecture, runtime (XPC vs in-process), module dependency graph | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §1–§5 |
| Critical engine invariants (prewarm gate, event streams, cancellation, per-tier memory, decoder drift, XPC forwarding) | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §4 + CLAUDE.md "Engine invariants" |
| SPM dependencies / pinning policy (`mlx-swift` + `mlx-swift-lm` in lockstep) | CLAUDE.md "Hard rules" + [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §2 |
| Testing policy (macOS smoke; iOS on-device only; benchmarks; telemetry) | CLAUDE.md "Commands" + [`docs/reference/ios-device-testing.md`](docs/reference/ios-device-testing.md) + [`docs/reference/telemetry-and-benchmarking.md`](docs/reference/telemetry-and-benchmarking.md) |
| Storage hygiene | [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) + `scripts/clean_build_caches.sh` |
| Release & iPhone status / release QA | [`docs/reference/macos-release-qa.md`](docs/reference/macos-release-qa.md) |
| Security / entitlements / permissions | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §13 + [`docs/reference/macos-permissions.md`](docs/reference/macos-permissions.md) + [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) |
| Vendored mlx-audio-swift patching | [`docs/reference/mlx-audio-swift-patching.md`](docs/reference/mlx-audio-swift-patching.md) |

If you arrived here from a code/script/CI comment that referenced a specific
section, use the table above to find the current location.
