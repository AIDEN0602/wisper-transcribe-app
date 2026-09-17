import SwiftUI
import WhisperCore

struct ContentView: View {
    @EnvironmentObject var app: AppCoordinator
    @EnvironmentObject var recorder: AudioRecorderManager
    @EnvironmentObject var transcription: TranscriptionManager
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var pendingUploads: PendingUploadStore
    @EnvironmentObject var settings: AppSettings

    @StateObject private var playback = AudioPlaybackController()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.brandNavy.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 14) {
                    topBar
                    recordingPanel
                    keyboardSessionPanel

                    if app.isKeyboardDictation || app.keyboardTranscriptReady {
                        keyboardBanner
                    }
                    if let error = activeError {
                        errorBanner(error)
                    }
                    if let transcript = app.currentTranscript {
                        TranscriptCard(transcript: transcript) {
                            app.currentTranscript = nil
                        }
                    }

                    HistoryFeed(
                        history: history,
                        pendingUploads: pendingUploads,
                        playback: playback,
                        retryPendingUploads: app.retryPendingUploads
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording { playback.stop() }
        }
    }

    private var keyboardSessionPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill((app.isKeyboardFlowSessionEnabled ? Color.brandAccent : Color.brandBlue).opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(app.isKeyboardFlowSessionEnabled ? Color.brandAccent : Color.brandBlue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Session")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(app.isKeyboardFlowSessionEnabled ? app.keyboardLocalTranscriptionMessage : "Required for voice typing in other apps")
                        .font(.caption)
                        .foregroundStyle(Color.brandMuted)
                }
                Spacer()
                Button(app.isKeyboardFlowSessionEnabled ? "End" : "Enable") {
                    if app.isKeyboardFlowSessionEnabled {
                        app.disableKeyboardFlowSession()
                    } else {
                        app.enableKeyboardFlowSession()
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(app.isKeyboardFlowSessionEnabled ? Color.brandSurfaceRaised : Color.brandAccent)
                .foregroundStyle(app.isKeyboardFlowSessionEnabled ? Color.white : Color.brandNavy)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: app.isKeyboardFlowSessionEnabled ? "mic.circle.fill" : "info.circle.fill")
                    .foregroundStyle(app.isKeyboardFlowSessionEnabled ? Color.brandWarning : Color.brandMuted)
                Text(app.isKeyboardFlowSessionEnabled
                     ? "Keep this session on, switch back to your text field, and use the Stealth Whisper keyboard. The orange microphone indicator stays visible; standby audio is discarded and only active dictation is saved."
                     : "Enable once before switching to the Stealth Whisper keyboard. Short English dictation is transcribed privately on this iPhone and inserted directly at the cursor; the Mac mini remains an automatic fallback.")
                    .font(.caption)
                    .foregroundStyle(Color.brandMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .whisperPanel(cornerRadius: 20)
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            WhisperMark(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("STEALTH WHISPER")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(Color.brandMuted)
                Text("Private voice notes")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.brandSurfaceRaised, in: Circle())
                    .overlay(Circle().stroke(Color.brandLine, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 10)
    }

    private var recordingPanel: some View {
        VStack(spacing: 18) {
            HStack {
                StatusPill(
                    text: recorder.isRecording ? "Recording" : statusHeadline,
                    color: recorder.isRecording ? .red : statusTint,
                    systemImage: recorder.isRecording ? "waveform" : statusIcon
                )
                Spacer()
                Text(recorder.isRecording ? timeString(recorder.elapsedTime) : "No fixed limit")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.brandMuted)
            }

            HStack(spacing: 18) {
                Button(action: app.toggleRecording) {
                    ZStack {
                        Circle()
                            .fill(recorder.isRecording ? Color.red : Color.brandAccent)
                            .frame(width: 72, height: 72)
                            .shadow(color: (recorder.isRecording ? Color.red : Color.brandAccent).opacity(0.22), radius: 20)
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(Color.brandNavy)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")

                VStack(alignment: .leading, spacing: 5) {
                    Text(recorder.isRecording ? "Listening privately" : "Capture a thought")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(Color.brandMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Original audio stays in your private history")
            }
            .font(.caption)
            .foregroundStyle(Color.brandMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .whisperPanel(cornerRadius: 26)
    }

    private var keyboardBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: app.keyboardTranscriptReady ? "checkmark.circle.fill" : "keyboard.fill")
                .font(.title3)
                .foregroundStyle(app.keyboardTranscriptReady ? Color.brandAccent : Color.brandBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.keyboardTranscriptReady ? "Dictation ready" : "Keyboard dictation")
                    .font(.subheadline.weight(.semibold))
                Text(app.keyboardTranscriptReady
                     ? "The transcript was delivered to the keyboard and will insert at the active cursor."
                     : (recorder.isRecording
                        ? "Recording from the active keyboard. Stop or cancel there."
                        : "Preparing the private microphone session…"))
                    .font(.caption)
                    .foregroundStyle(Color.brandMuted)
            }
            Spacer()
            if app.keyboardTranscriptReady {
                Button("Done") { app.dismissKeyboardTranscriptReady() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.brandAccent)
            }
        }
        .padding(14)
        .whisperPanel(cornerRadius: 18)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.brandWarning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs attention")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.brandMuted)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                app.lastError = nil
                recorder.errorMessage = nil
                playback.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.brandMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.brandWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.brandWarning.opacity(0.20)))
    }

    private var activeError: String? {
        app.lastError ?? recorder.errorMessage ?? playback.errorMessage
    }

    private var statusHeadline: String {
        if app.isTranscribing { return "Transcribing" }
        if !pendingUploads.items.isEmpty { return "Saved" }
        return settings.processingMode == .onDevice ? "On device" : "Private server"
    }

    private var statusTint: Color {
        pendingUploads.items.isEmpty ? .brandAccent : .brandWarning
    }

    private var statusIcon: String {
        if app.isTranscribing { return "waveform.badge.magnifyingglass" }
        if !pendingUploads.items.isEmpty { return "clock.arrow.circlepath" }
        return settings.processingMode == .onDevice ? "iphone" : "lock.shield.fill"
    }

    private var statusMessage: String {
        if recorder.isRecording {
            return app.isKeyboardDictation ? "Recording for the keyboard" : "Tap stop to save and transcribe"
        }
        if app.keyboardTranscriptReady { return "Your keyboard transcript is ready" }
        if app.isTranscribing { return "Audio saved · transcription in progress" }
        if !pendingUploads.items.isEmpty {
            return "\(pendingUploads.items.count) recording\(pendingUploads.items.count == 1 ? "" : "s") saved safely · retrying automatically"
        }
        switch settings.processingMode {
        case .server: return "Ready · private server processing"
        case .onDevice:
            switch transcription.state {
            case .downloadingModel(let progress): return "Downloading model · \(Int(progress * 100))%"
            case .loadingModel: return "Loading the local Whisper model"
            case .transcribing: return "Transcribing on this iPhone"
            case .failed: return "The local engine needs attention"
            default: return "Ready · audio never leaves this iPhone"
            }
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct TranscriptCard: View {
    let transcript: Transcript
    let onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Just transcribed", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandAccent)
                Spacer()
                Button {
                    UIPasteboard.general.string = TranscriptFormatter.plainText(transcript)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            Text(TranscriptFormatter.plainText(transcript))
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .whisperPanel(cornerRadius: 20)
    }
}

private struct HistoryFeed: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var pendingUploads: PendingUploadStore
    @ObservedObject var playback: AudioPlaybackController
    let retryPendingUploads: () -> Void

    @State private var search = ""
    @State private var expanded: Set<UUID> = []
    @State private var copiedID: UUID?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIBRARY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(Color.brandMuted)
                    Text(history.entries.isEmpty ? "Your transcripts" : "\(filtered.count) transcripts")
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                if !history.entries.isEmpty {
                    Image(systemName: history.isUsingICloud ? "icloud.fill" : "internaldrive.fill")
                        .foregroundStyle(history.isUsingICloud ? Color.brandAccent : Color.brandMuted)
                }
            }
            .padding(.top, 8)

            if !history.entries.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.brandMuted)
                    TextField("Search transcripts", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 13)
                .frame(height: 44)
                .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.brandLine))
            }

            if !pendingUploads.items.isEmpty {
                pendingPanel
            }

            if filtered.isEmpty {
                emptyPanel
            } else {
                ForEach(filtered) { entry in
                    entryCard(entry)
                }
            }
        }
    }

    private var pendingPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(Color.brandWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio saved safely")
                    .font(.subheadline.weight(.semibold))
                Text("\(pendingUploads.items.count) waiting for the private server")
                    .font(.caption)
                    .foregroundStyle(Color.brandMuted)
            }
            Spacer()
            Button("Retry", action: retryPendingUploads)
                .buttonStyle(.bordered)
                .tint(Color.brandWarning)
        }
        .padding(14)
        .whisperPanel(cornerRadius: 18)
    }

    private var emptyPanel: some View {
        VStack(spacing: 10) {
            WhisperMark(size: 46)
            Text(search.isEmpty ? "No transcripts yet" : "No matches")
                .font(.headline)
            Text(search.isEmpty ? "Record on your Watch, iPhone, or Mac. Everything appears here." : "Try a different word or phrase.")
                .font(.caption)
                .foregroundStyle(Color.brandMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .whisperPanel(cornerRadius: 22)
    }

    private func entryCard(_ entry: HistoryEntry) -> some View {
        let isOpen = expanded.contains(entry.id)
        let isThisPlaying = playback.entryID == entry.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: sourceIcon(entry.source))
                    .foregroundStyle(Color.brandBlue)
                    .frame(width: 32, height: 32)
                    .background(Color.brandBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(isOpen ? 3 : 2)
                    Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(Color.brandMuted)
                }
                Spacer(minLength: 8)
                if entry.audioFilename != nil {
                    Button {
                        playback.toggle(entryID: entry.id, url: history.audioURL(for: entry))
                    } label: {
                        Image(systemName: isThisPlaying && playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 36, height: 36)
                            .foregroundStyle(Color.brandNavy)
                            .background(Color.brandAccent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isThisPlaying && playback.isPlaying ? "Pause original audio" : "Play original audio")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            }

            if isThisPlaying {
                HStack(spacing: 10) {
                    Text(timeString(playback.currentTime))
                    Slider(
                        value: Binding(
                            get: { playback.duration > 0 ? playback.currentTime / playback.duration : 0 },
                            set: { playback.seek(to: $0) }
                        ),
                        in: 0...1
                    )
                    .tint(Color.brandAccent)
                    Text(timeString(playback.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.brandMuted)
            }

            if isOpen {
                Divider().overlay(Color.brandLine)
                Text(entry.text)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.86))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("\(timeString(entry.durationSeconds)) · \(entry.language.uppercased())")
                        .font(.caption2)
                        .foregroundStyle(Color.brandMuted)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = entry.text
                        copiedID = entry.id
                    } label: {
                        Label(copiedID == entry.id ? "Copied" : "Copy", systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(15)
        .whisperPanel(cornerRadius: 20)
        .contextMenu {
            if entry.audioFilename != nil {
                Button("Play original", systemImage: "play.fill") {
                    playback.toggle(entryID: entry.id, url: history.audioURL(for: entry))
                }
            }
            Button("Copy transcript", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = entry.text
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                if playback.entryID == entry.id { playback.stop() }
                history.delete(entry)
            }
        }
    }

    private var filtered: [HistoryEntry] {
        guard !search.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(search)
                || $0.displayTitle.localizedCaseInsensitiveContains(search)
        }
    }

    private func sourceIcon(_ source: HistorySource) -> String {
        switch source {
        case .iphone: return "iphone"
        case .watch: return "applewatch"
        case .mac: return "desktopcomputer"
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder) : String(format: "%d:%02d", minutes, remainder)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppCoordinator(
            recorder: AudioRecorderManager(),
            transcription: TranscriptionManager(),
            history: HistoryStore(),
            pendingUploads: PendingUploadStore()
        ))
        .environmentObject(AudioRecorderManager())
        .environmentObject(TranscriptionManager())
        .environmentObject(HistoryStore())
        .environmentObject(PendingUploadStore())
        .environmentObject(AppSettings.shared)
}
