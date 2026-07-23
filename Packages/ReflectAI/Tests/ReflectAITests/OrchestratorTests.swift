import Foundation
import ReflectCore
import XCTest

@testable import ReflectAI

final class OrchestratorTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!
    private var entries: EntriesRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-orch-\(UUID().uuidString)")
        db = try AppDatabase(at: tempDir.appendingPathComponent("t.sqlite"))
        entries = EntriesRepository(db)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func completedEntry(_ date: String = "2026-07-24") throws -> Entry {
        let entry = try entries.createDraft(entryDate: date)
        try entries.updateBody(id: entry.id, title: nil, body: "some words to work with")
        try entries.complete(id: entry.id)
        return entry
    }

    private func makeOrchestrator(
        runners: [PipelineJob.Stage: any PipelineStageRunner],
        enabled: Flag = Flag(true),
        online: Flag = Flag(true),
        maxAttempts: Int = 3
    ) -> PipelineOrchestrator {
        var config = PipelineOrchestrator.Configuration()
        config.maxAttempts = maxAttempts
        config.baseBackoff = .milliseconds(20)
        return PipelineOrchestrator(
            db: db, runners: runners,
            isEnabled: { enabled.value }, isOnline: { online.value },
            configuration: config)
    }

    private func jobStatuses(_ entryId: String) throws -> [PipelineJob.Stage: PipelineJob.Status] {
        let jobs = try entries.jobs(entryId: entryId)
        return Dictionary(uniqueKeysWithValues: jobs.map { ($0.stage, $0.status) })
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () throws -> Bool
    ) async rethrows {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("timed out waiting for condition")
    }

    // MARK: - AC-020: ordering

    func testReflectionRunsOnlyAfterExtractionSucceeds() async throws {
        let entry = try completedEntry()
        let recorder = Recorder()
        let orchestrator = makeOrchestrator(runners: [
            .extraction: RecordingRunner("extraction", recorder),
            .reflection: RecordingRunner("reflection", recorder),
            .embedding: RecordingRunner("embedding", recorder),
        ])
        orchestrator.kick()

        try await waitUntil {
            try jobStatuses(entry.id).allSatisfy { $0.value == .success }
        }
        let order = await recorder.events.map(\.label)
        let extractionIndex = try XCTUnwrap(order.firstIndex(of: "extraction"))
        let reflectionIndex = try XCTUnwrap(order.firstIndex(of: "reflection"))
        XCTAssertLessThan(extractionIndex, reflectionIndex, "AC-020")
    }

    func testTerminalExtractionFailureSkipsReflection() async throws {
        let entry = try completedEntry()
        let recorder = Recorder()
        let orchestrator = makeOrchestrator(runners: [
            .extraction: FailingRunner(error: AiError.auth),
            .reflection: RecordingRunner("reflection", recorder),
            .embedding: RecordingRunner("embedding", recorder),
        ])
        orchestrator.kick()

        try await waitUntil {
            let statuses = try jobStatuses(entry.id)
            return statuses[.extraction] == .failed
                && statuses[.reflection] == .skipped
                && statuses[.embedding] == .success
        }
        let jobs = try entries.jobs(entryId: entry.id)
        let extraction = try XCTUnwrap(jobs.first { $0.stage == .extraction })
        XCTAssertEqual(extraction.attempts, 1, "terminal errors do not retry")
        XCTAssertEqual(extraction.lastError, "API key rejected")
        let reflectionEvents = await recorder.events.filter { $0.label == "reflection" }
        XCTAssertTrue(reflectionEvents.isEmpty, "reflection must never run")
    }

    // MARK: - Retry / backoff

    func testRetryableFailureBacksOffThenSucceeds() async throws {
        let entry = try completedEntry()
        let runner = FlakyRunner(failuresBeforeSuccess: 2, error: AiError.network("down"))
        let orchestrator = makeOrchestrator(runners: [
            .extraction: runner,
            .reflection: SucceedingRunner(),
            .embedding: SucceedingRunner(),
        ])
        orchestrator.kick()

        try await waitUntil {
            try jobStatuses(entry.id).allSatisfy { $0.value == .success }
        }
        let extraction = try entries.jobs(entryId: entry.id)
            .first { $0.stage == .extraction }
        XCTAssertEqual(extraction?.attempts, 3, "two failures + one success")
    }

    func testRetryBudgetExhaustionFails() async throws {
        let entry = try completedEntry()
        let orchestrator = makeOrchestrator(
            runners: [
                .extraction: SucceedingRunner(),
                .reflection: SucceedingRunner(),
                .embedding: FailingRunner(error: AiError.network("always down")),
            ],
            maxAttempts: 2)
        orchestrator.kick()

        try await waitUntil {
            try jobStatuses(entry.id)[.embedding] == .failed
        }
        let embedding = try entries.jobs(entryId: entry.id)
            .first { $0.stage == .embedding }
        XCTAssertEqual(embedding?.attempts, 2)
        XCTAssertTrue(embedding?.lastError?.contains("network") == true)
    }

    // MARK: - Gates (AC-004) and offline (AC-025)

    func testDisabledGateLeavesJobsPending() async throws {
        let entry = try completedEntry()
        let orchestrator = makeOrchestrator(
            runners: [.extraction: SucceedingRunner()],
            enabled: Flag(false))
        orchestrator.kick()
        try? await Task.sleep(for: .milliseconds(150))
        let statuses = try jobStatuses(entry.id)
        XCTAssertTrue(statuses.allSatisfy { $0.value == .pending }, "AC-004")
    }

    func testOfflineQueuesThenDrainsOnReconnect() async throws {
        let entry = try completedEntry()
        let online = Flag(false)
        let orchestrator = makeOrchestrator(
            runners: [
                .extraction: SucceedingRunner(),
                .reflection: SucceedingRunner(),
                .embedding: SucceedingRunner(),
            ],
            online: online)
        orchestrator.kick()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(try jobStatuses(entry.id).allSatisfy { $0.value == .pending })

        online.value = true
        orchestrator.kick()  // the reconnect callback in the app does this
        try await waitUntil {
            try jobStatuses(entry.id).allSatisfy { $0.value == .success }
        }
    }

    // MARK: - Skip, ledger, re-run

    func testNotApplicableStageIsSkipped() async throws {
        let entry = try completedEntry()
        let orchestrator = makeOrchestrator(runners: [
            .extraction: SkippingRunner(reason: "empty entry"),
            .reflection: SucceedingRunner(),
            .embedding: SucceedingRunner(),
        ])
        orchestrator.kick()
        try await waitUntil {
            try jobStatuses(entry.id)[.extraction] == .skipped
        }
        let extraction = try entries.jobs(entryId: entry.id)
            .first { $0.stage == .extraction }
        XCTAssertEqual(extraction?.lastError, "empty entry")
    }

    func testSuccessWritesUsageLedger() async throws {
        let entry = try completedEntry()
        let orchestrator = makeOrchestrator(runners: [
            .extraction: SucceedingRunner(),
            .reflection: SucceedingRunner(),
            .embedding: SucceedingRunner(),
        ])
        orchestrator.kick()
        try await waitUntil {
            try jobStatuses(entry.id).allSatisfy { $0.value == .success }
        }
        let month = String(DBFormat.entryDate(.now).prefix(7))
        let total = try UsageRepository(db).monthTotal(month)
        XCTAssertEqual(total.calls, 3)
        XCTAssertEqual(total.promptTokens, 300, "100 per mock call")
    }

    func testManualRerunAfterTerminalFailure() async throws {
        let entry = try completedEntry()
        let flaky = SwitchableRunner(initial: AiError.schema("bad output"))
        let orchestrator = makeOrchestrator(runners: [
            .extraction: flaky,
            .reflection: SucceedingRunner(),
            .embedding: SucceedingRunner(),
        ])
        orchestrator.kick()
        try await waitUntil { try jobStatuses(entry.id)[.extraction] == .failed }

        flaky.error.value = nil  // "the model behaves this time"
        await orchestrator.rerun(entryId: entry.id)
        try await waitUntil {
            try jobStatuses(entry.id).allSatisfy { $0.value == .success }
        }
    }

    // MARK: - Crash recovery

    func testStaleRunningJobsRecoverOnFirstDrain() async throws {
        let entry = try completedEntry()
        try simulateStaleClaim(entryId: entry.id)
        let orchestrator = makeOrchestrator(runners: [
            .extraction: SucceedingRunner(),
            .reflection: SucceedingRunner(),
            .embedding: SucceedingRunner(),
        ])
        orchestrator.kick()
        try await waitUntil {
            try jobStatuses(entry.id).allSatisfy { $0.value == .success }
        }
    }

    func testUnregisteredStageDoesNotBurnAttempts() async throws {
        let entry = try completedEntry()
        // Only extraction registered — like the app between M12 and M13.
        let orchestrator = makeOrchestrator(runners: [
            .extraction: SucceedingRunner()
        ])
        orchestrator.kick()
        try await waitUntil {
            try jobStatuses(entry.id)[.extraction] == .success
        }
        try? await Task.sleep(for: .milliseconds(120))
        let jobs = try entries.jobs(entryId: entry.id)
        for job in jobs where job.stage != .extraction {
            XCTAssertEqual(job.status, .pending, "\(job.stage) waits for its runner")
            XCTAssertEqual(job.attempts, 0, "no-runner claims must not cost attempts")
        }
    }

    /// Simulates a killed session: a job left mid-claim.
    private func simulateStaleClaim(entryId: String) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs SET status = 'running', attempts = 1
                    WHERE entry_id = ? AND stage = 'extraction'
                    """,
                arguments: [entryId])
        }
    }

    // MARK: - Concurrency cap

    func testMaxTwoConcurrentJobs() async throws {
        for day in 1...4 {
            _ = try completedEntry(String(format: "2026-07-%02d", day))
        }
        let recorder = Recorder()
        let slow = SlowRunner(recorder: recorder, delay: .milliseconds(60))
        let orchestrator = makeOrchestrator(runners: [
            .extraction: slow, .reflection: slow, .embedding: slow,
        ])
        orchestrator.kick()
        try await waitUntil(timeout: .seconds(10)) {
            try PipelineRepository(db).counts()[.success] == 12
        }
        let peak = await recorder.peakConcurrent
        XCTAssertLessThanOrEqual(peak, 2, "FR-020 concurrency bound")
        XCTAssertGreaterThan(peak, 0)
    }
}

// MARK: - Test doubles

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    init(_ error: Error?) { _error = error }
    var value: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _error }
        set { lock.lock(); _error = newValue; lock.unlock() }
    }
}

private actor Recorder {
    struct Event { let label: String }
    private(set) var events: [Event] = []
    private var current = 0
    private(set) var peakConcurrent = 0

    func began(_ label: String) {
        events.append(Event(label: label))
        current += 1
        peakConcurrent = max(peakConcurrent, current)
    }

    func ended() { current -= 1 }
}

private let mockOutcome = StageOutcome(
    model: "mock/model", usage: AiUsage(promptTokens: 100, completionTokens: 20))

private struct SucceedingRunner: PipelineStageRunner {
    func run(entry: Entry) async throws -> StageOutcome { mockOutcome }
}

private struct FailingRunner: PipelineStageRunner {
    let error: Error
    func run(entry: Entry) async throws -> StageOutcome { throw error }
}

private struct SkippingRunner: PipelineStageRunner {
    let reason: String
    func run(entry: Entry) async throws -> StageOutcome {
        throw StageNotApplicable(reason: reason)
    }
}

private struct RecordingRunner: PipelineStageRunner {
    let label: String
    let recorder: Recorder
    init(_ label: String, _ recorder: Recorder) {
        self.label = label
        self.recorder = recorder
    }
    func run(entry: Entry) async throws -> StageOutcome {
        await recorder.began(label)
        await recorder.ended()
        return mockOutcome
    }
}

private final class FlakyRunner: PipelineStageRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private let error: Error
    init(failuresBeforeSuccess: Int, error: Error) {
        remainingFailures = failuresBeforeSuccess
        self.error = error
    }
    func run(entry: Entry) async throws -> StageOutcome {
        lock.lock()
        let shouldFail = remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        lock.unlock()
        if shouldFail { throw error }
        return mockOutcome
    }
}

private final class SwitchableRunner: PipelineStageRunner, @unchecked Sendable {
    let error: ErrorBox
    init(initial: Error?) { error = ErrorBox(initial) }
    func run(entry: Entry) async throws -> StageOutcome {
        if let error = error.value { throw error }
        return mockOutcome
    }
}

private struct SlowRunner: PipelineStageRunner {
    let recorder: Recorder
    let delay: Duration
    func run(entry: Entry) async throws -> StageOutcome {
        await recorder.began("slow")
        try? await Task.sleep(for: delay)
        await recorder.ended()
        return mockOutcome
    }
}
