import AVFoundation
import Foundation

/// Records microphone audio to an AAC `.m4a` file, matching the format the
/// existing iOS app and server pipeline use.
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {

    struct Recording {
        let url: URL
        let duration: TimeInterval
        let startedAt: Date
    }

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Where finished recordings are kept.
    static var recordingsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperApps/Recordings", isDirectory: true)
    }

    /// Asks for microphone access; calls back on the main thread.
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        let folder = Self.recordingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = folder.appendingPathComponent("recording_\(formatter.string(from: Date())).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.record() else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not start recording (no microphone access?)",
            ])
        }
        self.recorder = recorder
        startedAt = Date()
    }

    /// Stops and returns the finished recording, or nil if nothing was recording.
    func stop() -> Recording? {
        guard let recorder, let startedAt else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.startedAt = nil
        return Recording(url: recorder.url, duration: duration, startedAt: startedAt)
    }

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        self.recorder = nil
        startedAt = nil
    }

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
}
