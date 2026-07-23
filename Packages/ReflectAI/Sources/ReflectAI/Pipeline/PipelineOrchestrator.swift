// The async pipeline orchestrator (FR-020): drains pending pipeline_jobs
// with stage ordering (AC-020), bounded retries with exponential backoff,
// offline/AI-off gating (AC-004/AC-025), null-plus-warning failure
// semantics (AC-024), and per-call ledger writes (KPI-10).
import Foundation
import ReflectCore

public actor PipelineOrchestrator {
    public struct Configuration: Sendable {
        public var maxAttempts = 3
        public var maxConcurrent = 2
        public var baseBackoff: Duration = .seconds(2)
        public var maxBackoff: Duration = .seconds(60)

        public init() {}
    }

    private let repo: PipelineRepository
    private let usage: UsageRepository
    private let runners: [PipelineJob.Stage: any PipelineStageRunner]
    private let isEnabled: @Sendable () -> Bool
    private let isOnline: @Sendable () -> Bool
    private let config: Configuration

    private var inFlight = 0
    private var holdUntil: [String: ContinuousClock.Instant] = [:]
    private var recoveredStaleClaims = false

    public init(
        db: AppDatabase,
        runners: [PipelineJob.Stage: any PipelineStageRunner],
        isEnabled: @escaping @Sendable () -> Bool,
        isOnline: @escaping @Sendable () -> Bool = { true },
        configuration: Configuration = Configuration()
    ) {
        self.repo = PipelineRepository(db)
        self.usage = UsageRepository(db)
        self.runners = runners
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.config = configuration
    }

    // MARK: - Triggers

    /// Fire-and-forget drain trigger: entry completion, app launch,
    /// reconnect, manual re-run. Safe to call often.
    public nonisolated func kick() {
        Task { await self.drain() }
    }

    /// FR-031: reset stages for an entry and drain.
    public func rerun(entryId: String, stages: [PipelineJob.Stage]? = nil) async {
        try? repo.reenqueue(entryId: entryId, stages: stages)
        holdUntil = holdUntil.filter { _, until in until > .now }
        await drain()
    }

    // MARK: - Drain loop

    private func drain() async {
        if !recoveredStaleClaims {
            recoveredStaleClaims = true
            try? repo.recoverStaleRunning()
        }
        guard isEnabled(), isOnline() else { return }  // AC-004 / AC-025
        while inFlight < config.maxConcurrent {
            let now = ContinuousClock.now
            holdUntil = holdUntil.filter { _, until in until > now }
            guard let claim = try? repo.claimNext(
                excluding: Set(holdUntil.keys))
            else { break }
            guard claim.job.attempts <= config.maxAttempts else {
                try? repo.markFailed(job: claim.job, error: "attempt budget exhausted")
                continue
            }
            inFlight += 1
            Task {
                await self.execute(claim)
                await self.jobFinished()
            }
        }
    }

    private func jobFinished() async {
        inFlight -= 1
        await drain()
    }

    private func execute(_ claim: PipelineRepository.Claim) async {
        guard let runner = runners[claim.job.stage] else {
            // No runner registered (stage lands in a later milestone):
            // release the claim without spending an attempt and hold it
            // for this session.
            try? repo.releaseClaim(jobId: claim.job.id)
            holdUntil[claim.job.id] = .now + .seconds(3600)
            return
        }
        do {
            let outcome = try await runner.run(entry: claim.entry)
            try repo.markSuccess(
                jobId: claim.job.id, provider: "openrouter", model: outcome.model)
            try? usage.record(
                entryId: claim.entry.id,
                stage: claim.job.stage.rawValue,
                model: outcome.model,
                promptTokens: outcome.usage.promptTokens,
                completionTokens: outcome.usage.completionTokens,
                costEstimate: ModelPricing.estimate(
                    model: outcome.model, usage: outcome.usage))
        } catch let skip as StageNotApplicable {
            try? repo.markSkipped(jobId: claim.job.id, reason: skip.reason)
        } catch {
            await handleFailure(claim, error: error)
        }
    }

    private func handleFailure(_ claim: PipelineRepository.Claim, error: Error) async {
        let aiError = error as? AiError
        let retryable = aiError?.isRetryable ?? true  // unknown errors: retry
        let description = describe(error)

        if retryable && claim.job.attempts < config.maxAttempts {
            try? repo.returnToPending(jobId: claim.job.id, error: description)
            let delay = backoffDelay(attempts: claim.job.attempts, error: aiError)
            holdUntil[claim.job.id] = .now + delay
            scheduleKick(after: delay)
        } else {
            // AC-024: failed + last_error, no derived rows. The repository
            // cascades a reflection skip when extraction dies.
            try? repo.markFailed(job: claim.job, error: description)
        }
    }

    private func backoffDelay(attempts: Int, error: AiError?) -> Duration {
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            return .seconds(min(retryAfter, 120))
        }
        let exponent = max(0, attempts - 1)
        let scaled = config.baseBackoff * Int(1 << min(exponent, 5))
        return min(scaled, config.maxBackoff)
    }

    private nonisolated func scheduleKick(after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            await self.drain()
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case AiError.auth: "API key rejected"
        case AiError.notConfigured: "AI not configured"
        case AiError.rateLimited: "rate limited"
        case AiError.network(let detail): "network: \(detail)"
        case AiError.schema(let detail): "invalid model output: \(detail)"
        case AiError.provider(let status, let message):
            "provider error \(status): \(message)"
        default: String(describing: error)
        }
    }
}
