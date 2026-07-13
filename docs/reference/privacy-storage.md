# Privacy And Local Storage

QwenVoice/Vocello is local-first. Prompts, recorded or imported reference clips, transcripts, saved voices, generated audio, model files, and history stay on the user's device unless the user explicitly exports, shares, or uploads them elsewhere.

## macOS Storage

Installed/public macOS Release app support root:

```text
~/Library/Application Support/QwenVoice/
```

Debug builds use a separate persistent development root so models, saved voices, outputs, and `history.sqlite` survive rebuilds:

```text
~/Library/Application Support/QwenVoice-Debug/
```

The macOS app also honors:

```sh
QWENVOICE_APP_SUPPORT_DIR=/path/to/custom/app-support
```

Maintained macOS subtrees and preferences:

- `models/` stores installed Hugging Face model files. Speed and Quality folders for the same generation mode can coexist on macOS.
- `.qwenvoice-downloads/` stores staged model downloads, partial files, resume data, and download-state metadata while a download is in progress.
- `outputs/CustomVoice/`, `outputs/VoiceDesign/`, and `outputs/Clones/` store generated audio unless the user chooses a different output directory. If a user-chosen directory becomes missing or unwritable, new audio falls back to these default folders and Settings shows a warning — a generation is never lost to a vanished folder.
- `voices/` stores saved voice reference assets (the reference WAV plus an optional `.txt` transcript sidecar).
- Reference-clip **recording** (macOS, 2026-06) uses two short-lived directories under the system temporary directory: `voice-clone-references/` holds the in-progress capture and `voice-enroll/` holds a stable copy during enrollment. Both are deleted as part of enrollment/cancel; the kept copy is the one in `voices/`.
- `history.sqlite` stores local generation history.
- Active macOS model-quality choices are stored in app preferences, keyed per generation mode. `DebugMode` isolates preferences to `com.qwenvoice.app.debug`; Release builds use `UserDefaults.standard`.

Delete local macOS app data by quitting the app and removing the app support root or the specific subtree above. Deleting `models/` removes installed model files and requires downloading them again; it does not by itself clear normal app preferences such as the active model-quality choice.

## iPhone Storage

The iPhone app uses the App Group:

```text
group.com.patricedery.vocello.shared
```

Its shared container is rooted under the app-owned `Vocello` subtree and is managed by `Sources/iOSSupport/Services/AppPaths.swift`.

The May 2026 iOS identity rename moved pre-release storage from the old QVoice App Group to this Vocello App Group without migration, so device builds after the rename start with fresh iPhone data.

The iPhone app also honors:

```sh
QVOICE_APP_SUPPORT_DIR=/path/to/custom/app-support
```

(for test/hermetic runs; production uses the App Group container when available).

Maintained iPhone subtrees:

- `models/` stores verified installed model files.
- `downloads/` stores in-progress model delivery state; `downloads/staging/` holds staged partials.
- `outputs/` stores generated audio. The user can optionally also copy each new clip to an external Files/iCloud folder via Settings → "Saved outputs" (a user-granted security-scoped bookmark; no new entitlement). The internal copy here is always kept and is what History plays from.
- `voices/` stores saved voice reference assets.
- `cache/imported_references/` stores app-owned materializations of WAV, MP3, AIFF, or M4A files
  selected or opened through Files, plus an adjacent `.txt` sidecar when supplied. Enrollment copies
  the kept reference into `voices/`.
- Other `cache/` subtrees store required runtime cache data.
- `history.sqlite` stores local generation history.

The iPhone app intentionally keeps shared state constrained to the App Group app-support subtree. It does not use a parallel shared-user-defaults channel for model or voice state.

## Voice Cloning Consent

Voice cloning accepts user-provided reference audio — recorded in the app or imported through the
native Files picker/document-open route. Only clone voices you own or have permission to use.
Reference clips, transcripts, and saved voices are local files, but the user remains responsible for
rights and consent before recording, importing, or reusing them.

## Microphone And On-Device Transcription

Recording a reference clip uses the **Microphone** permission; transcript auto-fill uses **Speech Recognition**. Both are requested on first use, and recognition always runs with `requiresOnDeviceRecognition` — the audio is never sent to Apple or any server, on macOS or iPhone. Transcripts are stored only as the local `.txt` sidecar next to the voice's WAV. On macOS, transcription additionally requires Siri to be enabled (an OS gate — the system silently refuses speech-recognition authorization otherwise); the app detects this and links the relevant System Settings panes. Full permission model: [`macos-permissions.md`](macos-permissions.md).

## Diagnostics

Diagnostics should be user-initiated. The app may write local logs or exportable diagnostic files for model download, generation, playback, XPC, and model-admission failures, but it should not report those details over the network automatically.

Repository-local build and QA state lives under the ignored `build/` tree. Its machine-readable
contract is `config/build-output-policy.json`; `scripts/build_output_policy.py validate` rejects an
unowned root or a tracked command that bypasses the contract.

The table below is rendered from the manifest by
`python3 scripts/build_output_policy.py status --markdown`. Policy validation compares the marked
block byte-for-byte, so a manifest change cannot silently leave documentation stale.

<!-- BEGIN GENERATED BUILD OUTPUT POLICY TABLE -->
| Path | Owner | Class | Cleanup | Retention |
| --- | --- | --- | --- | --- |
| `build/cache/xcode/macos/` | macOS build and XCUITest lanes | `cache` | `aggressive` | Persistent incremental macOS Xcode cache |
| `build/cache/xcode/ios-device/` | Physical-device iOS build and XCUITest lanes | `cache` | `aggressive` | Persistent incremental physical-device Xcode cache |
| `build/cache/xcode/source-packages/` | Serialized Xcode SwiftPM resolver | `cache` | `aggressive` | Shared pinned Xcode package checkout and artifact store |
| `build/cache/swiftpm/mlx-audio-runtime/` | Vendored MLX Audio runtime SwiftPM commands | `cache` | `aggressive` | Persistent package-specific SwiftPM scratch cache |
| `build/scratch/derived-data/foundation/` | Foundation target compile-safety lane | `scratch` | `routine` | Delete after successful invocation and during routine cleanup |
| `build/scratch/derived-data/package-resolution/` | Serialized Xcode SwiftPM resolver | `scratch` | `routine` | Ephemeral resolver intermediates; the shared checkout lives under build/cache |
| `build/scratch/transient/` | One-off repository tooling and migration-only diagnostic probes | `scratch` | `routine` | Invocation-local helpers and obsolete untracked probes; routine cleanup removes them |
| `build/scratch/derived-data/release-macos/` | macOS release build and archive lane | `scratch` | `routine` | Isolated release DerivedData; never reused as a development cache |
| `build/scratch/derived-data/release-ios/` | Local iOS archive and export lane | `scratch` | `routine` | Isolated local archive DerivedData; never reused as a development cache |
| `build/scratch/derived-data/xcodebuildmcp/macos/` | XcodeBuildMCP macOS profile | `scratch` | `routine` | Session scratch; repository scripts remain authoritative |
| `build/scratch/derived-data/xcodebuildmcp/ios-device/` | XcodeBuildMCP physical-device iOS profile | `scratch` | `routine` | Session scratch; repository scripts remain authoritative |
| `build/scratch/derived-data/ci/` | GitHub Actions deterministic compile and archive lanes | `scratch` | `routine` | Ephemeral CI DerivedData |
| `build/artifacts/macos/` | macOS deterministic, benchmark, and profile validators | `artifact` | `governed` | Retain compact summaries and publication-repair evidence; prune raw evidence only after validation |
| `build/artifacts/ios/` | Physical-device iOS diagnostics, benchmarks, and profiles | `artifact` | `governed` | Retain compact summaries and publication-repair evidence; prune raw evidence only after validation |
| `build/artifacts/ui-tests/` | Unified macOS and physical-device XCUITest runner | `artifact` | `prune-ui-results` | Keep policy-selected passing and failure result bundles |
| `build/artifacts/diagnostics/` | Cross-platform logs, crash deltas, and local diagnostics | `artifact` | `governed` | Validator-owned; preserve unresolved failure and publication-repair evidence |
| `build/artifacts/symbols/macos/` | macOS build and release identity checks | `artifact` | `preserve` | Keep only symbols whose UUIDs match the current macOS app and XPC products |
| `build/artifacts/symbols/ios/` | Physical-device iOS build and archive identity checks | `artifact` | `preserve` | Keep only symbols whose UUIDs match the current iOS app product |
| `build/artifacts/foundation/` | Foundation compile-safety result bundles and logs | `artifact` | `routine` | Retain the latest useful compile-safety result; older output is disposable |
| `build/dist/macos/` | macOS signing, notarization, and packaging lane | `distribution` | `dist` | Never remove during routine or aggressive cleanup; explicit distribution cleanup only |
| `build/dist/ios/` | iOS archive and TestFlight export lane | `distribution` | `dist` | Never remove during routine or aggressive cleanup; explicit distribution cleanup only |
<!-- END GENERATED BUILD OUTPUT POLICY TABLE -->

The public `build/Vocello.app` and `build/vocello` paths are manifest-owned symlinks to the current
canonical macOS products; they are not independent application or CLI copies.

Every Xcode invocation supplies an explicit DerivedData and cloned-package path. Local macOS outputs
are arm64-only. XcodeBuildMCP uses its own managed scratch DerivedData and never becomes a third
persistent cache. Xcode GUI DerivedData outside the repository is report-only; cleanup touches it
only through `--external-xcode --yes` after exact project matching.

`project.yml` remains the source of truth for the CLI target. XcodeGen 2.45.4 traps when it directly
emits a shared scheme for a `tool` product, so `scripts/regenerate_project.sh` follows XcodeGen with
the narrow `scripts/generate_cli_scheme.py` renderer. That renderer substitutes the generated
`VocelloCLI` target identifier into `config/xcode-schemes/VocelloCLI.xcscheme.template`; project-input
validation rejects a missing or stale result. The supported CLI build therefore uses `-scheme
VocelloCLI` and the canonical managed macOS DerivedData rather than leaking state through a
scheme-less `-target` invocation.

Exact-PID Allocations traces can grow by multiple gigabytes during one cold model run, so successful
profiles publish compact evidence and discard the raw trace unless `--keep-trace` is explicit. Use
`scripts/clean_build_caches.sh` for a read-only inventory and `--routine --dry-run` for the bounded
cleanup preview. `--routine` removes eligible scratch and superseded evidence while preserving
source, tracked benchmark history, persistent caches, current UUID-matched dSYMs, distribution
outputs, publication-repair evidence, and model stores. `--aggressive` additionally removes
persistent compilation/package caches and the public aliases. `--prune-ui-results` and `--dist`
target only their named class; `--clobber --yes` removes ignored repository-local generated state.
`./scripts/build.sh clean` delegates to bounded aggressive cleanup rather than deleting the whole
tree. Model deletion remains a separate explicit `--models` action. A passed benchmark result is pruned
only when its compact registry record validates, and evidence needed to repair a failed publication
is preserved.
