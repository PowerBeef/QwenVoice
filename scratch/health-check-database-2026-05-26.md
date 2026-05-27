# Database Schema Audit — QwenVoice (2026-05-26)

## Summary

**Health: FRAGILE** — no CRITICAL data-loss or crash patterns detected in current migrations, but **macOS and iOS migration chains have already diverged** (macOS has `v4_index_generations_createdAt`; iOS does not). Both platforms duplicate the full `makeMigrator()` implementation in separate files, which caused the drift.

| Metric | Value |
|--------|-------|
| Framework | GRDB (`DatabaseQueue`) |
| Registered migrations | macOS **4**, iOS **3** |
| Tables | `generations` (single table, no FKs) |
| FK enforcement | Not configured (no FK constraints declared) |
| Idempotency | GRDB `registerMigration` run-once only; no explicit `IF NOT EXISTS` / column guards |
| Destructive ops | 1× `drop(table: "generations")` per platform inside data-preserving v3 recreation |
| **Counts** | CRITICAL **0** · HIGH **2** · MEDIUM **4** · LOW **2** |

**Immediate action:** Port `v4_index_generations_createdAt` to iOS and consolidate migrations into one shared module so macOS/iOS cannot drift again.

---

## Schema Map

- **Framework:** GRDB 7.x via `DatabaseQueue(path:)` — no custom `Configuration` / `prepareDatabase` hooks (no `PRAGMA foreign_keys`, no explicit WAL).
- **macOS entry:** `Sources/Services/DatabaseService.swift` → `~/Library/Application Support/QwenVoice-Debug|QwenVoice/.../history.sqlite`
- **iOS entry:** `Sources/iOSSupport/Services/DatabaseService.swift` → App Group container or `Q-Voice/.../history.sqlite`
- **Migrations (shared names v1–v3):** create table → add/drop `sortOrder` via table recreation → (macOS only) index on `createdAt`.
- **Models:** `Generation` in `Sources/Models/Generation.swift` (macOS) and `Sources/iOSSupport/Models/Generation.swift` (iOS) — column sets match final schema (no `sortOrder`).
- **Writes:** All CRUD wrapped in `dbQueue.write` / `read`; v2 backfill UPDATE loop runs inside GRDB migration transaction.
- **Cross-process:** Engine XPC / iOS extension do **not** touch `history.sqlite` — single-writer per platform.

---

## Issues

### HIGH — Platform schema drift (missing iOS v4 migration)

| Field | Detail |
|-------|--------|
| **Severity** | HIGH |
| **File:line** | `Sources/Services/DatabaseService.swift:93-98` (present) · `Sources/iOSSupport/Services/DatabaseService.swift:92` (absent) |
| **Phase** | 3 (completeness) + 4 (compound with duplicated migrator) |
| **Description** | macOS registers `v4_index_generations_createdAt` creating `idx_generations_createdAt` on `generations(createdAt)`. iOS `makeMigrator()` stops after v3. Same migration identifiers v1–v3 imply parity, but live schemas differ. Queries still work; iOS history fetches sort by `createdAt DESC` without the index (`Sources/iOSSupport/Services/DatabaseService.swift:133`, `Sources/Models/Generation.swift` Columns match). |
| **Impact** | Performance regression on iOS for large history tables; next schema change may be applied to one platform only (repeat of this drift); confusing for anyone assuming identical `history.sqlite` layout. |
| **Fix** | Add the same migration to iOS, then extract `makeMigrator()` to shared code (e.g. `Sources/SharedSupport/Database/GenerationMigrations.swift`) imported by both targets. |

```swift
migrator.registerMigration("v4_index_generations_createdAt") { db in
    try db.create(
        index: "idx_generations_createdAt",
        on: "generations",
        columns: ["createdAt"]
    )
}
```

---

### HIGH — Duplicated migration source (drift vector)

| Field | Detail |
|-------|--------|
| **Severity** | HIGH |
| **File:line** | `Sources/Services/DatabaseService.swift:38-101` · `Sources/iOSSupport/Services/DatabaseService.swift:37-92` |
| **Phase** | 3 (completeness) |
| **Description** | `makeMigrator()` is copy-pasted between macOS and iOS with only path/singleton annotation differences. `diff` shows v4 as the only schema delta today; CRUD bodies are otherwise identical. |
| **Impact** | Any future migration added to one file but not the other ships divergent schemas to production users on each platform. |
| **Fix** | Single shared `GenerationDatabaseMigrator.make()` used by both `DatabaseService` types; platform files keep only path resolution + CRUD. |

---

### MEDIUM — v2 backfill uses per-row UPDATE loop

| Field | Detail |
|-------|--------|
| **Severity** | MEDIUM |
| **File:line** | `Sources/Services/DatabaseService.swift:61-65` · `Sources/iOSSupport/Services/DatabaseService.swift:60-64` |
| **Phase** | 2 (Pattern 9 variant) + 3 |
| **Description** | After adding `sortOrder`, migration fetches all ids and runs one `UPDATE` per row. Loop is inside GRDB migration transaction (atomic), but O(n) statements on upgrade. |
| **Impact** | Slow first launch after v2 for users with thousands of history rows; brief startup block during migrate. Column was removed in v3, so this cost is historical-only for existing installs. |
| **Fix** | For future backfills, prefer set-based SQL, e.g. window function or `UPDATE ... SET sortOrder = (SELECT COUNT(*) FROM generations g2 WHERE g2.createdAt > g1.createdAt)`. No change required unless v2 is re-run. |

---

### MEDIUM — v3 table recreation without existence guards

| Field | Detail |
|-------|--------|
| **Severity** | MEDIUM |
| **File:line** | `Sources/Services/DatabaseService.swift:68-90` · `Sources/iOSSupport/Services/DatabaseService.swift:67-89` |
| **Phase** | 2 (Pattern 4) + 3 |
| **Description** | v3 correctly uses create-copy-drop-rename to remove `sortOrder` (safer than `DROP COLUMN`). No check for leftover `generations_v3` if a prior run crashed after partial manual repair. GRDB normally rolls back failed migrations. |
| **Impact** | Corrupted or manually edited DB could fail v3 with opaque errors; standard users unaffected. |
| **Fix** | Optional hardening: at start of v3, `DROP TABLE IF EXISTS generations_v3` and verify row counts match before drop. Keep table-recreation pattern. |

---

### MEDIUM — No post-migration schema sanity check

| Field | Detail |
|-------|--------|
| **Severity** | MEDIUM |
| **File:line** | `Sources/Services/DatabaseService.swift:27-28` · `Sources/iOSSupport/Services/DatabaseService.swift:26-27` |
| **Phase** | 3 (completeness) |
| **Description** | After `makeMigrator().migrate(queue)`, init assumes success. No verification that expected columns/indexes exist (e.g. `PRAGMA table_info(generations)`, index list). |
| **Impact** | Mid-migration corruption or partial manual edits surface later as query errors or empty history, not at init. |
| **Fix** | After migrate, assert required columns match `Generation.Columns` and (on macOS / once iOS has v4) index `idx_generations_createdAt` exists; fail init with clear `initError` if not. |

---

### MEDIUM — Silent degrade when DB init fails

| Field | Detail |
|-------|--------|
| **Severity** | MEDIUM |
| **File:line** | `Sources/Services/DatabaseService.swift:30-35,137-139` · `Sources/iOSSupport/Services/DatabaseService.swift:29-34,128-130` |
| **Phase** | 3 (completeness) |
| **Description** | Migration failure sets `dbQueue = nil`; `fetchAllGenerations()` logs a warning and returns `[]` instead of surfacing `initError`. |
| **Impact** | User sees empty history with no explanation; migration bugs hard to diagnose in TestFlight. |
| **Fix** | Expose read-only `isAvailable` / propagate `initError` to History UI; or rethrow on first fetch. |

---

### LOW — No explicit WAL / `prepareDatabase` configuration

| Field | Detail |
|-------|--------|
| **Severity** | LOW |
| **File:line** | `Sources/Services/DatabaseService.swift:26` · `Sources/iOSSupport/Services/DatabaseService.swift:25` |
| **Phase** | 3 |
| **Description** | `DatabaseQueue(path:)` uses GRDB defaults. No `PRAGMA journal_mode=WAL`. No FK pragma (no FKs today). |
| **Impact** | Currently single-process writer per DB file — acceptable. Would matter if extension/widget shared `history.sqlite`. |
| **Fix** | If multi-process access is added later: `Configuration` + `prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode=WAL") }`. |

---

### LOW — Index creation without `IF NOT EXISTS`

| Field | Detail |
|-------|--------|
| **Severity** | LOW |
| **File:line** | `Sources/Services/DatabaseService.swift:93-98` |
| **Phase** | 2 (Pattern 10) |
| **Description** | `db.create(index:on:columns:)` omits `ifNotExists: true`. Safe under normal GRDB migration bookkeeping. |
| **Impact** | Manual re-run or tampered `grdb_migrations` table could crash on duplicate index name. |
| **Fix** | `try db.create(index: "idx_generations_createdAt", on: "generations", columns: ["createdAt"], ifNotExists: true)` when porting to shared migrator. |

---

## Patterns Checked — No Issue Found

| Pattern | Result |
|---------|--------|
| ADD COLUMN NOT NULL without DEFAULT | **Clear** — v2 uses `.defaults(to: 0)` on nullable integer |
| DROP TABLE on user data without copy | **Clear** — v3 copies to `generations_v3` before drop |
| DROP COLUMN | **Clear** — v3 uses table recreation |
| INSERT OR REPLACE + FK cascade | **Clear** — no SQL UPSERT; `insertOrReplace` is in-memory `SavedVoicesViewModel` only |
| FOREIGN KEY without PRAGMA | **N/A** — no FK constraints |
| RENAME COLUMN | **Clear** — none |
| Batch insert outside transaction | **Clear** — CRUD uses `dbQueue.write`; v2 loop inside migration txn |
| `eraseDatabaseOnSchemaChange` | **Clear** — not used |

---

## Recommendations

1. **Immediate:** Add `v4_index_generations_createdAt` to `Sources/iOSSupport/Services/DatabaseService.swift` (or shared migrator).
2. **Short-term:** Extract shared `makeMigrator()` + consider shared `Generation` GRDB record to one module both targets import.
3. **Long-term:** Post-migrate schema assertion; surface `initError` in History/Settings; document that macOS and iOS `history.sqlite` files are not interchangeable across devices.
4. **Test plan:** Upgrade path v0→v4 with seeded DB (1000+ rows) on both platforms; kill app mid-v3 on test build and verify GRDB rollback; confirm iOS fetch latency with/without index on large dataset.

---

## Cross-Auditor Notes

- **storage-auditor:** `history.sqlite` lives under platform-specific App Support / App Group paths — backup and deletion semantics differ (`docs/reference/privacy-storage.md`).
- **swiftdata-auditor / core-data-auditor:** Not applicable — GRDB-only history store.
