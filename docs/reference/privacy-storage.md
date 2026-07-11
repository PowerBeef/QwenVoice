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
