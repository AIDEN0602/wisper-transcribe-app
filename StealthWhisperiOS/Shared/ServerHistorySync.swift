import Foundation

/// Pulls the home Mac mini's finished jobs into local history, so every
/// device shows every transcript no matter which device recorded it.
///
/// The mini has been the one place that always had the full picture — it
/// receives the watch's and the phone's uploads and keeps the transcripts —
/// but nothing ever read that list back, which is why finished
/// transcriptions were unreachable from the apps. iCloud Documents remains
/// the peer-to-peer path when it is available; this is the one that works
/// whether or not it is.
///
/// Server shape (verified live):
/// - `GET /jobs` → `{"jobs": {"<job_id>": {"step", "filename", "duration",
///   "started_at", "summary_preview", …}}}`
/// - `GET /download/<job_id>/full_transcript.txt` → the transcript, in the
///   same two formats `ServerTranscriptParser` handles.
@MainActor
final class ServerHistorySync {

    static let baseURL = URL(string: "https://mj-macmini.tail1611c2.ts.net")!

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    struct Job: Decodable {
        let step: String?
        let filename: String?
        let duration: Double?
        let started_at: String?
        let summary_preview: String?
    }

    private struct JobsResponse: Decodable { let jobs: [String: Job] }

    /// Imports every finished job the store doesn't have yet.
    /// Returns how many entries were added.
    /// `skipping` lets a device ignore its own uploads, which it already
    /// stored locally the moment it recorded them.
    @discardableResult
    func importCompletedJobs(
        into store: HistoryStore,
        skipping skippedSources: Set<HistorySource> = [],
        limit: Int = 100
    ) async -> Int {
        guard let jobs = await fetchJobs() else { return 0 }

        let finished = jobs
            .filter { $0.value.step == "done" && !skippedSources.contains(Self.source(for: $0.value.filename)) }
            .sorted { ($0.value.started_at ?? "") > ($1.value.started_at ?? "") }
            .prefix(limit)

        var imported = 0
        for (jobID, job) in finished {
            let entryID = Self.entryID(forJob: jobID)
            if store.contains(entryID) { continue }
            guard let text = await fetchTranscript(jobID: jobID) else { continue }

            let parsed = ServerTranscriptParser.parse(text)
            guard !parsed.text.isEmpty, !store.containsSimilar(text: parsed.text) else { continue }

            let entry = HistoryEntry(
                id: entryID,
                createdAt: Self.recordedAt(job: job) ?? Date(),
                source: Self.source(for: job.filename),
                durationSeconds: job.duration ?? parsed.segments.last?.end ?? 0,
                language: parsed.language ?? "unknown",
                text: parsed.text,
                segments: parsed.segments,
                audioFilename: nil,
                // Not `summary_preview`: the server's LLM writes it as a
                // reply ("Here is the meeting summary in the format you
                // requested:"), which makes every row look identical. The
                // first spoken sentence actually distinguishes recordings.
                title: HistoryStore.makeTitle(from: parsed.text)
            )
            store.importEntry(entry)
            imported += 1
        }
        if imported > 0 {
            historyLog.notice("imported \(imported) transcript(s) from the server")
        }
        return imported
    }

    private func fetchJobs() async -> [String: Job]? {
        do {
            let (data, response) = try await session.data(from: Self.baseURL.appendingPathComponent("jobs"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(JobsResponse.self, from: data).jobs
        } catch {
            historyLog.error("server job list unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fetchTranscript(jobID: String) async -> String? {
        let url = Self.baseURL.appendingPathComponent("download/\(jobID)/full_transcript.txt")
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Identity

    /// A stable entry id per job, so re-importing the same job never
    /// duplicates it — including the job this device uploaded itself.
    static func entryID(forJob jobID: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        // FNV-1a over the job id, spread across the 16 uuid bytes.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(jobID.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        var mix = hash
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: mix)
            mix >>= 8
        }
        var second = hash &* 0x9E37_79B9_7F4A_7C15
        for index in 8..<16 {
            bytes[index] = UInt8(truncatingIfNeeded: second)
            second >>= 8
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4 shape
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Upload filenames carry the moment of recording, which is what the
    /// history should be sorted by; `started_at` is only when the file
    /// reached the server (hours later for a watch recording that waited
    /// for a network).
    static func recordedAt(job: Job) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        if let filename = job.filename,
           let match = filename.range(of: #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#, options: .regularExpression),
           let date = formatter.date(from: String(filename[match])) {
            return date
        }
        // `started_at` is a naive local timestamp with microsecond
        // precision ("2026-03-30T01:24:22.482738") — no timezone and six
        // fractional digits, so ISO8601DateFormatter rejects it outright
        // and every job would otherwise land in history dated "now".
        if let startedAt = job.started_at {
            let trimmed = startedAt.split(separator: ".").first.map(String.init) ?? startedAt
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return formatter.date(from: trimmed)
        }
        return nil
    }

    static func source(for filename: String?) -> HistorySource {
        guard let filename else { return .iphone }
        if filename.hasPrefix("watch_") { return .watch }
        if filename.hasPrefix("mac_") { return .mac }
        return .iphone
    }
}
