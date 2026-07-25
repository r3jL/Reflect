import Foundation
import ReflectCore
import XCTest

@testable import ReflectAI

final class JournalRetrieverTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!
    private var entries: EntriesRepository!
    private var embeddings: EmbeddingsRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-retriever-\(UUID().uuidString)")
        db = try AppDatabase(at: tempDir.appendingPathComponent("t.sqlite"))
        entries = EntriesRepository(db)
        embeddings = EmbeddingsRepository(db)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    /// Unit-ish vectors on distinct axes so L2 distances are controllable.
    private func vector(_ seed: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 1024)
        v[0] = seed
        v[1] = 1
        return v
    }

    @discardableResult
    private func entry(
        _ body: String, date: String, embeddedAt seed: Float? = nil,
        mood: String? = nil, summary: String? = nil
    ) throws -> Entry {
        let entry = try entries.createDraft(entryDate: date)
        try entries.updateBody(id: entry.id, title: nil, body: body)
        if let seed {
            try embeddings.replaceEmbeddings(
                entryId: entry.id, chunks: [vector(seed)], model: "bge-m3",
                modelVersion: "t")
        }
        if mood != nil || summary != nil {
            try MetadataRepository(db).replaceReflection(
                entryId: entry.id,
                MetadataRepository.Reflection(
                    summary: summary ?? "", moodLabel: mood ?? "calm",
                    moodConfidence: 0.8, sentimentScore: 0.2, energy: "medium",
                    reflectionNote: "n"),
                modelVersion: "t")
        }
        return try XCTUnwrap(entries.fetch(id: entry.id))
    }

    private func retriever(
        queryVector seed: Float?,
        config: JournalRetriever.Configuration = .init()
    ) -> JournalRetriever {
        let provider = VectorProvider(
            vector: seed.map { self.vector($0) })
        return JournalRetriever(
            db: db, provider: provider, embeddingModel: { "bge-m3" },
            configuration: config)
    }

    // MARK: - Merge, ranking, dedupe

    func testMergeRankingAndDualMatchBoost() async throws {
        // A: semantic-only, very close (d≈0.1)
        let a = try entry("The proofs arrived quietly.", date: "2026-07-01",
                          embeddedAt: 0.5)
        // B: keyword-only ("herons")
        let b = try entry("Two herons stood in the river.", date: "2026-07-02")
        // C: both — semantically middling (d≈0.3) + keyword match
        let c = try entry("A herons sketch pinned above the desk.",
                          date: "2026-07-03", embeddedAt: 0.9)

        let context = try await retriever(queryVector: 0.6)
            .retrieve(question: "herons")

        XCTAssertEqual(context.verdict, .relevant)
        XCTAssertEqual(
            context.items.map(\.entryId), [a.id, c.id, b.id],
            "close semantic, then boosted dual-match, then keyword-only")
        XCTAssertEqual(context.items.map(\.citation), [1, 2, 3], "stable ids")

        let cItem = context.items[1]
        XCTAssertTrue(cItem.matchedKeyword && cItem.matchedSemantic)
        XCTAssertEqual(context.items[0].matchedSemantic, true)
        XCTAssertEqual(context.items[0].matchedKeyword, false)
        XCTAssertEqual(context.items[2].matchedKeyword, true)

        // Dedupe: three entries, three items, no repeats.
        XCTAssertEqual(Set(context.items.map(\.entryId)).count, 3)
    }

    // MARK: - Relevance floor & verdict

    func testFarSemanticMatchesAreDroppedAndVerdictHonest() async throws {
        // Only vector is far beyond the 1.25 floor; no keyword overlap.
        try entry("Nothing about the topic at all.", date: "2026-07-01",
                  embeddedAt: 30.0)

        let context = try await retriever(queryVector: 0.1)
            .retrieve(question: "zeppelin maintenance")
        XCTAssertEqual(context.verdict, .nothingRelevant)
        XCTAssertTrue(context.items.isEmpty, "weak context is dropped, not padded")
    }

    func testKeywordMatchesSurviveWithoutEmbeddings() async throws {
        // Keyword evidence stands even when the entry was never embedded.
        let a = try entry("The lighthouse keeper waved back.", date: "2026-07-01")
        let context = try await retriever(queryVector: 0.1)
            .retrieve(question: "lighthouse")
        XCTAssertEqual(context.items.map(\.entryId), [a.id])
        XCTAssertEqual(context.verdict, .relevant)
    }

    func testEmbedFailureDegradesToKeywordOnly() async throws {
        let a = try entry("A quiet lighthouse morning.", date: "2026-07-01",
                          embeddedAt: 0.5)
        _ = a
        let provider = VectorProvider(vector: nil)  // embed throws
        let retriever = JournalRetriever(
            db: db, provider: provider, embeddingModel: { "bge-m3" })
        let context = try await retriever.retrieve(question: "lighthouse")
        XCTAssertEqual(context.items.count, 1)
        XCTAssertFalse(context.items[0].matchedSemantic)
        XCTAssertTrue(context.items[0].matchedKeyword)
    }

    // MARK: - Budget & truncation

    func testTokenBudgetTruncatesAndCloses() async throws {
        let longBody = String(
            repeating: "A long paragraph about the lighthouse and its keeper. ",
            count: 60)  // ~3300 chars
        try entry(longBody + " alpha", date: "2026-07-03", embeddedAt: 0.5)
        try entry(longBody + " beta", date: "2026-07-02", embeddedAt: 0.52)
        try entry(longBody + " gamma", date: "2026-07-01", embeddedAt: 0.54)

        var config = JournalRetriever.Configuration()
        config.tokenBudget = 500  // ≈2000 chars — room for ~1 capped entry
        config.maxCharsPerEntry = 1600
        let context = try await retriever(queryVector: 0.51, config: config)
            .retrieve(question: "lighthouse keeper")

        XCTAssertGreaterThanOrEqual(context.items.count, 1)
        XCTAssertLessThan(context.items.count, 3, "budget must close the pack")
        XCTAssertTrue(context.items[0].truncated)
        XCTAssertTrue(context.items[0].text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(context.items[0].text.count, 1601)
    }

    func testDeterministicAcrossRuns() async throws {
        for i in 0..<4 {
            try entry("The lighthouse log, page \(i).",
                      date: String(format: "2026-07-%02d", i + 1),
                      embeddedAt: 0.4 + Float(i) * 0.1)
        }
        let first = try await retriever(queryVector: 0.55).retrieve(question: "lighthouse")
        let second = try await retriever(queryVector: 0.55).retrieve(question: "lighthouse")
        XCTAssertEqual(first, second)
    }

    // MARK: - Tie-breaks

    func testEqualScoresBreakTowardRecency() async throws {
        let older = try entry("An identical thought.", date: "2026-06-01",
                              embeddedAt: 0.7)
        let newer = try entry("An identical thought again.", date: "2026-07-20",
                              embeddedAt: 0.7)
        let context = try await retriever(queryVector: 0.7)
            .retrieve(question: "unmatchedword")
        XCTAssertEqual(
            context.items.map(\.entryId), [newer.id, older.id],
            "same distance → newer first")
    }

    // MARK: - Prompt block

    func testPromptBlockCarriesCitationsMoodAndSummary() async throws {
        try entry(
            "We rearranged the reading corner until the light agreed.",
            date: "2026-07-20", embeddedAt: 0.5,
            mood: "calm", summary: "A slow, satisfied afternoon.")
        let context = try await retriever(queryVector: 0.5)
            .retrieve(question: "reading corner")
        let block = context.promptBlock()
        XCTAssertTrue(block.hasPrefix("[1] 2026-07-20 · felt calm"))
        XCTAssertTrue(block.contains("Summary: A slow, satisfied afternoon."))
        XCTAssertTrue(block.contains("reading corner until the light"))
    }

    func testTrashedEntriesNeverRetrieved() async throws {
        let a = try entry("The lighthouse secret.", date: "2026-07-01",
                          embeddedAt: 0.5)
        try entries.softDelete(id: a.id)
        let context = try await retriever(queryVector: 0.5)
            .retrieve(question: "lighthouse")
        XCTAssertEqual(context.verdict, .nothingRelevant)
    }
}

// MARK: - Provider double

/// Returns one fixed query vector (or throws when nil — the embed-failure
/// path).
private final class VectorProvider: AiProvider, @unchecked Sendable {
    private let vector: [Float]?

    init(vector: [Float]?) {
        self.vector = vector
    }

    func structuredChat<Out: Decodable & Sendable>(
        model: String, system: String, user: String, maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage) {
        throw AiError.notConfigured
    }

    func embed(model: String, texts: [String]) async throws -> ([[Float]], AiUsage) {
        guard let vector else { throw AiError.network("no embedding") }
        return (
            texts.map { _ in vector },
            AiUsage(promptTokens: 5, completionTokens: 0)
        )
    }
}
