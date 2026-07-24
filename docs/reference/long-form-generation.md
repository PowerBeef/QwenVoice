# Long-form generation

This reference describes the shipping long-form v4 path — macOS since 2026-07-23 (stages A–E),
iOS since 2026-07-24 — and what remains open. Source and `config/runtime-refactor-contract.json`
(`longForm`, `longFormV4`) remain higher authority.

## Shipping path (macOS)

`LongTextGenerationRouter` routes scripts above 900 trimmed characters (the retired character
segmenter's historical threshold, kept so routing behavior is unchanged) into a long-form project:

1. **Planning.** `SpokenTextPlanner` + `LongFormPlanner` produce a schema-v4 plan: normalization
   with typed transformation risks, protected spans (decimals, versions, URLs, abbreviations),
   CJK-aware boundary precedence, a delivery-validated 300-unit runtime token ceiling per segment,
   and per-segment stable IDs with deterministic sub-seeds derived from the base seed.
2. **Sequential streaming execution.** `BatchGenerationRunner` runs one ordinary streaming take per
   planned segment — the same shipping path as a single take, with mandatory per-segment engine
   Fast QC, standard streaming telemetry, and live segment preview (auto-play-gated; the
   request-local `suppressStreamingPreview` flag remains available for silent contexts). Batch
   markers are never sent; the legacy XPC `generateBatch` route was retired 2026-07-24 (the
   in-process engine batch API remains for the CLI).
3. **Bounded assembly.** `BoundedLongFormAssembler` joins the persisted PCM16 segment WAVs in fixed
   blocks (bounded gain, edge trim/fade over verified non-speech, declared pauses, atomic publish)
   and the joined output passes its own duration-aware Fast QC with the plan's pause budget.
4. **Manifest v4.** `LongFormManifestV4` records plan + execution + assembly + replacement
   evidence and validates fail-closed. Schema-v3 documents remain readable only as a limited
   legacy summary; missing plan identity is never fabricated.
5. **History.** Migration v5 adds project columns keyed by the plan digest. The joined output is
   the project's single accepted History row; History groups projects with an expandable
   per-segment map (`history_longFormSegmentsToggle_<digest8>`). Per-project filenames
   (`long_form_joined_<digest8>.wav` / `long_form_manifest_<digest8>.json`) prevent cross-project
   overwrites.
6. **Resume and replacement.** In-session resume reuses saved takes (long-form retry never
   degrades to line-separated), and single-segment regeneration appends fail-closed
   accepted-replacement history (revision ≥ 2, strictly increasing, with recorded seeds).

Ordinary line-separated batch runs on the same sequential streaming path with the same QC,
telemetry, and preview semantics; only the planning and assembly stages are long-form-specific.
The sustained performance gate (`TTSEngineStore.hasSustainedPerformanceActivity`) holds across the
whole run — segments, QC, and assembly — so the UI performance posture matches a single take.

Evidence stays privacy-safe: manifests and assembly evidence carry digests, versions, ranges,
counts, frame maps, and typed risks — never original text, spoken text, transcripts, paths, or
audio bytes.

## QC calibration

The acceptance arc calibrated the joined-output gates: the app-side audio gate consumes the plan's
expected pause count (a zero budget rejects healthy narration), and dropout thresholds are
duration-aware (content ≥ 45 s: long-pause 600 ms, suspicious-single 1,500 ms, egregious
2,000 ms; short content keeps 350/900/1,200 ms). QC failures record their flags in the error
message and retain the rejected staged WAV under `stream_sessions/failed-audio-qc/`
(TelemetryGate-gated, newest only) for triage.

## Measured performance

First instrumented project (2026-07-23, canonical Mac mini M2 8 GB, smoke lane): a 2,280-character
script planned three ~50–60 s segments, streamed them sequentially, and joined 161.5 s of audio in
92.0 s wall — project RTF 1.76, inside the canonical gated single-take band. The smoke lane
summarizes each long-form run (`long-form-project-summary.txt`). Registry publication for
long-form project records would need a benchmark-pipeline schema review first; current evidence is
local/lane-level only.

## iOS path (since 2026-07-24)

iOS runs the same design in-process — `IOSGenerationTextLimitPolicy` routes scripts above the
900-character single-take limit into `IOSLongFormCoordinator`/`IOSLongFormProjectRunner`
(`Sources/iOS/Studio/IOSLongFormProject.swift`): the shared planner, per-segment sub-seeds, one
ordinary streaming take per segment with live narration (auto-play-gated), per-segment and
joined-output QC through the ported `AudioQualityGate` twin, bounded assembly, manifest v4, the
same per-project filenames, and one joined History row (iOS `Generation`/`DatabaseService` gained
the v5 columns and joined-row replacement). History groups projects behind a per-segment
disclosure (`history_longFormSegmentsToggle_<digest8>`), flattens during search, and keeps orphan
segments visible. In-session resume reuses saved takes (`longform_resumeChip`); the
sustained-performance refcount holds the fixed-refresh glass gate across the whole run. The
editor ceiling is 30,000 characters with the planner's 100-segment cap authoritative.
Differences from macOS: single-segment regeneration is not yet exposed (manifests carry empty
`replacements`), and line-separated batch remains intentionally absent — long-form **is** the
device-validated sequential-streaming design the iOS batch-removal invariant demanded.

Device acceptance passed 2026-07-24 on the paired iPhone 17 Pro (smoke run
`ios-xcui-smoke-20260724-183626-f9961535`): a >2,000-character script planned three segments,
streamed them sequentially (55.0 s + 45.4 s + 26.6 s), joined 127.2 s of audio through the
per-segment and joined QC gates, and grouped as a History project with a working per-segment
disclosure. The iOS smoke lane now runs both journeys (standard + long-form).

## Remaining work

- **iOS single-segment regeneration** — expose the shared replacement-lineage machinery on
  device (macOS-only today).
- **Segment-count scaling evidence** — clean 1-, 10-, and 100-segment macOS memory evidence
  proving steady-state memory does not scale with total audio duration (live acceptance covered a
  three-segment project).
- **Single-take spoken-text normalization** — single takes do not yet consume the spoken-text
  plan; it drives long-form only.
