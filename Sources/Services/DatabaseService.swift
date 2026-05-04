import Foundation
import GRDB

/// Manages SQLite database for generation history.
///
/// Intentionally not `@MainActor`-isolated. `DatabaseQueue` is GRDB's
/// thread-safe queue primitive; all read/write operations route through
/// it. The class state (`dbQueue` + `initError`) is set once during init
/// and read-only thereafter, so the `@unchecked Sendable` conformance
/// is sound. Non-isolation lets `GenerationPersistence` schedule writes
/// via `Task.detached` so they don't block the UI's main run loop —
/// previously the synchronous save on `@MainActor` introduced a 5-30ms
/// hitch right after every generation completed.
final class DatabaseService: @unchecked Sendable {
    /// Process-wide singleton. Marked `nonisolated(unsafe)` because the
    /// class itself manages thread-safety via `DatabaseQueue`; the
    /// initializer is the only place state is mutated.
    nonisolated(unsafe) static let shared = DatabaseService()

    private let dbQueue: DatabaseQueue?
    let initError: String?

    private init() {
        let dbPath = QwenVoiceApp.appSupportDir.appendingPathComponent("history.sqlite").path
        do {
            let queue = try DatabaseQueue(path: dbPath)
            try Self.makeMigrator().migrate(queue)
            self.dbQueue = queue
            self.initError = nil
        } catch {
            let message = "Database initialization failed: \(error.localizedDescription)"
            self.dbQueue = nil
            self.initError = message
            print("[DatabaseService] \(message)")
        }
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_generations") { db in
            try db.create(table: "generations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("modelTier", .text).notNull()
                t.column("voice", .text)
                t.column("emotion", .text)
                t.column("speed", .double)
                t.column("audioPath", .text).notNull()
                t.column("duration", .double)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        migrator.registerMigration("v2_add_sortOrder") { db in
            try db.alter(table: "generations") { t in
                t.add(column: "sortOrder", .integer).defaults(to: 0)
            }
            // Backfill: assign sortOrder matching existing createdAt desc order
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM generations ORDER BY createdAt DESC")
            for (index, row) in rows.enumerated() {
                let id: Int64 = row["id"]
                try db.execute(sql: "UPDATE generations SET sortOrder = ? WHERE id = ?", arguments: [index, id])
            }
        }

        migrator.registerMigration("v3_drop_sortOrder") { db in
            try db.create(table: "generations_v3") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("modelTier", .text).notNull()
                t.column("voice", .text)
                t.column("emotion", .text)
                t.column("speed", .double)
                t.column("audioPath", .text).notNull()
                t.column("duration", .double)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.execute(sql: """
                INSERT INTO generations_v3 (id, text, mode, modelTier, voice, emotion, speed, audioPath, duration, createdAt)
                SELECT id, text, mode, modelTier, voice, emotion, speed, audioPath, duration, createdAt
                FROM generations
                ORDER BY createdAt DESC
                """)

            try db.drop(table: "generations")
            try db.rename(table: "generations_v3", to: "generations")
        }

        migrator.registerMigration("v4_index_generations_createdAt") { db in
            try db.create(
                index: "idx_generations_createdAt",
                on: "generations",
                columns: ["createdAt"]
            )
        }

        return migrator
    }

    // MARK: - CRUD

    /// Synchronous variant. Kept for legacy / migration call sites that
    /// can't be moved to async (e.g. from `@MainActor` synchronous
    /// contexts during init). New off-main callers should prefer
    /// `saveGenerationAsync(_:)` which uses GRDB's async write.
    func saveGeneration(_ generation: inout Generation) throws {
        guard let dbQueue else {
            throw DatabaseServiceError.notInitialized(initError ?? "Unknown database error")
        }
        try dbQueue.write { db in
            try generation.save(db)
        }
    }

    /// Async variant — call from a detached Task to keep the SQLite
    /// write off the main run loop. GRDB's `DatabaseQueue.write` has an
    /// async overload that bridges to its internal write queue;
    /// returning the persisted Generation lets callers obtain the
    /// auto-assigned `id` without an `inout` parameter (unsendable in
    /// async contexts).
    func saveGenerationAsync(_ generation: Generation) async throws -> Generation {
        guard let dbQueue else {
            throw DatabaseServiceError.notInitialized(initError ?? "Unknown database error")
        }
        return try await dbQueue.write { db in
            var copy = generation
            try copy.save(db)
            return copy
        }
    }

    func fetchAllGenerations() throws -> [Generation] {
        if dbQueue == nil {
            print("[DatabaseService] Warning: database not initialized, returning empty results")
        }
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            try Generation.order(Generation.Columns.createdAt.desc).fetchAll(db)
        }
    }

    func deleteGeneration(id: Int64) throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            _ = try Generation.deleteOne(db, id: id)
        }
    }

    func deleteAllGenerations() throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            _ = try Generation.deleteAll(db)
        }
    }
}

enum DatabaseServiceError: LocalizedError {
    case notInitialized(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized(let reason):
            return "Database unavailable: \(reason)"
        }
    }
}
