import Foundation
import ReflectCore
import XCTest

@testable import ReflectAI

final class AskServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!
    private var entries: EntriesRepository!
    private var embeddings: EmbeddingsRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-ask-\(UUID().uuidString)")
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

    private func service(_ provider: any AiProvider) -> AskService {
        AskService(
            db: db, provider: provider,
            chatModel: { "chat-model" }, embeddingModel: { "bge-m3" })
    }

    // MARK: - Grounding

    func testContextReachesPromptVerbatimAndCitationsResolve() async throws {
        let entry = try embeddedEntry(
            "I finished the cartographer book on the ferry today.",
            date: "2026-07-08", seed: 0.5)
        let provider = AskProvider(
            queryVector: vector(0.5),
            answerJSON: """
                {"answer": "You finished it on the ferry, in early July.",
                 "citations": [1]}
                """)

        let exchange = try await service(provider).ask(
            question: "When did I finish the cartographer book?")

        let prompt = try XCTUnwrap(provider.lastUser.value)
        XCTAssertTrue(prompt.contains("[1] 2026-07-08"), "pack reaches the prompt")
        XCTAssertTrue(prompt.contains("cartographer book on the ferry"))
        XCTAssertTrue(prompt.contains("Question: When did I finish"))
        XCTAssertTrue(prompt.contains("your only sources"))

        XCTAssertFalse(exchange.declined)
        XCTAssertEqual(exchange.cited.map(\.entryId), [entry.id])
        XCTAssertEqual(exchange.answer, "You finished it on the ferry, in early July.")
    }

    func testEmptyPackDeclinesWithoutModelCall() async throws {
        // Journal has nothing related — and the provider proves no chat
        // call is ever made.
        let provider = AskProvider(queryVector: vector(0.5), answerJSON: "{}")
        let exchange = try await service(provider).ask(
            question: "What do I think about zeppelins?")

        XCTAssertTrue(exchange.declined)
        XCTAssertEqual(exchange.answer, AskService.declineAnswer)
        XCTAssertTrue(exchange.cited.isEmpty)
        XCTAssertEqual(provider.chatCalls.value, 0, "no spend, no invention risk")
    }

    func testInvalidCitationIdsAreFiltered() async throws {
        try embeddedEntry("The reading corner note.", date: "2026-07-20", seed: 0.5)
        let provider = AskProvider(
            queryVector: vector(0.5),
            answerJSON: """
                {"answer": "From your July note.", "citations": [1, 7, 12]}
                """)
        let exchange = try await service(provider).ask(question: "reading corner?")
        XCTAssertEqual(exchange.cited.map(\.citation), [1], "phantom ids dropped")
        XCTAssertFalse(exchange.declined)
    }

    func testThreadContextIncludedInFollowUps() async throws {
        try embeddedEntry("Notes about the studio lease.", date: "2026-07-15", seed: 0.5)
        let provider = AskProvider(
            queryVector: vector(0.5),
            answerJSON: "{\"answer\": \"More on that.\", \"citations\": [1]}")
        let prior = AskExchange(
            question: "When did I sign the lease?",
            answer: "In mid-July, you wrote about signing.",
            cited: [], declined: false)

        _ = try await service(provider).ask(
            question: "How did I feel about it?", thread: [prior])
        let prompt = try XCTUnwrap(provider.lastUser.value)
        XCTAssertTrue(prompt.contains("Earlier in this conversation:"))
        XCTAssertTrue(prompt.contains("Q: When did I sign the lease?"))
        XCTAssertTrue(prompt.contains("A: In mid-July, you wrote about signing."))
    }

    func testModelDeclineWithEmptyCitationsMarksDeclined() async throws {
        try embeddedEntry("Something adjacent but not the answer.",
                          date: "2026-07-10", seed: 0.5)
        let provider = AskProvider(
            queryVector: vector(0.5),
            answerJSON: """
                {"answer": "Your journal doesn't seem to hold this yet.",
                 "citations": []}
                """)
        let exchange = try await service(provider).ask(question: "something else?")
        XCTAssertTrue(exchange.declined)
        XCTAssertTrue(exchange.cited.isEmpty)
    }

    func testProviderFailurePropagates() async throws {
        try embeddedEntry("A relevant entry.", date: "2026-07-10", seed: 0.5)
        let provider = AskProvider(
            queryVector: vector(0.5), answerJSON: "{}",
            chatError: AiError.network("down"))
        do {
            _ = try await service(provider).ask(question: "relevant?")
            XCTFail("expected error")
        } catch let error as AiError {
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testSuccessRecordsChatLedger() async throws {
        try embeddedEntry("Ledger fodder entry.", date: "2026-07-10", seed: 0.5)
        let provider = AskProvider(
            queryVector: vector(0.5),
            answerJSON: "{\"answer\": \"Noted.\", \"citations\": [1]}")
        _ = try await service(provider).ask(question: "ledger fodder?")

        let month = String(DBFormat.entryDate(.now).prefix(7))
        let total = try UsageRepository(db).monthTotal(month)
        XCTAssertEqual(total.calls, 1)
        XCTAssertEqual(try fetchLedgerStage(), "chat")
    }

    private func fetchLedgerStage() throws -> String? {
        try db.reader.read {
            try String.fetchOne($0, sql: "SELECT stage FROM ai_usage LIMIT 1")
        }
    }
}

// MARK: - Provider double

private final class AskProvider: AiProvider, @unchecked Sendable {
    private let queryVector: [Float]
    private let answerJSON: String
    private let chatError: Error?
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
        lastUser.value = user
        if let chatError { throw chatError }
        return (
            try JSONDecoder().decode(Out.self, from: Data(answerJSON.utf8)),
            AiUsage(promptTokens: 800, completionTokens: 90)
        )
    }

    func embed(model: String, texts: [String]) async throws -> ([[Float]], AiUsage) {
        (texts.map { _ in queryVector }, AiUsage(promptTokens: 6, completionTokens: 0))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
