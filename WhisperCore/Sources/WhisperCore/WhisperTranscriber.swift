import Foundation
import WhisperKit

/// High-level on-device transcription engine shared by all our apps.
///
/// Wraps WhisperKit: downloads the CoreML model on first use, keeps it
/// loaded, and turns audio files into `Transcript` values.
public actor WhisperTranscriber {

    public enum State: Sendable, Equatable {
        case idle
        case downloadingModel(progress: Double)
        case loadingModel
        case ready
        case transcribing
        case failed(String)
    }

    public private(set) var state: State = .idle
    public let model: WhisperModel
    private let modelFolder: URL
    private var whisperKit: WhisperKit?
    private var stateObserver: (@Sendable (State) -> Void)?

    /// - Parameters:
    ///   - model: which Whisper variant to use.
    ///   - modelFolder: where models are stored; defaults to the shared app-support folder.
    public init(model: WhisperModel = .recommended, modelFolder: URL? = nil) {
        self.model = model
        self.modelFolder = modelFolder ?? ModelCatalog.defaultModelFolder()
    }

    /// Registers a callback fired on every state change (download progress, ready, …).
    public func observeState(_ observer: @escaping @Sendable (State) -> Void) {
        stateObserver = observer
        observer(state)
    }

    private func setState(_ new: State) {
        state = new
        stateObserver?(new)
    }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly.
    public func prepare() async throws {
        guard whisperKit == nil else { return }
        do {
            try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

            let variantFolder: URL
            if ModelCatalog.isDownloaded(model, folder: modelFolder) {
                variantFolder = ModelCatalog.variantFolder(model, folder: modelFolder)
            } else {
                // Clear any half-finished attempt first: leftovers make the
                // hub client resume into the same broken state forever.
                ModelCatalog.removeDownload(model, folder: modelFolder)
                setState(.downloadingModel(progress: 0))
                variantFolder = try await WhisperKit.download(
                    variant: model.rawValue,
                    downloadBase: modelFolder,
                    progressCallback: { [weak self] progress in
                        let fraction = progress.fractionCompleted
                        Task { await self?.setState(.downloadingModel(progress: fraction)) }
                    }
                )
                guard ModelCatalog.isDownloaded(model, folder: modelFolder) else {
                    throw WhisperError.modelsUnavailable(
                        "The \(model.displayName) download did not complete — some model files are missing. Check the network and try again."
                    )
                }
            }

            setState(.loadingModel)
            let config = WhisperKitConfig(
                downloadBase: modelFolder,
                modelFolder: variantFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            do {
                whisperKit = try await WhisperKit(config)
            } catch {
                // A failure *loading* an already-downloaded model (as opposed
                // to a failure during the download above) almost always
                // means a corrupted/partial previous download — delete it,
                // hub cache included, so the next attempt starts from a
                // clean re-download instead of failing the same way forever.
                ModelCatalog.removeDownload(model, folder: modelFolder)
                throw error
            }
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Transcribes an audio file on-device.
    /// - Parameters:
    ///   - url: audio file (m4a/wav/mp3/caf/aiff — anything AVFoundation reads).
    ///   - language: ISO 639-1 code to force a language, or nil for auto-detect.
    public func transcribe(_ url: URL, language: String? = nil) async throws -> Transcript {
        try await prepare()
        guard let whisperKit else {
            throw WhisperError.modelsUnavailable("Model failed to load")
        }

        setState(.transcribing)
        defer { setState(.ready) }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)

        let segments = results
            .flatMap { $0.segments }
            .sorted { $0.start < $1.start }
            .compactMap { segment -> TranscriptSegment? in
                let text = cleanSegmentText(segment.text)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: text
                )
            }
        let language = results.first?.language ?? language ?? "unknown"
        return Transcript(language: language, segments: segments)
    }

    /// Unloads the model to free memory.
    public func unload() {
        whisperKit = nil
        setState(.idle)
    }

    /// Strips Whisper special tokens like `<|startoftranscript|>` and trims whitespace.
    private func cleanSegmentText(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<|"), let close = text.range(of: "|>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
