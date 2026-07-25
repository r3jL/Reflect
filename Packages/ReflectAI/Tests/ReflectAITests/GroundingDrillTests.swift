// M20 grounding drill: the chat contract's defenses, adversarially.
// Layer 1 (deterministic decline) and the citation filter are covered in
// AskServiceTests; here we prove the contract itself reaches the model,
// weak context stays declinable, and failures leave no state behind.
import Foundation
import ReflectCore
import XCTest

@testable import ReflectAI

final class GroundingDrillTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!
    private var entries: EntriesRepository!
    private var embeddings: EmbeddingsRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-grounding-\(UUID().uuidString)")
        db = try AppDatabase(at: tempDir.appendingPathComponent("t.sqlite"))
        entries = EntriesRepository(db)
        embeddings = EmbeddingsRepository(db)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func vector(_ seed: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 1024)
        v[0] = seed
        v[1] = 1
        return v
    }

    @discardableResult
    private func embeddedEntry(_ body: String, date: String, seed: Float) throws -> Entry {
        let entry = try entries.createDraft(entryDate: date)
        try entries.updateBody(id: entry.id, title: nil, body: body)
        try embeddings.replaceEmbeddings(
            entryId: entry.id, chunks: [vector(seed)], model: "bge-m3",
            modelVersion: "t")
        return try XCTUnwrap(entries.fetch(id: entry.id))
    }

    /// The grounding rules must reach the model on every call — the
    /// system prompt is the layer-2 defense, so its load-bearing clauses
    /// are asserted, not assumed.
    func testGroundingContractReachesTheModel() async throws {
        try embeddedEntry("A day with the word capital in it, oddly.",
                          date: "2026-07-01", seed: 0.5)
        let provider = ContractCapturingProvider(
            queryVector: vector(0.5),
            answerJSON: "{\"answer\": \"ok\", \"citations\": [1]}")
        let service = AskService(
            db: db, provider: provider,
            chatModel: { "m" }, embeddingModel: { "bge-m3" })
        _ = try await service.ask(question: "capital?")

        let system = try XCTUnwrap(provider.lastSystem.value)
        for clause in [
            "ONLY", "numbered journal entries",
            "NEVER use outside knowledge",
            "never invent",
            "doesn't seem to hold this",
            "empty citations list",
        ] {
            XCTAssertTrue(system.contains(clause), "missing contract clause: \(clause)")
        }
    }

    /// Weak-but-nonzero context (a stray keyword hit) goes to the model —
    /// and a model that follows the contract and declines is honored as a
    /// decline, not dressed up as an answer.
    func testWeakContextDeclineIsHonored() async throws {
        try embeddedEntry("The word france appears once, about a font.",
                          date: "2026-07-02", seed: 0.5)
        let provider = ContractCapturingProvider(
            queryVector: vector(30.0),  // semantically unrelated
            answerJSON: """
                {"answer": "Your journal doesn't seem to hold this yet — \
                france appears only as a typeface note.", "citations": []}
                """)
        let service = AskService(
            db: db, provider: provider,
            chatModel: { "m" }, embeddingModel: { "bge-m3" })
        let exchange = try await service.ask(question: "france?")

        XCTAssertEqual(provider.chatCalls.value, 1, "keyword hit reaches layer 2")
        XCTAssertTrue(exchange.declined)
        XCTAssertTrue(exchange.cited.isEmpty)
    }

    /// A failure mid-conversation must leave nothing behind: the service
    /// is stateless, the same thread retries cleanly, and no ledger row
    /// is written for the failed call.
    func testMidThreadFailureLeavesNoState() async throws {
        try embeddedEntry("Notes about the exhibition space.",
                          date: "2026-07-03", seed: 0.5)
        let prior = AskExchange(
            question: "What about the space?", answer: "You visited Thursday.",
            cited: [], declined: false)

        let failing = ContractCapturingProvider(
            queryVector: vector(0.5), answerJSON: "{}",
            chatError: AiError.network("mid-thread drop"))
        let service = AskService(
            db: db, provider: failing,
            chatModel: { "m" }, embeddingModel: { "bge-m3" })
        do {
            _ = try await service.ask(question: "and after?", thread: [prior])
            XCTFail("expected failure")
        } catch {}

        let month = String(DBFormat.entryDate(.now).prefix(7))
        XCTAssertEqual(
            try UsageRepository(db).monthTotal(month).calls, 0,
            "failed calls never reach the ledger")

        // Same thread, healthy provider: the retry succeeds untouched.
        let healthy = ContractCapturingProvider(
            queryVector: vector(0.5),
            answerJSON: "{\"answer\": \"After, you signed.\", \"citations\": [1]}")
        let retryService = AskService(
            db: db, provider: healthy,
            chatModel: { "m" }, embeddingModel: { "bge-m3" })
        let exchange = try await retryService.ask(
            question: "and after?", thread: [prior])
        XCTAssertFalse(exchange.declined)
        let prompt = try XCTUnwrap(healthy.lastUser.value)
        XCTAssertTrue(prompt.contains("Q: What about the space?"), "thread intact")
    }
}

// MARK: - Provider double (captures system + user)

private final class ContractCapturingProvider: AiProvider, @unchecked Sendable {
    private let queryVector: [Float]
    private let answerJSON: String
    private let chatError: Error?
    let lastSystem = Box<String>()
    let lastUser = Box<String>()
    let chatCalls = Counter()

    init(queryVector: [Float], answerJSON: String, chatError: Error? = nil) {
        self.queryVector = queryVector
        self.answerJSON = answerJSON
        self.chatError = chatError
    }

    func structuredChat<Out: Decodable & Sendable>(
        model: String, system: String, user: String, maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage) {
        chatCalls.increment()
        lastSystem.value = system
        lastUser.value = user
        if let chatError { throw chatError }
        return (
            try JSONDecoder().decode(Out.self, from: Data(answerJSON.utf8)),
            AiUsage(promptTokens: 500, completionTokens: 60)
        )
    }

    func embed(model: String, texts: [String]) async throws -> ([[Float]], AiUsage) {
        (texts.map { _ in queryVector }, AiUsage(promptTokens: 4, completionTokens: 0))
    }
}
