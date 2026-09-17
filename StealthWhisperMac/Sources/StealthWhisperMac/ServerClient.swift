import Foundation

/// Uploads a finished Mac recording to the home Mac mini, the same way the
/// iPhone app does, so the transcript exists where every device can see it.
///
/// The Mac still transcribes on-device first — that is what puts text on the
/// clipboard within seconds — and this upload runs afterwards purely so the
/// recording joins the shared history the phone and watch read.
@MainActor
final class ServerClient {

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    /// Uploads the audio and returns the server's job id.
    /// `filename` is sent as `mac_<name>` so the shared history can tell
    /// which device a job came from.
    func upload(fileURL: URL, diarize: Bool = true) async throws -> String {
        let boundary = "StealthWhisperMac-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        appendField("diarize", diarize ? "true" : "false")
        appendField("express", "false")

        let name = fileURL.lastPathComponent.hasPrefix("mac_")
            ? fileURL.lastPathComponent
            : "mac_\(fileURL.lastPathComponent)"
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/m4a\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: ServerHistorySync.baseURL.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "no response body"
            throw ServerClientError.uploadFailed(message)
        }

        struct UploadResponse: Decodable { let job_id: String }
        guard let decoded = try? JSONDecoder().decode(UploadResponse.self, from: data) else {
            throw ServerClientError.uploadFailed(String(data: data, encoding: .utf8) ?? "unrecognised response")
        }
        return decoded.job_id
    }

    /// Cheap liveness probe, so the app can say "the mini isn't reachable"
    /// instead of silently keeping recordings to itself.
    func isReachable() async -> Bool {
        var request = URLRequest(url: ServerHistorySync.baseURL.appendingPathComponent("jobs"))
        request.timeoutInterval = 8
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }
}

enum ServerClientError: LocalizedError {
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .uploadFailed(message): return "Upload to the Mac mini failed: \(message)"
        }
    }
}
