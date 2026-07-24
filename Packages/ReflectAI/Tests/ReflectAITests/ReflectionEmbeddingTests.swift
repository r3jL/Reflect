import Foundation
import GRDB
import ReflectCore
import XCTest

@testable import ReflectAI

final class ReflectionEmbeddingTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!
    private var entries: EntriesRepository!
    private var metadata: MetadataRepository!
    private var embeddings: EmbeddingsRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-m13-\(UUID().uuidString)")
        db = try AppDatabase(at: tempDir.appendingPathComponent("t.sqlite"))
        entries = EntriesRepository(db)
        metadata = MetadataRepository(db)
        embeddings = EmbeddingsRepository(db)
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

    private static let reflectionTranscript = """
        {
          "summary": "The studio settled into being real today.",
          "mood": {"label": "Warm", "confidence": 0.85},
          "sentiment_score": 0.6,
          "energy": "medium",
          "reflection_note": "You wrote about the room the way people write about people they love."
        }
        """

    // MARK: - Reflection (AC-022)

    func testReflectionWritesValidatedRow() async throws {
        let entry = try entry("The studio is two days old and it already has a smell of its own.")
        try metadata.replaceExtraction(
            entryId: entry.id, themes: ["the studio"], tags: ["wood"],
            entities: [.init(name: "Theo", type: "person")],
            actionItems: [], selfQuestions: [])

        let provider = CannedProvider(chatJSON: Self.reflectionTranscript)
        let stage = ReflectionStage(
            db: db, provider: provider, model: { "anthropic/claude-sonnet-4.6" })
        let outcome = try await stage.run(entry: entry)

        XCTAssertEqual(outcome.model, "anthropic/claude-sonnet-4.6")
        let row = try XCTUnwrap(metadata.reflection(entryId: entry.id))
        XCTAssertEqual(row.moodLabel, "warm", "label normalized to lowercase")
        XCTAssertEqual(row.moodConfidence, 0.85)
        XCTAssertEqual(row.sentimentScore, 0.6)
        XCTAssertEqual(row.energy, "medium")
        XCTAssertTrue(row.reflectionNote.contains("about the room"))

        // FR-022: extraction context reaches the prompt.
        let sent = provider.lastUser.value ?? ""
        XCTAssertTrue(sent.contains("the studio"))
        XCTAssertTrue(sent.contains("Theo"))
    }

    func testReflectionRejectsOutOfContractValues() async throws {
        let cases: [(String, String)] = [
            ("bad mood", """
                {"summary":"s","mood":{"label":"euphoric","confidence":0.5},
                 "sentiment_score":0,"energy":"low","reflection_note":"n"}
                """),
            ("confidence range", """
                {"summary":"s","mood":{"label":"warm","confidence":1.4},
                 "sentiment_score":0,"energy":"low","reflection_note":"n"}
                """),
            ("sentiment range", """
                {"summary":"s","mood":{"label":"warm","confidence":0.4},
                 "sentiment_score":-3,"energy":"low","reflection_note":"n"}
                """),
            ("energy", """
                {"summary":"s","mood":{"label":"warm","confidence":0.4},
                 "sentiment_score":0,"energy":"frantic","reflection_note":"n"}
                """),
        ]
        for (name, json) in cases {
            let entry = try entry(
                "A body long enough to reflect on for case \(name).",
                date: "2026-0\(Int.random(in: 1...9))-1\(Int.random(in: 0...9))")
            let stage = ReflectionStage(
                db: db, provider: CannedProvider(chatJSON: json), model: { "m" })
            do {
                _ = try await stage.run(entry: entry)
                XCTFail("\(name): expected schema error")
            } catch let error as AiError {
                guard case .schema = error else {
                    return XCTFail("\(name): expected .schema, got \(error)")
                }
                XCTAssertNil(
                    try metadata.reflection(entryId: entry.id),
                    "\(name): no row on failure (AC-024)")
            }
        }
    }

    func testReflectionRerunReplacesRow() async throws {
        let entry = try entry("Another day in the studio, quieter than the last.")
        let first = ReflectionStage(
            db: db, provider: CannedProvider(chatJSON: Self.reflectionTranscript),
            model: { "m" })
        _ = try await first.run(entry: entry)

        let secondJSON = """
            {"summary":"A slower day.","mood":{"label":"quiet","confidence":0.7},
             "sentiment_score":-0.2,"energy":"low","reflection_note":"The pace dropped and you let it."}
            """
        let second = ReflectionStage(
            db: db, provider: CannedProvider(chatJSON: secondJSON), model: { "m" })
        _ = try await second.run(entry: entry)

        let row = try XCTUnwrap(metadata.reflection(entryId: entry.id))
        XCTAssertEqual(row.moodLabel, "quiet")
        XCTAssertEqual(row.summary, "A slower day.")
    }

    // MARK: - Embedding (AC-023, FR-030)

    func testEmbeddingWritesVersionedRows() async throws {
        let entry = try entry("A short entry about the river and the two herons.")
        let stage = EmbeddingStage(
            db: db, provider: CannedProvider(), model: { "baai/bge-m3" })
        let outcome = try await stage.run(entry: entry)

        XCTAssertEqual(outcome.model, "baai/bge-m3")
        XCTAssertEqual(try embeddings.chunkCount(entryId: entry.id), 1)
        let meta = try db.reader.read { dbc in
            try Row.fetchOne(
                dbc,
                sql: "SELECT model, model_version, dim, status FROM embeddings_meta WHERE entry_id = ?",
                arguments: [entry.id])
        }
        XCTAssertEqual(meta?["model"], "bge-m3")
        XCTAssertEqual(meta?["model_version"], "baai/bge-m3")
        XCTAssertEqual(meta?["dim"], 1024)
        XCTAssertEqual(meta?["status"], "current")
        XCTAssertNotNil(try embeddings.firstChunkVector(entryId: entry.id))
    }

    func testLongEntryChunksAndAllChunksLand() async throws {
        let paragraph = String(repeating: "A sentence that repeats itself gently. ", count: 40)
        let body = Array(repeating: paragraph, count: 4).joined(separator: "\n\n")
        let entry = try entry(body)
        XCTAssertGreaterThan(EmbeddingStage.chunk(body).count, 1)

        let stage = EmbeddingStage(db: db, provider: CannedProvider(), model: { "m" })
        _ = try await stage.run(entry: entry)
        XCTAssertEqual(
            try embeddings.chunkCount(entryId: entry.id),
            EmbeddingStage.chunk(body).count)
    }

    func testWrongDimensionFailsWithoutWrites() async throws {
        let entry = try entry("Dimensions matter a great deal to vec0 tables.")
        let provider = CannedProvider()
        provider.embedDim = 512
        let stage = EmbeddingStage(db: db, provider: provider, model: { "m" })
        do {
            _ = try await stage.run(entry: entry)
            XCTFail("expected schema error")
        } catch let error as AiError {
            guard case .schema = error else { return XCTFail("\(error)") }
            XCTAssertEqual(try embeddings.chunkCount(entryId: entry.id), 0)
        }
    }

    func testNearestEntriesExcludesSelfAndDedupes() async throws {
        func vector(_ seed: Float) -> [Float] {
            var v = [Float](repeating: 0, count: 1024)
            v[0] = seed
            v[1] = 1
            return v
        }
        let a = try entry("entry a", date: "2026-07-01")
        let b = try entry("entry b", date: "2026-07-02")
        let c = try entry("entry c", date: "2026-07-03")
        try embeddings.replaceEmbeddings(
            entryId: a.id, chunks: [vector(0.1), vector(0.12)], model: "bge-m3",
            modelVersion: "t")
        try embeddings.replaceEmbeddings(
            entryId: b.id, chunks: [vector(0.2)], model: "bge-m3", modelVersion: "t")
        try embeddings.replaceEmbeddings(
            entryId: c.id, chunks: [vector(0.9)], model: "bge-m3", modelVersion: "t")

        let neighbors = try embeddings.nearestEntries(
            to: vector(0.11), k: 2, excluding: [a.id])
        XCTAssertEqual(neighbors.map(\.entryId), [b.id, c.id])
    }

    // MARK: - Full pipeline integration

    func testFullPipelineEnrichesEntryEndToEnd() async throws {
        let entry = try entry("The market, the hill, and the small green door again.")
        let provider = FullCannedProvider()
        var config = PipelineOrchestrator.Configuration()
        config.baseBackoff = .milliseconds(10)
        let orchestrator = PipelineOrchestrator(
            db: db,
            runners: [
                .extraction: ExtractionStage(db: db, provider: provider, model: { "gx" }),
                .reflection: ReflectionStage(db: db, provider: provider, model: { "rx" }),
                .embedding: EmbeddingStage(db: db, provider: provider, model: { "ex" }),
            ],
            isEnabled: { true },
            configuration: config)
        try entries.complete(id: entry.id)
        orchestrator.kick()

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let statuses = try entries.jobs(entryId: entry.id).map(\.status)
            if statuses.count == 3, statuses.allSatisfy({ $0 == .success }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(try metadata.themes(entryId: entry.id), ["wandering"])
        XCTAssertEqual(
            try metadata.reflection(entryId: entry.id)?.moodLabel, "bright")
        XCTAssertEqual(try embeddings.chunkCount(entryId: entry.id), 1)
        XCTAssertEqual(try UsageRepository(db).monthTotal(
            String(DBFormat.entryDate(.now).prefix(7))).calls, 3)
    }
}

/// Routes structured-chat calls by output type — extraction and reflection
/// answered from one provider, like the real adapter.
private final class FullCannedProvider: AiProvider, @unchecked Sendable {
    func structuredChat<Out: Decodable & Sendable>(
        model: String, system: String, user: String, maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage) {
        let json: String
        if Out.self == ExtractionOutput.self {
            json = """
                {"themes":["wandering"],"tags":["market"],"entities":[],
                 "action_items":[],"self_questions":[]}
                """
        } else {
            json = """
                {"summary":"A wandering day.","mood":{"label":"bright","confidence":0.8},
                 "sentiment_score":0.7,"energy":"high","reflection_note":"The door keeps calling you back."}
                """
        }
        let decoded = try JSONDecoder().decode(Out.self, from: Data(json.utf8))
        return (decoded, AiUsage(promptTokens: 50, completionTokens: 20))
    }

    func embed(model: String, texts: [String]) async throws -> ([[Float]], AiUsage) {
        (texts.map { _ in [Float](repeating: 0.5, count: 1024) },
         AiUsage(promptTokens: 30, completionTokens: 0))
    }
}
