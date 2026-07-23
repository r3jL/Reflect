import GRDB
import XCTest

@testable import ReflectCore

final class ReflectCoreTests: XCTestCase {
    private var db: AppDatabase!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-tests-\(UUID().uuidString)")
        db = try AppDatabase(
            at: tempDir.appendingPathComponent("test.sqlite"))
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Schema

    func testMigrationCreatesFullSchema() throws {
        let tables = try db.reader.read { dbc in
            try String.fetchAll(
                dbc, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
        }
        for expected in [
            "entries", "media", "settings", "pipeline_jobs", "entry_reflection",
            "themes", "entry_themes", "entry_tags", "entities", "entry_entities",
            "action_items", "self_questions", "embeddings_meta", "vec_entries",
        ] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
        // WAL + vec + FK all active
        let (journalMode, vecVersion, fk) = try db.reader.read { dbc in
            (
                try String.fetchOne(dbc, sql: "PRAGMA journal_mode") ?? "?",
                try String.fetchOne(dbc, sql: "SELECT vec_version()") ?? "?",
                try Bool.fetchOne(dbc, sql: "PRAGMA foreign_keys") ?? false
            )
        }
        XCTAssertEqual(journalMode.lowercased(), "wal")
        XCTAssertTrue(vecVersion.hasPrefix("v"))
        XCTAssertTrue(fk)
    }

    // MARK: - Entry lifecycle (AC-001, AC-002, AC-003)

    func testDraftLifecycleAndCompletionEnqueuesJobs() throws {
        let repo = EntriesRepository(db)

        let draft = try repo.createDraft(entryDate: "2026-07-22")
        XCTAssertEqual(draft.status, .draft)
        XCTAssertEqual(draft.wordCount, 0)

        try repo.updateBody(
            id: draft.id, title: nil,
            body: "The studio is two days old and already it has a smell.")
        var fetched = try XCTUnwrap(try repo.fetch(id: draft.id))
        XCTAssertEqual(fetched.wordCount, 12)
        XCTAssertEqual(fetched.status, .draft)
        XCTAssertTrue(try repo.jobs(entryId: draft.id).isEmpty, "drafts must not enqueue")

        try repo.complete(id: draft.id)
        fetched = try XCTUnwrap(try repo.fetch(id: draft.id))
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertNotNil(fetched.completedAt)

        let jobs = try repo.jobs(entryId: draft.id)
        XCTAssertEqual(jobs.count, 3)
        XCTAssertEqual(Set(jobs.map(\.stage)), Set(PipelineJob.Stage.allCases))
        XCTAssertTrue(jobs.allSatisfy { $0.status == .pending })
    }

    /// FR-004 / AC-005: editing a completed entry re-enqueues the pipeline.
    func testEditingCompletedEntryReenqueues() throws {
        let repo = EntriesRepository(db)
        let entry = try repo.createDraft(entryDate: "2026-07-22")
        try repo.complete(id: entry.id)

        // Simulate a finished pipeline run.
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE pipeline_jobs SET status = 'success', attempts = 2")
        }

        try repo.updateBody(id: entry.id, title: nil, body: "revised text")
        let jobs = try repo.jobs(entryId: entry.id)
        XCTAssertTrue(jobs.allSatisfy { $0.status == .pending && $0.attempts == 0 })
    }

    // MARK: - FTS (FR-011, AC-009)

    func testFTSTriggersKeepIndexInSync() throws {
        let repo = EntriesRepository(db)
        let entry = try repo.createDraft(entryDate: "2026-07-22")
        try repo.updateBody(
            id: entry.id, title: "First evening",
            body: "We landed in Lisbon and the light did the thing.")

        XCTAssertEqual(try repo.searchKeyword("lisbon").count, 1)
        XCTAssertEqual(try repo.searchKeyword("lisb").count, 1, "prefix match")
        XCTAssertTrue(try repo.searchKeyword("kyoto").isEmpty)

        // Update replaces the indexed text.
        try repo.updateBody(id: entry.id, title: "First evening", body: "Kyoto instead.")
        XCTAssertTrue(try repo.searchKeyword("lisbon").isEmpty)
        XCTAssertEqual(try repo.searchKeyword("kyoto").count, 1)

        // Snippet comes back usable.
        let hit = try XCTUnwrap(try repo.searchKeyword("kyoto").first)
        XCTAssertTrue(hit.snippet.contains("Kyoto"))
    }

    func testSearchExcludesTrashedEntries() throws {
        let repo = EntriesRepository(db)
        let entry = try repo.createDraft(entryDate: "2026-07-22")
        try repo.updateBody(id: entry.id, title: nil, body: "a very findable phrase")
        try repo.softDelete(id: entry.id)
        XCTAssertTrue(try repo.searchKeyword("findable").isEmpty)
        try repo.restore(id: entry.id)
        XCTAssertEqual(try repo.searchKeyword("findable").count, 1)
    }

    // MARK: - Trash (FR-010, AC-008)

    func testTrashLifecycleWithMediaCleanupPaths() throws {
        let entries = EntriesRepository(db)
        let media = MediaRepository(db)

        let entry = try entries.createDraft(entryDate: "2026-07-22")
        try media.insert(
            entryId: entry.id, filePath: "media/photo1.jpg",
            thumbnailPath: "thumbs/photo1.jpg", mediaType: .photo,
            mimeType: "image/jpeg", fileSizeBytes: 1234)

        try entries.softDelete(id: entry.id)
        XCTAssertNil(try entries.fetchForDate("2026-07-22"), "trashed entries leave the timeline")
        XCTAssertEqual(try entries.trash().count, 1)

        let paths = try entries.emptyTrash()
        XCTAssertEqual(Set(paths), ["media/photo1.jpg", "thumbs/photo1.jpg"])
        XCTAssertNil(try entries.fetch(id: entry.id))
        XCTAssertTrue(try media.forEntry(entry.id).isEmpty, "cascade removed media rows")
    }

    // MARK: - Month fetch (Life view)

    func testMonthFetch() throws {
        let repo = EntriesRepository(db)
        try repo.createDraft(entryDate: "2026-07-01")
        try repo.createDraft(entryDate: "2026-07-31")
        try repo.createDraft(entryDate: "2026-08-01")
        XCTAssertEqual(try repo.month("2026-07").count, 2)
    }

    // MARK: - Settings

    func testSettingsUpsert() throws {
        let settings = SettingsRepository(db)
        XCTAssertNil(try settings.get(.aiEnabled))
        try settings.setBool(.aiEnabled, true)
        XCTAssertTrue(try settings.getBool(.aiEnabled))
        try settings.setBool(.aiEnabled, false)
        XCTAssertFalse(try settings.getBool(.aiEnabled))
    }

    // MARK: - Vectors (§4.3)

    func testVecRoundTripWithMeta() throws {
        let entry = try EntriesRepository(db).createDraft(entryDate: "2026-07-22")
        let vector: [Float] = (0..<1024).map { _ in Float.random(in: -1...1) }
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }

        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    INSERT INTO embeddings_meta
                        (entry_id, chunk_index, model, model_version, dim, embedded_at)
                    VALUES (?, 0, 'bge-m3', 'test', 1024, ?)
                    """,
                arguments: [entry.id, DBFormat.timestamp.string(from: .now)])
            let metaId = dbc.lastInsertedRowID
            try dbc.execute(
                sql: "INSERT INTO vec_entries(rowid, embedding) VALUES (?, ?)",
                arguments: [metaId, blob])
        }

        let nearest = try db.reader.read { dbc in
            try Row.fetchOne(
                dbc,
                sql: """
                    SELECT m.entry_id, v.distance
                    FROM vec_entries v
                    JOIN embeddings_meta m ON m.id = v.rowid
                    WHERE v.embedding MATCH ? AND k = 1
                    """,
                arguments: [blob])
        }
        XCTAssertEqual(nearest?["entry_id"], entry.id)
        XCTAssertEqual(nearest?["distance"] ?? 1.0, 0.0, accuracy: 1e-5)
    }

    // MARK: - Today helpers (M3)

    func testFetchOrCreateForDateIsIdempotent() throws {
        let repo = EntriesRepository(db)
        let first = try repo.fetchOrCreateForDate("2026-07-23")
        let second = try repo.fetchOrCreateForDate("2026-07-23")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.status, .draft)
    }

    func testStreakAndOnThisDaySources() throws {
        let repo = EntriesRepository(db)
        for date in ["2026-07-23", "2026-07-22", "2026-07-20", "2025-07-23"] {
            try repo.createDraft(entryDate: date)
        }
        XCTAssertEqual(
            try repo.distinctEntryDates(),
            ["2026-07-23", "2026-07-22", "2026-07-20", "2025-07-23"])
        XCTAssertEqual(
            try repo.onThisDayCount(monthDay: "07-23", excludingDate: "2026-07-23"), 1)
    }

    // MARK: - Life map sources (M4)

    func testMoodLabelsAndMediaPresence() throws {
        let entries = EntriesRepository(db)
        let media = MediaRepository(db)
        let a = try entries.createDraft(entryDate: "2026-07-01")
        let b = try entries.createDraft(entryDate: "2026-07-02")

        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    INSERT INTO entry_reflection (entry_id, mood_label, created_at)
                    VALUES (?, 'warm', ?)
                    """,
                arguments: [a.id, DBFormat.timestamp.string(from: .now)])
        }
        try media.insert(
            entryId: b.id, filePath: "media/x.jpg", thumbnailPath: nil,
            mediaType: .photo, mimeType: "image/jpeg", fileSizeBytes: 1)

        let moods = try entries.moodLabels(entryIds: [a.id, b.id])
        XCTAssertEqual(moods, [a.id: "warm"])
        XCTAssertEqual(try entries.entryIdsWithMedia([a.id, b.id]), [b.id])
        XCTAssertEqual(try entries.moodLabels(entryIds: []), [:])
    }

    // MARK: - Remember (M6)

    func testRecentPlaces() throws {
        let repo = EntriesRepository(db)
        let a = try repo.createDraft(entryDate: "2026-07-20")
        let b = try repo.createDraft(entryDate: "2026-07-21")
        try repo.updateContext(id: a.id, place: "Lisbon", weather: nil, isMilestone: false)
        try repo.updateContext(id: b.id, place: "The studio", weather: nil, isMilestone: false)
        XCTAssertEqual(try repo.recentPlaces(), ["The studio", "Lisbon"])
    }

    /// AC-009 / KPI-05: keyword search over a 1k-entry journal in <150ms.
    func testKeywordSearchAt1kEntriesWithinBudget() throws {
        let repo = EntriesRepository(db)
        let filler = [
            "Slow morning, the kind that forgives you for it.",
            "Worked on the typeface until the names blurred.",
            "A walk by the river; two herons, one idea.",
            "Read in the studio until the light moved on.",
        ]
        try db.writer.write { dbc in
            let stamp = DBFormat.timestamp.string(from: .now)
            for i in 0..<1000 {
                let day = String(
                    format: "%04d-%02d-%02d", 2020 + i / 365, 1 + (i / 28) % 12, 1 + i % 28)
                let body = i % 97 == 0
                    ? "We landed in Lisbon and the light did the thing. (\(i))"
                    : "\(filler[i % filler.count]) (\(i))"
                try dbc.execute(
                    sql: """
                        INSERT INTO entries (id, body, entry_date, status, word_count,
                                             created_at, updated_at)
                        VALUES (?, ?, ?, 'completed', 10, ?, ?)
                        """,
                    arguments: [UUID().uuidString, body, day, stamp, stamp])
            }
        }

        let t0 = ContinuousClock.now
        let hits = try repo.searchKeyword("lisbon")
        let elapsed = ContinuousClock.now - t0
        XCTAssertEqual(hits.count, 11)  // ceil(1000/97)
        XCTAssertLessThan(elapsed, .milliseconds(150), "KPI-05 budget")
    }

    // MARK: - AI usage ledger (M10, migration v2)

    func testUsageLedgerMonthTotals() throws {
        let usage = UsageRepository(db)
        let july = DateComponents(
            calendar: .current, year: 2026, month: 7, day: 10, hour: 12
        ).date!
        try usage.record(
            entryId: nil, stage: "extraction", model: "google/gemini-2.5-flash",
            promptTokens: 900, completionTokens: 300, costEstimate: 0.001, now: july)
        try usage.record(
            entryId: nil, stage: "reflection", model: "anthropic/claude-sonnet-4.6",
            promptTokens: 1200, completionTokens: 400, costEstimate: 0.0096, now: july)
        try usage.record(
            entryId: nil, stage: "embedding", model: "unpriced/model",
            promptTokens: 500, completionTokens: 0, costEstimate: nil, now: july)

        let total = try usage.monthTotal("2026-07")
        XCTAssertEqual(total.calls, 3)
        XCTAssertEqual(total.promptTokens, 2600)
        XCTAssertEqual(total.completionTokens, 700)
        XCTAssertEqual(try XCTUnwrap(total.costEstimate), 0.0106, accuracy: 1e-6)

        let empty = try usage.monthTotal("2026-06")
        XCTAssertEqual(empty.calls, 0)
        XCTAssertNil(empty.costEstimate)
    }

    // MARK: - Formats

    func testEntryDateFormatting() {
        let date = DateComponents(
            calendar: .current, year: 2026, month: 7, day: 5
        ).date!
        XCTAssertEqual(DBFormat.entryDate(date), "2026-07-05")
    }
}
