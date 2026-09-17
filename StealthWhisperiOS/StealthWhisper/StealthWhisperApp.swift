import SwiftUI
import AppIntents

/// One-shot flag set by the Record App Intent (which runs in a separate
/// process) and consumed by the app when it becomes active.
enum RecordingLaunchSignal {
    private static let key = "pendingActionButtonRecord"

    static func setPending() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func consumePending() -> Bool {
        let pending = UserDefaults.standard.bool(forKey: key)
        if pending { UserDefaults.standard.set(false, forKey: key) }
        return pending
    }
}

/// Appears in Shortcuts as "Record on Phone". Opens the app
/// and toggles recording — run once to start, again to stop. The name has to
/// say iPhone: the watch app publishes its own Record shortcut, and the two
/// sit next to each other in the watch's Action Button picker, where choosing
/// this one can't work — the iPhone app isn't installed on the watch.
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Record on Phone"
    static var description = IntentDescription("Start or stop a Stealth Whisper recording on this device.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingLaunchSignal.setPending()
        return .result()
    }
}

struct StealthWhisperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Record on Phone with \(.applicationName)",
                "Start \(.applicationName) on Phone",
            ],
            shortTitle: "Record on Phone",
            systemImageName: "mic.fill"
        )
    }
}

@main
struct StealthWhisperApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder: AudioRecorderManager
    @StateObject private var transcription: TranscriptionManager
    @StateObject private var history: HistoryStore
    @StateObject private var pendingUploads: PendingUploadStore
    @StateObject private var coordinator: AppCoordinator
    @StateObject private var settings = AppSettings.shared
    private let serverHistory = ServerHistorySync()

    init() {
        #if DEBUG
        TextCleanerDebugChecks.run()
        #endif

        let recorder = AudioRecorderManager()
        let transcription = TranscriptionManager()
        let history = HistoryStore()
        let pendingUploads = PendingUploadStore()
        _recorder = StateObject(wrappedValue: recorder)
        _transcription = StateObject(wrappedValue: transcription)
        _history = StateObject(wrappedValue: history)
        _pendingUploads = StateObject(wrappedValue: pendingUploads)
        _coordinator = StateObject(wrappedValue: AppCoordinator(
            recorder: recorder,
            transcription: transcription,
            history: history,
            pendingUploads: pendingUploads
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(transcription)
                .environmentObject(history)
                .environmentObject(pendingUploads)
                .environmentObject(settings)
                .environmentObject(coordinator)
                // Cold launch (Action Button on a not-running app) does NOT
                // deliver a scenePhase onChange for the initial .active
                // state, so the recording signal was missed on exactly the
                // common case. Consume it here too. The retry covers the
                // cross-process race where the intent's UserDefaults write
                // hasn't propagated by the time this first runs.
                .task { await checkPendingRecordingWithRetry() }
                // A cold launch starts in `.active` and may not emit a scene
                // phase change. Resume durable uploads here as well as in the
                // foreground hook below.
                .task { coordinator.retryPendingUploads() }
                // A cold launch delivers no scenePhase change for the
                // initial .active state, so syncing only from that hook
                // meant a freshly opened app never pulled anything.
                .task { await syncHistory() }
                .onOpenURL { url in
                    guard url.scheme == "stealthwhisper",
                          url.host == "keyboard-session" || url.host == "keyboard-dictation"
                    else { return }
                    coordinator.enableKeyboardFlowSession()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                coordinator.retryPendingUploads()
                coordinator.refreshKeyboardFlowSession()
                consumePendingRecording()
                // Picks up entries other devices wrote while we were away,
                // and retries the iCloud hookup if this launch started
                // before the container was ready.
                Task { await syncHistory() }
            } else if newPhase == .background {
                coordinator.suspendKeyboardFlowSessionIfNeeded()
            }
        }
    }

    /// Re-reads history, retries the iCloud hookup if this launch started
    /// before the container was ready, and pulls anything the Mac mini has
    /// that this phone doesn't — including recordings made on the Mac.
    private func syncHistory() async {
        history.refresh()
        await serverHistory.importCompletedJobs(into: history)
    }

    private func consumePendingRecording() {
        if RecordingLaunchSignal.consumePending() {
            coordinator.toggleRecording()
        }
    }

    private func checkPendingRecordingWithRetry() async {
        for _ in 0..<6 {
            if RecordingLaunchSignal.consumePending() {
                coordinator.toggleRecording()
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}
