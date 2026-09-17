import Foundation
import WhisperCore

/// Owns the WhisperCore transcriber, the selected model, and forwards
/// engine state changes to the UI on the main thread.
@MainActor
final class TranscriptionService {

    private static let modelDefaultsKey = "SelectedWhisperModel"

    private(set) var model: WhisperModel
    private var transcriber: WhisperTranscriber
    var onStateChange: ((WhisperTranscriber.State) -> Void)?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
        model = saved.flatMap(WhisperModel.init(rawValue:)) ?? .recommended
        transcriber = WhisperTranscriber(model: model)
        Task { await hookStateObserver() }
    }

    /// Switches models; takes effect for the next transcription.
    func selectModel(_ newModel: WhisperModel) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: Self.modelDefaultsKey)
        transcriber = WhisperTranscriber(model: newModel)
        Task { await hookStateObserver() }
    }

    func transcribe(_ url: URL) async throws -> Transcript {
        try await transcriber.transcribe(url)
    }

    /// Starts model download/load in the background so the first recording
    /// does not pay the full wait.
    func warmUp() {
        let transcriber = transcriber
        Task.detached(priority: .utility) {
            try? await transcriber.prepare()
        }
    }

    private func hookStateObserver() async {
        await transcriber.observeState { [weak self] state in
            DispatchQueue.main.async {
                self?.onStateChange?(state)
            }
        }
    }
}
