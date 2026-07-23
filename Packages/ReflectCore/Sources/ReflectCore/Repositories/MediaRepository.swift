// Media rows (§4.1). Files live on disk under the app media directory;
// the DB stores relative paths only. File I/O belongs to ReflectMedia (M5).
import Foundation
import GRDB

public struct MediaRepository {
    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    @discardableResult
    public func insert(
        entryId: String, filePath: String, thumbnailPath: String?,
        mediaType: Media.MediaType, mimeType: String, fileSizeBytes: Int,
        width: Int? = nil, height: Int? = nil, durationSeconds: Double? = nil,
        sortOrder: Int = 0, now: Date = .now
    ) throws -> Media {
        let media = Media(
            id: UUID().uuidString, entryId: entryId, filePath: filePath,
            thumbnailPath: thumbnailPath, mediaType: mediaType,
            mimeType: mimeType, fileSizeBytes: fileSizeBytes,
            width: width, height: height, durationSeconds: durationSeconds,
            sortOrder: sortOrder,
            createdAt: DBFormat.timestamp.string(from: now))
        try db.writer.write { try media.insert($0) }
        return media
    }

    public func forEntry(_ entryId: String) throws -> [Media] {
        try db.reader.read { dbc in
            try Media
                .filter(Column("entry_id") == entryId)
                .order(Column("sort_order"), Column("created_at"))
                .fetchAll(dbc)
        }
    }

    /// Removes the row; returns the on-disk paths the caller must delete.
    public func delete(id: String) throws -> [String] {
        try db.writer.write { dbc in
            guard let media = try Media.fetchOne(dbc, key: id) else { return [] }
            try media.delete(dbc)
            return [media.filePath, media.thumbnailPath].compactMap { $0 }
        }
    }
}
