import Foundation

/// Where a recording gets transcribed. Applies to every recording, phone
/// or watch — the previous watch-only "process on server" toggle has been
/// replaced by this single picker per Minje's privacy requirement: the
/// on-device engine (and its ~1.7GB model download) must never run unless
/// he explicitly opts into it here.
enum ProcessingMode: String, Codable {
    case server
    case onDevice
}

/// Small set of app-wide settings persisted via UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let serverMode = "ServerModeEnabled"
        static let removeFillerWords = "RemoveFillerWordsEnabled"
        static let processingMode = "ProcessingMode"
    }

    /// Legacy "Server mode": also copies finished recordings into the
    /// shared iCloud folder the OLD Mac-mini watch-folder pipeline polls.
    /// Off by default; unrelated to `processingMode` below, which is the
    /// new direct HTTP API path.
    @Published var serverModeEnabled: Bool {
        didSet { UserDefaults.standard.set(serverModeEnabled, forKey: Keys.serverMode) }
    }

    /// Strips filler words/stutters (see Shared/TextCleaner.swift) from
    /// finished transcripts. On by default. Only meaningful in `.onDevice`
    /// mode — server-side cleanup, if any, happens on the server itself.
    @Published var removeFillerWordsEnabled: Bool {
        didSet { UserDefaults.standard.set(removeFillerWordsEnabled, forKey: Keys.removeFillerWords) }
    }

    /// Default `.server`: every recording (phone or watch) uploads to the
    /// home server for transcription + diarization + summary. Switching to
    /// `.onDevice` is the *only* thing that ever triggers a WhisperCore
    /// model download — it must never happen implicitly (app launch,
    /// server being unreachable, etc).
    @Published var processingMode: ProcessingMode {
        didSet { UserDefaults.standard.set(processingMode.rawValue, forKey: Keys.processingMode) }
    }

    private init() {
        serverModeEnabled = UserDefaults.standard.bool(forKey: Keys.serverMode)
        removeFillerWordsEnabled = (UserDefaults.standard.object(forKey: Keys.removeFillerWords) as? Bool) ?? true
        let savedMode = UserDefaults.standard.string(forKey: Keys.processingMode).flatMap(ProcessingMode.init(rawValue:))
        processingMode = savedMode ?? .server
    }
}
