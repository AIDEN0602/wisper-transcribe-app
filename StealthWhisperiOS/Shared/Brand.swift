import AVFoundation
import Combine
import Foundation
import SwiftUI

/// The same restrained, low-light palette is used on iPhone, Watch, Mac,
/// keyboard, and web. The product should feel like a private instrument,
/// not a collection of unrelated sample screens.
extension Color {
    static let brandBlue = Color(red: 0x82 / 255.0, green: 0xA7 / 255.0, blue: 0xFF / 255.0)
    static let brandAccent = Color(red: 0x77 / 255.0, green: 0xEA / 255.0, blue: 0xB5 / 255.0)
    static let brandNavy = Color(red: 0x08 / 255.0, green: 0x0A / 255.0, blue: 0x0E / 255.0)
    static let brandSurface = Color(red: 0x11 / 255.0, green: 0x15 / 255.0, blue: 0x1B / 255.0)
    static let brandSurfaceRaised = Color(red: 0x18 / 255.0, green: 0x1E / 255.0, blue: 0x27 / 255.0)
    static let brandLine = Color.white.opacity(0.09)
    static let brandMuted = Color(red: 0x96 / 255.0, green: 0xA1 / 255.0, blue: 0xB2 / 255.0)
    static let brandWarning = Color(red: 0xFF / 255.0, green: 0xC6 / 255.0, blue: 0x6B / 255.0)
}

struct WhisperMark: View {
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(Color.brandAccent)
            HStack(alignment: .center, spacing: size * 0.055) {
                ForEach([0.30, 0.58, 0.82, 0.48, 0.26], id: \.self) { height in
                    Capsule()
                        .fill(Color.brandNavy.opacity(0.88))
                        .frame(width: size * 0.075, height: size * height)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .brandAccent
    var systemImage: String = "checkmark.shield.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.11), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 1))
    }
}

extension View {
    func whisperPanel(cornerRadius: CGFloat = 22) -> some View {
        background(Color.brandSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.brandLine, lineWidth: 1)
            )
    }
}

/// One small player shared by the iPhone and Mac history views. Keeping a
/// single player means starting another recording stops the previous one.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var entryID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(entryID: UUID, url: URL?) {
        if self.entryID == entryID, isPlaying {
            pause()
            return
        }
        if self.entryID == entryID, let player {
            preparePlaybackSession()
            player.play()
            isPlaying = true
            startTimer()
            return
        }
        guard let url else {
            errorMessage = "The original audio is still downloading from iCloud. Try again in a moment."
            return
        }

        do {
            preparePlaybackSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                throw NSError(
                    domain: "AudioPlaybackController",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The audio player could not start."]
                )
            }
            self.player = player
            self.entryID = entryID
            duration = player.duration
            currentTime = 0
            isPlaying = true
            errorMessage = nil
            startTimer()
        } catch {
            stop()
            errorMessage = "Couldn't play the original audio: \(error.localizedDescription)"
        }
    }

    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = max(0, min(1, fraction)) * duration
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        entryID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func pause() {
        player?.pause()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.isPlaying = player.isPlaying
            }
        }
    }

    private func preparePlaybackSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.stop()
            self.errorMessage = "The original audio could not be decoded."
        }
    }
}
