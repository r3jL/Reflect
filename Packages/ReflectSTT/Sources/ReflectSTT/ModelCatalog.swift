// Whisper model catalog + downloader. Models come from the official
// ggml conversions on Hugging Face; the download is the only network
// touch in the STT stack (transcription itself is offline).
import Foundation

public enum WhisperModel: String, CaseIterable, Sendable {
    case largeV3Turbo = "large-v3-turbo"
    case small = "small"
    case base = "base"

    public var fileName: String { "ggml-\(rawValue).bin" }

    public var downloadURL: URL {
        URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    public var approximateSize: String {
        switch self {
        case .largeV3Turbo: "1.6 GB"
        case .small: "466 MB"
        case .base: "142 MB"
        }
    }
}

public final class ModelStore {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    public func localURL(for model: WhisperModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    public func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    public func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: localURL(for: model))
    }

    /// Streams the model to disk, reporting progress in [0, 1].
    /// Cancellable via structured concurrency; partial files are removed.
    public func download(
        _ model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let destination = localURL(for: model)
        guard !isDownloaded(model) else {
            progress(1)
            return
        }
        let partial = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(
                from: model.downloadURL)
            let expected = response.expectedContentLength
            var received: Int64 = 0
            var chunk = Data(capacity: 1 << 20)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 1 << 20 {
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                    chunk.removeAll(keepingCapacity: true)
                    if expected > 0 {
                        progress(Double(received) / Double(expected))
                    }
                }
            }
            if !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            try FileManager.default.moveItem(at: partial, to: destination)
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}
