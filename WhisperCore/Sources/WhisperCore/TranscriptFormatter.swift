import Foundation

/// Renders a `Transcript` into the text formats the apps need.
///
/// The timestamped format matches the existing Mac-mini pipeline output
/// (`[MM:SS - MM:SS] text`) so transcripts look the same regardless of
/// whether they were produced on-device or by the server.
public enum TranscriptFormatter {

    /// Plain text, no timestamps. Good for clipboard.
    public static func plainText(_ transcript: Transcript) -> String {
        transcript.text
    }

    /// One line per segment: `[MM:SS - MM:SS] text`.
    public static func timestamped(_ transcript: Transcript) -> String {
        transcript.segments
            .map { "[\(clockTime($0.start)) - \(clockTime($0.end))] \($0.text.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
    }

    /// SubRip subtitle format (used later by SubWhisper).
    public static func srt(_ transcript: Transcript) -> String {
        transcript.segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(srtTime(segment.start)) --> \(srtTime(segment.end))
            \(segment.text.trimmingCharacters(in: .whitespaces))
            """
        }
        .joined(separator: "\n\n") + "\n"
    }

    /// `MM:SS`, rolling over to `H:MM:SS` past one hour.
    static func clockTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// `HH:MM:SS,mmm` as required by SRT.
    static func srtTime(_ seconds: TimeInterval) -> String {
        let totalMillis = max(0, Int((seconds * 1000).rounded()))
        let total = totalMillis / 1000
        let millis = totalMillis % 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, millis)
    }
}
