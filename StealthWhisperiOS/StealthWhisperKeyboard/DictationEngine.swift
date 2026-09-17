import Combine
import Foundation

enum DictationState: Equatable {
    case idle
    case sessionUnavailable(String)
    case starting
    case recording
    case transcribingLocal
    case transcribing
    case inserted
    case failed(String)
}

/// Voice-first keyboard controller. The extension never touches the
/// microphone (iOS forbids that); it exchanges small commands with an active
/// Keyboard Session in the containing app, which records and transcribes.
final class DictationEngine: ObservableObject {
    @Published private(set) var state: DictationState = .sessionUnavailable("Open Stealth Whisper and enable Keyboard Session.")
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var isSessionLive = false

    static let appGroupID = "group.com.stealth.whisper"
    static let stateKey = "KeyboardFlowState"
    static let activeSessionKey = "KeyboardFlowActiveSession"
    static let resultSessionKey = "KeyboardFlowResultSession"
    static let stopSessionKey = "KeyboardFlowStopSession"
    static let cancelSessionKey = "KeyboardFlowCancelSession"
    static let startedAtKey = "KeyboardFlowStartedAt"
    static let errorKey = "KeyboardFlowError"
    static let sessionReadyKey = "KeyboardFlowSessionReady"
    static let heartbeatKey = "KeyboardFlowHeartbeat"
    static let inputLevelKey = "KeyboardFlowInputLevel"
    static let transcriptTextKey = "KeyboardTranscriptText"
    static let transcriptMarkerKey = "KeyboardTranscriptID"

    private static let awaitingSessionKey = "KeyboardAwaitingFlowSession"
    private static let lastInsertedMarkerKey = "KeyboardLastInsertedTranscriptID"
    private static let heartbeatTolerance: TimeInterval = 4

    private let insertText: (String) -> Void
    private let hasFullAccess: () -> Bool
    private var timer: Timer?
    private var awaitingSessionID: String?
    private var appLaunchAttemptedAt: Date?

    init(hasFullAccess: @escaping () -> Bool, insertText: @escaping (String) -> Void) {
        self.hasFullAccess = hasFullAccess
        self.insertText = insertText
        awaitingSessionID = UserDefaults.standard.string(forKey: Self.awaitingSessionKey)
        refresh()
    }

    deinit { timer?.invalidate() }

    func startMonitoring() {
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func requestDictation() {
        guard hasFullAccess() else {
            state = .sessionUnavailable("Allow Full Access in Keyboard Settings.")
            return
        }
        guard let shared = UserDefaults(suiteName: Self.appGroupID), sessionIsLive(shared) else {
            isSessionLive = false
            state = .sessionUnavailable("Open Stealth Whisper and enable Keyboard Session.")
            return
        }

        let sessionID = UUID().uuidString
        awaitingSessionID = sessionID
        UserDefaults.standard.set(sessionID, forKey: Self.awaitingSessionKey)
        shared.set(sessionID, forKey: Self.activeSessionKey)
        shared.set("starting", forKey: Self.stateKey)
        shared.removeObject(forKey: Self.errorKey)
        shared.removeObject(forKey: Self.stopSessionKey)
        shared.removeObject(forKey: Self.cancelSessionKey)
        shared.synchronize()
        state = .starting
    }

    func reportAppLaunchAttempt() {
        appLaunchAttemptedAt = Date()
        state = .sessionUnavailable("Opening Stealth Whisper… If it stays here, open the app manually.")
    }

    func stopDictation() {
        guard let sessionID = awaitingSessionID,
              let shared = UserDefaults(suiteName: Self.appGroupID)
        else { return }
        shared.set(sessionID, forKey: Self.stopSessionKey)
        shared.synchronize()
        state = .transcribingLocal
    }

    func cancel() {
        guard let sessionID = awaitingSessionID,
              let shared = UserDefaults(suiteName: Self.appGroupID)
        else { return }
        shared.set(sessionID, forKey: Self.cancelSessionKey)
        shared.synchronize()
        clearAwaitingSession()
        state = isSessionLive ? .idle : .sessionUnavailable("Open Stealth Whisper and enable Keyboard Session.")
    }

    private func refresh() {
        guard hasFullAccess() else {
            isSessionLive = false
            inputLevel = 0
            state = .sessionUnavailable("Allow Full Access in Keyboard Settings.")
            return
        }
        guard let shared = UserDefaults(suiteName: Self.appGroupID) else {
            isSessionLive = false
            state = .sessionUnavailable("Reinstall Stealth Whisper to repair keyboard access.")
            return
        }
        shared.synchronize()
        isSessionLive = sessionIsLive(shared)
        inputLevel = isSessionLive ? min(1, max(0, shared.double(forKey: Self.inputLevelKey))) : 0

        if let started = shared.object(forKey: Self.startedAtKey) as? Date {
            elapsedTime = max(0, Date().timeIntervalSince(started))
        } else {
            elapsedTime = 0
        }

        let sharedState = shared.string(forKey: Self.stateKey) ?? "idle"
        if sharedState == "ready" {
            insertReadyTranscript(from: shared)
            return
        }

        if !isSessionLive {
            if awaitingSessionID != nil && (sharedState == "recording" || sharedState.hasPrefix("transcribing")) {
                state = .failed("Keyboard Session disconnected. Your audio remains in Stealth Whisper.")
            } else if let attempted = appLaunchAttemptedAt,
                      Date().timeIntervalSince(attempted) < 3 {
                state = .sessionUnavailable("Opening Stealth Whisper… If it stays here, open the app manually.")
            } else {
                state = .sessionUnavailable("Open Stealth Whisper and enable Keyboard Session.")
            }
            return
        }

        switch sharedState {
        case "starting": state = .starting
        case "recording": state = .recording
        case "transcribing-local": state = .transcribingLocal
        case "transcribing": state = .transcribing
        case "error":
            state = .failed(shared.string(forKey: Self.errorKey) ?? "Dictation failed. Your audio was saved.")
            clearAwaitingSession()
        default:
            if awaitingSessionID == nil { state = .idle }
        }
    }

    private func sessionIsLive(_ shared: UserDefaults) -> Bool {
        guard shared.bool(forKey: Self.sessionReadyKey),
              let heartbeat = shared.object(forKey: Self.heartbeatKey) as? Date
        else { return false }
        return abs(Date().timeIntervalSince(heartbeat)) < Self.heartbeatTolerance
    }

    private func insertReadyTranscript(from shared: UserDefaults) {
        guard let sessionID = awaitingSessionID,
              shared.string(forKey: Self.resultSessionKey) == sessionID,
              let marker = shared.string(forKey: Self.transcriptMarkerKey),
              marker != UserDefaults.standard.string(forKey: Self.lastInsertedMarkerKey),
              let text = shared.string(forKey: Self.transcriptTextKey),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        insertText(text)
        UserDefaults.standard.set(marker, forKey: Self.lastInsertedMarkerKey)
        clearAwaitingSession()
        shared.set("idle", forKey: Self.stateKey)
        shared.removeObject(forKey: Self.activeSessionKey)
        shared.removeObject(forKey: Self.stopSessionKey)
        shared.removeObject(forKey: Self.cancelSessionKey)
        shared.removeObject(forKey: Self.startedAtKey)
        shared.synchronize()
        state = .inserted
    }

    private func clearAwaitingSession() {
        awaitingSessionID = nil
        UserDefaults.standard.removeObject(forKey: Self.awaitingSessionKey)
    }
}
