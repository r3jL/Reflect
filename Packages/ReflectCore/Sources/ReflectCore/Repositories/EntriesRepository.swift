// Entry lifecycle per §5.1: draft → autosave → complete (enqueues pipeline
// jobs, AC-003) → optional edit (re-enqueues, FR-004) → soft delete/trash.
import Foundation
import GRDB

public struct EntriesRepository {
    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    // MARK: - Lifecycle

    /// FR-001: new draft for the given day.
    @discardableResult
    public func createDraft(entryDate: String, now: Date = .now) throws -> Entry {
        let stamp = DBFormat.timestamp.string(from: now)
        let entry = Entry(
            id: UUID().uuidString, title: nil, body: "", entryDate: entryDate,
            status: .draft, wordCount: 0, place: nil, weather: nil,
            isMilestone: false, isDeleted: false,
            createdAt: stamp, updatedAt: stamp, completedAt: nil)
        try db.writer.write { try entry.insert($0) }
        return entry
    }

    /// FR-002 autosave; FR-004: editing a completed entry re-enqueues jobs.
    public func updateBody(
        id: String, title: String?, body: String, now: Date = .now
    ) throws {
        try db.writer.write { dbc in
            guard var entry = try Entry.fetchOne(dbc, key: id) else { return }
            entry.title = title
            entry.body = body
            entry.wordCount = Entry.wordCount(of: body)
            entry.updatedAt = DBFormat.timestamp.string(from: now)
            try entry.update(dbc)
            if entry.status == .completed {
                try Self.enqueueJobs(dbc, entryId: id, now: now)
            }
        }
    }

    /// FR-015 context fields.
    public func updateContext(
        id: String, place: String?, weather: String?, isMilestone: Bool,
        now: Date = .now
    ) throws {
        try db.writer.write { dbc in
            guard var entry = try Entry.fetchOne(dbc, key: id) else { return }
            entry.place = place
            entry.weather = weather
            entry.isMilestone = isMilestone
            entry.updatedAt = DBFormat.timestamp.string(from: now)
            try entry.update(dbc)
        }
    }

    /// FR-003 / AC-003: complete sets `completed_at` and enqueues all three
    /// pipeline stages as `pending` (they stay pending offline, AC-004).
    public func complete(id: String, now: Date = .now) throws {
        try db.writer.write { dbc in
            guard var entry = try Entry.fetchOne(dbc, key: id) else { return }
            let stamp = DBFormat.timestamp.string(from: now)
            entry.status = .completed
            entry.completedAt = stamp
            entry.updatedAt = stamp
            try entry.update(dbc)
            try Self.enqueueJobs(dbc, entryId: id, now: now)
        }
    }

    /// One row per (entry, stage); re-completion resets existing rows to
    /// pending (FR-031 manual re-run uses the same path).
    static func enqueueJobs(_ dbc: Database, entryId: String, now: Date) throws {
        let stamp = DBFormat.timestamp.string(from: now)
        for stage in PipelineJob.Stage.allCases {
            try dbc.execute(
                sql: """
                    INSERT INTO pipeline_jobs (id, entry_id, stage, status, attempts, created_at)
                    VALUES (?, ?, ?, 'pending', 0, ?)
                    ON CONFLICT(entry_id, stage) DO UPDATE SET
                        status = 'pending', attempts = 0, last_error = NULL,
                        started_at = NULL, finished_at = NULL
                    """,
                arguments: [UUID().uuidString, entryId, stage.rawValue, stamp])
        }
    }

    // MARK: - Fetching

    public func fetch(id: String) throws -> Entry? {
        try db.reader.read { try Entry.fetchOne($0, key: id) }
    }

    /// The entry for a given day (Today view), trash excluded.
    public func fetchForDate(_ entryDate: String) throws -> Entry? {
        try db.reader.read { dbc in
            try Entry
                .filter(Column("entry_date") == entryDate)
                .filter(Column("is_deleted") == false)
                .order(Column("created_at").desc)
                .fetchOne(dbc)
        }
    }

    /// Today view: the day's entry, created as a draft if absent (AC-001).
    public func fetchOrCreateForDate(_ entryDate: String, now: Date = .now) throws -> Entry {
        try db.writer.write { dbc in
            if let existing = try Entry
                .filter(Column("entry_date") == entryDate)
                .filter(Column("is_deleted") == false)
                .order(Column("created_at").desc)
                .fetchOne(dbc)
            {
                return existing
            }
            let stamp = DBFormat.timestamp.string(from: now)
            let entry = Entry(
                id: UUID().uuidString, title: nil, body: "", entryDate: entryDate,
                status: .draft, wordCount: 0, place: nil, weather: nil,
                isMilestone: false, isDeleted: false,
                createdAt: stamp, updatedAt: stamp, completedAt: nil)
            try entry.insert(dbc)
            return entry
        }
    }

    /// Distinct days that have a non-trashed entry, newest first — the
    /// writing-streak source (Today margin metadata).
    public func distinctEntryDates(limit: Int = 400) throws -> [String] {
        try db.reader.read { dbc in
            try String.fetchAll(
                dbc,
                sql: """
                    SELECT DISTINCT entry_date FROM entries
                    WHERE is_deleted = 0
                    ORDER BY entry_date DESC LIMIT ?
                    """,
                arguments: [limit])
        }
    }

    /// "On this day" — past entries sharing the month-day (e.g. "07-23").
    public func onThisDayCount(monthDay: String, excludingDate: String) throws -> Int {
        try db.reader.read { dbc in
            try Int.fetchOne(
                dbc,
                sql: """
                    SELECT COUNT(*) FROM entries
                    WHERE entry_date LIKE '%-' || ? AND entry_date <> ?
                      AND is_deleted = 0
                    """,
                arguments: [monthDay, excludingDate]) ?? 0
        }
    }

    /// FR-009: reverse-chronological timeline (trash excluded).
    public func timeline(limit: Int = 100) throws -> [Entry] {
        try db.reader.read { dbc in
            try Entry
                .filter(Column("is_deleted") == false)
                .order(Column("entry_date").desc, Column("created_at").desc)
                .limit(limit)
                .fetchAll(dbc)
        }
    }

    /// All non-trashed entries within a month ("YYYY-MM") — the Life map.
    public func month(_ yearMonth: String) throws -> [Entry] {
        try db.reader.read { dbc in
            try Entry
                .filter(Column("entry_date") >= "\(yearMonth)-01")
                .filter(Column("entry_date") <= "\(yearMonth)-31")
                .filter(Column("is_deleted") == false)
                .order(Column("entry_date").asc)
                .fetchAll(dbc)
        }
    }

    /// Mood per entry from the Reflection stage (empty until Phase 1 runs).
    public func moodLabels(entryIds: [String]) throws -> [String: String] {
        guard !entryIds.isEmpty else { return [:] }
        return try db.reader.read { dbc in
            let placeholders = databaseQuestionMarks(count: entryIds.count)
            let rows = try Row.fetchAll(
                dbc,
                sql: """
                    SELECT entry_id, mood_label FROM entry_reflection
                    WHERE entry_id IN (\(placeholders)) AND mood_label IS NOT NULL
                    """,
                arguments: StatementArguments(entryIds))
            return Dictionary(
                uniqueKeysWithValues: rows.map { ($0["entry_id"] as String, $0["mood_label"] as String) })
        }
    }

    /// Which of the given entries have at least one media row (Life glyphs).
    public func entryIdsWithMedia(_ entryIds: [String]) throws -> Set<String> {
        guard !entryIds.isEmpty else { return [] }
        return try db.reader.read { dbc in
            let placeholders = databaseQuestionMarks(count: entryIds.count)
            let ids = try String.fetchAll(
                dbc,
                sql: "SELECT DISTINCT entry_id FROM media WHERE entry_id IN (\(placeholders))",
                arguments: StatementArguments(entryIds))
            return Set(ids)
        }
    }

    // MARK: - Search (FR-011)

    public struct SearchHit: Equatable {
        public let entry: Entry
        public let snippet: String
    }

    /// FTS5 keyword search over title/body, trash excluded, offline (AC-009).
    public func searchKeyword(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try db.reader.read { dbc in
            let rows = try Row.fetchAll(
                dbc,
                sql: """
                    SELECT e.*, snippet(entries_fts, 1, '', '', '…', 12) AS snippet
                    FROM entries_fts f
                    JOIN entries e ON e.rowid = f.rowid
                    WHERE entries_fts MATCH ? AND e.is_deleted = 0
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [FTS5Pattern(matchingAllPrefixesIn: trimmed), limit])
            return try rows.map { row in
                SearchHit(
                    entry: try Entry(row: row),
                    snippet: row["snippet"] ?? "")
            }
        }
    }

    // MARK: - Trash (FR-010)

    public func softDelete(id: String, now: Date = .now) throws {
        try setDeleted(id: id, deleted: true, now: now)
    }

    public func restore(id: String, now: Date = .now) throws {
        try setDeleted(id: id, deleted: false, now: now)
    }

    public func trash() throws -> [Entry] {
        try db.reader.read { dbc in
            try Entry
                .filter(Column("is_deleted") == true)
                .order(Column("updated_at").desc)
                .fetchAll(dbc)
        }
    }

    /// Hard-deletes everything in the trash. Returns the media file paths the
    /// caller must remove from disk (repositories never touch the filesystem).
    @discardableResult
    public func emptyTrash() throws -> [String] {
        try db.writer.write { dbc in
            let trashedIds = try String.fetchAll(
                dbc, sql: "SELECT id FROM entries WHERE is_deleted = 1")
            guard !trashedIds.isEmpty else { return [] }
            let paths = try String.fetchAll(
                dbc,
                sql: """
                    SELECT file_path FROM media WHERE entry_id IN \
                    (SELECT id FROM entries WHERE is_deleted = 1)
                    UNION
                    SELECT thumbnail_path FROM media WHERE thumbnail_path IS NOT NULL \
                    AND entry_id IN (SELECT id FROM entries WHERE is_deleted = 1)
                    """)
            try Entry.filter(keys: trashedIds).deleteAll(dbc)
            return paths
        }
    }

    private func setDeleted(id: String, deleted: Bool, now: Date) throws {
        try db.writer.write { dbc in
            guard var entry = try Entry.fetchOne(dbc, key: id) else { return }
            entry.isDeleted = deleted
            entry.updatedAt = DBFormat.timestamp.string(from: now)
            try entry.update(dbc)
        }
    }

    // MARK: - Pipeline job visibility

    public func jobs(entryId: String) throws -> [PipelineJob] {
        try db.reader.read { dbc in
            try PipelineJob
                .filter(Column("entry_id") == entryId)
                .order(Column("stage"))
                .fetchAll(dbc)
        }
    }
}
