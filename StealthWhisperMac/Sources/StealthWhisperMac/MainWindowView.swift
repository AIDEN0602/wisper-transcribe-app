import AppKit
import SwiftUI
import WhisperCore

/// The app's real home: record, see what happened, read every transcript
/// from every device. The menu bar item is now only a shortcut into this.
struct MainWindowView: View {
    @EnvironmentObject private var controller: RecordingController
    @ObservedObject private var history = RecordingController.shared.history
    @StateObject private var playback = AudioPlaybackController()
    @State private var search = ""
    @State private var expanded: Set<UUID> = []
    @State private var selectedEntryID: UUID?
    @State private var showRecovery = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color.brandNavy)
        .preferredColorScheme(.dark)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { controller.refreshUnfinished() }
        .onChange(of: controller.isRecording) { _, recording in
            if recording { playback.stop() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                WhisperMark(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("STEALTH WHISPER")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(Color.brandMuted)
                    Text("Private voice workspace")
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                modelMenu
            }

            HStack(spacing: 16) {
                recordButton
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.isRecording ? timeString(controller.elapsed) : "Capture a thought")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(controller.engineSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    syncStatus
                }
                Spacer()
                if controller.isTranscribing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            .whisperPanel(cornerRadius: 20)

            if let error = controller.lastError ?? playback.errorMessage {
                errorBanner(error)
            }
        }
        .padding(18)
    }

    private var recordButton: some View {
        Button {
            controller.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red : Color.brandAccent)
                    .frame(width: 60, height: 60)
                Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.brandNavy)
            }
        }
        .buttonStyle(.plain)
        .help(controller.isRecording ? "Stop and transcribe (⌥⌘R)" : "Start recording (⌥⌘R)")
    }

    private var syncStatus: some View {
        HStack(spacing: 4) {
            Image(systemName: serverIcon)
                .foregroundStyle(controller.serverReachable == true ? Color.brandAccent : .secondary)
            Text(serverText)
            if controller.pendingUploadCount > 0 {
                Button("Retry") { controller.retrySharing() }
                    .buttonStyle(.link)
            }
            if history.isUsingICloud {
                Image(systemName: "icloud.fill").foregroundStyle(Color.brandAccent)
                Text("+ iCloud")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var serverIcon: String {
        switch controller.serverReachable {
        case .some(true): return "arrow.triangle.2.circlepath"
        case .some(false): return "exclamationmark.icloud"
        case .none: return "ellipsis.circle"
        }
    }

    private var serverText: String {
        if controller.pendingUploadCount > 0 {
            return "\(controller.pendingUploadCount) recording\(controller.pendingUploadCount == 1 ? "" : "s") saved · sharing will retry automatically"
        }
        switch controller.serverReachable {
        case .some(true): return "Private sync online"
        case .some(false): return "Offline · recordings stay safely on this Mac"
        case .none: return "Checking private sync…"
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(WhisperModel.allCases) { model in
                Button {
                    controller.selectModel(model)
                } label: {
                    Label(
                        "\(model.displayName) — \(ModelCatalog.isDownloaded(model) ? "downloaded" : "\(model.approximateDownloadMB) MB")",
                        systemImage: model == controller.transcription.model ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Label("Model", systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                controller.lastError = nil
                playback.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.brandWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.brandWarning.opacity(0.22)))
    }

    // MARK: - Body

    private var content: some View {
        List(selection: $selectedEntryID) {
            if !controller.unfinished.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showRecovery) {
                        if controller.unfinished.contains(where: { !$0.isPlayable }) {
                            HStack {
                                Text("Interrupted files stay here until you decide what to do.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Move damaged to Trash") {
                                    controller.trashDamagedRecordings()
                                }
                                .buttonStyle(.link)
                                .disabled(controller.isTranscribing)
                            }
                        }
                        ForEach(controller.unfinished) { item in
                            unfinishedRow(item)
                        }
                    } label: {
                        Label(
                            "Recovery · \(controller.unfinished.count) saved recording\(controller.unfinished.count == 1 ? "" : "s")",
                            systemImage: "archivebox.fill"
                        )
                        .foregroundStyle(Color.brandWarning)
                    }
                }
            }
            Section(history.entries.isEmpty ? "History" : "History (\(filtered.count))") {
                if filtered.isEmpty {
                    Text(history.entries.isEmpty
                         ? "Nothing yet. Press the microphone, or ⌥⌘R from anywhere."
                         : "No transcript matches “\(search)”.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(filtered) { entry in
                        entryRow(entry)
                            .tag(entry.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color.brandNavy)
        .searchable(text: $search, placement: .toolbar, prompt: "Search transcripts")
        .onCopyCommand {
            guard let entry = selectedEntry else { return [] }
            return [NSItemProvider(object: entry.text as NSString)]
        }
    }

    private func unfinishedRow(_ item: RecordingController.UnfinishedRecording) -> some View {
        HStack {
            Image(systemName: item.isPlayable ? "waveform" : "exclamationmark.triangle")
                .foregroundStyle(item.isPlayable ? Color.brandBlue : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.callout)
                Text(item.isPlayable
                     ? "\(item.sizeBytes / 1024) KB — \(controller.isTranscribing ? "transcribing…" : "ready to retry")"
                     : "Unfinished audio file — kept because the app never silently deletes a recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isPlayable {
                Button("Retry") { controller.retryUnfinished(item) }
                    .disabled(controller.isTranscribing)
            }
            Button("Move to Trash", role: .destructive) { controller.trashUnfinished(item) }
                .disabled(controller.isTranscribing)
        }
        .padding(.vertical, 2)
    }

    /// One line per transcript: what it was about and when. The transcript
    /// itself opens on click — the list is for finding things, not reading
    /// them.
    private func entryRow(_ entry: HistoryEntry) -> some View {
        let isOpen = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon(entry.source))
                    .foregroundStyle(Color.brandBlue)
                    .help(entry.source.rawValue)
                Text(entry.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    controller.copyToClipboard(entry.text)
                    selectedEntryID = entry.id
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy transcript (⌘C)")
                if entry.audioFilename != nil {
                    Button {
                        playback.toggle(entryID: entry.id, url: history.audioURL(for: entry))
                    } label: {
                        Image(systemName: playback.entryID == entry.id && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.brandAccent)
                    }
                    .buttonStyle(.borderless)
                    .help("Play original audio")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedEntryID = entry.id
                if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            }

            if isOpen {
                if playback.entryID == entry.id {
                    HStack(spacing: 8) {
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
                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text("\(timeString(entry.durationSeconds)) · \(entry.source.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Copy") { controller.copyToClipboard(entry.text) }
                    Button("Copy with times") { controller.copyToClipboard(timestamped(entry)) }
                    Button(role: .destructive) {
                        history.delete(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if entry.audioFilename != nil {
                Button("Play original") {
                    playback.toggle(entryID: entry.id, url: history.audioURL(for: entry))
                }
                Divider()
            }
            Button("Copy") { controller.copyToClipboard(entry.text) }
            Button("Copy with times") { controller.copyToClipboard(timestamped(entry)) }
            Divider()
            Button("Delete", role: .destructive) { history.delete(entry) }
        }
    }

    // MARK: - Helpers

    private var filtered: [HistoryEntry] {
        guard !search.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(search)
                || $0.displayTitle.localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedEntry: HistoryEntry? {
        guard let selectedEntryID else { return nil }
        return filtered.first { $0.id == selectedEntryID }
    }

    private func sourceIcon(_ source: HistorySource) -> String {
        switch source {
        case .mac: return "laptopcomputer"
        case .iphone: return "iphone"
        case .watch: return "applewatch"
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func timestamped(_ entry: HistoryEntry) -> String {
        guard !entry.segments.isEmpty else { return entry.text }
        return entry.segments.map { segment in
            "[\(timeString(segment.start))] \(segment.text)"
        }.joined(separator: "\n")
    }
}
