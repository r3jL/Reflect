// M16 failure drill: the full orchestrator with the REAL stages, a
// scripted provider injecting each failure mode from the M16 plan.
// Every path must end in null + warning (AC-024) — never fabricated rows,
// never a wedged queue.
import Foundation
import ReflectCore
import XCTest

@testable import ReflectAI

final class FailureDrillTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!
    private var entries: EntriesRepository!
    private var metadata: MetadataRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-drill-\(UUID().uuidString)")
        db = try AppDatabase(at: tempDir.appendingPathComponent("t.sqlite"))
        entries = EntriesRepository(db)
        metadata = MetadataRepository(db)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Harness

    private func completedEntry() throws -> Entry {
        let entry = try entries.createDraft(entryDate: "2026-07-25")
        try entries.updateBody(
            id: entry.id, title: nil,
            body: "A real entry with enough words for every stage to want it.")
        try entries.complete(id: entry.id)
        return entry
    }

    private func orchestrator(_ provider: any AiProvider) -> PipelineOrchestrator {
        var config = PipelineOrchestrator.Configuration()
        config.baseBackoff = .milliseconds(15)
        return PipelineOrchestrator(
            db: db,
            runners: [
                .extraction: ExtractionStage(db: db, provider: provider, model: { "gx" }),
                .reflection: ReflectionStage(db: db, provider: provider, model: { "rx" }),
                .embedding: EmbeddingStage(db: db, provider: provider, model: { "ex" }),
            ],
            isEnabled: { true },
            configuration: config)
    }

    private func statuses(_ entryId: String) throws -> [PipelineJob.Stage: PipelineJob] {
        Dictionary(
            uniqueKeysWithValues: try entries.jobs(entryId: entryId)
                .map { ($0.stage, $0) })
    }

    private func waitUntil(
        timeout: Duration = .seconds(6), _ condition: () throws -> Bool
    ) async rethrows {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out")
    }

    private func assertNoExtractionRows(_ entryId: String) throws {
        XCTAssertTrue(try metadata.themes(entryId: entryId).isEmpty)
        XCTAssertTrue(try metadata.tags(entryId: entryId).isEmpty)
        XCTAssertTrue(try metadata.entities(entryId: entryId).isEmpty)
    }

    // MARK: - Drills

    /// Auth revoked: extraction fails terminally on attempt 1, reflection
    /// cascades to skipped, embedding is independent... and also auth-fails.
    /// Result: warnings, zero derived rows, zero ledger entries.
    func testAuthRevoked() async throws {
        let entry = try completedEntry()
        let provider = DrillProvider(
            chat: [.fail(AiError.auth)], embed: .fail(AiError.auth))
        orchestrator(provider).kick()

        try await waitUntil {
            let s = try self.statuses(entry.id)
            return s[.extraction]?.status == .failed
                && s[.reflection]?.status == .skipped
                && s[.embedding]?.status == .failed
        }
        let s = try statuses(entry.id)
        XCTAssertEqual(s[.extraction]?.attempts, 1, "terminal: no retries")
        XCTAssertEqual(s[.extraction]?.lastError, "API key rejected")
        try assertNoExtractionRows(entry.id)
        XCTAssertNil(try metadata.reflection(entryId: entry.id))
        XCTAssertEqual(
            try EmbeddingsRepository(db).chunkCount(entryId: entry.id), 0)
        let month = String(DBFormat.entryDate(.now).prefix(7))
        XCTAssertEqual(try UsageRepository(db).monthTotal(month).calls, 0)
    }

    /// Malformed model output (post-retry schema failure): terminal, no
    /// partial writes, embedding unaffected.
    func testMalformedOutput() async throws {
        let entry = try completedEntry()
        let provider = DrillProvider(
            chat: [.fail(AiError.schema("not valid for schema"))], embed: .ok)
        orchestrator(provider).kick()

        try await waitUntil {
            let s = try self.statuses(entry.id)
            return s[.extraction]?.status == .failed
                && s[.embedding]?.status == .success
        }
        let s = try statuses(entry.id)
        XCTAssertEqual(s[.extraction]?.attempts, 1)
        XCTAssertTrue(s[.extraction]?.lastError?.contains("invalid model output") == true)
        XCTAssertEqual(s[.reflection]?.status, .skipped)
        try assertNoExtractionRows(entry.id)
    }

    /// Rate limited once, then the provider recovers: the queue retries
    /// with backoff and the entry ends fully enriched.
    func testRateLimitedThenRecovers() async throws {
        let entry = try completedEntry()
        let provider = DrillProvider(
            chat: [
                .fail(AiError.rateLimited(retryAfterSeconds: 0.02)),
                .ok,  // extraction retry
                .ok,  // reflection
            ],
            embed: .ok)
        orchestrator(provider).kick()

        try await waitUntil {
            try self.statuses(entry.id).values.allSatisfy { $0.status == .success }
        }
        XCTAssertEqual(try statuses(entry.id)[.extraction]?.attempts, 2)
        XCTAssertEqual(try metadata.themes(entryId: entry.id), ["wandering"])
    }

    /// Network drops mid-pipeline: extraction lands, reflection fails twice
    /// on transport then recovers on the final attempt.
    func testNetworkDropMidPipeline() async throws {
        let entry = try completedEntry()
        let provider = DrillProvider(
            chat: [
                .ok,  // extraction
                .fail(AiError.network("timeout")),
                .fail(AiError.network("timeout")),
                .ok,  // reflection, attempt 3
            ],
            embed: .ok)
        orchestrator(provider).kick()

        try await waitUntil {
            try self.statuses(entry.id).values.allSatisfy { $0.status == .success }
        }
        XCTAssertEqual(try statuses(entry.id)[.reflection]?.attempts, 3)
        XCTAssertEqual(
            try metadata.reflection(entryId: entry.id)?.moodLabel, "bright")
    }

    /// Provider 500s exhaust the budget: failed + last_error, and a later
    /// manual re-run against a healthy provider heals everything (FR-031).
    func testServerErrorsThenManualRerunHeals() async throws {
        let entry = try completedEntry()
        let sick = DrillProvider(
            chat: [
                .fail(AiError.provider(status: 503, message: "overloaded")),
                .fail(AiError.provider(status: 503, message: "overloaded")),
                .fail(AiError.provider(status: 503, message: "overloaded")),
            ],
            embed: .ok)
        let first = orchestrator(sick)
        first.kick()
        try await waitUntil {
            try self.statuses(entry.id)[.extraction]?.status == .failed
        }
        try assertNoExtractionRows(entry.id)

        let healthy = orchestrator(DrillProvider(chat: [.ok, .ok], embed: .ok))
        await healthy.rerun(entryId: entry.id)
        try await waitUntil {
            try self.statuses(entry.id).values.allSatisfy { $0.status == .success }
        }
        XCTAssertEqual(try metadata.themes(entryId: entry.id), ["wandering"])
    }
}

// MARK: - Scripted provider

private final class DrillProvider: AiProvider, @unchecked Sendable {
    enum Step {
        case ok
        case fail(Error)
    }

    private let lock = NSLock()
    private var chatSteps: [Step]
    private let embedStep: Step

    init(chat: [Step], embed: Step) {
        chatSteps = chat
        embedStep = embed
    }

    func structuredChat<Out: Decodable & Sendable>(
        model: String, system: String, user: String, maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage) {
        lock.lock()
        let step = chatSteps.isEmpty ? .ok : chatSteps.removeFirst()
        lock.unlock()
        if case .fail(let error) = step { throw error }

        let json: String
        if Out.self == ExtractionOutput.self {
            json = """
                {"themes":["wandering"],"tags":["market"],"entities":[],
                 "action_items":[],"self_questions":[]}
                """
        } else {
            json = """
                {"summary":"A day.","mood":{"label":"bright","confidence":0.8},
                 "sentiment_score":0.5,"energy":"medium","reflection_note":"A gentle note."}
                """
        }
        return (
            try JSONDecoder().decode(Out.self, from: Data(json.utf8)),
            AiUsage(promptTokens: 40, completionTokens: 15)
        )
    }

    func embed(model: String, texts: [String]) async throws -> ([[Float]], AiUsage) {
        if case .fail(let error) = embedStep { throw error }
        return (
            texts.map { _ in [Float](repeating: 0.3, count: 1024) },
            AiUsage(promptTokens: 20, completionTokens: 0)
        )
    }
}
