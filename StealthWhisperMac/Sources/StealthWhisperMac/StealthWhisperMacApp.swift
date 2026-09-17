import AppKit
import SwiftUI

@main
struct StealthWhisperMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = RecordingController.shared

    var body: some Scene {
        Window("Stealth Whisper", id: "main") {
            MainWindowView()
                .environmentObject(controller)
        }
        .defaultSize(width: 720, height: 560)
        .commands {
            CommandGroup(after: .newItem) {
                Button(controller.isRecording ? "Stop & Transcribe" : "Start Recording") {
                    controller.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.option, .command])
            }
        }

        MenuBarExtra {
            Button(controller.isRecording ? "Stop & Transcribe" : "Start Recording") {
                controller.toggleRecording()
            }
            Text(controller.engineSummary)
            Divider()
            Button("Open Stealth Whisper") { AppDelegate.showMainWindow() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: controller.isRecording ? "record.circle.fill" : "waveform.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Keeps running with the window closed so the global ⌥⌘R hotkey and the
    /// menu bar item stay available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showMainWindow() }
        return true
    }

    /// Stops an in-flight recording so its audio file is closed properly
    /// rather than left unreadable.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            RecordingController.shared.finalizeForTermination()
        }
    }

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
