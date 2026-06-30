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

<p align="center">
  <img src="docs/readme_banner_vocello.png" alt="Vocello banner with abstract voice waves and the Vocello logo" width="920">
</p>

<p align="center"><em>Formerly QwenVoice — now Vocello 2.1.</em></p>

**Contents:** [Get Vocello](#get-vocello) · [Why Vocello](#why-vocello) · [Workflows](#three-voice-workflows) · [Install](#install-macos) · [System requirements](#system-requirements) · [Privacy](#local-first-privacy) · [Build from source](#build-from-source) · [CLI](#command-line-tool-vocello) · [iPhone](#-vocello-for-iphone--arriving-soon) · [Contributing](#contributing) · [License](#license)

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

<table>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/vocello-custom-voice.png" alt="Custom Voice screen">
      <br>
      <strong>Custom Voice</strong><br>
      Pick one of nine built-in Qwen3 speaker presets, choose a delivery style and intensity, and generate a clean spoken line. The fastest path when you want a consistent voice right away.
    </td>
    <td width="50%">
      <img src="docs/screenshots/vocello-voice-design.png" alt="Voice Design screen">
      <br>
      <strong>Voice Design</strong><br>
      Describe the voice you want in plain language — character, age, accent, texture — then write the script. Vocello shapes the take from that brief, and you can save the result to reuse later.
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/vocello-voice-cloning.png" alt="Voice Cloning screen">
      <br>
      <strong>Voice Cloning</strong><br>
      Record a short reference clip with your Mac's microphone, or import one (WAV, MP3, AIFF, M4A, FLAC, OGG, or WebM). The transcript can auto-fill with on-device transcription. Only clone voices you own or have permission to use.
    </td>
    <td width="50%">
      <img src="docs/screenshots/vocello-model-downloads.png" alt="Model downloads settings screen">
      <br>
      <strong>Model downloads</strong><br>
      Install and manage the Speed and Quality package for each voice mode from Settings. Generation screens own the Speed/Quality choice while you write.
    </td>
  </tr>
</table>

## More in the app

<table>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/vocello-delivery-presets.png" alt="The delivery presets menu open, showing ten styles">
      <br>
      <strong>Delivery presets</strong><br>
      Ten expressive styles — from Whisper and Calm to Dramatic and Excited — each with a subtle / normal / strong intensity, or describe a custom tone in your own words.
    </td>
    <td width="50%">
      <img src="docs/screenshots/vocello-history.png" alt="The History screen listing past generations">
      <br>
      <strong>History &amp; library</strong><br>
      Every generation is saved locally with its mode, voice, and length. Replay it, save it to your voice library, export the audio, or search back through past takes. Clear-all lets you keep the audio files or delete them too.
    </td>
  </tr>
</table>

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
scripts/macos_test.sh models ensure   # one-time Speed model for macOS UI/bench tests
scripts/macos_test.sh test            # macOS UI smoke (12 tests; -only-testing scoped via script)
scripts/ios_device.sh ui-test         # on-device iOS UI-flow smoke (requires paired iPhone)
```

More technical detail:

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — unified architecture map: modules, dependencies, runtime (XPC vs in-process), and the generation lifecycle
- [`AGENTS.md`](AGENTS.md) — repo guide: build, architecture, engine invariants, dependency pinning, release policy, conventions
- [`docs/reference/cli.md`](docs/reference/cli.md) — the headless `vocello` command-line tool
- [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) — local storage and deletion details

## Command-line tool (`vocello`)

Vocello ships a headless command-line tool, `vocello`, built from source alongside the app (it is not part of the app download). It drives the same local Swift + MLX engine in-process — no Python, no bundled weights — and serves two roles: scriptable local generation from the terminal, and the deterministic driver for the perf/quality benchmarks. Models install via the app (Settings → Model downloads) or `vocello models install <id>` into the shared `~/Library/Application Support/QwenVoice/models` store. For macOS test fixtures (debug symlink), run `scripts/macos_test.sh models ensure` once.

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

<table>
  <tr>
    <td width="300" valign="top">
      <img src="docs/screenshots/vocello-ios-studio.png" alt="Vocello running on iPhone — the Studio screen with Custom / Design / Clone modes" width="300">
    </td>
    <td valign="top">
      <p>Vocello is coming to iPhone — the <strong>same local, private engine</strong>, running <strong>fully on-device</strong> on Apple Silicon. Write a script, pick or describe a voice, and generate speech without a cloud round-trip, exactly like the Mac app.</p>
      <p><strong>On-device generation already works.</strong> The remaining piece is the <strong>App Store / TestFlight</strong> distribution lane (not GitHub Releases), which is still in progress. No public release date yet.</p>
      <p>This is what the native Swift + MLX rebuild was for: replacing the old bundled Python runtime with an engine that runs entirely on-device — the only way to bring Vocello to iPhone.</p>
      <p><strong>Want to follow along?</strong> Star ⭐ and watch 👀 the repo for updates.</p>
    </td>
  </tr>
</table>

## Contributing

- **Report bugs or request features:** [GitHub Issues](https://github.com/PowerBeef/QwenVoice/issues)
- **Build, test, and architecture:** [`AGENTS.md`](AGENTS.md) (commands in §8, testing in §12)
- **Release QA checklist:** [`docs/reference/macos-release-qa.md`](docs/reference/macos-release-qa.md)

**Social preview (maintainers):** upload [`docs/social_preview.png`](docs/social_preview.png) under GitHub → **Settings → General → Social preview** so link cards use the Vocello artwork.

## License

Vocello is available under the [MIT License](LICENSE).

## Built on

Vocello builds on [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS), [mlx-audio](https://github.com/Blaizzy/mlx-audio), [MLX](https://github.com/ml-explore/mlx), and [GRDB.swift](https://github.com/groue/GRDB.swift).
