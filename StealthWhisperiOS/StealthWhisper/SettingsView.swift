import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var transcription: TranscriptionManager
    @EnvironmentObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Transcription", selection: $settings.processingMode) {
                        Label("Private server", systemImage: "lock.shield.fill").tag(ProcessingMode.server)
                        Label("On this iPhone", systemImage: "iphone").tag(ProcessingMode.onDevice)
                    }
                    .pickerStyle(.inline)
                } header: {
                    sectionTitle("PROCESSING")
                } footer: {
                    Text(settings.processingMode == .server
                         ? "Audio is saved first, then sent to your private server. If it is offline, the app keeps the recording and retries."
                         : "Audio stays on this iPhone. Requires a one-time 1.7 GB Whisper model download.")
                }
                .onChange(of: settings.processingMode) { _, mode in
                    if mode == .onDevice { transcription.warmUp() }
                }

                if settings.processingMode == .onDevice {
                    Section {
                        NavigationLink {
                            ModelPickerView()
                        } label: {
                            LabeledContent("Whisper model", value: transcription.model.displayName)
                        }
                        Toggle("Clean filler words", isOn: $settings.removeFillerWordsEnabled)
                    } header: {
                        sectionTitle("ON-DEVICE")
                    } footer: {
                        Text("Cleanup runs only after transcription finishes. Your original audio is never changed.")
                    }
                }

                Section {
                    LabeledContent("Transcript sync", value: history.isUsingICloud ? "iCloud" : "This device")
                    LabeledContent("Original audio", value: "Saved with history")
                    LabeledContent("Recording limit", value: "No fixed limit")
                } header: {
                    sectionTitle("PRIVACY & STORAGE")
                }

                Section {
                    Toggle("Legacy iCloud upload", isOn: $settings.serverModeEnabled)
                } header: {
                    sectionTitle("ADVANCED")
                } footer: {
                    Text("Only enable this for the older Mac-mini folder pipeline. It is not needed for normal use.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        setupStep("1", "Add Stealth Whisper in Settings → General → Keyboard → Keyboards")
                        setupStep("2", "Open it again and enable Full Access")
                        setupStep("3", "Tap the keyboard mic, swipe back, speak, then tap stop")
                    }
                    .padding(.vertical, 4)
                } header: {
                    sectionTitle("DICTATION KEYBOARD")
                } footer: {
                    Text("The app briefly opens to start the private microphone session. Swipe back to the previous app; the transcript inserts at the cursor automatically.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.brandNavy)
            .tint(Color.brandAccent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(Color.brandMuted)
    }

    private func setupStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(Color.brandNavy)
                .frame(width: 22, height: 22)
                .background(Color.brandAccent, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
        .environmentObject(TranscriptionManager())
        .environmentObject(HistoryStore())
}
