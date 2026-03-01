import Foundation
import GRDB

/// Manages SQLite database for generation history.
final class DatabaseService {
    static let shared = DatabaseService()
    private static let generationSelectColumns = """
        id, text, mode, modelTier, voice, emotion, speed, audioPath, duration, createdAt
        """

    private var dbQueue: DatabaseQueue?
    private(set) var initError: String?

    private init() {
        do {
            let dbPath = QwenVoiceApp.appSupportDir.appendingPathComponent("history.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath)
            try migrate()
        } catch {
            let message = "Database initialization failed: \(error.localizedDescription)"
            initError = message
            print("[DatabaseService] \(message)")
        }
    }

    // MARK: - Migration

    private func migrate() throws {
        guard let dbQueue else { return }

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

        try migrator.migrate(dbQueue)
    }

    // MARK: - CRUD

    func saveGeneration(_ generation: inout Generation) throws {
        guard let dbQueue else {
            throw DatabaseServiceError.notInitialized(initError ?? "Unknown database error")
        }
        try dbQueue.write { db in
            try generation.save(db)
        }
    }

    func fetchAllGenerations() throws -> [Generation] {
        if dbQueue == nil {
            print("[DatabaseService] Warning: database not initialized, returning empty results")
        }
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            let sql = """
                SELECT \(Self.generationSelectColumns)
                FROM generations
                ORDER BY createdAt DESC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map(Generation.init(row:))
        }
    }

    func searchGenerations(query: String) throws -> [Generation] {
        if dbQueue == nil {
            print("[DatabaseService] Warning: database not initialized, returning empty results")
        }
        guard let dbQueue else { return [] }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try dbQueue.read { db in
            let pattern = "%\(escaped)%"
            let sql = """
                SELECT \(Self.generationSelectColumns)
                FROM generations
                WHERE text LIKE ? ESCAPE '\\'
                   OR COALESCE(voice, '') LIKE ? ESCAPE '\\'
                ORDER BY createdAt DESC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern, pattern])
            return rows.map(Generation.init(row:))
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
