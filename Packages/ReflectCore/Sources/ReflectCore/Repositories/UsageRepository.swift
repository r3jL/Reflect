// AI spend ledger (KPI-10 / AC-030). Written by the pipeline after each
// provider call; read by Settings for the monthly spend line.
import Foundation
import GRDB

public struct UsageRepository {
    public struct MonthTotal: Equatable {
        public let calls: Int
        public let promptTokens: Int
        public let completionTokens: Int
        /// Sum of known estimates; nil only when no call was priceable.
        public let costEstimate: Double?
    }

    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    public func record(
        entryId: String?,
        stage: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        costEstimate: Double?,
        now: Date = .now
    ) throws {
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    INSERT INTO ai_usage
                        (id, entry_id, stage, model, prompt_tokens,
                         completion_tokens, cost_estimate, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, entryId, stage, model, promptTokens,
                    completionTokens, costEstimate,
                    DBFormat.timestamp.string(from: now),
                ])
        }
    }

    /// One stage's share of a month (Settings' chat spend line, M20).
    public func monthStageTotal(
        _ yearMonth: String, stage: String
    ) throws -> MonthTotal {
        try db.reader.read { dbc in
            let row = try Row.fetchOne(
                dbc,
                sql: """
                    SELECT COUNT(*) AS calls,
                           COALESCE(SUM(prompt_tokens), 0) AS pt,
                           COALESCE(SUM(completion_tokens), 0) AS ct,
                           SUM(cost_estimate) AS cost
                    FROM ai_usage
                    WHERE created_at LIKE ? || '%' AND stage = ?
                    """,
                arguments: [yearMonth, stage])
            return MonthTotal(
                calls: row?["calls"] ?? 0,
                promptTokens: row?["pt"] ?? 0,
                completionTokens: row?["ct"] ?? 0,
                costEstimate: row?["cost"])
        }
    }

    /// Totals for a calendar month ("2026-07").
    public func monthTotal(_ yearMonth: String) throws -> MonthTotal {
        try db.reader.read { dbc in
            let row = try Row.fetchOne(
                dbc,
                sql: """
                    SELECT COUNT(*) AS calls,
                           COALESCE(SUM(prompt_tokens), 0) AS pt,
                           COALESCE(SUM(completion_tokens), 0) AS ct,
                           SUM(cost_estimate) AS cost
                    FROM ai_usage WHERE created_at LIKE ? || '%'
                    """,
                arguments: [yearMonth])
            return MonthTotal(
                calls: row?["calls"] ?? 0,
                promptTokens: row?["pt"] ?? 0,
                completionTokens: row?["ct"] ?? 0,
                costEstimate: row?["cost"])
        }
    }
}
