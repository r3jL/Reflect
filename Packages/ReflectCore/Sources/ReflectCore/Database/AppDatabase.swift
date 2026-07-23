// Database bootstrap (§3.2): GRDB DatabasePool (WAL), foreign keys, and
// per-connection sqlite-vec registration — the pattern validated by the
// M0 spike (sqlite3_auto_extension is a no-op on Apple platforms).
import CSQLiteVec
import Foundation
import GRDB
import SQLite3

public final class AppDatabase {
    public let writer: any DatabaseWriter

    /// Opens (or creates) the database at `url`, migrating to the latest schema.
    public convenience init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: url.path, configuration: AppDatabase.makeConfiguration())
        try self.init(writer: pool)
    }

    /// Designated initializer — also used by tests with a temporary database.
    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Migrations.migrator.migrate(writer)
    }

    /// The app's standard on-disk location (Application Support/Reflect).
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return support.appendingPathComponent("Reflect/reflect.sqlite")
    }

    public static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)
            guard rc == SQLITE_OK else {
                let message = errMsg.map { String(cString: $0) } ?? "unknown"
                throw DatabaseError(
                    resultCode: ResultCode(rawValue: rc),
                    message: "sqlite3_vec_init failed: \(message)")
            }
        }
        return config
    }

    public var reader: any DatabaseReader { writer }
}

// MARK: - Shared value formats

public enum DBFormat {
    /// ISO-8601 UTC, the spec's timestamp format (§4).
    public static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `entry_date` — the calendar day an entry is "about" (YYYY-MM-DD).
    public static func entryDate(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
