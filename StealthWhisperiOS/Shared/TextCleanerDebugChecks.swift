import Foundation
import os

/// There is no XCTest target in this project yet, so this is the
/// "else a small assert-based debug check" fallback: a dozen ko/en cases
/// exercised once at app launch in DEBUG builds only (see
/// `StealthWhisperApp.init()`, itself wrapped in `#if DEBUG`).
///
/// IMPORTANT: this must never crash the app. A regression in a text-polish
/// feature should degrade (a filler rule occasionally over/under-matches),
/// not take down app launch. Failures are reported via `print` and
/// `os_log` only — no `assert`/`fatalError` — so they're loud in Xcode's
/// console and Console.app without ever trapping.
enum TextCleanerDebugChecks {
    private struct Case {
        let name: String
        let input: String
        let expected: String
    }

    private static let cases: [Case] = [
        Case(name: "ko leading filler", input: "음 어제 회의 어떻게 됐어?", expected: "어제 회의 어떻게 됐어?"),
        Case(name: "ko elongated leading filler + comma", input: "어어, 그거 진짜 좋았어요", expected: "그거 진짜 좋았어요"),
        Case(name: "ko leading 그러니까", input: "그러니까 우리는 내일 다시 얘기하자", expected: "우리는 내일 다시 얘기하자"),
        Case(name: "ko stutter phrase", input: "그래서 그래서 이게 문제였어요", expected: "그래서 이게 문제였어요"),
        Case(name: "en stutter word", input: "I I think we should go", expected: "I think we should go"),
        Case(name: "en elongated filler", input: "Umm, so that's the plan", expected: "so that's the plan"),
        Case(name: "en leading like + comma removed", input: "Like, I dunno what to do", expected: "I dunno what to do"),
        Case(name: "en mid-sentence like kept (content)", input: "I like turtles a lot", expected: "I like turtles a lot"),
        Case(name: "en leading you know removed", input: "You know, this is important", expected: "this is important"),
        Case(name: "en you know kept (content)", input: "You know the answer already", expected: "You know the answer already"),
        Case(name: "en mid you know interjection removed", input: "It's fine, you know, we'll manage", expected: "It's fine, we'll manage"),
        Case(name: "no-op passthrough", input: "Let's meet tomorrow at three", expected: "Let's meet tomorrow at three"),
        // Regression guard: stutter-detection must not start mid-word — a
        // naive \S+ pattern previously matched the "is" inside "this" against
        // the real word "is" that follows, corrupting "this" into "th".
        Case(name: "stutter word-boundary regression guard", input: "this is is important", expected: "this is important"),
    ]

    private static let log = Logger(subsystem: "com.stealth.whisper", category: "TextCleanerDebugChecks")

    /// Runs every case and reports any mismatch via `print`/`os_log`.
    /// Deliberately never crashes, traps, or throws — see the type-level
    /// doc comment.
    static func run() {
        var failures: [String] = []
        for testCase in cases {
            let actual = TextCleaner.clean(testCase.input)
            if actual != testCase.expected {
                failures.append("[\(testCase.name)] input=\"\(testCase.input)\" expected=\"\(testCase.expected)\" actual=\"\(actual)\"")
            }
        }
        guard !failures.isEmpty else { return }

        print("TextCleanerDebugChecks: \(failures.count) failure(s):")
        for failure in failures { print("  - \(failure)") }
        log.error("TextCleanerDebugChecks: \(failures.count, privacy: .public) failure(s) — see stdout for details")
    }
}
