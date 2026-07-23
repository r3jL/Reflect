// Microphone capture for voice entries (FR-029): AVAudioEngine tap,
// converted to the 16kHz mono float PCM whisper expects. Audio stays in
// memory and never leaves the device.
import AVFoundation
import Foundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
        interleaved: false)!

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        samples.removeAll()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns everything recorded.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16000
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = 16000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat, frameCapacity: capacity)
        else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(
            start: channel[0], count: count))
        lock.unlock()
    }
}
