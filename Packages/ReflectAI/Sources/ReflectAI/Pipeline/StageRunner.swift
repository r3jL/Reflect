// The contract between the orchestrator and its stages. A stage does its
// own provider call(s) and writes its own derived rows; the orchestrator
// owns job bookkeeping, retries, and the usage ledger.
import Foundation
import ReflectCore

/// What a completed stage reports back for the ledger.
public struct StageOutcome: Equatable, Sendable {
    public let model: String
    public let usage: AiUsage

    public init(model: String, usage: AiUsage) {
        self.model = model
        self.usage = usage
    }
}

/// Thrown by a stage that has nothing to do for this entry (e.g. an empty
/// body) — the job is marked `skipped`, not failed.
public struct StageNotApplicable: Error {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public protocol PipelineStageRunner: Sendable {
    /// Runs the stage for `entry` (a claim-time snapshot; FR-004 re-enqueues
    /// if the user edits meanwhile). Must be side-effect free on failure —
    /// derived rows land only on success (FR-024).
    func run(entry: Entry) async throws -> StageOutcome
}
