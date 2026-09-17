import Foundation
import WhisperCore

// Developer CLI for WhisperCore. Doubles as the smoke-test runner on the
// Mac mini, where `swift test` is unavailable (Command Line Tools ship no
// XCTest). Usage:
//
//   whispercore-cli check
//   whispercore-cli transcribe <audio-file> [--model tiny] [--language ko] [--format text|timestamped|srt]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func runChecks() {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("  ok  \(label)")
        } else {
            failures += 1
            print("FAIL  \(label)")
        }
    }

    let transcript = Transcript(language: "ko", segments: [
        TranscriptSegment(start: 0, end: 2.5, text: " 안녕하세요 "),
        TranscriptSegment(start: 2.5, end: 3661.2, text: "긴 회의입니다"),
        TranscriptSegment(start: 3661.2, end: 3662, text: "   "),
    ])

    expect(transcript.text == "안녕하세요 긴 회의입니다", "Transcript.text joins and trims")
    expect(transcript.duration == 3662, "Transcript.duration uses last segment end")

    let timestamped = TranscriptFormatter.timestamped(transcript)
    expect(timestamped.contains("[00:00 - 00:02] 안녕하세요"), "timestamped MM:SS format")
    expect(timestamped.contains("[00:02 - 1:01:01] 긴 회의입니다"), "timestamped hour rollover")

    let srt = TranscriptFormatter.srt(transcript)
    expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,500\n안녕하세요"), "SRT cue formatting")
    expect(srt.contains("01:01:01,200"), "SRT hour timestamp")

    expect(WhisperModel.recommended == .largeTurbo, "recommended model is large turbo")
    expect(ModelCatalog.isDownloaded(.tiny, folder: URL(fileURLWithPath: "/nonexistent")) == false,
           "isDownloaded false for missing folder")

    if failures > 0 {
        fail("\(failures) check(s) failed")
    }
    print("All checks passed.")
}

/// Prints which models are fully downloaded on this machine.
func runModels() {
    for model in WhisperModel.allCases {
        let mark = ModelCatalog.isDownloaded(model) ? "ready  " : "missing"
        print("\(mark)  \(model.rawValue)  (~\(model.approximateDownloadMB) MB)")
    }
    print("\nfolder: \(ModelCatalog.defaultModelFolder().path)")
}

/// Downloads a model up front, so the first recording never waits — and so a
/// stalled download is visible here instead of failing silently in the app.
func runDownload(_ arguments: [String]) async {
    var model = WhisperModel.recommended
    var rest = arguments[...]
    while let flag = rest.first {
        rest = rest.dropFirst()
        guard let value = rest.first else { fail("Missing value for \(flag)") }
        rest = rest.dropFirst()
        switch flag {
        case "--model":
            guard let parsed = WhisperModel(rawValue: value) else {
                fail("Unknown model '\(value)'. Options: \(WhisperModel.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            model = parsed
        default: fail("Unknown flag \(flag)")
        }
    }

    if ModelCatalog.isDownloaded(model) {
        print("\(model.rawValue) is already complete.")
        return
    }

    let transcriber = WhisperTranscriber(model: model)
    await transcriber.observeState { state in
        switch state {
        case let .downloadingModel(progress):
            FileHandle.standardError.write(Data(String(format: "downloading %3.0f%%\r", progress * 100).utf8))
        case .loadingModel:
            FileHandle.standardError.write(Data("\nloading model…\n".utf8))
        default:
            break
        }
    }
    do {
        try await transcriber.prepare()
        print("\n\(model.rawValue) ready at \(ModelCatalog.variantFolder(model).path)")
    } catch {
        fail("\nDownload failed: \(error)")
    }
}

func runTranscribe(_ arguments: [String]) async {
    guard let first = arguments.first else {
        fail("usage: whispercore-cli transcribe <audio-file> [--model NAME] [--language CODE] [--format text|timestamped|srt]")
    }
    let audioURL = URL(fileURLWithPath: first)
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
        fail("No such file: \(audioURL.path)")
    }

    var model = WhisperModel.recommended
    var language: String?
    var format = "timestamped"
    var rest = arguments.dropFirst()
    while let flag = rest.first {
        rest = rest.dropFirst()
        guard let value = rest.first else { fail("Missing value for \(flag)") }
        rest = rest.dropFirst()
        switch flag {
        case "--model":
            guard let parsed = WhisperModel(rawValue: value) else {
                fail("Unknown model '\(value)'. Options: \(WhisperModel.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            model = parsed
        case "--language": language = value
        case "--format": format = value
        default: fail("Unknown flag \(flag)")
        }
    }

    let transcriber = WhisperTranscriber(model: model)
    await transcriber.observeState { state in
        switch state {
        case let .downloadingModel(progress):
            FileHandle.standardError.write(Data(String(format: "downloading model… %3.0f%%\r", progress * 100).utf8))
        case .loadingModel:
            FileHandle.standardError.write(Data("\nloading model…\n".utf8))
        case .transcribing:
            FileHandle.standardError.write(Data("transcribing…\n".utf8))
        default:
            break
        }
    }

    do {
        let start = Date()
        let transcript = try await transcriber.transcribe(audioURL, language: language)
        let elapsed = Date().timeIntervalSince(start)
        switch format {
        case "text": print(TranscriptFormatter.plainText(transcript))
        case "srt": print(TranscriptFormatter.srt(transcript))
        default: print(TranscriptFormatter.timestamped(transcript))
        }
        FileHandle.standardError.write(Data(String(
            format: "\nlanguage=%@ segments=%d audio=%.1fs elapsed=%.1fs\n",
            transcript.language, transcript.segments.count, transcript.duration, elapsed
        ).utf8))
    } catch {
        fail("Transcription failed: \(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "check":
    runChecks()
case "models":
    runModels()
case "download":
    await runDownload(Array(arguments.dropFirst()))
case "transcribe":
    await runTranscribe(Array(arguments.dropFirst()))
default:
    fail("usage: whispercore-cli <check|models|download|transcribe> …")
}
