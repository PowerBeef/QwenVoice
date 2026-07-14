# Maintaining the Vocello Qwen3 audio runtime

The source under `third_party_patches/mlx-audio-swift/` is an owned, specialized product runtime,
not a thin patch stack. Its physical path remains unchanged to avoid needless package and project
churn.

## Authority

Use these sources in order:

1. Runtime source and deterministic tests.
2. `VENDOR_MANIFEST.json` for provenance/package scope.
3. `PATCHES.json` for semantic deltas, state, evidence, and upstream disposition.
4. `PERFORMANCE.md` and the Qwen/Mimi subsystem guides for design narrative.
5. Historical audits only for dated research context.

`QwenVoiceCore` owns application engine coordination. The vendor package owns Qwen3 model loading,
sampling, streaming, Mimi decoding, and clone artifacts. `QwenVoiceBackendCore` is the narrow
app-owned policy/provenance vocabulary between those layers; it is not an MLX re-export target.

## Local change policy

Direct edits are appropriate when a change belongs to the Qwen3/MLXAudio implementation rather
than app coordination. Keep the change focused and:

- add or update a stable `PATCHES.json` entry;
- identify state as active, diagnostic, dormant, rejected, shared, superseded, or removed;
- name source files, deterministic tests, and current documentation;
- attach a tracked benchmark record for measured performance claims, or explicitly mark the
  evidence historical, diagnostic, or unmeasured;
- record upstream disposition and removal criteria;
- preserve VoiceOver-independent product behavior, typed completion, cancellation, output, and
  memory contracts.

Do not mass-format, add a nested `.git`, create a vendor-local `.build`, or replace the snapshot
with a fresh upstream tree. Direct SwiftPM work must use
`--scratch-path build/cache/swiftpm/mlx-audio-runtime`.

## Production contracts

- Custom, Design, and Clone use the bounded streaming pipeline. Non-final chunk evaluation may
  overlap token generation; the final chunk is synchronized before terminal completion.
- Talker and subtalker sampling use official checkpoint behavior unless an explicit diagnostic
  override is active.
- `maxTokens` is a quality failure, not a successful truncated result.
- Clone prompt artifacts are atomically published and fail closed on file, digest, shape, dtype,
  mode, or runtime-profile mismatch.
- The generation gate has one owner and deterministic FIFO/cancellation-transfer behavior.
- Decoder partitioning, reset, and timing instrumentation must not change the waveform.

Details and test references live in `PERFORMANCE.md`, `CLONE_ARTIFACT_FORMAT.md`, and
`PATCHES.json`.

## Selective upstream intake

Use a separate branch and an explicit upstream checkout:

1. Review the desired upstream commit against the recorded import baseline.
2. Run `python3 scripts/vendor_runtime_contract.py rebuild-baseline --upstream-dir PATH` only when
   intentionally changing the recorded import baseline.
3. Port selected changes as isolated commits and update the manifest/ledger.
4. Regenerate the Xcode project when products or dependencies change.
5. Run:

```sh
python3 scripts/vendor_runtime_contract.py validate
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

Model-dependent benchmarks remain explicit evidence for performance or output-quality changes;
they are not required for documentation-only or ordinary deterministic publishing.

## Review checklist

- [ ] The change belongs in the lower-level runtime.
- [ ] `PATCHES.json` covers every changed vendor file.
- [ ] Tests and documentation references exist.
- [ ] Measured claims cite a current record or carry an explicit non-current evidence class.
- [ ] Upstream disposition and removal criteria are current.
- [ ] Package products and dependency pins still match `VENDOR_MANIFEST.json`.
- [ ] Deterministic gates pass without writing `.build` inside vendored source.
