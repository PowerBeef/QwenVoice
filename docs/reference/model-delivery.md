# Model delivery

Vocello uses one shared native downloader, `HuggingFaceDownloader`, for pinned Hugging Face model
artifacts. macOS and the CLI use foreground `URLSession` instances. iPhone uses one bundle-aware
background session for the app lifetime. There is no second downloader, cloud synthesis path, or
ordinary-CI model fetch.

## Integrity and installation

Every file is matched to the model contract or the bundled iOS catalog, downloaded into staging,
checked against its exact byte count and SHA-256, and installed by an atomic directory swap. A
newly assembled file is hashed once. A same-process verified-artifact receipt permits finalization
without reading the complete file again; after a relaunch the staged file is hashed once before a
new receipt is trusted. Installed models retain the existing integrity-manifest format.

macOS and CLI staging remains next to the model store under `.qwenvoice-downloads/`. iPhone has one
layout under the app-support root:

```text
downloads/
  ios_model_delivery_state.json
  staging/
    delegate-files/
    <model-id>/{files,partials,resume-data}/
diagnostics/model-downloads/
models/
```

### Cross-platform production catalog

`Sources/Resources/qwenvoice_production_model_catalog.json` is the reproducible, bundled catalog
contract for future convergence of macOS, CLI, and iPhone delivery. Its versioned shape is declared
by `config/model-catalog-schema-v1.json`; it is generated only from the shared model contract and
checked-in exact file evidence:

```sh
python3 scripts/model_catalog_contract.py rebuild --check
python3 scripts/model_catalog_contract.py validate
```

Every covered artifact has a 40-character immutable Hugging Face revision, an allowlisted HTTPS
resolve URL, safe relative paths, positive exact byte counts, and a lowercase SHA-256 for every
required file. Source digests make independent edits to the shared contract, iPhone catalog, or
generated catalog fail validation.

Initial artifact requests remain restricted to the catalog's exact host. URLSession redirects are
also policy-checked: only HTTPS destinations without credentials or IP/local hosts are accepted,
and the destination must remain on the configured host or the explicit Hugging Face distribution
suffixes `huggingface.co` and `hf.co`. A rejected redirect is never adopted as background work.

The catalog is `complete`: the bundled iPhone evidence supplies the three Speed variants and
`config/model-artifact-receipts.json` supplies the three Quality variants. All six packages pin a
revision plus the exact size and SHA-256 of every required file; no hash or size is inferred.
macOS and CLI now resolve `ProductionModelCatalog` and call the same exact-file `downloadFiles`
route rather than enumerating a live repository. `validate --require-complete` proves this static
contract. It does not replace the isolated Mac/iPhone lifecycle proofs, which must be refreshed as
explicit quality evidence after redirect, restoration, or delivery-routing changes.

The iOS ledger is atomically written, versioned, and contains only privacy-safe identifiers and
relative paths. It records the logical request, model and artifact version, expected and verified
files, retries, monotonic received bytes, and terminal state. A one-time migration cancels the old
per-model sessions, waits for their cancellation callbacks, moves recoverable staging into the v2
layout, and removes the old document only when those sessions are empty. Installed models are not
touched.

## iPhone restoration and ownership

At launch, the coordinator asks the single background session for all tasks. Valid tasks whose
encoded model/artifact/file identity exactly matches the ledger and current catalog are adopted.
Unknown, stale, or duplicate tasks are cancelled, and only missing files receive new tasks.
Delegate temporary files are synchronously moved into durable app-group staging before the callback
returns. UIKit's background-session completion handler is released only after all delegate events
and durable install/failure postprocessing finish. Completion routing is exact-identifier scoped:
the canonical and debug-isolated coordinators retain and acknowledge only their own session's
handler. A foreign handler is neither stored nor completed, while an owned session with no durable
work is completed after reconciliation.

iPhone runs one model request at a time. macOS keeps its existing foreground concurrency. Both
platforms keep per-file range chunking disabled by default.

## States, cancellation, and retry

Visible states are: queued, waiting for connectivity, downloading, retrying, verifying, installing,
cancelling, installed, failed, deleting, and deleted. Speed and ETA are shown only during active
transfer. A separate no-progress message appears after 20 seconds of an actively running task;
waiting-for-connectivity comes from the URLSession delegate.

Explicit **Cancel** is a discard operation. The coordinator first persists `cancelRequested`, stops
new task registration, awaits all resume-data cancellation callbacks and terminal tasks, persists
the final deleted tombstone, and only then removes staging or reports deletion. If either critical
ledger write fails, cancellation fails closed: tasks or staging are preserved as applicable, the UI
shows a privacy-safe storage error, and relaunch cannot silently reinterpret the request as queued.
**Retry** preserves already verified files and reconstructs progress from the ledger, staged
partials, and adopted task byte counts.

Transient connection failures and HTTP 408, 429, and 5xx responses retry up to three times. A
`Retry-After` value is honored up to five minutes. One integrity mismatch receives one clean retry.
Cancellation, disk exhaustion, local filesystem errors, TLS trust failures, configuration errors,
and permanent 4xx responses do not retry.

## Diagnostics and acceptance

Local diagnostic summaries retain at most 20 records and 5 MB. Their allowlisted fields cover
timing, protocol, redirect/reuse and constrained/expensive-network flags, transferred bytes, and a
sanitized failure class. A successful attempt also records expected and wire bytes, duplicate bytes,
retry count, protocol set, thermal state, phase timings, and final-integrity status. Task completion
waits for URLSession's terminal callback so the success summary cannot overtake final task metrics.
They never contain a raw URL, absolute path, device identity, or user data.

Deterministic tests are model-free and Simulator-free. Live delivery is an explicit diagnostic:

```sh
# isolated macOS/CLI data root
./build/vocello models install pro_custom_speed \
  --data-dir build/scratch/transient/model-download-acceptance/ --verbose

# paired physical iPhone; safe leaf under managed Application Support,
# never the canonical App Group model tree
scripts/ui_test.sh ios model-download
```

The iPhone proof backgrounds and terminates the app during transfer, relaunches it, requires
non-regressing adopted progress, waits for exact verified installation, and deletes the isolated
model through the visible UI. It is not part of smoke, benchmark, CI, release, or packaging.
Crash-delta snapshots retain hashes rather than duplicating the device's historical diagnostics;
the lane pulls only its bounded model-download summaries into the local untracked result artifact.

The 2026-07-14 isolated Custom Speed acceptance passed on the Mac mini M2 8 GB and physical iPhone
17 Pro. Both transfers moved the exact 2,312,057,897 expected bytes without retry or duplicate
payload. Control-plane traffic such as the macOS catalog response is recorded separately and is
never classified as duplicate model payload. The iPhone XCUITest completed its
background/relaunch/install/visible-delete lifecycle in
81.6 seconds and reported HTTP/2 plus HTTP/1.1 with fair thermal state. This is lifecycle evidence,
not a performance baseline, and did not change concurrency or range-chunking defaults.

The lane also enters canonical Settings before and after the isolated lifecycle and requires all
three production models to remain installed with no visible canonical transfer in flight. The
debug isolation override accepts only an absolute
diagnostic path or one safe relative leaf; traversal and nested relative paths fail closed. Only
the managed relative leaf selects a separate app-lifetime background session, and its identifier
contains a one-way digest rather than the leaf itself. Production and absolute diagnostic roots
retain the historical bundle-scoped session identifier, so private paths cannot create arbitrary
URLSession namespaces.

That proof predates redirect-policy enforcement. The next explicitly requested isolated iPhone
delivery proof must therefore confirm that the provider's live redirect chain remains within the
declared `huggingface.co`/`hf.co` boundary. This deferred live check does not block deterministic
development publication, and it must not be represented as passed from the earlier artifact.

## Tuning policy

One live transfer is a lifecycle proof, not a concurrency experiment. Connection counts or chunking
defaults may change only after a controlled comparison improves total transfer time by at least 15%
without more retries, duplicate bytes, thermal regression, or restoration failure.

Background Assets was evaluated and not adopted in this change. See
[`../decisions/model-delivery-background-assets.md`](../decisions/model-delivery-background-assets.md).

Changed-path evidence expectations are classified by
[`evidence-impact.md`](evidence-impact.md). Live model downloads remain explicit quality evidence,
not ordinary commit, merge, or release-packaging blockers.
