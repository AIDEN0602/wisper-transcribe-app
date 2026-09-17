import AVFoundation
import Combine

/// Records microphone audio on the iPhone and hands the finished file off
/// for on-device transcription.
///
/// - Live Activity, Now Playing, and ActivityKit are never used (stealth
///   is the point). The `.record` audio session category (instead of
///   `.playAndRecord`) keeps lock-screen media controls from appearing.
/// - The orange Dynamic Island dot is shown by iOS itself as the
///   microphone-in-use indicator and cannot be suppressed.
final class AudioRecorderManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var errorMessage: String?
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var isKeyboardSessionActive = false

    /// Called only when the recorder ends because of an audio-system
    /// interruption. Manual stops return their URL directly to
    /// AppCoordinator and do not use this callback.
    var onRecordingFinished: ((URL) -> Void)?

    // MARK: - Private

    private var audioRecorder: AVAudioRecorder?
    private var keyboardStandbyEngine: AVAudioEngine?
    private var timer: Timer?
    private var currentFileURL: URL?

    // MARK: - Storage

    /// Local recordings folder, always used regardless of Server mode.
    static var recordingsFolder: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Public API

    func startRecording(completion: ((Bool) -> Void)? = nil) {
        requestMicrophonePermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "Microphone access is required. Enable it in Settings."
                    completion?(false)
                    return
                }
                self.beginRecording(filenamePrefix: "recording", completion: completion)
            }
        }
    }

    /// Keeps the containing app's microphone session alive while the user is
    /// in another app. iOS keyboard extensions cannot access the microphone,
    /// so the keyboard sends commands through the App Group and this process
    /// performs the actual recording. Standby buffers are discarded and no
    /// audio file is created until dictation starts.
    func startKeyboardSession(completion: ((Bool) -> Void)? = nil) {
        requestMicrophonePermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "Microphone access is required. Enable it in Settings."
                    completion?(false)
                    return
                }
                guard !self.isRecording else {
                    self.errorMessage = "Stop the current recording before starting Keyboard Session."
                    completion?(false)
                    return
                }
                self.isKeyboardSessionActive = true
                let started = self.startKeyboardStandbyEngine()
                if !started { self.isKeyboardSessionActive = false }
                completion?(started)
            }
        }
    }

    func stopKeyboardSession() {
        isKeyboardSessionActive = false
        stopKeyboardStandbyEngine(deactivateSession: !isRecording)
        inputLevel = 0
    }

    func startKeyboardRecording(completion: ((Bool) -> Void)? = nil) {
        guard isKeyboardSessionActive else {
            errorMessage = "Keyboard Session is not active."
            completion?(false)
            return
        }
        stopKeyboardStandbyEngine(deactivateSession: false)
        beginRecording(filenamePrefix: "keyboard_recording", completion: completion)
    }

    @discardableResult
    func cancelKeyboardRecording() -> URL? {
        let url = finishRecording(notifyCoordinator: false)
        if let url { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Stops recording and returns the finished file's URL, or nil if
    /// nothing was recording.
    @discardableResult
    func stopRecording() -> URL? {
        finishRecording(notifyCoordinator: false)
    }

    @discardableResult
    private func finishRecording(notifyCoordinator: Bool) -> URL? {
        guard isRecording, let audioRecorder else { return nil }

        // Clear observable state before calling stop(). AVAudioRecorder may
        // synchronously invoke its delegate, and doing this first prevents a
        // manual stop from being processed twice.
        timer?.invalidate()
        timer = nil
        isRecording = false
        self.audioRecorder = nil
        elapsedTime = audioRecorder.currentTime
        inputLevel = 0

        let url = currentFileURL
        currentFileURL = nil
        audioRecorder.stop()

        if isKeyboardSessionActive {
            _ = startKeyboardStandbyEngine()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        if AppSettings.shared.serverModeEnabled, let url {
            uploadToICloud(from: url)
        }
        if notifyCoordinator, let url { onRecordingFinished?(url) }
        return url
    }

    // MARK: - Private: Setup

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

    private func beginRecording(filenamePrefix: String, completion: ((Bool) -> Void)?) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let filename = "\(filenamePrefix)_\(Self.dateStamp()).m4a"
            let url = Self.recordingsFolder.appendingPathComponent(filename)
            currentFileURL = url

            // AAC, 44100Hz, mono, 128kbps — matches the existing pipeline's format.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 128000,
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw NSError(
                    domain: "AudioRecorderManager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone did not start recording."]
                )
            }
            audioRecorder = recorder

            isRecording = true
            elapsedTime = 0
            errorMessage = nil

            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.audioRecorder, self.isRecording else { return }
                recorder.updateMeters()
                self.elapsedTime = recorder.currentTime
                self.inputLevel = Self.normalizedLevel(decibels: recorder.averagePower(forChannel: 0))
            }
            completion?(true)
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            if isKeyboardSessionActive { _ = startKeyboardStandbyEngine() }
            completion?(false)
        }
    }

    /// Runs a silent input tap so iOS keeps this containing app eligible for
    /// background microphone work. The buffers are intentionally ignored.
    private func startKeyboardStandbyEngine() -> Bool {
        stopKeyboardStandbyEngine(deactivateSession: false)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { _, _ in }
            engine.prepare()
            try engine.start()
            keyboardStandbyEngine = engine
            errorMessage = nil
            return true
        } catch {
            stopKeyboardStandbyEngine(deactivateSession: true)
            errorMessage = "Keyboard Session couldn't start: \(error.localizedDescription)"
            return false
        }
    }

    private func stopKeyboardStandbyEngine(deactivateSession: Bool) {
        if let engine = keyboardStandbyEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            keyboardStandbyEngine = nil
        }
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Private: Server mode (optional iCloud upload, off by default)

    private func uploadToICloud(from localURL: URL) {
        guard let containerURL = FileManager.default
            .url(forUbiquityContainerIdentifier: "iCloud.com.stealth.whisper")?
            .appendingPathComponent("Documents")
        else {
            errorMessage = "iCloud is unavailable. Check that iCloud Drive is enabled."
            return
        }

        do {
            try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
            let destURL = containerURL.appendingPathComponent(localURL.lastPathComponent)
            try FileManager.default.copyItem(at: localURL, to: destURL)
        } catch {
            errorMessage = "iCloud upload failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func normalizedLevel(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        // -50 dB is effectively silence for the compact keyboard waveform.
        return min(1, max(0, Double(decibels + 50) / 50))
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorderManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.audioRecorder === recorder, self.isRecording else { return }
            if !flag { self.errorMessage = "Recording was interrupted. The captured audio was saved." }
            _ = self.finishRecording(notifyCoordinator: true)
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { self.errorMessage = "Recording encode error: \(error.localizedDescription)" }
    }
}
