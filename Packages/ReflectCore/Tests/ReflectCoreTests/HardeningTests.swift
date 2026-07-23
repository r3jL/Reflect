// M9 hardening: KPI benchmarks at spec scale (10k entries) and WAL
// durability under simulated crash. The benchmark is gated behind
// REFLECT_BENCH=1 to keep everyday test runs fast.
import Foundation
import GRDB
import XCTest

@testable import ReflectCore

final class HardeningTests: XCTestCase {
    private var tempDir: URL!
    private var db: AppDatabase!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-hardening-\(UUID().uuidString)")
        db = try AppDatabase(at: tempDir.appendingPathComponent("bench.sqlite"))
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - KPI-11: committed writes survive a crash (WAL never checkpointed)

    func testCommittedWritesSurviveSimulatedCrash() throws {
        let repo = EntriesRepository(db)
        for i in 0..<50 {
            let entry = try repo.createDraft(
                entryDate: String(format: "2026-06-%02d", (i % 28) + 1))
            try repo.updateBody(id: entry.id, title: nil, body: "committed body \(i)")
        }

        // Snapshot main+wal+shm while the pool is still open — the moral
        // equivalent of pulling the plug before any checkpoint.
        let snapshotDir = tempDir.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(
            at: snapshotDir, withIntermediateDirectories: true)
        let base = tempDir.appendingPathComponent("bench.sqlite").path
        let walSize = (try? FileManager.default
            .attributesOfItem(atPath: base + "-wal")[.size] as? Int) ?? 0
        XCTAssertGreaterThan(walSize ?? 0, 0, "WAL should hold the writes")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(
                atPath: base + suffix,
                toPath: snapshotDir.appendingPathComponent("bench.sqlite" + suffix).path)
        }

        let recovered = try AppDatabase(
            at: snapshotDir.appendingPathComponent("bench.sqlite"))
        let count = try recovered.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM entries") ?? 0
        }
        let integrity = try recovered.reader.read {
            try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "?"
        }
        XCTAssertEqual(count, 50, "no committed entry may be lost (KPI-11)")
        XCTAssertEqual(integrity, "ok")
    }

    // MARK: - KPI benchmark at 10k entries (REFLECT_BENCH=1)

    func testBenchmarkAt10kEntries() throws {
        guard ProcessInfo.processInfo.environment["REFLECT_BENCH"] == "1" else {
            throw XCTSkip("REFLECT_BENCH not set")
        }
        let repo = EntriesRepository(db)
        let filler = [
            "Slow morning, the kind that forgives you for it.",
            "Worked on the typeface until the names blurred into one another.",
            "A walk by the river; two herons, one idea worth keeping.",
            "Read in the studio until the light moved on without me.",
        ]

        // Seed 10k completed entries + 10k 1024-dim vectors.
        var ids: [String] = []
        try db.writer.write { dbc in
            let stamp = DBFormat.timestamp.string(from: .now)
            for i in 0..<10_000 {
                let id = UUID().uuidString
                ids.append(id)
                let day = String(
                    format: "%04d-%02d-%02d",
                    2000 + i / 366, 1 + (i / 31) % 12, 1 + i % 28)
                let body = i % 971 == 0
                    ? "We landed in Lisbon and the light did the thing. (\(i))"
                    : "\(filler[i % filler.count]) (\(i))"
                try dbc.execute(
                    sql: """
                        INSERT INTO entries (id, body, entry_date, status, word_count,
                                             created_at, updated_at)
                        VALUES (?, ?, ?, 'completed', 12, ?, ?)
                        """,
                    arguments: [id, body, day, stamp, stamp])
                try dbc.execute(
                    sql: """
                        INSERT INTO embeddings_meta
                            (entry_id, chunk_index, model, model_version, dim, embedded_at)
                        VALUES (?, 0, 'bge-m3', 'bench', 1024, ?)
                        """,
                    arguments: [id, stamp])
                let metaId = dbc.lastInsertedRowID
                var vector = [Float](repeating: 0, count: 1024)
                for j in 0..<1024 {
                    vector[j] = Float((i * 31 + j * 7) % 1000) / 500 - 1
                }
                try dbc.execute(
                    sql: "INSERT INTO vec_entries(rowid, embedding) VALUES (?, ?)",
                    arguments: [metaId, vector.withUnsafeBufferPointer { Data(buffer: $0) }])
            }
        }

        func ms(_ body: () throws -> Void) rethrows -> Double {
            let t0 = ContinuousClock.now
            try body()
            return Double((ContinuousClock.now - t0).components.attoseconds) / 1e15
        }

        // KPI-02: entry writes (updateBody incl. FTS + job re-enqueue), P50/P95.
        var writeTimes: [Double] = []
        for i in 0..<200 {
            let id = ids[(i * 47) % ids.count]
            writeTimes.append(
                try ms {
                    try repo.updateBody(
                        id: id, title: nil,
                        body: "revised on pass \(i) — a slightly longer body to be fair about it.")
                })
        }
        writeTimes.sort()
        let p50 = writeTimes[writeTimes.count / 2]
        let p95 = writeTimes[Int(Double(writeTimes.count) * 0.95)]

        // KPI-05: FTS search.
        var hits = 0
        let searchMs = try ms { hits = try repo.searchKeyword("lisbon").count }

        // KPI-06: KNN top-5 over 10k vectors.
        var probe = [Float](repeating: 0, count: 1024)
        for j in 0..<1024 { probe[j] = Float((5000 * 31 + j * 7) % 1000) / 500 - 1 }
        let knnMs = try ms {
            _ = try db.reader.read { dbc in
                try Row.fetchAll(
                    dbc,
                    sql: """
                        SELECT rowid, distance FROM vec_entries
                        WHERE embedding MATCH ? AND k = 5 ORDER BY distance
                        """,
                    arguments: [probe.withUnsafeBufferPointer { Data(buffer: $0) }])
            }
        }

        // Month fetch (Life map source).
        let monthMs = try ms { _ = try repo.month("2010-06") }

        print("""
            BENCH @10k entries:
              KPI-02 write P50 \(String(format: "%.1f", p50))ms · \
            P95 \(String(format: "%.1f", p95))ms (budget: <100 typical, <200 P95)
              KPI-05 FTS search \(String(format: "%.1f", searchMs))ms, \(hits) hits (budget <150)
              KPI-06 KNN top-5 \(String(format: "%.1f", knnMs))ms (budget <100)
              Life month fetch \(String(format: "%.1f", monthMs))ms
            """)

        XCTAssertLessThan(p95, 200, "KPI-02 P95")
        XCTAssertLessThan(searchMs, 150, "KPI-05")
        XCTAssertLessThan(knnMs, 100, "KPI-06")
    }
}
