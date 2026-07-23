// Settings key/value store (§4.1). API key material never lands here —
// it lives in the Keychain (FR-013); this table may hold a reference name.
import Foundation
import GRDB

public struct SettingsRepository {
    public enum Key: String, CaseIterable, Sendable {
        case aiEnabled = "ai.enabled"
        case aiProvider = "ai.provider"
        case modelExtraction = "ai.model.extraction"
        case modelReflection = "ai.model.reflection"
        case modelEmbedding = "ai.embedding.model"
        case sttModel = "stt.model"
        case appLock = "security.app_lock"
    }

    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    public func get(_ key: Key) throws -> String? {
        try db.reader.read { dbc in
            try String.fetchOne(
                dbc, sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key.rawValue])
        }
    }

    public func set(_ key: Key, _ value: String, now: Date = .now) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                        updated_at = excluded.updated_at
                    """,
                arguments: [key.rawValue, value, DBFormat.timestamp.string(from: now)])
        }
    }

    public func getBool(_ key: Key) throws -> Bool {
        try get(key) == "true"
    }

    public func setBool(_ key: Key, _ value: Bool, now: Date = .now) throws {
        try set(key, value ? "true" : "false", now: now)
    }
}
