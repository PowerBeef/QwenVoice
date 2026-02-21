import Foundation
import GRDB

/// Manages SQLite database for generation history.
final class DatabaseService {
    static let shared = DatabaseService()

    private var dbQueue: DatabaseQueue?

    private init() {
        do {
            let dbPath = QwenVoiceApp.appSupportDir.appendingPathComponent("history.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath)
            try migrate()
        } catch {
            print("[DatabaseService] Failed to initialize: \(error)")
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

        try migrator.migrate(dbQueue)
    }

    // MARK: - CRUD

    func saveGeneration(_ generation: inout Generation) throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            try generation.save(db)
        }
    }

    func fetchAllGenerations() throws -> [Generation] {
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            try Generation.order(Generation.Columns.createdAt.desc).fetchAll(db)
        }
    }

    func searchGenerations(query: String) throws -> [Generation] {
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            try Generation
                .filter(Generation.Columns.text.like("%\(query)%"))
                .order(Generation.Columns.createdAt.desc)
                .fetchAll(db)
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
