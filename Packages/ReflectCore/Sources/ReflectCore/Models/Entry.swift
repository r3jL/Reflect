// The immutable-by-AI source of truth (§4.1). `body` is authored only by
// the user; all AI output lives in separate derived tables.
import Foundation
import GRDB

public struct Entry: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, PersistableRecord
{
    public enum Status: String, Codable, Sendable {
        case draft, completed
    }

    public var id: String
    public var title: String?
    public var body: String
    public var entryDate: String
    public var status: Status
    public var wordCount: Int
    public var place: String?
    public var weather: String?
    public var isMilestone: Bool
    public var isDeleted: Bool
    public var createdAt: String
    public var updatedAt: String
    public var completedAt: String?

    public static let databaseTableName = "entries"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public static func wordCount(of body: String) -> Int {
        body.split(whereSeparator: \.isWhitespace).count
    }
}

public struct Media: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, PersistableRecord
{
    public enum MediaType: String, Codable, Sendable {
        case photo, video
    }

    public var id: String
    public var entryId: String
    public var filePath: String
    public var thumbnailPath: String?
    public var mediaType: MediaType
    public var mimeType: String
    public var fileSizeBytes: Int
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var sortOrder: Int
    public var createdAt: String

    public static let databaseTableName = "media"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

public struct PipelineJob: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, PersistableRecord
{
    public enum Stage: String, Codable, CaseIterable, Sendable {
        case extraction, reflection, embedding
    }

    public enum Status: String, Codable, Sendable {
        case pending, running, success, failed, skipped
    }

    public var id: String
    public var entryId: String
    public var stage: Stage
    public var status: Status
    public var attempts: Int
    public var lastError: String?
    public var provider: String?
    public var model: String?
    public var startedAt: String?
    public var finishedAt: String?
    public var createdAt: String

    public static let databaseTableName = "pipeline_jobs"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}
