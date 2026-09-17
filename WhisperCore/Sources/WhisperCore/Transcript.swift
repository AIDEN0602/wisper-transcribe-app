import Foundation

/// A single time-stamped chunk of transcribed speech.
public struct TranscriptSegment: Codable, Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: TimeInterval { end - start }
}

/// The result of transcribing one audio file or recording.
public struct Transcript: Codable, Sendable {
    public var language: String
    public var segments: [TranscriptSegment]
    /// Wall-clock date the source audio was recorded, when known.
    public var recordedAt: Date?

    public init(language: String, segments: [TranscriptSegment], recordedAt: Date? = nil) {
        self.language = language
        self.segments = segments
        self.recordedAt = recordedAt
    }

    /// All segment text joined into one plain string.
    public var text: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var duration: TimeInterval {
        segments.last?.end ?? 0
    }
}
