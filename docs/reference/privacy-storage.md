# Privacy And Local Storage

QwenVoice/Vocello is local-first. Prompts, imported reference clips, saved voices, generated audio, model files, and history stay on the user's device unless the user explicitly exports, shares, or uploads them elsewhere.

## macOS Storage

Default macOS app support root:

```text
~/Library/Application Support/QwenVoice/
```

The macOS app also honors:

```sh
QWENVOICE_APP_SUPPORT_DIR=/path/to/custom/app-support
```

Maintained macOS subtrees:

- `models/` stores installed Hugging Face model files.
- `.qwenvoice-downloads/` stores staged model downloads, partial files, resume data, and download-state metadata while a download is in progress.
- `outputs/CustomVoice/`, `outputs/VoiceDesign/`, and `outputs/Clones/` store generated audio unless the user chooses a different output directory.
- `voices/` stores saved voice reference assets.
- `history.sqlite` stores local generation history.

Delete local macOS app data by quitting the app and removing the app support root or the specific subtree above. Deleting `models/` removes installed model files and requires downloading them again.

## iPhone Storage

The iPhone app uses the App Group:

```text
group.com.qvoice.shared
```

Its shared container is rooted under the app-owned `Vocello` subtree and is managed by `Sources/iOSSupport/Services/AppPaths.swift`.

Maintained iPhone subtrees:

- `models/` stores verified installed model files.
- `downloads/` and `staging/` store in-progress model delivery state.
- `outputs/` stores generated audio.
- `voices/` stores saved voice reference assets.
- `cache/` stores required runtime cache data.

The iPhone app intentionally keeps shared state constrained to the App Group app-support subtree. It does not use a parallel shared-user-defaults channel for model or voice state.

## Voice Cloning Consent

Voice cloning accepts user-provided reference audio. Only clone voices you own or have permission to use. Reference clips, transcripts, and saved voices are local files, but the user remains responsible for rights and consent before importing or reusing them.

## Diagnostics

Diagnostics should be user-initiated. The app may write local logs or exportable diagnostic files for model download, generation, playback, XPC, and model-admission failures, but it should not report those details over the network automatically.
