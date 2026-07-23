import Foundation
import ReflectCore
import XCTest

@testable import ReflectAI

final class ExtractionStageTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!
    private var entries: EntriesRepository!
    private var metadata: MetadataRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-extract-\(UUID().uuidString)")
        db = try AppDatabase(at: tempDir.appendingPathComponent("t.sqlite"))
        entries = EntriesRepository(db)
        metadata = MetadataRepository(db)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(_ body: String, date: String = "2026-07-24") throws -> Entry {
        let entry = try entries.createDraft(entryDate: date)
        try entries.updateBody(id: entry.id, title: nil, body: body)
        return try XCTUnwrap(entries.fetch(id: entry.id))
    }

    private func stage(json: String) -> ExtractionStage {
        ExtractionStage(
            db: db,
            provider: CannedProvider(chatJSON: json),
            model: { "google/gemini-2.5-flash" })
    }

    private static let fullTranscript = """
        {
          "themes": ["The Studio", "beginnings "],
          "tags": ["Studio", "lease", "typeface"],
          "entities": [
            {"name": "Theo", "type": "person"},
            {"name": "Column", "type": "project"},
            {"name": "Lisbon", "type": "landmark"}
          ],
          "action_items": [
            {"text": "sign the lease papers", "due_hint": "tomorrow"},
            {"text": "order the studio chairs", "due_hint": null}
          ],
          "self_questions": ["Am I ready to run a place of my own?"]
        }
        """

    // MARK: - AC-021

    func testExtractionWritesAllRowFamilies() async throws {
        let entry = try entry("We signed for the studio today and Theo cried a little.")
        let outcome = try await stage(json: Self.fullTranscript).run(entry: entry)

        XCTAssertEqual(outcome.model, "google/gemini-2.5-flash")
        XCTAssertEqual(
            try metadata.themes(entryId: entry.id), ["beginnings", "the studio"],
            "themes canonicalized (trimmed, lowercased)")
        XCTAssertEqual(
            try metadata.tags(entryId: entry.id), ["lease", "studio", "typeface"])
        XCTAssertEqual(
            try metadata.entities(entryId: entry.id),
            [
                .init(name: "Lisbon", type: "other"),  // unknown type mapped
                .init(name: "Theo", type: "person"),
                .init(name: "Column", type: "project"),
            ])
        XCTAssertEqual(
            try metadata.actionItems(entryId: entry.id),
            [
                .init(text: "sign the lease papers", dueHint: "tomorrow"),
                .init(text: "order the studio chairs", dueHint: nil),
            ])
        XCTAssertEqual(
            try metadata.selfQuestions(entryId: entry.id),
            ["Am I ready to run a place of my own?"])
    }

    // MARK: - AC-005: supersede on re-run

    func testRerunReplacesPriorRows() async throws {
        let entry = try entry("A long day at the studio with the typeface.")
        _ = try await stage(json: Self.fullTranscript).run(entry: entry)

        let second = """
            {"themes": ["rest"], "tags": ["sunday"], "entities": [],
             "action_items": [], "self_questions": []}
            """
        _ = try await stage(json: second).run(entry: entry)

        XCTAssertEqual(try metadata.themes(entryId: entry.id), ["rest"])
        XCTAssertEqual(try metadata.tags(entryId: entry.id), ["sunday"])
        XCTAssertTrue(try metadata.entities(entryId: entry.id).isEmpty)
        XCTAssertTrue(try metadata.actionItems(entryId: entry.id).isEmpty)
        XCTAssertTrue(try metadata.selfQuestions(entryId: entry.id).isEmpty)
        // The canonical registry keeps old themes for other entries' use.
        XCTAssertEqual(try metadata.themeCount(), 3)
    }

    func testThemesAndEntitiesDedupeAcrossEntries() async throws {
        let first = try entry("Studio day one, full of beginnings.", date: "2026-07-20")
        let second = try entry("Studio day two with Theo.", date: "2026-07-21")
        _ = try await stage(json: Self.fullTranscript).run(entry: first)
        _ = try await stage(json: Self.fullTranscript).run(entry: second)

        XCTAssertEqual(try metadata.themeCount(), 2, "one row per canonical theme")
        XCTAssertEqual(try entityCount(), 3, "entities deduped on (name, type)")
    }

    private func entityCount() throws -> Int {
        try db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM entities") ?? 0
        }
    }

    // MARK: - Guards

    func testTooShortEntrySkips() async throws {
        let entry = try entry("Tired. Bed.")
        do {
            _ = try await stage(json: Self.fullTranscript).run(entry: entry)
            XCTFail("expected StageNotApplicable")
        } catch is StageNotApplicable {
            // expected
        }
    }

    func testProviderFailureWritesNothing() async throws {
        let entry = try entry("A perfectly extractable entry about the studio.")
        let failing = ExtractionStage(
            db: db,
            provider: CannedProvider(error: AiError.network("down")),
            model: { "m" })
        do {
            _ = try await failing.run(entry: entry)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(try metadata.themes(entryId: entry.id).isEmpty)
            XCTAssertTrue(try metadata.tags(entryId: entry.id).isEmpty, "FR-024: no partial writes")
        }
    }

    func testOnlyTitleAndBodyAreSent() async throws {
        let provider = CannedProvider(chatJSON: Self.fullTranscript)
        var made = try entry("The studio smells of cut wood and coffee today.")
        try entries.updateContext(
            id: made.id, place: "Secret Location", weather: "19°", isMilestone: true)
        made = try XCTUnwrap(entries.fetch(id: made.id))

        _ = try await ExtractionStage(db: db, provider: provider, model: { "m" })
            .run(entry: made)
        let sent = provider.lastUser.value ?? ""
        XCTAssertTrue(sent.contains("cut wood"))
        XCTAssertFalse(sent.contains("Secret Location"), "place never leaves the device")
        XCTAssertFalse(sent.contains("19°"), "weather never leaves the device")
    }
}

// MARK: - Canned provider

final class CannedProvider: AiProvider, @unchecked Sendable {
    let chatJSON: String?
    let error: Error?
    let usage: AiUsage
    let lastUser = Box<String>()

    init(
        chatJSON: String? = nil,
        error: Error? = nil,
        usage: AiUsage = AiUsage(promptTokens: 200, completionTokens: 80)
    ) {
        self.chatJSON = chatJSON
        self.error = error
        self.usage = usage
    }

    func structuredChat<Out: Decodable & Sendable>(
        model: String, system: String, user: String, maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage) {
        lastUser.value = user
        if let error { throw error }
        let decoded = try JSONDecoder().decode(
            Out.self, from: Data((chatJSON ?? "{}").utf8))
        return (decoded, usage)
    }

    func embed(model: String, texts: [String]) async throws -> ([[Float]], AiUsage) {
        if let error { throw error }
        return (texts.map { _ in [Float](repeating: 0.1, count: 1024) }, usage)
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
