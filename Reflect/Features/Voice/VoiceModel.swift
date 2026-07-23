// Voice capture state machine (FR-029): idle → (download model if absent)
// → recording → transcribing → text inserted at the caret. The transcriber
// stays loaded after first use; the model choice follows Settings.
import Foundation
import Observation
import ReflectCore
import ReflectSTT

@Observable
@MainActor
final class VoiceModel {
    enum Phase: Equatable {
        case idle
        case denied
        case downloading(Double)
        case recording
        case transcribing
    }

    private(set) var phase: Phase = .idle
    private(set) var errorText: String?

    private let recorder = AudioRecorder()
    private var transcriber: WhisperTranscriber?
    private var loadedModel: WhisperModel?

    private var modelStore: ModelStore? {
        try? ModelStore(
            directory: AppServices.mediaStore.rootURL
                .appendingPathComponent("models"))
    }

    private var selectedModel: WhisperModel {
        let raw = (try? AppServices.settings.get(.sttModel)) ?? "large-v3-turbo"
        return WhisperModel(rawValue: raw) ?? .largeV3Turbo
    }

    var modelDownloaded: Bool {
        modelStore?.isDownloaded(selectedModel) ?? false
    }

    /// The mic button's single action: kicks off whatever the state needs.
    func toggle(insert: @escaping (String) -> Void) {
        errorText = nil
        switch phase {
        case .recording:
            finishRecording(insert: insert)
        case .idle, .denied:
            Task { await beginFlow() }
        case .downloading, .transcribing:
            break  // in flight; button is inert
        }
    }

    private func beginFlow() async {
        guard await AudioRecorder.requestPermission() else {
            phase = .denied
            errorText = "Microphone access is off for Reflect in System Settings."
            return
        }
        guard let store = modelStore else { return }
        let model = selectedModel
        if !store.isDownloaded(model) {
            phase = .downloading(0)
            do {
                try await store.download(model) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.phase {
                            self?.phase = .downloading(fraction)
                        }
                    }
                }
            } catch {
                phase = .idle
                errorText = "Model download failed — check your connection."
                return
            }
        }
        do {
            try recorder.start()
            phase = .recording
        } catch {
            phase = .idle
            errorText = "Could not start the microphone."
        }
    }

    private func finishRecording(insert: @escaping (String) -> Void) {
        let samples = recorder.stop()
        guard samples.count > 8000 else {  // < 0.5s — nothing to say
            phase = .idle
            return
        }
        phase = .transcribing
        let model = selectedModel
        guard let store = modelStore else {
            phase = .idle
            return
        }
        let modelPath = store.localURL(for: model).path
        let cached = (loadedModel == model) ? transcriber : nil

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let transcriber = try cached ?? WhisperTranscriber(modelPath: modelPath)
                let text = try transcriber.transcribe(samples: samples)
                await MainActor.run { [weak self] in
                    self?.transcriber = transcriber
                    self?.loadedModel = model
                    self?.phase = .idle
                    if !text.isEmpty { insert(text + " ") }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.phase = .idle
                    self?.errorText = "Transcription failed."
                }
            }
        }
    }
}
