import XCTest
import GRDB
@testable import QwenVoice

final class DatabaseServiceTests: XCTestCase {
    @MainActor
    func testMigratorCreatesCreatedAtIndex() throws {
        let dbQueue = try DatabaseQueue()

        try DatabaseService.makeMigrator().migrate(dbQueue)

        let indexes = try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'index' AND tbl_name = 'generations'
                ORDER BY name
                """
            )
        }

        XCTAssertTrue(indexes.contains("idx_generations_createdAt"))
    }

    @MainActor
    func testMigratorPreservesCreatedAtOrderingWhenAddingIndex() throws {
        let dbQueue = try DatabaseQueue()
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
                t.column("createdAt", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        try dbQueue.write { db in
            for offset in [30.0, 10.0, 20.0] {
                var generation = Generation(
                    id: nil,
                    text: "Sample \(offset)",
                    mode: "custom",
                    modelTier: "pro",
                    voice: "Vivian",
                    emotion: nil,
                    speed: nil,
                    audioPath: "/tmp/\(offset).wav",
                    duration: 1.0,
                    createdAt: baseDate.addingTimeInterval(offset)
                )
                try generation.save(db)
            }
        }

        try DatabaseService.makeMigrator().migrate(dbQueue)

        let createdAtValues = try dbQueue.read { db in
            try Date.fetchAll(
                db,
                sql: "SELECT createdAt FROM generations ORDER BY createdAt DESC"
            )
        }

        XCTAssertEqual(
            createdAtValues,
            [30.0, 20.0, 10.0].map { baseDate.addingTimeInterval($0) }
        )
    }
}
