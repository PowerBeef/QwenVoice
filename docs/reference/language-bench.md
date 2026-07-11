# Language bench (Phases 2–3)

Headless matrix for the Qwen3 language path:

1. **Phase 2 — hint contract:** UI hint → resolved `notes.languageHint` in engine telemetry.
2. **Phase 3 — output verification:** in-app Speech transcription + language score + WER vs script.

## Config

| File | Role |
| --- | --- |
| `config/language-bench-corpus.json` | Native script snippets per language |
| `config/language-bench-matrix.json` | Cells: mode, `uiHint`, `scriptLang`, `expectedHint` |

Cells tagged `"quick": true` form the **quick** subset (English + French + negative control, 7 cells).
**full** runs all 19 cells (6 languages × custom pinned/auto + design auto + negative).

## iOS (on-device)

Requires Custom Voice **Speed** installed on the paired iPhone.

**Speech Recognition (app):** Phase 3 transcribes each output WAV in the app process. Grant
**Settings → Privacy → Speech Recognition → Vocello** once before the first output-gated run.

### Phase 3 prerequisites (on-device Speech assets)

Output verification uses **on-device Speech** in the locale of each cell. EN/FR work out of the
box; **DE, ES, ZH, JA** need system dictation languages and downloaded voice assets on the
phone. Without them, cells fail with `transcription_failed` in `check_language_output.py` even
when hint gate and synthesis succeed.

**One-time setup (on the iPhone — Settings app, not Vocello):**

1. **Keyboards:** Settings → General → Keyboard → Keyboards → Add keyboard — e.g.
   Allemand, Espagnol, Japonais (Romaji), Chinois simplifié (Pinyin QWERTY).
2. **Dictation languages:** Settings → search *dictée* → **Langues de Dictée** — enable
   Allemand, Espagnol, Japonais, Mandarin (and any variants listed for your locale).
3. **Wi‑Fi download:** Keep the phone on Wi‑Fi until Settings no longer shows that voice
   content for those languages will download later (French UI: *sera téléchargé plus tard
   lorsque l'iPhone sera connecté au Wi‑Fi*).
4. **Re-run** after assets finish: `scripts/ios_device.sh lang-bench --subset full --label "lang-full-output-v3"`.

Confirm Speech assets manually in Settings on the physical device before running the matrix.
Vocello UI expectations remain documented in [`ios-ui-reference.md`](ios-ui-reference.md).

```sh
scripts/ios_device.sh lang-bench --subset quick --label "lang-smoke"
scripts/ios_device.sh lang-bench --subset full --label "lang-full"
```

Skip output verification (hint gate only):

```sh
QVOICE_LANG_BENCH_SKIP_OUTPUT=1 scripts/ios_device.sh lang-bench --subset quick
```

Per cell the driver sets:

- `QVOICE_IOS_DEVICE_RUN_ID` — shared run id (`ios-lang-bench-…`)
- `QVOICE_MAC_BENCH_CELL` — matrix cell id
- `QVOICE_IOS_DEVICE_DIAGNOSTICS_LANGUAGE` — language hint (`english`, `french`, …; omitted for Auto)
- `QVOICE_IOS_DEVICE_DIAGNOSTICS_SPEC` — `mode:speed:<script>`
- `QVOICE_IOS_DEVICE_DIAGNOSTICS_VERIFY_OUTPUT=1` — Speech round-trip (default unless skipped)

Gates:

- `scripts/check_language_hints.py` — `engine/generations.jsonl`
- `scripts/check_language_output.py` — `device-diagnostics-done.json` → `outputVerification`

### Validated (2026-07-06)

| Run | Subset | Hint gate | Output gate | Notes |
| --- | --- | --- | --- | --- |
| `ios-lang-bench-20260706-110143` | quick | **7/7 PASS** | — | Hint only (pre–Phase 3 output) |
| `ios-lang-bench-20260706-112319` | quick | **7/7 PASS** | **6/6 PASS** | Locale-locked ASR + stored `pass`; negative control hint-only |
| `ios-lang-bench-20260706-135146` | full | **19/19 PASS** | **7/18 FAIL** | DE/ES/ZH/JA `transcription_failed` — Speech Wi‑Fi assets pending on device |

Negative control `custom-fr-text-en-pinned` is **hint-only** (`skipOutputVerification`) — pinned
English hint is sent, but synthesis still speaks French for a French script today.

Re-run full output gate after Phase 3 prerequisites above are satisfied on the phone.

## macOS (in-process CLI)

Requires test models (`scripts/macos_test.sh models ensure`).

```sh
scripts/macos_test.sh lang-bench --subset quick
```

Uses `QWENVOICE_DEBUG=1`, `vocello generate --language …`, and the hint gate against
`~/Library/Application Support/QwenVoice-Debug/diagnostics/`. CLI Speech is **not** used
(TCC); output verification is available through the iOS device-diagnostics lane only.

## Offline gate tests

```sh
python3 scripts/test_check_language_hints.py
python3 scripts/test_check_language_output.py
```

## Related

- Phase 1 unit tests: `scripts/macos_test.sh core-test`
- Language semantics: `docs/reference/qwen3-tts-guide.md` §7
- iOS device lanes: `docs/reference/ios-device-testing.md`
