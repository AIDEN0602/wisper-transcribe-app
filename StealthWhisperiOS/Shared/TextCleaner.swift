import Foundation

/// One stage in the text-cleaning pipeline. Deliberately narrow so a later
/// *optional* stage (e.g. a light LLM polish pass) can be appended without
/// touching any existing rule-based stage. No network/LLM stage exists
/// yet, and none should be wired without Minje's explicit approval of a
/// personal API key — this protocol only exists to make that additive
/// later, not to enable it now.
protocol TextCleaningStage {
    func clean(_ text: String) -> String
}

/// Ordered, swappable pipeline of cleaning stages.
struct TextCleaningPipeline {
    let stages: [TextCleaningStage]

    /// Fully rule-based, fully on-device, no network access.
    static let `default` = TextCleaningPipeline(stages: [
        StutterCollapseStage(),
        FillerWordStage(),
        WhitespaceTidyStage(),
    ])

    func run(_ text: String) -> String {
        stages.reduce(text) { $1.clean($0) }
    }
}

/// Rule-based filler-word and stutter cleanup, applied to one *finished*
/// utterance. Callers must only run this on final speech-recognition
/// results, never on partial/streaming text, or the user will see the
/// live transcript flicker as words are struck mid-utterance.
enum TextCleaner {
    static func clean(_ text: String) -> String {
        TextCleaningPipeline.default.run(text)
    }
}

// MARK: - Stutter collapse

/// Collapses an immediately-repeated word or short phrase (1-3 words) —
/// "그래서 그래서" → "그래서", "I I think" → "I think". Only exact,
/// immediately-adjacent repeats are collapsed, so this never touches
/// normal (non-stuttered) text.
struct StutterCollapseStage: TextCleaningStage {
    func clean(_ text: String) -> String {
        // Group 1 must start right at a whitespace/string-start boundary —
        // without that, \S+ can begin mid-word (e.g. matching "is" inside
        // "this" against a following real "is"), producing a false stutter.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|(?<=\s))(\S+(?:\s+\S+){0,2})\s+\1(?=\s|[,.!?，。]|$)"#,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        // Re-scan after each fix: collapsing one stutter can reveal another
        // (e.g. "I I I think" needs two passes), bounded to avoid any risk
        // of looping forever on unexpected input.
        for _ in 0..<5 {
            let range = NSRange(result.startIndex..., in: result)
            guard let match = regex.firstMatch(in: result, options: [], range: range),
                  let fullRange = Range(match.range, in: result),
                  let groupRange = Range(match.range(at: 1), in: result)
            else { break }
            result.replaceSubrange(fullRange, with: String(result[groupRange]))
        }
        return result
    }
}

// MARK: - Filler words

/// Removes standalone/leading filler words and interjections. Conservative
/// by construction: every rule requires the filler to be its own token
/// (bounded by whitespace, punctuation, or a string edge) — never a
/// substring of a real word — and "like"/"you know" additionally require
/// the comma-bounded interjection shape so genuine content ("I like
/// turtles", "you know the answer") is never touched.
struct FillerWordStage: TextCleaningStage {
    /// Korean fillers: elongation shows up as the whole syllable repeating
    /// ("어" → "어어어"), so the core pattern repeats the whole token.
    private static let koreanFillers = ["음", "어", "그", "아", "저기", "뭐랄까", "그러니까"]

    /// English fillers: elongation shows up as the last letter stretching
    /// ("um" → "ummmm"), so only the final character repeats.
    private static let englishFillers = ["um", "uh", "er", "hmm"]

    func clean(_ text: String) -> String {
        var result = text
        result = removeStandalone(result, tokens: Self.koreanFillers) { escaped in
            "(?:\(escaped)){1,}"
        }
        result = removeStandalone(result, tokens: Self.englishFillers, caseInsensitive: true) { escaped in
            guard let last = escaped.last else { return escaped }
            return String(escaped.dropLast()) + String(last) + "+"
        }
        result = removeLeadingLike(result)
        result = removeYouKnowInterjection(result)
        return result
    }

    private func removeStandalone(
        _ text: String,
        tokens: [String],
        caseInsensitive: Bool = false,
        corePattern: (String) -> String
    ) -> String {
        var result = text
        for token in tokens {
            let escaped = NSRegularExpression.escapedPattern(for: token)
            let core = corePattern(escaped)
            // Optional "trailing off" punctuation (음..., um~) belongs to the
            // same interjection and is removed with it; a following comma is
            // left alone here and cleaned up by WhitespaceTidyStage instead.
            let pattern = #"(?:^|(?<=[\s,，。.!?…~-]))"# + core + #"[.…~-]*(?=$|[\s,，。.!?])"#
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result
    }

    /// "like" is only a filler when it opens a sentence and is immediately
    /// followed by a pause (comma) — e.g. "Like, I dunno". Never removed
    /// mid-sentence, so "I like turtles" is untouched.
    private func removeLeadingLike(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|(?<=[.!?]\s)|(?<=\n))[Ll]ike\s*,\s*"#
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// "you know" is only a filler as its own comma-bounded interjection —
    /// "You know, it's fine" or "it's fine, you know, we'll manage" — never
    /// when it carries real content ("you know the answer").
    private func removeYouKnowInterjection(_ text: String) -> String {
        var result = text
        if let leading = try? NSRegularExpression(
            pattern: #"(?:^|(?<=[.!?]\s)|(?<=\n))[Yy]ou know\s*,\s*"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = leading.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        if let midOrTrailing = try? NSRegularExpression(
            pattern: #",\s*[Yy]ou know(?=[,.!?]|$)"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = midOrTrailing.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result
    }
}

// MARK: - Whitespace tidy

/// Cleans up the spacing/punctuation debris a removal can leave behind
/// (a leading comma, a double space, space before punctuation).
struct WhitespaceTidyStage: TextCleaningStage {
    func clean(_ text: String) -> String {
        var result = text
        result = replacing(result, pattern: #"[ \t]{2,}"#, with: " ")
        result = replacing(result, pattern: #"\s+([,.!?，。])"#, with: "$1")
        result = replacing(result, pattern: #"^[,，]\s*"#, with: "")
        result = replacing(result, pattern: #"([,，])\s*\1+"#, with: "$1")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
