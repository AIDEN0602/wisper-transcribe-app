import AVFoundation
import Combine
import WatchConnectivity

/// One recording handed off from the watch to the iPhone.
struct WatchTransfer: Identifiable {
    enum Status {
        case sending          // file transfer to iPhone in progress
        case sent             // file transfer completed
        case processing       // iPhone is uploading to / polling the server
        case waitingForServer // server unreachable — iPhone will retry automatically
        case done             // iPhone finished and saved it to history
        case failed           // either the transfer or the processing failed
    }

    let id: UUID
    let date: Date
    let duration: TimeInterval
    var status: Status
}

/// Records audio on the wrist and hands finished files to the paired
/// iPhone via `WCSession` file transfer. File transfers are queued by
/// WatchConnectivity and resume automatically, so this works even if the
/// phone isn't reachable the moment recording stops.
final class WatchRecorderManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var isPhoneReachable = false
    @Published var transfers: [WatchTransfer] = []
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileURL: URL?
    private var transferIDs: [ObjectIdentifier: UUID] = [:]

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Re-queues any recording still sitting in `pendingFolder` at launch.
    ///
    /// Files are written there while recording and only deleted once the
    /// phone confirms the transfer (see `session(_:didFinish:error:)`). Until
    /// this existed, nothing ever looked in that folder again: if the app was
    /// force-quit, crashed, or was killed by watchOS between the recording
    /// stopping and its transfer completing, the audio stayed on the watch
    /// forever, invisible in the UI and never retried. That is how finished
    /// recordings silently went missing.
    ///
    /// Anything unplayable is kept, not deleted — a recording interrupted
    /// mid-write has no duration to read but is still the only copy of what
    /// was said, so it goes to the phone regardless and is left on disk if
    /// the transfer fails.
    private func recoverOrphanedRecordings() {
        let folder = Self.pendingFolder
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        // WatchConnectivity keeps its own transfer queue across launches, so
        // anything already in flight must not be sent a second time.
        let alreadyQueued = Set(WCSession.default.outstandingFileTransfers.map(\.file.fileURL.lastPathComponent))

        let orphans = files
            .filter { $0.pathExtension == "m4a" }
            .filter { !alreadyQueued.contains($0.lastPathComponent) }
            .filter { $0 != currentFileURL }
            .filter { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 > 0 } ?? false }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }

        for url in orphans {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            send(url, duration: Self.playableDuration(of: url), date: modified)
        }
    }

    /// Length of an already-written recording, or 0 when the file can't be
    /// read — which is what an interrupted recording looks like, since the
    /// index that makes an m4a playable is only written when recording stops
    /// cleanly.
    private static func playableDuration(of url: URL) -> TimeInterval {
        (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    // MARK: - Recording

    private func startRecording() {
        requestMicrophonePermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "Microphone access is required."
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
        } catch {
            errorMessage = Self.describe(error, prefix: "Couldn't prepare audio")
            return
        }

        // watchOS requires the asynchronous activation call — setActive(true)
        // fails here with "Session activation failed" (561015905). Activation
        // can also lose a race with the app becoming frontmost right after an
        // Action Button launch, so give it a few tries before giving up.
        activateSession(attemptsLeft: 4) { [weak self] error in
            guard let self else { return }
            if let error {
                self.errorMessage = Self.describe(error, prefix: "Failed to start recording")
            } else {
                self.startRecorder()
            }
        }
    }

    /// Calls the watchOS-only async activation, retrying briefly on failure.
    /// `completion` runs on the main queue with nil on success.
    private func activateSession(attemptsLeft: Int, completion: @escaping (Error?) -> Void) {
        AVAudioSession.sharedInstance().activate(options: []) { [weak self] activated, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if activated {
                    completion(nil)
                } else if attemptsLeft > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.activateSession(attemptsLeft: attemptsLeft - 1, completion: completion)
                    }
                } else {
                    completion(error ?? NSError(
                        domain: NSOSStatusErrorDomain,
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio session wouldn't activate."]
                    ))
                }
            }
        }
    }

    private func startRecorder() {
        do {
            let folder = Self.pendingFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("watch_recording_\(Self.dateStamp()).m4a")
            currentFileURL = url

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 64000,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                currentFileURL = nil
                try? FileManager.default.removeItem(at: url)
                errorMessage = "Failed to start recording: the recorder did not start."
                return
            }
            self.recorder = recorder

            isRecording = true
            elapsedTime = 0
            errorMessage = nil

            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
        } catch {
            errorMessage = Self.describe(error, prefix: "Failed to start recording")
        }
    }

    /// Advances the display from the amount of audio actually captured.
    ///
    /// A previous version also stopped the recording when this value appeared
    /// unchanged for five timer ticks. That is not a safe signal on watchOS:
    /// UI timers can be delayed while the display sleeps or the app changes
    /// state even though the system audio session is still valid. Treating
    /// those delayed ticks as a stalled recorder caused valid recordings to
    /// be cancelled unexpectedly.
    private func tick() {
        guard let recorder, isRecording else { return }
        elapsedTime = recorder.currentTime
    }

    private func stopRecording() {
        guard isRecording, let recorder else { return }
        // Read from the recorder, not the on-screen timer: this is the length
        // of the audio being handed to the phone, and it's what the history
        // entry and the server job end up labelled with.
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false

        guard let url = currentFileURL else { return }
        currentFileURL = nil
        send(url, duration: duration)
    }

    // MARK: - Sending to iPhone

    /// `date` is when the audio was recorded, which is only "now" for a
    /// recording that just stopped — a recovered one carries its original
    /// file date so the list doesn't relabel old audio as new.
    private func send(_ url: URL, duration: TimeInterval, date: Date = Date()) {
        let id = UUID()
        transfers.insert(WatchTransfer(id: id, date: date, duration: duration, status: .sending), at: 0)
        // The same UUID goes out as file metadata so the iPhone can echo
        // processing-status messages back tagged with this exact ID.
        let transfer = WCSession.default.transferFile(url, metadata: ["recordingID": id.uuidString])
        transferIDs[ObjectIdentifier(transfer)] = id
    }

    /// Applies a status update reported by the iPhone (see
    /// `session(_:didReceiveMessage:)` below) for the transfer matching
    /// `recordingID`, if it's still in the list.
    private func applyStatusUpdate(recordingID: String, status: WatchTransfer.Status) {
        guard let id = UUID(uuidString: recordingID) else { return }
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = status
    }

    private func updateTransfer(_ transfer: WCSessionFileTransfer, status: WatchTransfer.Status) {
        let key = ObjectIdentifier(transfer)
        guard let id = transferIDs[key] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.transfers.firstIndex(where: { $0.id == id }) else { return }
            self.transfers[index].status = status
        }
        transferIDs[key] = nil
    }

    // MARK: - Helpers

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted)
            }
        @unknown default:
            completion(false)
        }
    }

    /// Includes the numeric code — the localized strings for audio-session
    /// failures are all but identical, so the code is what identifies them.
    private static func describe(_ error: Error, prefix: String) -> String {
        let nsError = error as NSError
        return "\(prefix): \(nsError.localizedDescription) (\(nsError.code))"
    }

    private static var pendingFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingRecordings", isDirectory: true)
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

// MARK: - WCSessionDelegate

extension WatchRecorderManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
            // Runs here rather than in `init` because it consults
            // `outstandingFileTransfers`, which isn't populated until the
            // session finishes activating.
            guard activationState == .activated else { return }
            self.recoverOrphanedRecordings()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isPhoneReachable = session.isReachable }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        updateTransfer(fileTransfer, status: error == nil ? .sent : .failed)
        // Only drop the local copy once the phone actually has it. This used
        // to delete unconditionally, so a failed transfer destroyed the only
        // copy of the recording; now a failure leaves the file for
        // `recoverOrphanedRecordings()` to retry on the next launch.
        guard error == nil else { return }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }

    /// The iPhone reports processing progress back as plain messages —
    /// see AppCoordinator.notifyWatch(recordingID:status:) on the phone.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveStatus(message)
    }

    /// Durable counterpart to `didReceiveMessage`: the phone uses this when
    /// the watch is out of range as transcription finishes.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receiveStatus(userInfo)
    }

    private func receiveStatus(_ message: [String: Any]) {
        guard let recordingID = message["recordingID"] as? String,
              let statusRaw = message["status"] as? String
        else { return }

        let status: WatchTransfer.Status
        switch statusRaw {
        case "processing": status = .processing
        case "waiting": status = .waitingForServer
        case "done": status = .done
        case "failed": status = .failed
        default: return
        }

        DispatchQueue.main.async { [weak self] in
            self?.applyStatusUpdate(recordingID: recordingID, status: status)
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension WatchRecorderManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            DispatchQueue.main.async { self.errorMessage = "Recording ended unexpectedly." }
        }
    }
}
