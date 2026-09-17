import Foundation

/// Talks to Minje's home Whisper server (Tailscale Funnel, publicly
/// reachable at this exact hostname — verified live: POST /upload,
/// GET /jobs, and GET /download/<job_id>/full_transcript.txt all work
/// over plain HTTPS with no auth). This is the DEFAULT processing path
/// for watch recordings; on-device WhisperCore stays as the offline
/// fallback and always handles iPhone-initiated recordings directly.
///
/// Verified against the real server:
/// - GET /jobs returns `{"jobs": {"<job_id>": {"step", "step_label",
///   "progress", "filename", "diarize", "duration", "num_speakers",
///   "output_dir", "summary_preview", ...}}}`. There is no list of
///   output filenames — `output_dir` is a local path on the Mac mini's
///   filesystem, not fetchable over HTTP, and `summary_preview` is a
///   truncated preview of the LLM summary, not the transcript.
/// - GET /download/<job_id>/full_transcript.txt is a **fixed filename**
///   regardless of the original upload's filename, and always exists
///   once a job reaches `step == "done"`. That's the one this client
///   fetches. A `summary.txt` also exists at the same path shape but
///   isn't used here (the server already sends that to Telegram).
/// - Diarized jobs prefix the file with a Korean header block and use
///   `[MM:SS - MM:SS] SPEAKER_00: text` lines; non-diarized jobs are
///   flowing prose with no timestamps at all. `parseTranscript` handles
///   both shapes.
enum ServerUploadError: LocalizedError {
    case uploadFailed(String)
    case jobFailed(String)
    case timedOut
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let message): return "Upload failed: \(message)"
        case .jobFailed(let message): return "Server processing failed: \(message)"
        case .timedOut: return "Server processing timed out"
        case .transcriptUnavailable: return "Server finished but the transcript wasn't available"
        }
    }
}

struct ServerJobResult {
    /// The mini's job id, so the entry can adopt the same identity the
    /// shared history import derives from it.
    var jobID: String? = nil
    let text: String
    let segments: [HistorySegment]
    let language: String?
    /// First line of the server's LLM `summary_preview`, if the job
    /// exposed one — used as the history entry's title.
    var summaryTitle: String? = nil
}

final class ServerUploadManager: NSObject {
    static let shared = ServerUploadManager()

    private static let baseURL = URL(string: "https://mj-macmini.tail1611c2.ts.net")!
    private static let backgroundSessionID = "com.stealth.whisper.server-upload"

    /// Only the initial upload uses a background URLSession configuration
    /// (per spec: "uploads should ... survive app backgrounding" — a
    /// multi-minute recording upload is the part actually at risk of
    /// being killed mid-transfer). Polling /jobs and fetching the
    /// transcript are quick, small requests on a plain session.
    private lazy var uploadSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let pollingSession = URLSession(configuration: .ephemeral)

    /// Set by the app-launch background-session-events hook
    /// (see AppDelegate) so a transfer that completes while the app was
    /// suspended can still call back into iOS before it re-suspends us.
    var backgroundCompletionHandler: (() -> Void)?

    private var responseBuffers: [Int: Data] = [:]
    private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]
    /// A background task can finish before the relaunched app has rebuilt its
    /// async continuation. Keep that response by filename so the durable
    /// pending queue can adopt it instead of submitting a duplicate job.
    private var completedResponses: [String: Result<Data, Error>] = [:]
    private let responseStateLock = NSLock()

    /// Full pipeline: upload, poll until done, fetch the transcript.
    func processRecording(fileURL: URL, diarize: Bool = true, express: Bool = false) async throws -> ServerJobResult {
        let jobID = try await upload(fileURL: fileURL, diarize: diarize, express: express)
        let summaryPreview = try await waitForCompletion(jobID: jobID)
        var result = try await fetchTranscript(jobID: jobID)
        result.summaryTitle = summaryPreview
        result.jobID = jobID
        return result
    }

    // MARK: - Upload (background session)

    private func upload(fileURL: URL, diarize: Bool, express: Bool) async throws -> String {
        let filename = fileURL.lastPathComponent
        let data: Data

        if let completed = takeCompletedResponse(for: filename) {
            data = try completed.get()
        } else if let existing = await outstandingUpload(for: filename) {
            data = try await response(for: existing, filename: filename)
        } else {
            let boundary = "StealthWhisper-\(UUID().uuidString)"
            let bodyURL = try Self.writeMultipartBody(
                fileURL: fileURL,
                boundary: boundary,
                diarize: diarize,
                express: express
            )
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            var request = URLRequest(url: Self.baseURL.appendingPathComponent("upload"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let task = uploadSession.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = filename
            data = try await response(for: task, filename: filename)
        }

        return try Self.decodeJobID(from: data)
    }

    private static func decodeJobID(from data: Data) throws -> String {
        struct UploadResponse: Decodable {
            let job_id: String
        }
        do {
            return try JSONDecoder().decode(UploadResponse.self, from: data).job_id
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "(non-text response)"
            throw ServerUploadError.uploadFailed(body)
        }
    }

    private func outstandingUpload(for filename: String) async -> URLSessionUploadTask? {
        await withCheckedContinuation { continuation in
            uploadSession.getAllTasks { tasks in
                continuation.resume(returning: tasks.compactMap { $0 as? URLSessionUploadTask }
                    .first { $0.taskDescription == filename })
            }
        }
    }

    private func response(for task: URLSessionUploadTask, filename: String) async throws -> Data {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            // Make checking a just-finished task and registering interest in
            // an in-flight one atomic with the delegate's completion path.
            responseStateLock.lock()
            if let completed = completedResponses.removeValue(forKey: filename) {
                responseStateLock.unlock()
                continuation.resume(with: completed)
                return
            }
            continuations[task.taskIdentifier] = continuation
            responseStateLock.unlock()
            task.resume()
        }
    }

    private func takeCompletedResponse(for filename: String) -> Result<Data, Error>? {
        responseStateLock.lock()
        defer { responseStateLock.unlock() }
        return completedResponses.removeValue(forKey: filename)
    }

    private static func writeMultipartBody(fileURL: URL, boundary: String, diarize: Bool, express: Bool) throws -> URL {
        let filename = fileURL.lastPathComponent
        let audioData = try Data(contentsOf: fileURL)

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "diarize", value: diarize ? "true" : "false")
        appendField(name: "express", value: express ? "true" : "false")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        try body.write(to: tempURL)
        return tempURL
    }

    // MARK: - Polling (plain session)

    /// Returns the job's `summary_preview` (if the server produced one) so
    /// the caller can title the history entry with the LLM summary.
    @discardableResult
    private func waitForCompletion(jobID: String, maxWait: TimeInterval = 30 * 60, pollInterval: TimeInterval = 5) async throws -> String? {
        struct JobsResponse: Decodable { let jobs: [String: JobStatus] }
        struct JobStatus: Decodable {
            let step: String?
            let step_label: String?
            let progress: Double?
            let summary_preview: String?
        }

        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            let (data, _) = try await pollingSession.data(from: Self.baseURL.appendingPathComponent("jobs"))
            if let decoded = try? JSONDecoder().decode(JobsResponse.self, from: data),
               let job = decoded.jobs[jobID] {
                if job.step == "done" || (job.progress ?? 0) >= 100 {
                    return job.summary_preview
                }
                if job.step == "error" {
                    throw ServerUploadError.jobFailed(job.step_label ?? "Unknown server error")
                }
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw ServerUploadError.timedOut
    }

    // MARK: - Transcript fetch (plain session)

    private func fetchTranscript(jobID: String) async throws -> ServerJobResult {
        let url = Self.baseURL.appendingPathComponent("download/\(jobID)/full_transcript.txt")
        let (data, response) = try await pollingSession.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else {
            throw ServerUploadError.transcriptUnavailable
        }
        return Self.parseTranscript(text)
    }

    /// Delegates to the shared parser so the Mac app and this one read the
    /// server's transcripts identically.
    private static func parseTranscript(_ raw: String) -> ServerJobResult {
        let parsed = ServerTranscriptParser.parse(raw)
        return ServerJobResult(text: parsed.text, segments: parsed.segments, language: parsed.language)
    }
}

// MARK: - Background session delegate plumbing

extension ServerUploadManager: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBuffers[dataTask.taskIdentifier, default: Data()].append(data)
    }
}

extension ServerUploadManager: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let data = responseBuffers.removeValue(forKey: id) ?? Data()
        let result: Result<Data, Error>
        if let error {
            result = .failure(error)
        } else if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            result = .failure(ServerUploadError.uploadFailed(message))
        } else {
            result = .success(data)
        }

        responseStateLock.lock()
        let continuation = continuations.removeValue(forKey: id)
        if continuation == nil, let filename = task.taskDescription {
            completedResponses[filename] = result
        }
        responseStateLock.unlock()

        if let continuation {
            continuation.resume(with: result)
        }
    }
}

extension ServerUploadManager: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
