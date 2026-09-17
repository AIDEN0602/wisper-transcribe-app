import SwiftUI

/// A voice surface, not a replacement QWERTY keyboard. Text is inserted at
/// the host app's current cursor as soon as Mac-mini transcription finishes.
struct KeyboardRootView: View {
    @ObservedObject var engine: DictationEngine
    let onMic: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onGlobe: () -> Void
    let onStartSession: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header
            voiceSurface
            controls
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 248)
        .background(
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.064, blue: 0.080), Color.brandNavy],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) { Rectangle().fill(Color.brandLine).frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            WhisperMark(size: 27)
            VStack(alignment: .leading, spacing: 1) {
                Text("STEALTH WHISPER")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Color.brandMuted)
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.isSessionLive ? Color.brandAccent : Color.brandWarning)
                    .frame(width: 7, height: 7)
                Text(engine.isSessionLive ? "Session live" : "Session off")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(engine.isSessionLive ? Color.brandAccent : Color.brandWarning)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(Color.brandLine, lineWidth: 1))
        }
    }

    private var voiceSurface: some View {
        HStack(spacing: 14) {
            Button(action: onMic) {
                ZStack {
                    Circle()
                        .fill(micColor)
                        .frame(width: 64, height: 64)
                        .shadow(color: micColor.opacity(0.22), radius: 16)
                    micSymbol
                }
                .foregroundStyle(Color.brandNavy)
            }
            .buttonStyle(.plain)
            .disabled(micDisabled)
            .accessibilityLabel(engine.state == .recording ? "Stop dictation" : "Start dictation")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    ForEach(0..<18, id: \.self) { index in
                        Capsule()
                            .fill(waveColor(index: index))
                            .frame(maxWidth: .infinity)
                            .frame(height: waveHeight(index: index))
                            .animation(.easeOut(duration: 0.12), value: engine.inputLevel)
                    }
                }
                .frame(height: 30)

                HStack {
                    Text(statusDetail)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.brandMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if engine.state == .recording {
                        Text(timeString(engine.elapsedTime))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.brandAccent)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity)
        .frame(height: 94)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.brandLine, lineWidth: 1))
    }

    @ViewBuilder
    private var micSymbol: some View {
        switch engine.state {
        case .recording:
            Image(systemName: "stop.fill").font(.system(size: 21, weight: .bold))
        case .starting, .transcribingLocal, .transcribing:
            ProgressView().tint(Color.brandNavy)
        default:
            Image(systemName: "mic.fill").font(.system(size: 23, weight: .bold))
        }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            compactButton(systemName: "globe", label: "Next keyboard", action: onGlobe)

            if engine.isSessionLive {
                if engine.state == .recording || engine.state == .starting {
                    Button(action: onCancel) {
                        Label("Cancel", systemImage: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .overlay(Capsule().stroke(Color.brandLine, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(isTranscribing ? "Text will insert automatically" : "Tap mic, speak, then tap stop")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.brandMuted)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button(action: onStartSession) {
                    Label("Start Keyboard Session", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.brandNavy)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Color.brandAccent, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            compactButton(systemName: "delete.left", label: "Delete", action: onDelete)
        }
    }

    private func compactButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 38)
                .background(Color.brandSurfaceRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.brandLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var statusTitle: String {
        switch engine.state {
        case .idle: return "Ready to dictate"
        case .sessionUnavailable: return "Keyboard Session required"
        case .starting: return "Starting microphone"
        case .recording: return "Listening"
        case .transcribingLocal: return "Transcribing on this iPhone"
        case .transcribing: return "Transcribing on your Mac mini"
        case .inserted: return "Inserted at the cursor"
        case .failed: return "Dictation needs attention"
        }
    }

    private var statusDetail: String {
        switch engine.state {
        case .idle: return "No clipboard step"
        case .sessionUnavailable(let message), .failed(let message): return message
        case .starting: return "Stay here — recording will start automatically"
        case .recording: return "Speak naturally, then tap stop"
        case .transcribingLocal: return "Private on-device text will insert automatically"
        case .transcribing: return "Keep this text field active"
        case .inserted: return "Ready for another thought"
        }
    }

    private var micDisabled: Bool {
        switch engine.state {
        case .starting, .transcribingLocal, .transcribing: return true
        default: return false
        }
    }

    private var isTranscribing: Bool {
        engine.state == .transcribingLocal || engine.state == .transcribing
    }

    private var micColor: Color {
        switch engine.state {
        case .recording: return .red
        case .sessionUnavailable, .failed: return Color.brandWarning
        default: return Color.brandAccent
        }
    }

    private func waveHeight(index: Int) -> CGFloat {
        guard engine.state == .recording else { return index.isMultiple(of: 3) ? 5 : 3 }
        let pattern = [0.45, 0.75, 1.0, 0.6, 0.85, 0.5]
        let strength = max(0.12, engine.inputLevel)
        return 4 + CGFloat(pattern[index % pattern.count] * strength * 25)
    }

    private func waveColor(index: Int) -> Color {
        guard engine.state == .recording else { return Color.brandLine }
        return index.isMultiple(of: 2) ? Color.brandAccent : Color.brandBlue
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    KeyboardRootView(
        engine: DictationEngine(hasFullAccess: { true }, insertText: { _ in }),
        onMic: {},
        onCancel: {},
        onDelete: {},
        onGlobe: {},
        onStartSession: {}
    )
}
