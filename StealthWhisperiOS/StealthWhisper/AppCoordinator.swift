import AVFoundation
import Foundation
import WatchConnectivity
import WhisperCore

/// Ties the recorder, the on-device transcriber, the server upload path,
/// and history together. `AppSettings.shared.processingMode` decides
/// where transcription happens for *every* recording — phone or watch —
/// `.server` by default. The on-device engine is never touched (no
/// warm-up, no model download) unless the user explicitly switches to
/// `.onDevice`, so its ~1.7GB download can never happen implicitly.
@MainActor
final class AppCoordinator: ObservableObject {
    let recorder: AudioRecorderManager
    let transcription: TranscriptionManager
    let history: HistoryStore
    let pendingUploads: PendingUploadStore
    private let serverClient = ServerUploadManager.shared

    @Published var currentTranscript: Transcript?
    @Published var isTranscribing = false
    @Published var lastError: String?
    @Published private(set) var isKeyboardDictation = false
    @Published private(set) var keyboardTranscriptReady = false
    @Published private(set) var isKeyboardFlowSessionEnabled = false
    @Published private(set) var isKeyboardLocalTranscriptionReady = false
    @Published private(set) var keyboardLocalTranscriptionMessage = "On-device English model not prepared"

    private static let keyboardAppGroupID = "group.com.stealth.whisper"
    private static let keyboardTranscriptTextKey = "KeyboardTranscriptText"
    private static let keyboardTranscriptMarkerKey = "KeyboardTranscriptID"
    private static let keyboardPendingFilenameKey = "KeyboardPendingRecordingFilename"
    private static let keyboardStateKey = "KeyboardFlowState"
    private static let keyboardActiveSessionKey = "KeyboardFlowActiveSession"
    private static let keyboardResultSessionKey = "KeyboardFlowResultSession"
    private static let keyboardStopSessionKey = "KeyboardFlowStopSession"
    private static let keyboardCancelSessionKey = "KeyboardFlowCancelSession"
    private static let keyboardStartedAtKey = "KeyboardFlowStartedAt"
    private static let keyboardErrorKey = "KeyboardFlowError"
    private static let keyboardSessionReadyKey = "KeyboardFlowSessionReady"
    private static let keyboardHeartbeatKey = "KeyboardFlowHeartbeat"
    private static let keyboardInputLevelKey = "KeyboardFlowInputLevel"
    private var keyboardDictationFilename: String?
    private var keyboardSessionID: String?
    private var keyboardCommandTimer: Timer?

    /// A foreground event can fire more than once while a previous retry is
    /// still running. Keep one pipeline per file so the server never receives
    /// duplicate jobs for the same recording.
    private var activeServerFiles: Set<String> = []
    private var activeOperationCount = 0

    init(
        recorder: AudioRecorderManager,
        transcription: TranscriptionManager,
        history: HistoryStore,
        pendingUploads: PendingUploadStore
    ) {
        self.recorder = recorder
        self.transcription = transcription
        self.history = history
        self.pendingUploads = pendingUploads
        clearStaleKeyboardSession()

        // Deliberately no `transcription.warmUp()` here — server is the
        // default path and app launch must never trigger a model download.
        recorder.onRecordingFinished = { [weak self] url in
            guard let self else { return }
            if self.isKeyboardDictation {
                self.keyboardDictationFilename = url.lastPathComponent
                UserDefaults.standard.set(url.lastPathComponent, forKey: Self.keyboardPendingFilenameKey)
                self.setKeyboardState("transcribing")
            }
            self.handleFinishedRecording(url, source: .iphone, recordingID: nil)
        }
        WatchConnectivityManager.shared.onFileReceived = { [weak self] url, recordingID in
            self?.handleFinishedRecording(url, source: .watch, recordingID: recordingID)
        }
    }

    func toggleRecording() {
        if recorder.isRecording {
            if isKeyboardDictation {
                stopKeyboardDictation()
                return
            }
            guard let url = recorder.stopRecording() else { return }
            handleFinishedRecording(url, source: .iphone, recordingID: nil)
        } else {
            if isKeyboardFlowSessionEnabled { disableKeyboardFlowSession() }
            recorder.startRecording()
        }
    }

    /// Enables a persistent, user-visible microphone session in the containing
    /// app. The extension cannot use the microphone; while this is enabled it
    /// only sends start/stop/cancel commands through the App Group. Standby
    /// audio is discarded by AudioRecorderManager and never written to disk.
    func enableKeyboardFlowSession() {
        guard !isKeyboardFlowSessionEnabled else {
            publishKeyboardHeartbeat()
            return
        }
        guard !recorder.isRecording else {
            lastError = "Stop the current recording before enabling Keyboard Session."
            return
        }
        recorder.startKeyboardSession { [weak self] started in
            guard let self else { return }
            guard started else {
                self.lastError = self.recorder.errorMessage ?? "Keyboard Session couldn't start."
                self.setKeyboardError(self.lastError ?? "Keyboard Session couldn't start.")
                return
            }
            self.isKeyboardFlowSessionEnabled = true
            self.setKeyboardState("idle")
            self.publishKeyboardHeartbeat()
            self.startKeyboardCommandPolling()
            self.prepareKeyboardLocalTranscription()
        }
    }

    func disableKeyboardFlowSession() {
        if isKeyboardDictation { cancelKeyboardDictation() }
        isKeyboardFlowSessionEnabled = false
        recorder.stopKeyboardSession()
        keyboardCommandTimer?.invalidate()
        keyboardCommandTimer = nil
        clearStaleKeyboardSession()
    }

    private func beginKeyboardDictation(sessionID: String) {
        guard isKeyboardFlowSessionEnabled, !recorder.isRecording else {
            setKeyboardError("Keyboard Session is not ready. Open Stealth Whisper and enable it again.")
            return
        }
        keyboardTranscriptReady = false
        isKeyboardDictation = true
        keyboardSessionID = sessionID
        keyboardDictationFilename = nil
        UserDefaults.standard.removeObject(forKey: Self.keyboardPendingFilenameKey)
        if let shared = UserDefaults(suiteName: Self.keyboardAppGroupID) {
            shared.removeObject(forKey: Self.keyboardStopSessionKey)
            shared.removeObject(forKey: Self.keyboardCancelSessionKey)
            shared.removeObject(forKey: Self.keyboardErrorKey)
            shared.synchronize()
        }
        setKeyboardState("starting")
        recorder.startKeyboardRecording { [weak self] started in
            guard let self else { return }
            if started {
                guard let shared = UserDefaults(suiteName: Self.keyboardAppGroupID) else { return }
                shared.set(sessionID, forKey: Self.keyboardActiveSessionKey)
                shared.set(Date(), forKey: Self.keyboardStartedAtKey)
                shared.set("recording", forKey: Self.keyboardStateKey)
                shared.removeObject(forKey: Self.keyboardErrorKey)
                shared.synchronize()
            } else {
                self.isKeyboardDictation = false
                self.keyboardSessionID = nil
                UserDefaults.standard.removeObject(forKey: Self.keyboardPendingFilenameKey)
                self.setKeyboardError(self.recorder.errorMessage ?? "The microphone couldn't start.")
            }
        }
    }

    private func stopKeyboardDictation() {
        guard isKeyboardDictation, let url = recorder.stopRecording() else { return }
        keyboardDictationFilename = url.lastPathComponent
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.keyboardPendingFilenameKey)
        setKeyboardState("transcribing-local")
        processKeyboardOnDevice(url: url)
    }

    private func cancelKeyboardDictation() {
        _ = recorder.cancelKeyboardRecording()
        isKeyboardDictation = false
        keyboardDictationFilename = nil
        keyboardSessionID = nil
        UserDefaults.standard.removeObject(forKey: Self.keyboardPendingFilenameKey)
        guard let shared = UserDefaults(suiteName: Self.keyboardAppGroupID) else { return }
        shared.set("idle", forKey: Self.keyboardStateKey)
        shared.removeObject(forKey: Self.keyboardActiveSessionKey)
        shared.removeObject(forKey: Self.keyboardStopSessionKey)
        shared.removeObject(forKey: Self.keyboardCancelSessionKey)
        shared.removeObject(forKey: Self.keyboardStartedAtKey)
        shared.removeObject(forKey: Self.keyboardErrorKey)
        shared.synchronize()
    }

    func dismissKeyboardTranscriptReady() {
        keyboardTranscriptReady = false
    }

    private func prepareKeyboardLocalTranscription() {
        keyboardLocalTranscriptionMessage = "Preparing private on-device English model…"
        Task {
            do {
                try await FastOnDeviceTranscriber.prepare()
                isKeyboardLocalTranscriptionReady = true
                keyboardLocalTranscriptionMessage = "On-device English · no Mac round trip"
            } catch {
                isKeyboardLocalTranscriptionReady = false
                keyboardLocalTranscriptionMessage = "Mac mini fallback · \(error.localizedDescription)"
            }
        }
    }

    private func processKeyboardOnDevice(url: URL) {
        let duration = Self.audioDuration(at: url)
        Task {
            beginOperation()
            defer { endOperation() }
            do {
                let rawText = try await FastOnDeviceTranscriber.transcribe(fileURL: url)
                let text = AppSettings.shared.removeFillerWordsEnabled ? TextCleaner.clean(rawText) : rawText
                history.addEntry(
                    source: .iphone,
                    durationSeconds: duration,
                    language: "en",
                    text: text,
                    segments: [],
                    audioURL: url
                )
                isKeyboardLocalTranscriptionReady = true
                keyboardLocalTranscriptionMessage = "On-device English · no Mac round trip"
                publishLatestTranscript(text, fileURL: url)
            } catch {
                // Keep the original recoverable server pipeline as a fallback
                // for a missing model, denied permission, or analyzer error.
                isKeyboardLocalTranscriptionReady = false
                keyboardLocalTranscriptionMessage = "Mac mini fallback · local transcription unavailable"
                setKeyboardState("transcribing")
                handleFinishedRecording(url, source: .iphone, recordingID: nil)
            }
        }
    }

    private func handleFinishedRecording(_ url: URL, source: HistorySource, recordingID: String?) {
        let duration = Self.audioDuration(at: url)
        switch AppSettings.shared.processingMode {
        case .server:
            processOnServer(url: url, source: source, duration: duration, recordingID: recordingID, pendingID: nil)
        case .onDevice:
            transcribeOnDevice(url: url, source: source, duration: duration, recordingID: recordingID)
        }
    }

    /// Uploads to the home server. On failure this deliberately does
    /// **not** fall back to on-device (that would trigger the ~1.7GB model
    /// download server mode exists to avoid) — instead the recording is
    /// persisted in `pendingUploads` before networking begins and shown as
    /// "Waiting for server" until the server finishes. That ordering makes
    /// a background upload recoverable even if iOS terminates the app.
    private func processOnServer(url: URL, source: HistorySource, duration: TimeInterval, recordingID: String?, pendingID: UUID?) {
        // Queue first, upload second. If iOS terminates the app while its
        // background upload is running, the next launch now has a durable
        // record to retry instead of losing track of the audio forever.
        let queuedID = pendingID ?? pendingUploads.add(
            audioFilename: url.lastPathComponent,
            source: source,
            durationSeconds: duration,
            recordingID: recordingID
        ).id
        guard activeServerFiles.insert(url.lastPathComponent).inserted else { return }

        Task {
            beginOperation()
            defer {
                activeServerFiles.remove(url.lastPathComponent)
                endOperation()
            }
            notifyWatch(recordingID: recordingID, status: "processing")
            do {
                let isKeyboardRequest = isKeyboardDictation && keyboardDictationFilename == url.lastPathComponent
                let result = try await serverClient.processRecording(
                    fileURL: url,
                    diarize: !isKeyboardRequest,
                    express: isKeyboardRequest
                )
                history.addEntry(
                    source: source,
                    durationSeconds: duration,
                    language: result.language ?? "unknown",
                    text: result.text,
                    segments: result.segments,
                    audioURL: url,
                    title: result.summaryTitle,
                    id: result.jobID.map(ServerHistorySync.entryID(forJob:)) ?? UUID()
                )
                pendingUploads.remove(id: queuedID)
                publishLatestTranscript(result.text, fileURL: url)
                notifyWatch(recordingID: recordingID, status: "done")
            } catch {
                if isKeyboardDictation, keyboardDictationFilename == url.lastPathComponent {
                    setKeyboardError("Transcription failed. The audio is saved in Stealth Whisper.")
                    isKeyboardDictation = false
                    keyboardDictationFilename = nil
                    keyboardSessionID = nil
                    UserDefaults.standard.removeObject(forKey: Self.keyboardPendingFilenameKey)
                }
                notifyWatch(recordingID: recordingID, status: "waiting")
            }
        }
    }

    /// Retries every queued recording. Called on cold launch, foregrounding,
    /// and from the visible "Retry now" control.
    func retryPendingUploads() {
        guard AppSettings.shared.processingMode == .server else { return }
        for pending in pendingUploads.items {
            let url = AudioRecorderManager.recordingsFolder.appendingPathComponent(pending.audioFilename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                pendingUploads.remove(id: pending.id)
                continue
            }
            processOnServer(
                url: url,
                source: pending.source,
                duration: pending.durationSeconds,
                recordingID: pending.recordingID,
                pendingID: pending.id
            )
        }
    }

    /// Only reachable via the "On-device" processing mode in Settings.
    private func transcribeOnDevice(url: URL, source: HistorySource, duration: TimeInterval, recordingID: String?) {
        Task {
            beginOperation()
            defer { endOperation() }
            do {
                let raw = try await transcription.transcribe(url)
                let transcript = AppSettings.shared.removeFillerWordsEnabled ? Self.applyFillerCleanup(to: raw) : raw
                if source == .iphone {
                    currentTranscript = transcript
                }
                publishLatestTranscript(TranscriptFormatter.plainText(transcript), fileURL: url)
                history.addEntry(
                    source: source,
                    durationSeconds: duration,
                    language: transcript.language,
                    text: TranscriptFormatter.plainText(transcript),
                    segments: transcript.segments.map { HistorySegment(start: $0.start, end: $0.end, text: $0.text) },
                    audioURL: url
                )
                if source == .watch { notifyWatch(recordingID: recordingID, status: "done") }
            } catch {
                lastError = "Transcription failed: \(error.localizedDescription)"
                if isKeyboardDictation, keyboardDictationFilename == url.lastPathComponent {
                    setKeyboardError("Transcription failed. The audio is saved in Stealth Whisper.")
                    isKeyboardDictation = false
                    keyboardDictationFilename = nil
                    keyboardSessionID = nil
                    UserDefaults.standard.removeObject(forKey: Self.keyboardPendingFilenameKey)
                }
                if source == .watch { notifyWatch(recordingID: recordingID, status: "failed") }
            }
        }
    }

    /// Best-effort status echo back to the watch so its transfer list can
    /// show "Transcribing…"/"Waiting for server"/"Done" beyond the
    /// file-transfer completion it already knows about on its own.
    /// Falls back to durable user-info delivery if the watch isn't reachable.
    private func notifyWatch(recordingID: String?, status: String) {
        guard let recordingID, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload = ["recordingID": recordingID, "status": status]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            // Unlike an immediate message, user info waits for the watch to
            // reconnect. Final status therefore survives the watch leaving
            // range while the server is transcribing.
            WCSession.default.transferUserInfo(payload)
        }
    }

    private func beginOperation() {
        activeOperationCount += 1
        isTranscribing = true
    }

    private func endOperation() {
        activeOperationCount = max(0, activeOperationCount - 1)
        isTranscribing = activeOperationCount > 0
    }

    /// Publishes every successful transcript to the read-only App Group used
    /// by the keyboard. This no longer depends on a keyboard-initiated deep
    /// link, because iOS doesn't allow keyboard extensions to open their
    /// containing app.
    private func publishLatestTranscript(_ text: String, fileURL: URL) {
        let marker = UUID().uuidString
        guard let shared = UserDefaults(suiteName: Self.keyboardAppGroupID) else {
            lastError = "Couldn't share the transcript with the keyboard. Reinstall the app to refresh its App Group permission."
            return
        }
        shared.set(text, forKey: Self.keyboardTranscriptTextKey)
        shared.set(marker, forKey: Self.keyboardTranscriptMarkerKey)
        shared.synchronize()
        if isKeyboardDictation, keyboardDictationFilename == fileURL.lastPathComponent {
            if let keyboardSessionID {
                shared.set(keyboardSessionID, forKey: Self.keyboardResultSessionKey)
            }
            shared.set("ready", forKey: Self.keyboardStateKey)
            shared.removeObject(forKey: Self.keyboardErrorKey)
            shared.synchronize()
            isKeyboardDictation = false
            keyboardDictationFilename = nil
            UserDefaults.standard.removeObject(forKey: Self.keyboardPendingFilenameKey)
            keyboardTranscriptReady = true
            keyboardSessionID = nil
        }
    }

    private func startKeyboardCommandPolling() {
        keyboardCommandTimer?.invalidate()
        keyboardCommandTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isKeyboardFlowSessionEnabled,
                      let shared = UserDefaults(suiteName: Self.keyboardAppGroupID)
                else { return }
                shared.synchronize()

                self.publishKeyboardHeartbeat(shared: shared)

                if self.isKeyboardDictation, let sessionID = self.keyboardSessionID {
                    if shared.string(forKey: Self.keyboardCancelSessionKey) == sessionID {
                        self.cancelKeyboardDictation()
                    } else if shared.string(forKey: Self.keyboardStopSessionKey) == sessionID {
                        self.stopKeyboardDictation()
                    }
                    return
                }

                guard !self.recorder.isRecording,
                      shared.string(forKey: Self.keyboardStateKey) == "starting",
                      let requestedSession = shared.string(forKey: Self.keyboardActiveSessionKey),
                      !requestedSession.isEmpty
                else { return }
                if shared.string(forKey: Self.keyboardCancelSessionKey) == requestedSession {
                    self.cancelKeyboardDictation()
                    return
                }
                self.beginKeyboardDictation(sessionID: requestedSession)
            }
        }
        RunLoop.main.add(keyboardCommandTimer!, forMode: .common)
    }

    private func publishKeyboardHeartbeat(shared: UserDefaults? = nil) {
        guard isKeyboardFlowSessionEnabled,
              let shared = shared ?? UserDefaults(suiteName: Self.keyboardAppGroupID)
        else { return }
        shared.set(true, forKey: Self.keyboardSessionReadyKey)
        shared.set(Date(), forKey: Self.keyboardHeartbeatKey)
        shared.set(recorder.inputLevel, forKey: Self.keyboardInputLevelKey)
        shared.synchronize()
    }

    private func clearStaleKeyboardSession() {
        guard let shared = UserDefaults(suiteName: Self.keyboardAppGroupID) else { return }
        shared.set(false, forKey: Self.keyboardSessionReadyKey)
        shared.removeObject(forKey: Self.keyboardHeartbeatKey)
        shared.removeObject(forKey: Self.keyboardInputLevelKey)
        shared.removeObject(forKey: Self.keyboardActiveSessionKey)
        shared.removeObject(forKey: Self.keyboardStopSessionKey)
        shared.removeObject(forKey: Self.keyboardCancelSessionKey)
        shared.removeObject(forKey: Self.keyboardStartedAtKey)
        if shared.string(forKey: Self.keyboardStateKey) != "ready" {
            shared.set("idle", forKey: Self.keyboardStateKey)
            shared.removeObject(forKey: Self.keyboardErrorKey)
        }
        shared.synchronize()
    }

    func refreshKeyboardFlowSession() {
        if isKeyboardFlowSessionEnabled {
            publishKeyboardHeartbeat()
            if keyboardCommandTimer == nil { startKeyboardCommandPolling() }
        }
    }

    func suspendKeyboardFlowSessionIfNeeded() {
        // The active audio engine is what keeps the command bridge alive in
        // the background. No state mutation is needed when the scene resigns.
        if isKeyboardFlowSessionEnabled {
            publishKeyboardHeartbeat()
        }
    }

    private func setKeyboardState(_ state: String) {
        guard let shared = UserDefaults(suiteName: Self.keyboardAppGroupID) else { return }
        shared.set(state, forKey: Self.keyboardStateKey)
        if let keyboardSessionID { shared.set(keyboardSessionID, forKey: Self.keyboardActiveSessionKey) }
        shared.synchronize()
    }

    private func setKeyboardError(_ message: String) {
        guard let shared = UserDefaults(suiteName: Self.keyboardAppGroupID) else { return }
        shared.set(message, forKey: Self.keyboardErrorKey)
        shared.set("error", forKey: Self.keyboardStateKey)
        shared.synchronize()
    }

    private static func audioDuration(at url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Runs the rule-based filler-word/stutter cleaner (Shared/TextCleaner)
    /// over each segment, so both the plain-text and timestamped views stay
    /// consistent. This is a *finished* transcript (Whisper has no partial
    /// streaming concept here), matching "final results only".
    private static func applyFillerCleanup(to transcript: Transcript) -> Transcript {
        let cleanedSegments = transcript.segments.map {
            TranscriptSegment(start: $0.start, end: $0.end, text: TextCleaner.clean($0.text))
        }
        return Transcript(language: transcript.language, segments: cleanedSegments, recordedAt: transcript.recordedAt)
    }
}
