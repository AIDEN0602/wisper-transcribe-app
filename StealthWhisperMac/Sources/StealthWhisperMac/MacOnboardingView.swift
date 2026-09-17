import SwiftUI

struct MacOnboardingView: View {
    @EnvironmentObject private var controller: RecordingController
    @Binding var isPresented: Bool
    @AppStorage("MacOnboardingCompletedV1") private var onboardingCompleted = false

    @State private var useServer = true
    @State private var serverURL = ""
    @State private var isTestingServer = false
    @State private var serverTestResult: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                WhisperMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Stealth Whisper")
                        .font(.title2.weight(.semibold))
                    Text("Private transcription, ready in three steps")
                        .foregroundStyle(.secondary)
                }
            }

            setupRow(number: "1", title: "Speech model") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.engineSummary)
                    if !controller.modelIsReady {
                        ProgressView()
                            .controlSize(.small)
                        Text("The recommended model downloads automatically. Keep the app open and connected to the internet the first time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Model ready for offline transcription", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.brandAccent)
                    }
                }
            }

            setupRow(number: "2", title: "Private Mac mini server") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Share recordings and history through my private server", isOn: $useServer)
                    TextField("https://your-mac-mini.example", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!useServer)
                    HStack {
                        Button(isTestingServer ? "Testing…" : "Save and test") {
                            saveAndTest()
                        }
                        .disabled(isTestingServer || (useServer && serverURL.isEmpty))
                        if let serverTestResult {
                            Label(
                                serverTestResult ? "Connected" : "Saved, but not reachable",
                                systemImage: serverTestResult ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(serverTestResult ? Color.brandAccent : Color.brandWarning)
                        }
                    }
                    Text("Turn this off to keep the Mac app completely local. You can change it later with the gear button.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            setupRow(number: "3", title: "Start recording") {
                Text("Allow microphone access when macOS asks. Press ⌥⌘R from anywhere to start or stop; the transcript is copied automatically.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Finish setup") {
                    Task {
                        if useServer { _ = await controller.configureServer(enabled: true, urlString: serverURL) }
                        else { _ = await controller.configureServer(enabled: false, urlString: serverURL) }
                        onboardingCompleted = true
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 600)
        .background(Color.brandNavy)
        .preferredColorScheme(.dark)
        .onAppear {
            useServer = controller.serverEnabled
            serverURL = controller.serverURLString
        }
    }

    private func setupRow<Content: View>(
        number: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline.monospacedDigit())
                .frame(width: 30, height: 30)
                .background(Color.brandAccent, in: Circle())
                .foregroundStyle(Color.brandNavy)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .whisperPanel(cornerRadius: 16)
    }

    private func saveAndTest() {
        isTestingServer = true
        serverTestResult = nil
        Task {
            serverTestResult = await controller.configureServer(enabled: useServer, urlString: serverURL)
            isTestingServer = false
        }
    }
}
