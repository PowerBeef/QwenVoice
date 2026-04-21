<p align="center">
  <img src="docs/readme_banner_vocello.png" alt="Vocello banner" width="100%">
</p>

# Vocello

Vocello is a native macOS app for creating voices locally on Apple Silicon. It brings Qwen3-TTS into a polished desktop workflow for Custom Voice, Voice Design, and Voice Cloning, with generation that stays on your machine instead of disappearing into a remote service.

If you care about privacy, creative control, and a tool that feels at home on the Mac, Vocello is built for exactly that.

## Why Vocello

- **Your work stays local.** Vocello is built for offline voice creation on Apple Silicon, so generation happens on your Mac — no accounts, no uploads, no usage metering.
- **It feels like a real app, not a research demo.** The goal is a focused desktop tool you can actually build with, not a notebook wrapped in a window.
- **The workflow is unified.** Designing a voice, refining a voice, and cloning a voice all live in one place, with a shared library and history.

## What You Can Do

- **Custom Voice** — shape reusable voices with a workflow built for iteration, not just one-off outputs.
- **Voice Design** — guide tone, character, and style to create voices that feel intentional.
- **Voice Cloning** — build from a reference voice while keeping the rest of the process inside the same local app.
- **Local generation and export** — generate on macOS, keep your outputs on disk, and work without a repo-owned backend service.

## A Short History

Vocello has been shipping as a native macOS app since late February 2026 under its earlier working title, `QwenVoice`. Over the first six weeks of the project, **fifteen public macOS releases** shipped on GitHub, from `v1.0.0` on February 21 to `v1.2.3` on April 2 — moving steadily from a first usable build into a signed, notarized, installer-grade Mac app with a full Custom Voice / Voice Design / Voice Cloning workflow.

Since the 1.2.3 release, work on `main` has been a larger-scale rebuild of the engine layer: a fully native Swift + MLX runtime replacing the earlier Python-backed engine, heavy generation isolated in a bundled XPC helper, and a shared engine core that a new in-development iPhone version will also use. That work is what the Vocello brand represents — the same project, maturing into its long-term shape.

## On The Vocello Name

Vocello is the long-term name for this project.

The rename from `QwenVoice` isn't a change of direction, a fork, or a winding-down — it's the branding the project is committing to as it grows up from a codebase built around one model into a real Mac app built around a real product. The repository keeps the `QwenVoice` name for technical continuity so existing history, links, and tooling stay intact, while everything people download, install, and use from here on is `Vocello`.

Concretely:

- The next shipped macOS app, download artifact, and release notes will all be `Vocello`.
- Active development continues on this repo's `main` branch under the Vocello brand.
- An iPhone version is being built in the same codebase, on the same shared engine core, under the same brand.

If you used this project under its earlier name, nothing is being abandoned. The direction is the same, the team is the same, and the product is getting a real name for the long run.

## Available Today

- **Primary platform:** macOS (always has been).
- **Latest public release on GitHub:** `QwenVoice 1.2.3`, published 2026-04-02 — the last release shipped under the QwenVoice name.
- **Next release:** will ship as Vocello from the same Releases page. It's the first release built on the new native engine and is being stabilized on `main`.
- **System requirements:** Apple Silicon Mac. The 1.2.3 DMG ships dual-UI packages for macOS 15 and macOS 26. The next release narrows to **macOS 26 or newer** so the app can rely on the current Mac UI layer end-to-end.
- **Distribution:** signed and notarized DMG on GitHub Releases.
- **iPhone:** an iOS version is in active development in the same codebase. It has never been a public release and is not shipping today.

## Install Vocello

Download from [GitHub Releases](https://github.com/PowerBeef/QwenVoice/releases).

Today that page has the latest QwenVoice-branded DMG (1.2.3). The next DMG published there will be the first Vocello-branded release — same project, same codebase, new name and new native engine. Drag the app into `/Applications`, launch it, and it handles first-run model setup from there.

## macOS Today, iPhone Next

Vocello has always been built primarily for the Mac. It's a native desktop app designed around a real keyboard-and-window workflow, and the macOS experience is where the shared engine core gets polished first.

An iPhone version is in active development in the same codebase, on the same shared core, under the same brand. It isn't a public release surface yet — the project is intentionally getting the Mac app stable and dependable before opening a second platform to the public. Because both platforms share one engine core, work done on macOS compounds directly into the iPhone experience when it launches.

## Under The Hood

The rebuild that's happening on `main` (not yet in a public release):

- **Fully native Swift + MLX runtime** on Apple Silicon — no bundled Python runtime, no wrapped CLI.
- **Heavy generation isolated in a bundled XPC helper** on macOS, so model loads and long-running synthesis don't share the UI process.
- **Shared engine core** (`QwenVoiceCore`) that both the macOS app and the in-development iPhone version run against.
- **macOS 26+** as the single supported OS line going forward.

For deeper context, see [docs/reference/current-state.md](docs/reference/current-state.md) and [docs/reference/engineering-status.md](docs/reference/engineering-status.md).

## Roadmap Posture

- **Now:** ship the first Vocello-branded release on macOS from the new native engine, keep the shared core polished.
- **Next:** launch the iPhone version once the Mac app is proven in the wild.
- **Always:** local-first generation on Apple Silicon, a unified voice workflow, and no drift back to a repo-owned remote backend.

## Built On

Vocello builds on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)

## For Contributors

- [CLAUDE.md](CLAUDE.md) — primary repo operating guide
- [docs/README.md](docs/README.md) — index of maintained docs
- [docs/reference/current-state.md](docs/reference/current-state.md)
- [docs/reference/engineering-status.md](docs/reference/engineering-status.md)
- [docs/reference/release-readiness.md](docs/reference/release-readiness.md)
- [docs/reference/vendoring-runtime.md](docs/reference/vendoring-runtime.md)
