import XCTest

@testable import ReflectSTT

final class ReflectSTTTests: XCTestCase {
    func testModelCatalogPaths() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelStore(directory: dir)
        let url = store.localURL(for: .largeV3Turbo)
        XCTAssertEqual(url.lastPathComponent, "ggml-large-v3-turbo.bin")
        XCTAssertFalse(store.isDownloaded(.largeV3Turbo))
        XCTAssertTrue(
            WhisperModel.base.downloadURL.absoluteString.contains(
                "huggingface.co/ggerganov/whisper.cpp"))
    }

    /// AC-028/KPI-08 integration: set REFLECT_STT_MODEL=/path/to/ggml-*.bin
    /// to load a real model and transcribe a 15s buffer under the 5s budget.
    /// Skipped when no model path is provided (keeps CI offline).
    func testTranscribe15sWithinBudget() throws {
        guard let modelPath = ProcessInfo.processInfo
            .environment["REFLECT_STT_MODEL"]
        else {
            throw XCTSkip("REFLECT_STT_MODEL not set")
        }

        let transcriber = try WhisperTranscriber(modelPath: modelPath)
        // 15s of quiet band-limited noise — content-independent encode cost
        // dominates whisper's runtime, so timing is representative.
        var samples = [Float](repeating: 0, count: 16000 * 15)
        var state: UInt32 = 12345
        for i in samples.indices {
            state = state &* 1664525 &+ 1013904223
            samples[i] = (Float(state % 2000) / 1000 - 1) * 0.02
        }

        let t0 = ContinuousClock.now
        _ = try transcriber.transcribe(samples: samples)
        let elapsed = ContinuousClock.now - t0
        print("KPI-08 transcription of 15s clip: \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(5), "KPI-08 budget")
    }
}
