# CLAUDE.md

`AGENTS.md` is now the primary repo guide for QwenVoice.
Read `/Users/patricedery/Coding_Projects/QwenVoice/AGENTS.md` first for architecture, source-of-truth order, safety boundaries, build and test workflows, and cross-file change rules.

This file only adds Claude Code-specific guidance.

## Start Here

- Use `AGENTS.md` for repo-level behavior and review checklists.
- Use `cli/CLAUDE.md` as a supplement when the task is focused on the standalone CLI.
- Prefer repo truth (`rg`, source, manifests, scripts) before relying on prose docs.

## Claude-Specific Tooling

Prefer repo scripts and `xcodebuild` shell flows for normal build, validation, and test work.

- Default execution order: local repo truth -> shell commands and repo scripts -> project inspection helpers -> visual Xcode workflows only when they add real value
- Do not default to simulator-style workflows for this native macOS app
- Do not use browser automation tooling for the native app UI
- Fall back to shell commands if a preferred helper is unavailable

### Suggested Routing

- `desktop-commander` for local file inspection, structured reads, and search
- `xcode-mcp` for project and build-setting inspection when shell output is noisy
- `XcodeBuildMCP` for build, run, log, and screenshot flows when a visual workflow is genuinely useful
- `apple-docs` for Apple platform API guidance
- `context7` for third-party library documentation
- `github` for hosted repo state, PR metadata, and remote issue context
- Browser-oriented tools only for web docs or browser tasks, not the native app

## Skills

This repo is a native macOS SwiftUI app with a bundled Python backend.
Prefer direct repo inspection and repo scripts first.

When installed and relevant, the most useful skills are usually:

- `swiftui-ui-patterns`
- `swiftui-view-refactor`
- `swiftui-liquid-glass`
- `swift-concurrency-expert`
- `swiftui-performance-audit`
- `simplify-code`

For tests, benchmarks, and diagnostics, prefer calling `python3 scripts/harness.py ...` directly instead of wrapping those flows in a skill.

## Practical Reminder

- Keep `AGENTS.md`, `docs/reference/current-state.md`, and user-facing docs aligned when stable repo facts change.
- If a task touches Swift/Python boundaries, verify both sides rather than trusting one implementation in isolation.
