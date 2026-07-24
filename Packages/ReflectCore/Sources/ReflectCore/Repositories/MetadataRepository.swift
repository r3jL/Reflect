// Derived-metadata writes (§4.2). One transaction per entry per stage run:
// prior rows for the entry are replaced wholesale (AC-005 supersede), theme
// and entity registries stay canonical (deduped) across the journal.
import Foundation
import GRDB

public struct MetadataRepository {
    public struct EntityRef: Equatable, Sendable {
        public let name: String
        public let type: String
        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public struct ActionItemRef: Equatable, Sendable {
        public let text: String
        public let dueHint: String?
        public init(text: String, dueHint: String?) {
            self.text = text
            self.dueHint = dueHint
        }
    }

    public static let entityTypes: Set<String> = [
        "person", "place", "book", "company", "project", "other",
    ]

    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    // MARK: - Extraction write (FR-021)

    public func replaceExtraction(
        entryId: String,
        themes: [String],
        tags: [String],
        entities: [EntityRef],
        actionItems: [ActionItemRef],
        selfQuestions: [String],
        now: Date = .now
    ) throws {
        let stamp = DBFormat.timestamp.string(from: now)
        try db.writer.write { dbc in
            // Supersede: this entry's prior extraction rows go away first.
            for table in [
                "entry_themes", "entry_tags", "entry_entities",
                "action_items", "self_questions",
            ] {
                try dbc.execute(
                    sql: "DELETE FROM \(table) WHERE entry_id = ?",
                    arguments: [entryId])
            }

            for rawTheme in themes {
                let name = Self.canonical(rawTheme)
                guard !name.isEmpty else { continue }
                let themeId = try Self.findOrCreate(
                    dbc, table: "themes", name: name)
                try dbc.execute(
                    sql: """
                        INSERT OR IGNORE INTO entry_themes (entry_id, theme_id)
                        VALUES (?, ?)
                        """,
                    arguments: [entryId, themeId])
            }

            for rawTag in tags {
                let tag = Self.canonical(rawTag)
                guard !tag.isEmpty else { continue }
                try dbc.execute(
                    sql: "INSERT OR IGNORE INTO entry_tags (entry_id, tag) VALUES (?, ?)",
                    arguments: [entryId, tag])
            }

            for entity in entities {
                let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let type = Self.entityTypes.contains(entity.type) ? entity.type : "other"
                let entityId: String
                if let existing = try String.fetchOne(
                    dbc,
                    sql: "SELECT id FROM entities WHERE name = ? AND type = ?",
                    arguments: [name, type])
                {
                    entityId = existing
                } else {
                    entityId = UUID().uuidString
                    try dbc.execute(
                        sql: "INSERT INTO entities (id, name, type) VALUES (?, ?, ?)",
                        arguments: [entityId, name, type])
                }
                try dbc.execute(
                    sql: """
                        INSERT OR IGNORE INTO entry_entities (entry_id, entity_id)
                        VALUES (?, ?)
                        """,
                    arguments: [entryId, entityId])
            }

            for item in actionItems {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try dbc.execute(
                    sql: """
                        INSERT INTO action_items (id, entry_id, text, status, due_hint, created_at)
                        VALUES (?, ?, ?, 'open', ?, ?)
                        """,
                    arguments: [UUID().uuidString, entryId, text, item.dueHint, stamp])
            }

            for question in selfQuestions {
                let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try dbc.execute(
                    sql: """
                        INSERT INTO self_questions (id, entry_id, text, created_at)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [UUID().uuidString, entryId, text, stamp])
            }
        }
    }

    // MARK: - Reflection write (FR-022)

    public struct Reflection: Equatable, Sendable {
        public let summary: String
        public let moodLabel: String
        public let moodConfidence: Double
        public let sentimentScore: Double
        public let energy: String
        public let reflectionNote: String
        public let model: String?

        public init(
            summary: String, moodLabel: String, moodConfidence: Double,
            sentimentScore: Double, energy: String, reflectionNote: String,
            model: String? = nil
        ) {
            self.summary = summary
            self.moodLabel = moodLabel
            self.moodConfidence = moodConfidence
            self.sentimentScore = sentimentScore
            self.energy = energy
            self.reflectionNote = reflectionNote
            self.model = model
        }
    }

    /// 1:1 with the entry; superseded wholesale on re-run (AC-005/AC-022).
    public func replaceReflection(
        entryId: String,
        _ reflection: Reflection,
        modelVersion: String,
        now: Date = .now
    ) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    INSERT OR REPLACE INTO entry_reflection
                        (entry_id, summary, mood_label, mood_confidence,
                         sentiment_score, energy, reflection_note, model,
                         model_version, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entryId, reflection.summary, reflection.moodLabel,
                    reflection.moodConfidence, reflection.sentimentScore,
                    reflection.energy, reflection.reflectionNote,
                    reflection.model, modelVersion,
                    DBFormat.timestamp.string(from: now),
                ])
        }
    }

    public func reflection(entryId: String) throws -> Reflection? {
        try db.reader.read { dbc in
            guard let row = try Row.fetchOne(
                dbc,
                sql: "SELECT * FROM entry_reflection WHERE entry_id = ?",
                arguments: [entryId])
            else { return nil }
            return Reflection(
                summary: row["summary"] ?? "",
                moodLabel: row["mood_label"] ?? "",
                moodConfidence: row["mood_confidence"] ?? 0,
                sentimentScore: row["sentiment_score"] ?? 0,
                energy: row["energy"] ?? "",
                reflectionNote: row["reflection_note"] ?? "",
                model: row["model"])
        }
    }

    // MARK: - Reads

    public func themes(entryId: String) throws -> [String] {
        try db.reader.read { dbc in
            try String.fetchAll(
                dbc,
                sql: """
                    SELECT t.name FROM themes t
                    JOIN entry_themes et ON et.theme_id = t.id
                    WHERE et.entry_id = ? ORDER BY t.name
                    """,
                arguments: [entryId])
        }
    }

    public func tags(entryId: String) throws -> [String] {
        try db.reader.read { dbc in
            try String.fetchAll(
                dbc,
                sql: "SELECT tag FROM entry_tags WHERE entry_id = ? ORDER BY tag",
                arguments: [entryId])
        }
    }

    public func entities(entryId: String) throws -> [EntityRef] {
        try db.reader.read { dbc in
            let rows = try Row.fetchAll(
                dbc,
                sql: """
                    SELECT e.name, e.type FROM entities e
                    JOIN entry_entities ee ON ee.entity_id = e.id
                    WHERE ee.entry_id = ? ORDER BY e.type, e.name
                    """,
                arguments: [entryId])
            return rows.map { EntityRef(name: $0["name"], type: $0["type"]) }
        }
    }

    public func actionItems(entryId: String) throws -> [ActionItemRef] {
        try db.reader.read { dbc in
            let rows = try Row.fetchAll(
                dbc,
                sql: """
                    SELECT text, due_hint FROM action_items
                    WHERE entry_id = ? ORDER BY rowid
                    """,
                arguments: [entryId])
            return rows.map { ActionItemRef(text: $0["text"], dueHint: $0["due_hint"]) }
        }
    }

    public func selfQuestions(entryId: String) throws -> [String] {
        try db.reader.read { dbc in
            try String.fetchAll(
                dbc,
                sql: """
                    SELECT text FROM self_questions
                    WHERE entry_id = ? ORDER BY rowid
                    """,
                arguments: [entryId])
        }
    }

    public func themeCount() throws -> Int {
        try db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM themes") ?? 0
        }
    }

    // MARK: - Helpers

    static func canonical(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func findOrCreate(
        _ dbc: Database, table: String, name: String
    ) throws -> String {
        if let existing = try String.fetchOne(
            dbc, sql: "SELECT id FROM \(table) WHERE name = ?", arguments: [name])
        {
            return existing
        }
        let id = UUID().uuidString
        try dbc.execute(
            sql: "INSERT INTO \(table) (id, name) VALUES (?, ?)",
            arguments: [id, name])
        return id
    }
}
