import Foundation
import GRDB

enum GenerationSortField: String, CaseIterable {
    case date, duration, voice, mode, manual

    var label: String {
        rawValue.capitalized
    }
}

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
        guard let dbQueue else { return }
        try dbQueue.write { db in
            if generation.id == nil {
                let min = try Int.fetchOne(db, sql: "SELECT MIN(sortOrder) FROM generations") ?? 0
                generation.sortOrder = min - 1
            }
            try generation.save(db)
        }
    }

    func fetchAllGenerations() throws -> [Generation] {
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            try Generation.order(Generation.Columns.createdAt.desc).fetchAll(db)
        }
    }

    func fetchGenerations(sortBy: GenerationSortField, ascending: Bool) throws -> [Generation] {
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            let ordering: SQLOrderingTerm
            switch sortBy {
            case .date:     ordering = ascending ? Generation.Columns.createdAt.asc : Generation.Columns.createdAt.desc
            case .duration: ordering = ascending ? Generation.Columns.duration.asc : Generation.Columns.duration.desc
            case .voice:    ordering = ascending ? Generation.Columns.voice.asc : Generation.Columns.voice.desc
            case .mode:     ordering = ascending ? Generation.Columns.mode.asc : Generation.Columns.mode.desc
            case .manual:   ordering = ascending ? Generation.Columns.sortOrder.asc : Generation.Columns.sortOrder.desc
            }
            return try Generation.order(ordering).fetchAll(db)
        }
    }

    func updateSortOrders(_ idOrderPairs: [(id: Int64, sortOrder: Int)]) throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            for pair in idOrderPairs {
                try db.execute(sql: "UPDATE generations SET sortOrder = ? WHERE id = ?",
                               arguments: [pair.sortOrder, pair.id])
            }
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
