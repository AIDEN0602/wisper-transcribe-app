import SwiftUI
import AppIntents

/// Cross-process flag the Action Button path uses. The App Intent may run
/// in a separate extension process from the running watch app, so it can't
/// call the recorder directly — it sets this flag and the app consumes it
/// the next time it becomes active.
enum RecordingLaunchSignal {
    private static let key = "pendingActionButtonRecord"

    static func setPending() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Returns true at most once per set: reading it clears it.
    static func consumePending() -> Bool {
        let pending = UserDefaults.standard.bool(forKey: key)
        if pending { UserDefaults.standard.set(false, forKey: key) }
        return pending
    }
}

/// The App Shortcut bound to the Apple Watch Ultra Action Button
/// (Settings → Action Button → Action: Shortcut → Stealth Whisper). Opens
/// the app and toggles recording — press once to start, again to stop.
/// The title has to differ from the iPhone app's intent: both apps publish a
/// Record shortcut, and the watch's Action Button picker lists them side by
/// side. With identical titles it's a coin flip, and picking the iPhone one
/// fails on the wrist ("can't open app") because that app isn't on the watch.
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Record on Watch"
    static var description = IntentDescription("Start or stop a Stealth Whisper recording on your watch.")

    // Recording needs the app active on the watch, so bring it forward.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingLaunchSignal.setPending()
        return .result()
    }
}

/// Registers the intent so it appears in Shortcuts and, on Apple Watch
/// Ultra, as an Action Button target.
struct StealthWhisperWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Record on Watch with \(.applicationName)",
                "Start \(.applicationName) on Watch",
            ],
            shortTitle: "Record on Watch",
            systemImageName: "mic.fill"
        )
    }
}

@main
struct StealthWhisperWatchApp: App {
    @StateObject private var recorder = WatchRecorderManager()
    @StateObject private var history = HistoryStore()
    @Environment(\.scenePhase) private var scenePhase
    /// watchOS has no iCloud Documents, so the wrist can only see the other
    /// devices' transcripts by asking the Mac mini for them directly.
    private let serverHistory = ServerHistorySync()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchContentView()
            }
            .environmentObject(recorder)
            .environmentObject(history)
            // A cold launch delivers no scenePhase change for the initial
            // .active state, so the Action Button signal would be missed on
            // exactly the common case. Poll for it instead: the intent's flag
            // write and the app launch race each other, so the flag can land
            // a moment after the first check.
            .task { await consumePendingRecordingWithRetry() }
            // Cold launch sends no scenePhase change, so the wrist would
            // never pull on the launch that matters most.
            .task { await serverHistory.importCompletedJobs(into: history, limit: 20) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    handleActionButtonLaunchIfNeeded()
                    // Keep the wrist's list in step with the Mac and phone.
                    // Watch screens are small: the most recent handful is
                    // all that is ever scrolled through.
                    Task { await serverHistory.importCompletedJobs(into: history, limit: 20) }
                }
            }
        }
    }

    /// If the app was brought forward by the Action Button (via
    /// ToggleRecordingIntent), toggle recording once the app is active.
    /// The flag consume is one-shot, so a plain tap-to-open never triggers
    /// this and the scenePhase/onAppear double-call can't double-fire.
    private func handleActionButtonLaunchIfNeeded() {
        guard RecordingLaunchSignal.consumePending() else { return }
        recorder.toggleRecording()
    }

    /// Same check, but kept up for ~1s after launch so a flag that arrives
    /// just behind the app still starts the recording.
    private func consumePendingRecordingWithRetry() async {
        for _ in 0..<6 {
            if RecordingLaunchSignal.consumePending() {
                recorder.toggleRecording()
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}
