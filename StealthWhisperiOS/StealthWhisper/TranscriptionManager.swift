import Foundation
import WhisperCore

/// Owns the on-device WhisperCore engine, exposes its state to SwiftUI,
/// and persists the selected model across launches.
@MainActor
final class TranscriptionManager: ObservableObject {
    @Published private(set) var state: WhisperTranscriber.State = .idle
    @Published private(set) var model: WhisperModel

    private var transcriber: WhisperTranscriber

    private static let modelDefaultsKey = "SelectedWhisperModel"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
        let model = saved.flatMap(WhisperModel.init(rawValue:)) ?? .recommended
        self.model = model
        self.transcriber = WhisperTranscriber(model: model)
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

    /// Starts model download/load in the background so the first
    /// recording does not pay the full wait.
    func warmUp() {
        let transcriber = transcriber
        Task.detached(priority: .utility) {
            try? await transcriber.prepare()
        }
    }

    func transcribe(_ url: URL) async throws -> Transcript {
        try await transcriber.transcribe(url)
    }

    private func hookStateObserver() async {
        await transcriber.observeState { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
            }
        }
    }
}
