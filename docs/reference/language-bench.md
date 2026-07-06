# Language bench (Phase 2 — hint contract)

Headless matrix that verifies **UI language selection → resolved `notes.languageHint`**
in engine telemetry. No ASR / no human listening — hint resolution only.

## Config

| File | Role |
| --- | --- |
| `config/language-bench-corpus.json` | Native script snippets per language |
| `config/language-bench-matrix.json` | Cells: mode, `uiHint`, `scriptLang`, `expectedHint` |

Cells tagged `"quick": true` form the **quick** subset (English + French + negative control, 7 cells).
**full** runs all 19 cells (6 languages × custom pinned/auto + design auto + negative).

## iOS (on-device)

Requires Custom Voice **Speed** installed on the paired iPhone.

```sh
scripts/ios_device.sh lang-bench --subset quick --label "lang-smoke"
scripts/ios_device.sh lang-bench --subset full --label "lang-full"
```

Per cell the driver sets:

- `QVOICE_MAC_BENCH_RUN_ID` — shared run id (`ios-lang-bench-…`)
- `QVOICE_MAC_BENCH_CELL` — matrix cell id
- `QVOICE_IOS_AUTORUN_LANG` — UI hint (`english`, `french`, …; omitted for Auto)
- `QVOICE_IOS_AUTORUN` — `mode:speed:<script>`

Gate: `scripts/check_language_hints.py` on pulled `engine/generations.jsonl`.

## macOS (in-process CLI)

Requires test models (`scripts/macos_test.sh models ensure`).

```sh
scripts/macos_test.sh lang-bench --subset quick
```

Uses `QWENVOICE_DEBUG=1`, `vocello generate --language …`, and the same gate script against
`~/Library/Application Support/QwenVoice-Debug/diagnostics/`.

## Offline gate test

```sh
python3 scripts/test_check_language_hints.py
```

## Related

- Phase 1 unit tests: `scripts/macos_test.sh core-test`
- Language semantics: `docs/reference/qwen3-tts-guide.md` §7
- iOS device lanes: `docs/reference/ios-device-testing.md`
