import AVFoundation
import Foundation
import Speech

/// Uses Apple's iOS 26 speech model for short keyboard dictation. The model
/// runs entirely on the phone and lives in system storage, so keyboard text
/// does not need a Mac-mini network round trip.
enum FastOnDeviceTranscriber {
    enum TranscriptionError: LocalizedError {
        case unsupportedOS
        case authorizationDenied
        case localeUnavailable
        case modelUnavailable
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .unsupportedOS: return "Fast on-device dictation requires iOS 26 or later."
            case .authorizationDenied: return "Speech Recognition access is required for local dictation."
            case .localeUnavailable: return "English on-device transcription is unavailable on this device."
            case .modelUnavailable: return "The English speech model couldn't be reserved on this device."
            case .emptyResult: return "No speech was detected."
            }
        }
    }

    static func prepare() async throws {
        guard #available(iOS 26.0, *) else { throw TranscriptionError.unsupportedOS }
        guard await requestAuthorization() else { throw TranscriptionError.authorizationDenied }
        _ = try await preparedTranscriber()
    }

    static func transcribe(fileURL: URL) async throws -> String {
        guard #available(iOS 26.0, *) else { throw TranscriptionError.unsupportedOS }
        guard await requestAuthorization() else { throw TranscriptionError.authorizationDenied }

        let transcriber = try await preparedTranscriber()
        let audioFile = try AVAudioFile(forReading: fileURL)
        async let resultText: String = transcriber.results.reduce(into: "") { text, result in
            text += String(result.text.characters)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let finalSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: finalSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = try await resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyResult }
        return text
    }

    @available(iOS 26.0, *)
    private static func preparedTranscriber() async throws -> SpeechTranscriber {
        let requestedLocale = Locale(identifier: "en-US")
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        else { throw TranscriptionError.localeUnavailable }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let reserved = try await AssetInventory.reserve(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard reserved || status == .installed else { throw TranscriptionError.modelUnavailable }

        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
