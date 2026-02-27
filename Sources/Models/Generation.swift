import Foundation
import GRDB

/// A record of a single TTS generation, stored in SQLite via GRDB.
struct Generation: Identifiable, Codable, Hashable {
    var id: Int64?
    var text: String
    var mode: String            // "custom", "design", "clone"
    var modelTier: String       // "pro", "lite"
    var voice: String?          // speaker name or voice description
    var emotion: String?
    var speed: Double?
    var audioPath: String
    var duration: Double?
    var createdAt: Date
    /// Display-friendly date string
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    /// Short text preview (first 60 chars)
    var textPreview: String {
        if text.count <= 60 { return text }
        return String(text.prefix(60)) + "..."
    }

    /// Whether the audio file still exists on disk
    var audioFileExists: Bool {
        FileManager.default.fileExists(atPath: audioPath)
    }
}

// MARK: - GRDB TableRecord + FetchableRecord + PersistableRecord

extension Generation: TableRecord, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "generations"

    enum Columns: String, ColumnExpression {
        case id, text, mode, modelTier, voice, emotion, speed, audioPath, duration, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
