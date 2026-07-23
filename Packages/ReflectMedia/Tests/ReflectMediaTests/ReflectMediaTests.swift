import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ReflectMedia

final class ReflectMediaTests: XCTestCase {
    private var tempDir: URL!
    private var store: MediaStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflect-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
        store = try MediaStore(rootURL: tempDir.appendingPathComponent("store"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - AC-006: photo attach + thumbnail < 1s

    func testPhotoImportWithinBudget() async throws {
        let photo = try makeTestJPEG(width: 2400, height: 1600)

        let t0 = ContinuousClock.now
        let imported = try await store.importFile(from: photo)
        let elapsed = ContinuousClock.now - t0

        XCTAssertLessThan(elapsed, .seconds(1), "AC-006 budget")
        XCTAssertEqual(imported.kind, .photo)
        XCTAssertEqual(imported.mimeType, "image/jpeg")
        XCTAssertEqual(imported.width, 2400)
        XCTAssertEqual(imported.height, 1600)
        XCTAssertNil(imported.durationSeconds)
        XCTAssertGreaterThan(imported.fileSizeBytes, 0)

        // Original + display-sized thumbnail both exist on disk.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.absoluteURL(imported.relativePath).path))
        let thumbURL = store.absoluteURL(try XCTUnwrap(imported.thumbnailRelativePath))
        let thumbSource = try XCTUnwrap(
            CGImageSourceCreateWithURL(thumbURL as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(thumbSource, 0, nil)
            as? [CFString: Any]
        let thumbWidth = try XCTUnwrap(props?[kCGImagePropertyPixelWidth] as? Int)
        XCTAssertLessThanOrEqual(thumbWidth, 1200)
    }

    // MARK: - AC-007: video attach + poster < 3s

    func testVideoImportWithinBudget() async throws {
        let video = try await makeTestMP4(width: 640, height: 480, frames: 30)

        let t0 = ContinuousClock.now
        let imported = try await store.importFile(from: video)
        let elapsed = ContinuousClock.now - t0

        XCTAssertLessThan(elapsed, .seconds(3), "AC-007 budget")
        XCTAssertEqual(imported.kind, .video)
        let duration = try XCTUnwrap(imported.durationSeconds)
        XCTAssertEqual(duration, 1.0, accuracy: 0.2)  // 30 frames @ 30fps
        XCTAssertNotNil(imported.thumbnailRelativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.absoluteURL(imported.thumbnailRelativePath!).path))
        XCTAssertGreaterThan(imported.width ?? 0, 0)
    }

    // MARK: - Removal + unsupported types

    func testRemoveDeletesFiles() async throws {
        let photo = try makeTestJPEG(width: 400, height: 300)
        let imported = try await store.importFile(from: photo)
        let paths = [imported.relativePath, imported.thumbnailRelativePath!]
        store.remove(relativePaths: paths)
        for path in paths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: store.absoluteURL(path).path))
        }
    }

    func testUnsupportedTypeRejected() async throws {
        let text = tempDir.appendingPathComponent("note.txt")
        try "not media".write(to: text, atomically: true, encoding: .utf8)
        do {
            _ = try await store.importFile(from: text)
            XCTFail("expected unsupportedType")
        } catch MediaStoreError.unsupportedType {
            // expected — and no stray copy left behind
            let mediaDir = store.rootURL.appendingPathComponent("media")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: mediaDir.path)
            XCTAssertTrue(leftovers.isEmpty)
        }
    }

    // MARK: - Fixtures

    private func makeTestJPEG(width: Int, height: Int) throws -> URL {
        let url = tempDir.appendingPathComponent("fixture-\(width)x\(height).jpg")
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.65, green: 0.42, blue: 0.27, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeTestMP4(width: Int, height: Int, frames: Int) async throws -> URL {
        let url = tempDir.appendingPathComponent("fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var bufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(
                nil, try XCTUnwrap(adaptor.pixelBufferPool), &bufferOut)
            let buffer = try XCTUnwrap(bufferOut)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(
                    base, Int32((frame * 8) % 256),
                    CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(
                        value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}
