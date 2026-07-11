<h1 align="center">Vocello</h1>

<p align="center">
  A local, private voice studio for Apple Silicon. Write a script, shape how the voice should sound, and generate speech right on your device — no cloud, no account, no per-line meter.<br>
  <strong>On your Mac today · iPhone arriving soon.</strong>
</p>

<p align="center">
  <a href="https://vocello.vercel.app/"><img src="https://img.shields.io/badge/Website-vocello.vercel.app-7b61ff?style=flat-square&logo=vercel" alt="Website"></a>
  <a href="https://github.com/PowerBeef/QwenVoice/releases/tag/v2.1.0"><img src="https://img.shields.io/badge/Vocello-2.1.0-7b61ff?style=flat-square" alt="Vocello 2.1.0"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111827?style=flat-square&logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/iPhone-arriving%20soon-7b61ff?style=flat-square&logo=apple" alt="iPhone — arriving soon">
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-111827?style=flat-square&logo=apple" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License: MIT"></a>
  <a href="https://github.com/PowerBeef/QwenVoice/releases/tag/v2.1.0"><img src="https://img.shields.io/github/downloads/PowerBeef/QwenVoice/v2.1.0/total?label=2.1.0%20downloads&style=flat-square" alt="Downloads"></a>
</p>

<div align="center">

![Vocello banner with abstract voice waves and the Vocello logo](https://vocello.vercel.app/assets/readme-banner.png)

</div>

<p align="center"><em>Formerly QwenVoice — now Vocello 2.1.</em></p>

**Contents:** [Get Vocello](#get-vocello) · [Why Vocello](#why-vocello) · [Workflows](#three-voice-workflows) · [Install](#install-macos) · [System requirements](#system-requirements) · [Privacy](#local-first-privacy) · [Build from source](#build-from-source) · [Development](#development-checkpoint) · [CLI](#command-line-tool-vocello) · [iPhone](#-vocello-for-iphone--arriving-soon) · [Contributing](#contributing) · [License](#license)

**Releases:** [v2.1.0 (latest)](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.1.0) · [All releases](https://github.com/PowerBeef/QwenVoice/releases) · [What's new in 2.1.0](docs/releases/v2.1.0.md)

---

- 🎙️ **Three ways to make a voice** — pick a built-in speaker, describe one in plain language, or clone a reference clip you have rights to (record it in the app, or import a file).
- 🔒 **Private by default** — after a one-time model download, every line renders on your device. No scripts uploaded, no audio sent to a cloud service.
- ⚡ **Fast, native Swift + MLX** — faster than realtime on Apple Silicon, down to 8 GB Macs. No Python runtime, no bundled weights, no cloud queue.
- 🌍 **Speaks ten languages** — with automatic language detection, ten delivery styles, and reproducible takes.

## Get Vocello

| Platform | Build | Notes |
| --- | --- | --- |
| **macOS 26+** (Apple Silicon) | **Vocello 2.1.0** — [Download DMG](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.1.0) | Signed, notarized, stable. Double-click to open. |
| **macOS 15** | QwenVoice 1.2.3 — [Download legacy](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3) | Legacy build. No 2.x backport planned. |
| **iPhone** (iOS 26+, Apple Silicon) | **Arriving soon** | The same on-device engine; ships via App Store / TestFlight (not GitHub Releases). |

## Why Vocello

- **Private by default.** After models are installed, generation runs locally. Your scripts, history, recorded clips, and generated audio stay in local app storage unless you choose to export them.
- **Faster than realtime, even on 8 GB Macs.** A native Swift + MLX engine (no Python runtime, no bundled weights) generates speech faster than it plays back on Apple Silicon. The 2.1 backend work pushed the entry-level 8 GB Mac past realtime, with smoother memory behavior while you generate.
- **Ten languages, auto-detected.** Chinese, English, Japanese, Korean, German, French, Russian, Portuguese, Spanish, and Italian. The language selector shows the language detected from your script (`Language · Auto`) and lets you pin a specific one.
- **Ten delivery styles with intensity.** Neutral, Happy, Sad, Angry, Fearful, Surprised, Whisper, Dramatic, Calm, and Excited — each at subtle, normal, or strong intensity, plus a free-text custom tone when you want to describe the delivery in your own words.
- **A real voice library.** Record a reference clip with your Mac's microphone (or import one), let it transcribe on-device, save the result, and reuse it. Voice Design results can be saved and re-used for cloning, and the speaker and language pickers surface recommendations that follow the language you're writing in.
- **Reproducible takes.** A variation control (Expressive, Balanced, Consistent) trades take-to-take variety against stability, every generation records its sampling seed, and multi-line batches share one seed so a batch reads as a single consistent performance.
- **No subscription meter.** Download the models you want, then generate on your own hardware without paying per line or waiting on a cloud queue.

## Three voice workflows

| | |
| --- | --- |
| ![Custom Voice screen](https://vocello.vercel.app/assets/screens/custom-voice.png)<br><br>**Custom Voice**<br>Pick one of nine built-in Qwen3 speaker presets, choose a delivery style and intensity, and generate a clean spoken line. The fastest path when you want a consistent voice right away. | ![Voice Design screen](https://vocello.vercel.app/assets/screens/voice-design.png)<br><br>**Voice Design**<br>Describe the voice you want in plain language — character, age, accent, texture — then write the script. Vocello shapes the take from that brief, and you can save the result to reuse later. |
| ![Voice Cloning screen](https://vocello.vercel.app/assets/screens/voice-cloning.png)<br><br>**Voice Cloning**<br>Record a short reference clip with your Mac's microphone, or import one (WAV, MP3, AIFF, M4A, FLAC, OGG, or WebM). The transcript can auto-fill with on-device transcription. Only clone voices you own or have permission to use. | ![Model downloads settings screen](https://vocello.vercel.app/assets/screens/model-downloads.png)<br><br>**Model downloads**<br>Install and manage the Speed and Quality package for each voice mode from Settings. Generation screens own the Speed/Quality choice while you write. |

## More in the app

| | |
| --- | --- |
| ![The delivery presets menu open, showing ten styles](https://vocello.vercel.app/assets/screens/delivery-presets.png)<br><br>**Delivery presets**<br>Ten expressive styles — from Whisper and Calm to Dramatic and Excited — each with a subtle / normal / strong intensity, or describe a custom tone in your own words. | ![The History screen listing past generations](https://vocello.vercel.app/assets/screens/history.png)<br><br>**History &amp; library**<br>Every generation is saved locally with its mode, voice, and length. Replay it, save it to your voice library, export the audio, or search back through past takes. Clear-all lets you keep the audio files or delete them too. |

## Install (macOS)

1. Download [`Vocello-macos26.dmg`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.1.0).
2. Open the DMG and drag `Vocello.app` to `/Applications`.
3. Open Vocello.
4. Go to **Settings → Model downloads** and install the voice models you want (the recommended Speed packages are ~7 GB total).
5. Generate from Custom Voice, Voice Design, or Voice Cloning.

No Python setup or local server is required — install the app, download models from Settings, and generate locally.

The DMG is signed with an Apple Developer ID certificate and notarized with a stapled ticket, so the first launch opens with a double-click (no right-click bypass). To verify:

```sh
xcrun stapler validate Vocello-macos26.dmg                           # "The validate action worked!"
spctl -a -vvv --type open --context context:primary-signature Vocello-macos26.dmg   # accepted, source=Notarized Developer ID
```

A `release-metadata.txt` (commit SHA, Xcode version, SDK, marketing version, build number) is attached to the same release for build provenance.

> **Upgrading from 2.0?** Replace `Vocello.app` with the new build. Your installed models, history, and saved voices live in `~/Library/Application Support/QwenVoice/` and carry over — no re-download needed.

## System requirements

- **macOS 26.0+** on an Apple Silicon Mac — available now.
- **iPhone (iOS 26.0+)** on Apple Silicon — arriving soon via App Store / TestFlight.
- **8 GB RAM minimum** (16 GB+ recommended for Quality variants and heavy batches).
- Voice models installed from **Settings → Model downloads**.

**Speed** models are smaller 4-bit packages for faster startup and lower memory use — the recommended default, and what runs faster than realtime on an 8 GB Mac. **Quality** models are larger 8-bit packages for devices with more headroom.

Vocello 2.1.0 is the current stable macOS release. For macOS 15, use [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3); no 2.x backport is planned. Every macOS GitHub Release ships a notarized, stapled, Developer ID–signed DMG — a normal double-click install with no Gatekeeper workarounds.

## Local-first privacy

- Speech generation runs locally after models are installed.
- Generated audio, recorded reference clips, and history stay in local app storage unless you export them.
- Model downloads come from Hugging Face when you install a voice model.
- Recording a reference clip and transcript auto-fill ask for the **Microphone** and **Speech Recognition** permissions on first use. Both run entirely on your Mac — recognition is on-device only, and nothing is sent to Apple or anyone else. (Transcript auto-fill additionally requires Siri to be enabled, a macOS requirement; the app explains this and links the right Settings pane.)
- Voice cloning should only be used with voices you own or have permission to use.

## Build from source

The `main` branch contains the current Vocello codebase (macOS app, iPhone app, and the `vocello` CLI). The stable macOS release is tagged [`v2.1.0`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.1.0) ([release notes](docs/releases/v2.1.0.md)).

**Requires Xcode 26** on macOS 26+ (Apple Silicon) to build from source.

Vocello's engine is **native Swift + MLX** — no Python, no bundled weights. On macOS it runs **out-of-process** in an isolated XPC service; on iPhone it runs **in-process**, fully on-device. Architecture, engine invariants, and release policy live in [`AGENTS.md`](AGENTS.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

```sh
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice
./scripts/regenerate_project.sh
open QwenVoice.xcodeproj
```

The Xcode project is generated from [`project.yml`](project.yml) (edit it, not the `.xcodeproj`, then rerun `regenerate_project.sh`). SPM dependencies — MLX, Swift HuggingFace, GRDB, and the vendored mlx-audio — are deliberately **pinned to exact versions** for backend determinism; bumping them follows a benchmark-gated process documented in [`.agents/backend-mlx.md`](.agents/backend-mlx.md).

Useful checks:

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
scripts/macos_test.sh models ensure   # explicit repair/bootstrap only when visible Settings readiness fails
scripts/macos_test.sh test            # deterministic Core + XPC + Qwen3 runtime tests (no UI)
scripts/ui_test.sh macos smoke        # explicit XCUITest acceptance only
scripts/ui_test.sh macos benchmark
scripts/macos_test.sh gate            # deterministic macOS platform gate
scripts/ui_test.sh ios smoke          # paired physical iPhone only
scripts/ui_test.sh ios benchmark
scripts/ios_device.sh lang-bench --subset quick --label "…"  # language hint + output bench
scripts/ios_device.sh device-state      # physical-device reachability/unlock/interference probe
scripts/ios_device.sh gate              # physical-device deterministic/runtime gate
```

Testing runbook: [`docs/reference/testing-runbook.md`](docs/reference/testing-runbook.md). XCUITest
is the sole autonomous app UI driver: native macOS and a paired physical iPhone only. Smoke and
benchmark lanes are explicit frontend acceptance work.

Commits, pushes, pull requests, and ordinary merges use deterministic verification only. Missing
models, physical-device, or XCUITest evidence never blocks preserving or sharing development work.
Frontend lanes run only for explicit acceptance. Their absence never blocks release packaging,
signing, notarization, artifact upload, a macOS package, or an iOS archive/TestFlight build.

More technical detail:

- [`docs/development-progress.md`](docs/development-progress.md) — active maintainer checkpoint: completed transition, verified acceptance evidence, and the Codex reinstall/resume sequence
- [`docs/project-map.html`](docs/project-map.html) — canonical interactive project map: features, targets, dependencies, flows, source ownership, contracts, and development routes
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture reference: runtime design, engine invariants, and request lifecycles
- [`AGENTS.md`](AGENTS.md) — repo guide: build, architecture, engine invariants, dependency pinning, release policy, conventions
- [`docs/reference/cli.md`](docs/reference/cli.md) — the headless `vocello` command-line tool
- [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) — local storage and deletion details

## Development checkpoint

The repository uses one XCUITest stack for native macOS and the paired physical iPhone.
Deterministic tests are the development, CI, and packaging requirement; smoke and benchmark UI
results are produced only for explicitly requested frontend acceptance. Maintainers and new Codex
sessions should start with [`AGENTS.md`](AGENTS.md), then follow the exact checkpoint and
resume sequence in [`docs/development-progress.md`](docs/development-progress.md).

## Command-line tool (`vocello`)

Vocello ships a headless command-line tool, `vocello`, built from source alongside the app (it is not part of the app download). It drives the same local Swift + MLX engine in-process — no Python, no bundled weights — and serves two roles: scriptable local generation from the terminal, and the deterministic driver for the perf/quality benchmarks. Models install via the app (Settings → Model downloads) or `vocello models install <id>` into the shared `~/Library/Application Support/QwenVoice/models` store. For macOS test fixtures, use `scripts/macos_test.sh models ensure` only as explicit repair/bootstrap; UI generation lanes require visible Settings readiness and never invoke it automatically.

```sh
./scripts/build.sh cli                 # build build/vocello
build/vocello <command> [options]      # run it (runs in place)
```

| Command | What it does |
| --- | --- |
| `generate` | Synthesize one clip (Custom Voice / Voice Design / Voice Cloning); supports `--stream`, `--json`, and piped stdin. |
| `custom` / `design` / `clone` | Shortcuts for `generate --mode …` (also pick the mode interactively, or list them with `modes`). |
| `batch` | Synthesize many clips from a file with a single model load. |
| `voices` | List, enroll, or delete saved clone voices. |
| `speakers` | List the built-in Custom Voice speakers. |
| `models` | List/status/install models (`models install <id>` for headless download). |
| `bench` | Drive the perf/quality matrix and aggregate the results. |

```sh
# Generate a clip (mode shortcut), or pipe a script in
build/vocello custom --variant speed --text "The train left at dawn."
echo "Hello there." | build/vocello generate --variant speed --stream --json

# Discover modes/speakers/models, then bulk synth (one model load)
build/vocello modes
build/vocello speakers list
build/vocello models list
build/vocello models install pro_custom_speed   # optional; or use the app / macos_test.sh models ensure
build/vocello batch --file lines.txt --mode custom --variant speed --out-dir /tmp/batch
```

stdout is machine-readable (an output path, or JSON with `--json`); progress notes go to stderr. Full reference: [`docs/reference/cli.md`](docs/reference/cli.md).

## 📱 Vocello for iPhone — arriving soon

| | |
| --- | --- |
| ![Vocello running on iPhone — the Studio screen with Custom / Design / Clone modes](https://vocello.vercel.app/assets/screens/ios-studio.png) | Vocello is coming to iPhone — the **same local, private engine**, running **fully on-device** on Apple Silicon. Write a script, pick or describe a voice, and generate speech without a cloud round-trip, exactly like the Mac app. Record a Clone reference on-device or import WAV, MP3, AIFF, or M4A audio from Files; an adjacent transcript sidecar can prefill enrollment, and the saved voice opens directly in Clone.<br><br>**On-device generation already works.** The remaining piece is the **App Store / TestFlight** distribution lane (not GitHub Releases), which is still in progress. No public release date yet.<br><br>This is what the native Swift + MLX rebuild was for: replacing the old bundled Python runtime with an engine that runs entirely on-device — the only way to bring Vocello to iPhone.<br><br>**Want to follow along?** Star ⭐ and watch 👀 the repo for updates. |

## Contributing

- **Report bugs or request features:** [GitHub Issues](https://github.com/PowerBeef/QwenVoice/issues)
- **Build, test, and architecture:** [`AGENTS.md`](AGENTS.md) (Workflows + Commands; testing in [`docs/reference/testing-runbook.md`](docs/reference/testing-runbook.md))
- **Release QA checklist:** [`docs/reference/macos-release-qa.md`](docs/reference/macos-release-qa.md)

**Social preview (maintainers):** upload [`docs/social_preview.png`](docs/social_preview.png) under GitHub → **Settings → General → Social preview** so link cards use the Vocello artwork.

## License

Vocello is available under the [MIT License](LICENSE).

## Built on

Vocello builds on [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS), [mlx-audio](https://github.com/Blaizzy/mlx-audio), [MLX](https://github.com/ml-explore/mlx), and [GRDB.swift](https://github.com/groue/GRDB.swift).
