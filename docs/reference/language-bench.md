# Language bench (Phases 2–3)

Headless matrix for the Qwen3 language path:

1. **Phase 2 — hint contract:** UI hint → resolved `notes.languageHint` in engine telemetry.
2. **Phase 3 — output verification:** three-pass locale-locked on-device Speech consensus,
   language score, WER/CER, and exact fixed-seed WAV proof vs script.

## Config

| File | Role |
| --- | --- |
| `config/language-bench-corpus.json` | Native script snippets per language |
| `config/language-bench-matrix.json` | Cells: mode, `uiHint`, `scriptLang`, `expectedHint` |
| `config/language-bench-diagnostic-cohort.json` | Fixed cells and five predeclared seeds for autonomous failure diagnosis |

Cells tagged `"quick": true` form the **quick** subset (English + French + negative control, 7 cells).
**full** runs all 19 cells (6 languages × custom pinned/auto + design auto + negative).

## iOS (on-device)

Requires Custom Voice and Voice Design **Speed** installed on the paired iPhone.

**Speech Recognition (app):** Phase 3 transcribes each output WAV in the app process. Grant
**Settings → Privacy → Speech Recognition → Vocello** once before the first output-gated run.

### Phase 3 prerequisites (on-device Speech assets)

Output verification runs three sequential recognitions of the exact generated WAV using
**on-device Speech** in the deterministic locale of each cell. All three final transcripts must
agree before WER/CER is scored. EN/FR work out of the
box; **DE, ES, ZH, JA** need system dictation languages and downloaded voice assets on the
phone. Authorization denied, recognizer unavailable, missing on-device support, timeout, engine
error, inconsistent transcripts, or failed WER/CER are distinct machine failures; none is replaced
with a fabricated score or a listening judgment.

The versioned `normalized-edit-rate-v1` accuracy contract uses **WER ≤ 0.15** for languages with
word boundaries and **CER ≤ 0.15** for Chinese and Japanese; both scores and both word/character
edit-count decompositions remain evidence. The Python gate and history publisher independently
recompute the metrics from the tracked corpus and untracked consensus transcript before accepting
the Swift verdict.

**One-time setup (on the iPhone — Settings app, not Vocello):**

1. **Keyboards:** Settings → General → Keyboard → Keyboards → Add keyboard — e.g.
   Allemand, Espagnol, Japonais (Romaji), Chinois simplifié (Pinyin QWERTY).
2. **Dictation languages:** Settings → search *dictée* → **Langues de Dictée** — enable
   Allemand, Espagnol, Japonais, Mandarin (and any variants listed for your locale).
3. **Wi‑Fi download:** Keep the phone on Wi‑Fi until Settings no longer shows that voice
   content for those languages will download later (French UI: *sera téléchargé plus tard
   lorsque l'iPhone sera connecté au Wi‑Fi*).
4. **Re-run** after assets finish: `scripts/ios_device.sh lang-bench --subset full --label "lang-full-output-v3"`.

Confirm Speech assets visually in Settings on the physical device before running the matrix; this
is an operational download prerequisite, not a subjective audio review.
Vocello UI expectations remain documented in [`ios-ui-reference.md`](ios-ui-reference.md).
Language-benchmark labels are opaque privacy-safe identifiers matching
`[A-Za-z0-9][A-Za-z0-9._-]{0,95}`; they are not free-form notes.

```sh
scripts/ios_device.sh lang-bench --subset quick --label "lang-smoke"
scripts/ios_device.sh lang-bench --subset full --label "lang-full"
scripts/ios_device.sh lang-bench --diagnostic-cohort
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
- `QVOICE_IOS_DEVICE_DIAGNOSTICS_SEED` — immutable UInt64 from the pre-generation plan
- `QVOICE_IOS_DEVICE_DIAGNOSTICS_VARIATION=expressive` — explicit sampling policy

Before the first launch, the driver atomically writes `language-run-plan.json` with one-based take
indexes, child run IDs, cells, prompt-equivalence groups, seeds, and sampling variation. Normal
quick/full matrices use one stable seed per mode/script language; pinned and Auto Custom cells for
the same script intentionally share both prompt assembly and seed so the hint is the controlled
variable. The diagnostic cohort is seed-major and evaluates exactly three cells across five fixed
seeds (15 takes). It performs no retry and never publishes benchmark history.

Gates:

- `scripts/check_language_hints.py` — exact plan-selected `engine/generations.jsonl`, including
  run/cell/generation/seed/variation and resolved prompt-assembly correlation
- `scripts/check_language_output.py` — exact plan-selected `device-diagnostics-done.json` →
  `outputVerification`, exact WAV SHA/metadata, and structured three-pass recognition evidence

The device sentinel is schema v2 and is written last as a completion barrier. The collector copies
only the plan-selected engine/app rows, their verbose sidecars, the exact `output.wav`, and bounded
manifests into the untracked run artifact. It verifies the WAV digest, byte/frame/channel/sample-rate
metadata, generation identity, and unique ordering; it never summarizes the phone's historical
diagnostics tree. Raw transcripts and audio remain untracked.

After both requested gates pass, the runner automatically publishes one privacy-safe `language`
record under `benchmarks/runs/language/` and regenerates `benchmarks/HISTORY.md`. A run made with
`QVOICE_LANG_BENCH_SKIP_OUTPUT=1` is recorded as `partial` and excluded from normal timing trends.
Failed cells, missing typed telemetry/model identity, or a publication error leave the tracked
registry unchanged; the untracked artifact directory retains the idempotent repair command.
Passing the diagnostic cohort prints its verdict locally and intentionally creates no record.

### Historical validation snapshot (2026-07-06)

The table below is preserved as dated operational evidence; it is not the current acceptance
state. Current PASS evidence must exist in `benchmarks/runs/language/` and appear in generated
`benchmarks/HISTORY.md`, while the active resume status lives in
[`../development-progress.md`](../development-progress.md). The current tracked registry contains
macOS hint-only records but no physical-iPhone language PASS record, so a fresh output-gated iOS
run remains required before claiming current Phase 3 acceptance.

| Run | Subset | Hint gate | Output gate | Notes |
| --- | --- | --- | --- | --- |
| `ios-lang-bench-20260706-110143` | quick | **7/7 PASS** | — | Hint only (pre–Phase 3 output) |
| `ios-lang-bench-20260706-112319` | quick | **7/7 PASS** | **6/6 PASS** | Locale-locked ASR + stored `pass`; negative control hint-only |
| `ios-lang-bench-20260706-135146` | full | **19/19 PASS** | **7/18 FAIL** | DE/ES/ZH/JA `transcription_failed` — Speech Wi‑Fi assets pending on device |

Negative control `custom-fr-text-en-pinned` is **hint-only** (`skipOutputVerification`) — pinned
English hint is sent, but synthesis still speaks French for a French script today.

Re-run the full output gate after the Phase 3 prerequisites above are satisfied on the phone. A
failed or incomplete run correctly creates no tracked history and cannot be replaced by this dated
table or a listening judgment.

## macOS (in-process CLI)

Requires test models (`scripts/macos_test.sh models ensure`).

```sh
scripts/macos_test.sh lang-bench --subset quick
```

Uses `QWENVOICE_DEBUG=1`, `vocello generate --language …`, and the hint gate against
`~/Library/Application Support/QwenVoice-Debug/diagnostics/`. CLI Speech is **not** used
(TCC); output verification is available through the iOS device-diagnostics lane only. Successful
macOS hint-only evidence is therefore explicitly `partial` in benchmark history.

## Offline gate tests

```sh
python3 scripts/test_check_language_hints.py
python3 scripts/test_check_language_output.py
```

## Related

- Phase 1 unit tests: `scripts/macos_test.sh core-test`
- Language semantics: `docs/reference/qwen3-tts-guide.md` §7
- iOS device lanes: `docs/reference/ios-device-testing.md`
