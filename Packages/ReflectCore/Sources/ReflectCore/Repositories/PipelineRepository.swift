// Durable job-queue persistence (FR-020). The orchestrator (ReflectAI)
// drives these transitions; this repository owns the SQL invariants:
// atomic claims, stage dependency (reflection needs extraction success),
// trash exclusion, and the failure state machine (AC-024).
import Foundation
import GRDB

public struct PipelineRepository {
    public struct Claim: Equatable, Sendable {
        public let job: PipelineJob
        public let entry: Entry
    }

    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    /// Crash recovery: only one process ever runs this queue, so any
    /// `running` job found at startup is a stale claim from a killed
    /// session — return it to pending (its attempt was already counted).
    @discardableResult
    public func recoverStaleRunning() throws -> Int {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs SET status = 'pending'
                    WHERE status = 'running'
                    """)
            return dbc.changesCount
        }
    }

    // MARK: - Claiming

    /// Claimable = pending, entry not trashed, and — for reflection — the
    /// entry's extraction already succeeded (AC-020). `excluding` carries
    /// the orchestrator's in-memory backoff holds.
    public func claimNext(excluding: Set<String> = []) throws -> Claim? {
        try db.writer.write { dbc in
            let rows = try Row.fetchAll(
                dbc,
                sql: """
                    SELECT j.id AS job_id FROM pipeline_jobs j
                    JOIN entries e ON e.id = j.entry_id AND e.is_deleted = 0
                    WHERE j.status = 'pending'
                      AND (j.stage IN ('extraction','embedding')
                           OR (j.stage = 'reflection' AND EXISTS (
                               SELECT 1 FROM pipeline_jobs x
                               WHERE x.entry_id = j.entry_id
                                 AND x.stage = 'extraction'
                                 AND x.status = 'success')))
                    ORDER BY j.created_at, j.stage
                    LIMIT 25
                    """)
            for row in rows {
                let jobId: String = row["job_id"]
                if excluding.contains(jobId) { continue }
                let changed = try dbc.execute(
                    sql: """
                        UPDATE pipeline_jobs
                        SET status = 'running', attempts = attempts + 1, started_at = ?
                        WHERE id = ? AND status = 'pending'
                        """,
                    arguments: [DBFormat.timestamp.string(from: .now), jobId])
                _ = changed
                guard dbc.changesCount == 1,
                      let job = try PipelineJob.fetchOne(dbc, key: jobId),
                      let entry = try Entry.fetchOne(dbc, key: job.entryId)
                else { continue }
                return Claim(job: job, entry: entry)
            }
            return nil
        }
    }

    // MARK: - Transitions

    public func markSuccess(jobId: String, provider: String, model: String) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs
                    SET status = 'success', provider = ?, model = ?,
                        last_error = NULL, finished_at = ?
                    WHERE id = ?
                    """,
                arguments: [provider, model, DBFormat.timestamp.string(from: .now), jobId])
        }
    }

    public func markSkipped(jobId: String, reason: String) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs
                    SET status = 'skipped', last_error = ?, finished_at = ?
                    WHERE id = ?
                    """,
                arguments: [reason, DBFormat.timestamp.string(from: .now), jobId])
        }
    }

    /// Retryable failure with attempts left: back to pending (attempts
    /// stays incremented from the claim).
    public func returnToPending(jobId: String, error: String) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs
                    SET status = 'pending', last_error = ? WHERE id = ?
                    """,
                arguments: [error, jobId])
        }
    }

    /// Undo a claim that did no work (e.g. no runner registered for the
    /// stage in this app version) — the attempt is not counted.
    public func releaseClaim(jobId: String) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs
                    SET status = 'pending', attempts = MAX(0, attempts - 1),
                        started_at = NULL
                    WHERE id = ? AND status = 'running'
                    """,
                arguments: [jobId])
        }
    }

    /// Terminal failure (AC-024): job fails with `last_error`, no derived
    /// rows. A terminally failed extraction also skips the entry's
    /// reflection job — it can never become claimable (revived by re-run).
    public func markFailed(job: PipelineJob, error: String) throws {
        try db.writer.write { dbc in
            let stamp = DBFormat.timestamp.string(from: .now)
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs
                    SET status = 'failed', last_error = ?, finished_at = ?
                    WHERE id = ?
                    """,
                arguments: [error, stamp, job.id])
            if job.stage == .extraction {
                try dbc.execute(
                    sql: """
                        UPDATE pipeline_jobs
                        SET status = 'skipped', last_error = 'extraction failed',
                            finished_at = ?
                        WHERE entry_id = ? AND stage = 'reflection'
                          AND status IN ('pending','failed')
                        """,
                    arguments: [stamp, job.entryId])
            }
        }
    }

    // MARK: - Re-run (FR-031)

    /// Resets stages to pending with a fresh attempt budget. `stages: nil`
    /// resets all three.
    public func reenqueue(
        entryId: String, stages: [PipelineJob.Stage]? = nil
    ) throws {
        let names = (stages ?? PipelineJob.Stage.allCases).map(\.rawValue)
        try db.writer.write { dbc in
            let marks = databaseQuestionMarks(count: names.count)
            try dbc.execute(
                sql: """
                    UPDATE pipeline_jobs
                    SET status = 'pending', attempts = 0, last_error = NULL,
                        started_at = NULL, finished_at = NULL
                    WHERE entry_id = ? AND stage IN (\(marks))
                    """,
                arguments: StatementArguments([entryId] + names))
        }
    }

    // MARK: - Introspection

    public func counts() throws -> [PipelineJob.Status: Int] {
        try db.reader.read { dbc in
            let rows = try Row.fetchAll(
                dbc,
                sql: "SELECT status, COUNT(*) AS n FROM pipeline_jobs GROUP BY status")
            var out: [PipelineJob.Status: Int] = [:]
            for row in rows {
                if let status = PipelineJob.Status(rawValue: row["status"]) {
                    out[status] = row["n"]
                }
            }
            return out
        }
    }
}
