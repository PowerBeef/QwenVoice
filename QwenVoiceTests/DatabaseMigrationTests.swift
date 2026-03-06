import XCTest
import GRDB
@testable import QwenVoice

final class DatabaseMigrationTests: XCTestCase {
    func testFreshSchemaHasNoSortOrderColumn() throws {
        let dbQueue = try DatabaseQueue(path: temporaryDatabasePath().path)

        try DatabaseService.makeMigrator().migrate(dbQueue)

        let columns = try columnNames(in: dbQueue)
        XCTAssertEqual(
            columns,
            ["id", "text", "mode", "modelTier", "voice", "emotion", "speed", "audioPath", "duration", "createdAt"]
        )
        XCTAssertFalse(columns.contains("sortOrder"))
    }

    func testMigratingLegacyV2SchemaPreservesRowsAndDropsSortOrder() throws {
        let dbQueue = try DatabaseQueue(path: temporaryDatabasePath().path)
        try seedLegacyV2Schema(in: dbQueue)

        try DatabaseService.makeMigrator().migrate(dbQueue)

        let columns = try columnNames(in: dbQueue)
        XCTAssertFalse(columns.contains("sortOrder"))

        let generations = try dbQueue.read { db in
            try Generation.fetchAll(db)
        }

        XCTAssertEqual(generations.count, 1)
        XCTAssertEqual(generations.first?.text, "Legacy fixture")
        XCTAssertEqual(generations.first?.mode, "clone")
        XCTAssertEqual(generations.first?.audioPath, "/tmp/legacy.wav")
    }

    private func temporaryDatabasePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func columnNames(in dbQueue: DatabaseQueue) throws -> [String] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(generations)")
                .compactMap { row in
                    row["name"] as String?
                }
        }
    }

    private func seedLegacyV2Schema(in dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v1_create_generations')")
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v2_add_sortOrder')")
            try db.execute(sql: """
                CREATE TABLE generations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    modelTier TEXT NOT NULL,
                    voice TEXT,
                    emotion TEXT,
                    speed DOUBLE,
                    audioPath TEXT NOT NULL,
                    duration DOUBLE,
                    createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    sortOrder INTEGER DEFAULT 0
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO generations (
                        text, mode, modelTier, voice, emotion, speed, audioPath, duration, createdAt, sortOrder
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    )
                    """,
                arguments: [
                    "Legacy fixture",
                    "clone",
                    "pro",
                    "fixture_voice",
                    nil,
                    nil,
                    "/tmp/legacy.wav",
                    1.5,
                    "2026-03-05 12:00:00",
                    0,
                ]
            )
        }
    }
}
