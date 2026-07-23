// Media file management (§3.5): originals copied into the app data
// directory, thumbnails via ImageIO, video posters + duration via
// AVFoundation — no ffmpeg. The DB stores relative paths only (§4.1);
// this store owns the files, repositories own the rows.
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImportedMedia: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case photo, video
    }

    public let relativePath: String
    public let thumbnailRelativePath: String?
    public let kind: Kind
    public let mimeType: String
    public let fileSizeBytes: Int
    public let width: Int?
    public let height: Int?
    public let durationSeconds: Double?
}

public enum MediaStoreError: Error {
    case unsupportedType(String)
    case unreadableImage
    case posterFailed
}

public final class MediaStore {
    public let rootURL: URL
    private let fileManager = FileManager.default

    private var mediaDir: URL { rootURL.appendingPathComponent("media") }
    private var thumbsDir: URL { rootURL.appendingPathComponent("thumbnails") }

    /// Longest thumbnail edge — display-sized, not archival (originals keep
    /// full resolution).
    public var thumbnailMaxPixel = 1200

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
    }

    public func absoluteURL(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    /// Copies `source` into the store and derives thumbnail + metadata.
    /// AC-006 (photo <1s) / AC-007 (video ≤60s <3s) budgets apply.
    public func importFile(from source: URL) async throws -> ImportedMedia {
        let ext = source.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else {
            throw MediaStoreError.unsupportedType(ext)
        }

        let id = UUID().uuidString
        let relativePath = "media/\(id).\(ext)"
        let destination = absoluteURL(relativePath)
        try fileManager.copyItem(at: source, to: destination)
        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        let mime = type.preferredMIMEType ?? "application/octet-stream"

        if type.conforms(to: .image) {
            let (thumbRel, width, height) = try makePhotoThumbnail(destination, id: id)
            return ImportedMedia(
                relativePath: relativePath, thumbnailRelativePath: thumbRel,
                kind: .photo, mimeType: mime, fileSizeBytes: size,
                width: width, height: height, durationSeconds: nil)
        }

        if type.conforms(to: .audiovisualContent) {
            let (thumbRel, width, height, duration) = try await makeVideoPoster(
                destination, id: id)
            return ImportedMedia(
                relativePath: relativePath, thumbnailRelativePath: thumbRel,
                kind: .video, mimeType: mime, fileSizeBytes: size,
                width: width, height: height, durationSeconds: duration)
        }

        try? fileManager.removeItem(at: destination)
        throw MediaStoreError.unsupportedType(ext)
    }

    /// Removes files for the given relative paths (ignores missing files).
    public func remove(relativePaths: [String]) {
        for path in relativePaths {
            try? fileManager.removeItem(at: absoluteURL(path))
        }
    }

    // MARK: - Photo (ImageIO)

    private func makePhotoThumbnail(
        _ url: URL, id: String
    ) throws -> (String, Int?, Int?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaStoreError.unreadableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
        else {
            throw MediaStoreError.unreadableImage
        }
        let thumbRel = "thumbnails/\(id).jpg"
        try writeJPEG(thumb, to: absoluteURL(thumbRel))
        return (thumbRel, width, height)
    }

    // MARK: - Video (AVFoundation)

    private func makeVideoPoster(
        _ url: URL, id: String
    ) async throws -> (String, Int?, Int?, Double) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: thumbnailMaxPixel, height: thumbnailMaxPixel)
        // A poster from just inside the clip reads better than frame zero.
        let posterTime = CMTime(
            seconds: min(1.0, max(0, duration * 0.25)), preferredTimescale: 600)
        let (poster, _) = try await generator.image(at: posterTime)

        let thumbRel = "thumbnails/\(id).jpg"
        try writeJPEG(poster, to: absoluteURL(thumbRel))
        return (thumbRel, poster.width, poster.height, duration)
    }

    // MARK: - Shared

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw MediaStoreError.posterFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaStoreError.posterFailed
        }
    }
}
