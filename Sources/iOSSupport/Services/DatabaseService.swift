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
///
/// This is the iOS copy (mirrors `Sources/Services/DatabaseService.swift`); it
/// resolves its database file under the iOS App Group container via `AppPaths`,
/// which is itself platform-specific.
final class DatabaseService: @unchecked Sendable {
    /// Process-wide singleton. The service manages thread-safety via
    /// `DatabaseQueue`; the initializer is the only place state is mutated.
    static let shared = DatabaseService()

    private let dbQueue: DatabaseQueue?
    let initError: String?

    private init() {
        let dbPath = AppPaths.appSupportDir.appendingPathComponent("history.sqlite").path
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
        GenerationMigrations.makeMigrator()
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
