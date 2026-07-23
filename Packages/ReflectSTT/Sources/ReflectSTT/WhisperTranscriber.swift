// Swift face of whisper.cpp (FR-029/AC-028): load a ggml model once,
// transcribe 16kHz mono float samples fully on-device.
import CWhisper
import Foundation

public enum TranscriberError: Error {
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)
}

public final class WhisperTranscriber {
    private let context: OpaquePointer
    // Kept alive for the lifetime of the transcriber; whisper reads the
    // pointer during whisper_full.
    private let languageCString: UnsafeMutablePointer<CChar>

    /// Loads a ggml model file. Expensive (seconds, model-sized memory) —
    /// hold on to the instance.
    public init(modelPath: String, language: String = "auto") throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let context = whisper_init_from_file_with_params(modelPath, params)
        else {
            throw TranscriberError.modelLoadFailed(modelPath)
        }
        self.context = context
        self.languageCString = strdup(language)
    }

    deinit {
        whisper_free(context)
        free(languageCString)
    }

    /// `samples`: 16kHz mono PCM in [-1, 1]. Returns the joined transcript.
    public func transcribe(samples: [Float]) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.language = UnsafePointer(languageCString)
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else {
            throw TranscriberError.transcriptionFailed(status)
        }

        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
