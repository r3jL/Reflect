// Versioned vector writes (§4.3, FR-023/FR-030): metadata rows carry
// model/version/dim provenance; raw vectors live in vec0, joined by the
// meta id. Re-embedding an entry replaces its rows wholesale.
import Foundation
import GRDB

public struct EmbeddingsRepository {
    public struct Neighbor: Equatable, Sendable {
        public let entryId: String
        public let distance: Double
    }

    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    /// Writes one row pair per chunk in a single transaction (AC-023).
    public func replaceEmbeddings(
        entryId: String,
        chunks: [[Float]],
        model: String,
        modelVersion: String,
        now: Date = .now
    ) throws {
        let stamp = DBFormat.timestamp.string(from: now)
        try db.writer.write { dbc in
            try dbc.execute(
                sql: """
                    DELETE FROM vec_entries WHERE rowid IN
                        (SELECT id FROM embeddings_meta WHERE entry_id = ?)
                    """,
                arguments: [entryId])
            try dbc.execute(
                sql: "DELETE FROM embeddings_meta WHERE entry_id = ?",
                arguments: [entryId])

            for (index, vector) in chunks.enumerated() {
                try dbc.execute(
                    sql: """
                        INSERT INTO embeddings_meta
                            (entry_id, chunk_index, model, model_version, dim,
                             status, embedded_at)
                        VALUES (?, ?, ?, ?, ?, 'current', ?)
                        """,
                    arguments: [
                        entryId, index, model, modelVersion, vector.count, stamp,
                    ])
                let metaId = dbc.lastInsertedRowID
                try dbc.execute(
                    sql: "INSERT INTO vec_entries(rowid, embedding) VALUES (?, ?)",
                    arguments: [
                        metaId,
                        vector.withUnsafeBufferPointer { Data(buffer: $0) },
                    ])
            }
        }
    }

    /// Chunk count for an entry (0 = not yet embedded).
    public func chunkCount(entryId: String) throws -> Int {
        try db.reader.read { dbc in
            try Int.fetchOne(
                dbc,
                sql: "SELECT COUNT(*) FROM embeddings_meta WHERE entry_id = ?",
                arguments: [entryId]) ?? 0
        }
    }

    /// The stored vector for an entry's first chunk — the query vector for
    /// memory echoes (local-only retrieval, DEC-P1-01).
    public func firstChunkVector(entryId: String) throws -> [Float]? {
        try db.reader.read { dbc in
            guard let data = try Data.fetchOne(
                dbc,
                sql: """
                    SELECT v.embedding FROM vec_entries v
                    JOIN embeddings_meta m ON m.id = v.rowid
                    WHERE m.entry_id = ? AND m.chunk_index = 0 AND m.status = 'current'
                    """,
                arguments: [entryId])
            else { return nil }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    /// KNN over current vectors, deduped to the nearest chunk per entry.
    /// `excluding` drops the query entry itself (and same-day companions).
    public func nearestEntries(
        to vector: [Float], k: Int, excluding: Set<String> = []
    ) throws -> [Neighbor] {
        try db.reader.read { dbc in
            let rows = try Row.fetchAll(
                dbc,
                sql: """
                    SELECT m.entry_id, v.distance
                    FROM vec_entries v
                    JOIN embeddings_meta m ON m.id = v.rowid
                    JOIN entries e ON e.id = m.entry_id AND e.is_deleted = 0
                    WHERE v.embedding MATCH ? AND k = ?
                      AND m.status = 'current'
                    ORDER BY v.distance
                    """,
                arguments: [
                    vector.withUnsafeBufferPointer { Data(buffer: $0) },
                    k + excluding.count + 4,
                ])
            var seen = Set<String>()
            var out: [Neighbor] = []
            for row in rows {
                let entryId: String = row["entry_id"]
                guard !excluding.contains(entryId), !seen.contains(entryId)
                else { continue }
                seen.insert(entryId)
                out.append(Neighbor(entryId: entryId, distance: row["distance"]))
                if out.count == k { break }
            }
            return out
        }
    }
}
