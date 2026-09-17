import Foundation

/// Turns the Mac mini's `full_transcript.txt` into text plus segments.
///
/// Two shapes come off that server, both handled here:
/// - diarized: a Korean header block (`=== 전체 전사본 ===`, `언어: …`)
///   followed by `[MM:SS - MM:SS] SPEAKER_00: text` lines
/// - non-diarized: flowing prose, no header, no timestamps
enum ServerTranscriptParser {

    struct Parsed {
        let text: String
        let segments: [HistorySegment]
        let language: String?
    }

    static func parse(_ raw: String) -> Parsed {
        var body = raw
        var language: String?

        if raw.hasPrefix("=") {
            if let blankRange = raw.range(of: "\n\n") {
                body = String(raw[blankRange.upperBound...])
            }
            if let langRange = raw.range(of: #"언어:\s*(.+)"#, options: .regularExpression) {
                let value = raw[langRange]
                    .replacingOccurrences(of: "언어:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                language = value.contains("english") ? "en" : (value.contains("korean") ? "ko" : value)
            }
        }

        guard let regex = try? NSRegularExpression(pattern: #"^\[(\d+):(\d+) - (\d+):(\d+)\]\s*(.+)$"#) else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(text: trimmed, segments: [], language: language)
        }

        var segments: [HistorySegment] = []
        var plainLines: [String] = []
        body.enumerateLines { line, _ in
            // A transcript with no speech has a header but no blank line
            // after it, so header rows would otherwise become the entry's
            // text and title ("=== 전체 전사본 ===").
            guard !Self.isHeaderLine(line) else { return }
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, options: [], range: range),
               let m1 = Range(match.range(at: 1), in: line), let s1 = Range(match.range(at: 2), in: line),
               let m2 = Range(match.range(at: 3), in: line), let s2 = Range(match.range(at: 4), in: line),
               let textRange = Range(match.range(at: 5), in: line),
               let startMin = Double(line[m1]), let startSec = Double(line[s1]),
               let endMin = Double(line[m2]), let endSec = Double(line[s2]) {
                let text = Self.stripUnknownSpeaker(String(line[textRange]).trimmingCharacters(in: .whitespaces))
                guard !text.isEmpty else { return }
                segments.append(HistorySegment(start: startMin * 60 + startSec, end: endMin * 60 + endSec, text: text))
                plainLines.append(text)
            } else {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { return }
                plainLines.append(trimmedLine)
            }
        }

        if segments.isEmpty {
            // Use the collected lines, not the raw body: they are the ones
            // with the header already dropped, so a recording with no
            // speech comes back empty instead of titled "=== 전체 전사본 ===".
            let trimmed = plainLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let wholeSegment = trimmed.isEmpty ? [] : [HistorySegment(start: 0, end: 0, text: trimmed)]
            return Parsed(text: trimmed, segments: wholeSegment, language: language)
        }

        return Parsed(text: plainLines.joined(separator: " "), segments: segments, language: language)
    }

    /// Rows of the server's Korean header block, which describe the job
    /// rather than what was said.
    private static func isHeaderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("===") { return true }
        for prefix in ["날짜:", "녹음 시간:", "화자 수:", "언어:"] where trimmed.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Diarization labels every line even when it found one speaker, and
    /// "Unknown:" in front of every sentence is pure noise. Real speaker
    /// numbers (`SPEAKER_00:`) are kept — those carry information.
    private static func stripUnknownSpeaker(_ text: String) -> String {
        guard text.hasPrefix("Unknown:") else { return text }
        return String(text.dropFirst("Unknown:".count)).trimmingCharacters(in: .whitespaces)
    }
}
