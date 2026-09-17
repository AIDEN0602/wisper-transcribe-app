import AppKit
import AVFoundation
import Combine
import Foundation
import WhisperCore

/// Everything the window and the menu bar both need: the recorder, the
/// on-device engine, history, and — crucially — the errors, which used to
/// live in a menu-bar row nobody ever opened.
@MainActor
final class RecordingController: ObservableObject {

    /// One instance drives the window, the menu bar item, and the app
    /// delegate's quit handling.
    static let shared = RecordingController()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var engineState: WhisperTranscriber.State = .idle
    @Published private(set) var isTranscribing = false
    @Published private(set) var unfinished: [UnfinishedRecording] = []
    @Published private(set) var pendingUploadCount = 0
    /// Last failure, shown as a banner until dismissed or superseded.
    @Published var lastError: String?
    /// Set when a transcript is copied, so the UI can confirm it briefly.
    @Published var lastCopiedAt: Date?

    /// Whether the Mac mini answered the last time we asked, so the window
    /// can say where recordings are going.
    @Published private(set) var serverReachable: Bool?

    let history = HistoryStore()
    let transcription = TranscriptionService()

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyManager()
    private let serverClient = ServerClient()
    private let serverSync = ServerHistorySync()
    private var timer: Timer?
    private var syncTimer: Timer?
    private var processingURLs: Set<URL> = []
    private var isSharing = false

    /// A recording left in the staging folder because it was never
    /// transcribed — usually because the app was quit mid-recording.
    struct UnfinishedRecording: Identifiable, Equatable {
        let id: URL
        let createdAt: Date
        let sizeBytes: Int
        let isPlayable: Bool
        var url: URL { id }
        var name: String { id.lastPathComponent }
    }

    init() {
        hotkey.onHotkey = { [weak self] in self?.toggleRecording() }
        hotkey.register()
        transcription.onStateChange = { [weak self] state in
            self?.engineState = state
            if case let .failed(message) = state { self?.lastError = message }
        }
        transcription.warmUp()
        refreshUnfinished()

        // Nothing here waits for a button. Recordings left behind by a
        // previous session get transcribed, and the mini's finished jobs
        // (the watch's and the phone's) get pulled in, on their own.
        Task { await catchUp() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncFromServer() }
        }
    }

    /// Startup work: finish what was interrupted, then pull shared history.
    private func catchUp() async {
        await transcribeLeftovers()
        await syncFromServer()
    }

    /// Transcribes anything still staged from an earlier session, oldest
    /// first. Damaged files are left in place and surfaced in the window —
    /// they are the only case with nothing to do automatically.
    private func transcribeLeftovers() async {
        refreshUnfinished()
        for item in unfinished.filter(\.isPlayable).sorted(by: { $0.createdAt < $1.createdAt }) {
            await process(item.url, duration: Self.audioDuration(at: item.url))
        }
    }

    /// Pulls finished jobs off the Mac mini into local history. Mac uploads
    /// are skipped: this device already saved them when it recorded them.
    func syncFromServer() async {
        // This also retries files whose earlier upload failed. Previously the
        // three-minute timer only downloaded history, so pending Mac audio
        // could remain stuck until another recording happened to finish.
        await uploadPending()
        serverReachable = await serverClient.isReachable()
        guard serverReachable == true else { return }
        await serverSync.importCompletedJobs(into: history, skipping: [.mac])
    }

    var modelIsReady: Bool { ModelCatalog.isDownloaded(transcription.model) }

    /// One line describing the engine, for the window header.
    var engineSummary: String {
        switch engineState {
        case .idle:
            return modelIsReady ? "Ready — \(transcription.model.displayName)" : "Model not downloaded yet"
        case let .downloadingModel(progress):
            return String(format: "Downloading %@ — %.0f%%", transcription.model.displayName, progress * 100)
        case .loadingModel: return "Loading model…"
        case .ready: return "Ready — \(transcription.model.displayName)"
        case .transcribing: return "Transcribing…"
        case let .failed(message): return "Error: \(message)"
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopAndTranscribe()
        } else {
            AudioRecorder.requestPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startRecording()
                } else {
                    self.lastError = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
                }
            }
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
            isRecording = true
            elapsed = 0
            lastError = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.recorder.isRecording else { return }
                    self.elapsed = self.recorder.elapsed
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopAndTranscribe() {
        timer?.invalidate()
        timer = nil
        isRecording = false
        guard let recording = recorder.stop() else { return }
        elapsed = 0
        Task { await process(recording.url, duration: recording.duration) }
    }

    func discardRecording() {
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = 0
        recorder.cancel()
    }

    /// Finishes writing the audio file when the app is quitting.
    ///
    /// An `.m4a` is only a valid file once the recorder is stopped: quitting
    /// mid-recording used to leave a multi-megabyte file that no player or
    /// transcriber could open. Stopping here keeps the audio, and the next
    /// launch offers it back as an unfinished recording.
    func finalizeForTermination() {
        guard recorder.isRecording else { return }
        _ = recorder.stop()
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Transcription

    /// Transcribes on this Mac first — that is what puts the text on the
    /// clipboard within seconds — then hands the audio to the Mac mini so
    /// the phone and watch see the recording too.
    private func process(_ url: URL, duration: TimeInterval) async {
        guard processingURLs.insert(url).inserted else { return }
        isTranscribing = true
        defer {
            processingURLs.remove(url)
            isTranscribing = !processingURLs.isEmpty
        }
        do {
            let transcript = try await transcription.transcribe(url)
            let entry = history.addEntry(
                source: .mac,
                durationSeconds: duration,
                language: transcript.language,
                text: TranscriptFormatter.plainText(transcript),
                segments: transcript.segments.map {
                    HistorySegment(start: $0.start, end: $0.end, text: $0.text)
                },
                audioURL: url
            )
            copyToClipboard(entry.text)
            // History kept its own copy of the audio, so the staging file's
            // only remaining job is the upload. Moving it out of the
            // staging folder is what keeps that folder an accurate list of
            // recordings still waiting to be transcribed.
            stageForUpload(url)
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
        }
        refreshUnfinished()
        await uploadPending()
    }

    // MARK: - Sharing with the other devices

    private func stageForUpload(_ url: URL) {
        let folder = Self.pendingUploadFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    /// Sends everything transcribed but not yet shared. Files stay put on
    /// failure and go out on the next attempt, so a mini that is asleep
    /// only ever delays sharing.
    private func uploadPending() async {
        guard !isSharing else { return }
        isSharing = true
        defer { isSharing = false }
        let folder = Self.pendingUploadFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let audioFiles = files.filter { $0.pathExtension.lowercased() == "m4a" }
        pendingUploadCount = audioFiles.count
        guard !audioFiles.isEmpty else { return }

        for file in audioFiles {
            do {
                _ = try await serverClient.upload(fileURL: file)
                try? FileManager.default.removeItem(at: file)
                pendingUploadCount = max(0, pendingUploadCount - 1)
                serverReachable = true
            } catch {
                serverReachable = false
                historyLog.error("upload to the mini failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    func retrySharing() {
        Task { await syncFromServer() }
    }

    func retryUnfinished(_ item: UnfinishedRecording) {
        guard item.isPlayable else { return }
        Task { await process(item.url, duration: Self.audioDuration(at: item.url)) }
    }

    static var pendingUploadFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperApps/PendingUpload", isDirectory: true)
    }

    /// Removes an unfinished recording from the app without destroying it
    /// immediately. The user can still recover it from the macOS Trash.
    func trashUnfinished(_ item: UnfinishedRecording) {
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashedURL)
        } catch {
            lastError = "Couldn't move the recording to Trash: \(error.localizedDescription)"
        }
        refreshUnfinished()
    }

    func trashDamagedRecordings() {
        let damaged = unfinished.filter { !$0.isPlayable }
        var failures: [String] = []
        for item in damaged {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashedURL)
            } catch {
                failures.append(item.name)
            }
        }
        refreshUnfinished()
        if !failures.isEmpty {
            lastError = "Couldn't move \(failures.count) damaged recording\(failures.count == 1 ? "" : "s") to Trash."
        }
    }

    /// Anything still sitting in the staging folder has not made it into
    /// history yet.
    func refreshUnfinished() {
        let folder = AudioRecorder.recordingsFolder
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        )) ?? []
        unfinished = files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return UnfinishedRecording(
                    id: url,
                    // The name carries when it was recorded; the file's own
                    // creation date only says when it last moved.
                    createdAt: Self.recordedAt(filename: url.lastPathComponent)
                        ?? values?.creationDate ?? .distantPast,
                    sizeBytes: values?.fileSize ?? 0,
                    isPlayable: (try? AVAudioFile(forReading: url)) != nil
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastCopiedAt = Date()
    }

    func selectModel(_ model: WhisperModel) {
        transcription.selectModel(model)
        transcription.warmUp()
        objectWillChange.send()
    }

    private static func recordedAt(filename: String) -> Date? {
        guard let match = filename.range(of: #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#, options: .regularExpression)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: String(filename[match]))
    }

    private static func audioDuration(at url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
