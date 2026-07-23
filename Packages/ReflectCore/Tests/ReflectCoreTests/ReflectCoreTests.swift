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

    // MARK: - Formats

    func testEntryDateFormatting() {
        let date = DateComponents(
            calendar: .current, year: 2026, month: 7, day: 5
        ).date!
        XCTAssertEqual(DBFormat.entryDate(date), "2026-07-05")
    }
}
