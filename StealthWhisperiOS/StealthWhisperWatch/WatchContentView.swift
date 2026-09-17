import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var recorder: WatchRecorderManager
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    WhisperMark(size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("STEALTH")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(Color.brandMuted)
                        Text("Whisper")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    Spacer()
                    Circle()
                        .fill(recorder.isPhoneReachable ? Color.brandAccent : Color.brandWarning)
                        .frame(width: 7, height: 7)
                }

                VStack(spacing: 10) {
                    Text(recorder.isRecording ? timeString(recorder.elapsedTime) : "READY")
                        .font(.system(size: recorder.isRecording ? 27 : 11, weight: .semibold, design: .monospaced))
                        .tracking(recorder.isRecording ? 0 : 1.6)
                        .foregroundStyle(recorder.isRecording ? .white : Color.brandAccent)

                    Button(action: recorder.toggleRecording) {
                        ZStack {
                            Circle()
                                .fill(recorder.isRecording ? Color.red : Color.brandAccent)
                                .frame(width: 72, height: 72)
                                .shadow(color: (recorder.isRecording ? Color.red : Color.brandAccent).opacity(0.25), radius: 16)
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundStyle(Color.brandNavy)
                        }
                    }
                    .buttonStyle(.plain)

                    Text(recorder.isRecording ? "Tap to save" : "Tap to record")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.brandMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .whisperPanel(cornerRadius: 22)

                if let error = recorder.errorMessage {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.brandWarning)
                        Text(error)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.brandMuted)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.brandWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }

                if let latest = recorder.transfers.first {
                    transferCard(latest)
                }

                NavigationLink {
                    WatchHistoryView(history: history)
                } label: {
                    HStack {
                        Image(systemName: "text.justify.left")
                            .foregroundStyle(Color.brandBlue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Transcripts")
                                .font(.system(size: 12, weight: .semibold))
                            Text(history.entries.isEmpty ? "Nothing yet" : "\(history.entries.count) saved")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.brandMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.brandMuted)
                    }
                    .padding(11)
                    .whisperPanel(cornerRadius: 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .containerBackground(Color.brandNavy.gradient, for: .navigation)
    }

    private func transferCard(_ transfer: WatchTransfer) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon(for: transfer.status))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color(for: transfer.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: transfer.status))
                    .font(.system(size: 11, weight: .semibold))
                Text(transfer.date, format: .dateTime.hour().minute())
                    .font(.system(size: 9))
                    .foregroundStyle(Color.brandMuted)
            }
            Spacer()
        }
        .padding(10)
        .whisperPanel(cornerRadius: 15)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func icon(for status: WatchTransfer.Status) -> String {
        switch status {
        case .sending: return "arrow.up.circle.fill"
        case .sent: return "checkmark.circle.fill"
        case .processing: return "waveform.badge.magnifyingglass"
        case .waitingForServer: return "clock.arrow.circlepath"
        case .done: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func color(for status: WatchTransfer.Status) -> Color {
        switch status {
        case .sending, .sent, .processing: return Color.brandBlue
        case .waitingForServer: return Color.brandWarning
        case .done: return Color.brandAccent
        case .failed: return .red
        }
    }

    private func label(for status: WatchTransfer.Status) -> String {
        switch status {
        case .sending: return "Sending to iPhone"
        case .sent: return "Saved on iPhone"
        case .processing: return "Transcribing"
        case .waitingForServer: return "Saved · retrying"
        case .done: return "Transcript ready"
        case .failed: return "Needs attention"
        }
    }
}

#Preview {
    NavigationStack {
        WatchContentView()
    }
    .environmentObject(WatchRecorderManager())
    .environmentObject(HistoryStore())
}
