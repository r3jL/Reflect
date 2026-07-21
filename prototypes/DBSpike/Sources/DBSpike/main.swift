// DB de-risk spike for Reflect.
// Proves, in one process: GRDB (WAL, foreign keys, migrations) + FTS5 keyword
// search + sqlite-vec KNN over 10k 1024-dim vectors — the §3.2 stack.
import CSQLiteVec
import Foundation
import GRDB
import SQLite3

func step(_ label: String, _ body: () throws -> String) rethrows {
    let t0 = ContinuousClock.now
    let detail = try body()
    let ms = Double((ContinuousClock.now - t0).components.attoseconds) / 1e15
    print("✅ \(label) — \(detail)  [\(String(format: "%.1f", ms)) ms]")
}

// 1. Register sqlite-vec on every connection GRDB opens.
// NOTE: sqlite3_auto_extension is a no-op on Apple platforms ("process-global
// auto extensions are not supported") — per-connection init is the working path.
let dbDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("reflect-dbspike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("spike.sqlite").path

var config = Configuration()
config.foreignKeysEnabled = true
config.prepareDatabase { db in
    var errMsg: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)
    guard rc == SQLITE_OK else {
        let message = errMsg.map { String(cString: $0) } ?? "unknown"
        throw NSError(domain: "spike", code: Int(rc), userInfo: [
            NSLocalizedDescriptionKey: "sqlite3_vec_init failed: \(message)"])
    }
}
// DatabasePool = WAL mode automatically (what the app will use per §3.2).
let dbQueue = try DatabasePool(path: dbPath, configuration: config)

try dbQueue.read { db in
    let sqliteVersion = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?"
    let vecVersion = try String.fetchOne(db, sql: "SELECT vec_version()") ?? "?"
    let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "?"
    print("SQLite \(sqliteVersion) · sqlite-vec \(vecVersion) · journal_mode=\(journalMode)")
}

// 2. Schema (the §4 subset this spike exercises), via GRDB migrations.
var migrator = DatabaseMigrator()
migrator.registerMigration("v1") { db in
    try db.execute(sql: """
        CREATE TABLE entries (
            id         TEXT PRIMARY KEY,
            title      TEXT,
            body       TEXT NOT NULL DEFAULT '',
            entry_date TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE entries_fts USING fts5(
            title, body, content='entries', content_rowid='rowid'
        );
        CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN
            INSERT INTO entries_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        CREATE TABLE embeddings_meta (
            id       INTEGER PRIMARY KEY,
            entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            model    TEXT NOT NULL,
            dim      INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE vec_entries USING vec0(
            embedding float[1024]
        );
        """)
}
try migrator.migrate(dbQueue)

// 3. FTS5: insert a few entries, keyword-search them.
try step("FTS5 keyword search") {
    try dbQueue.write { db in
        let rows: [(String, String)] = [
            ("First evening", "We landed in Lisbon and the light did the thing it always does."),
            ("The studio", "We opened the studio doors. Six people came. It was everything."),
            ("Quiet Sunday", "A grey day. Did not write much. That is allowed."),
        ]
        for (title, body) in rows {
            try db.execute(
                sql: """
                    INSERT INTO entries (id, title, body, entry_date, created_at)
                    VALUES (?, ?, ?, date('now'), datetime('now'))
                    """,
                arguments: [UUID().uuidString, title, body])
        }
    }
    let hits = try dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT e.title FROM entries_fts f
            JOIN entries e ON e.rowid = f.rowid
            WHERE entries_fts MATCH ? ORDER BY rank
            """, arguments: ["studio"])
    }
    guard hits.count == 1, hits[0]["title"] == "The studio" else {
        throw NSError(domain: "spike", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "unexpected FTS results: \(hits)"])
    }
    return "matched \"studio\" → \(hits[0]["title"] as String? ?? "?")"
}

// 4. sqlite-vec: 10k random 1024-dim vectors (KPI-06 scale), then KNN.
let dim = 1024
let count = 10_000
func randomVector(_ n: Int) -> [Float] {
    (0..<n).map { _ in Float.random(in: -1...1) }
}
func blob(_ v: [Float]) -> Data {
    v.withUnsafeBufferPointer { Data(buffer: $0) }
}

var probe: [Float] = []
try step("insert \(count) × \(dim)-dim vectors") {
    try dbQueue.write { db in
        for i in 1...count {
            let v = randomVector(dim)
            if i == count / 2 { probe = v } // remember one to search for
            try db.execute(
                sql: "INSERT INTO vec_entries(rowid, embedding) VALUES (?, ?)",
                arguments: [i, blob(v)])
        }
    }
    return "vec0 table populated"
}

try step("KNN top-5 over \(count) vectors (KPI-06 target <100ms)") {
    let rows = try dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT rowid, distance FROM vec_entries
            WHERE embedding MATCH ? AND k = 5
            ORDER BY distance
            """, arguments: [blob(probe)])
    }
    guard rows.count == 5, rows[0]["rowid"] == Int64(count / 2) else {
        throw NSError(domain: "spike", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "nearest neighbor was not the probe row: \(rows)"])
    }
    let d = rows[0]["distance"] as Double? ?? -1
    return "nearest = probe row \(count / 2) (distance \(String(format: "%.4f", d)))"
}

// 5. Durability sanity: foreign keys + cascade behavior.
try step("foreign keys + cascade") {
    try dbQueue.write { db in
        let id = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO entries (id, body, entry_date, created_at)
                VALUES (?, 'x', date('now'), datetime('now'))
                """,
            arguments: [id])
        try db.execute(
            sql: "INSERT INTO embeddings_meta (entry_id, model, dim) VALUES (?, 'bge-m3', 1024)",
            arguments: [id])
        try db.execute(sql: "DELETE FROM entries WHERE id = ?", arguments: [id])
        let orphans = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM embeddings_meta WHERE entry_id = ?",
            arguments: [id]) ?? -1
        guard orphans == 0 else {
            throw NSError(domain: "spike", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "cascade delete failed"])
        }
        return "ON DELETE CASCADE verified"
    }
}

try? FileManager.default.removeItem(at: dbDir)
print("\n🎉 DB spike passed — GRDB + FTS5 + sqlite-vec coexist in one connection.")
