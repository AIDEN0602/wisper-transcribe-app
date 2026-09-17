import Foundation

/// One recording that finished locally but hasn't reached the server yet
/// (the most recent upload attempt failed — most likely the server was
/// unreachable). Retried automatically the next time the app comes to the
/// foreground. Deliberately local-only, NOT part of the synced
/// HistoryEntry schema — Mac/Watch don't need to know about a job that
/// hasn't produced a transcript yet, and server mode must never silently
/// fall back to on-device (that would trigger the model download the
/// user turned server mode on to avoid).
struct PendingUpload: Identifiable, Codable, Equatable {
    let id: UUID
    let audioFilename: String
    let source: HistorySource
    let durationSeconds: TimeInterval
    let createdAt: Date
    let recordingID: String?
}

final class PendingUploadStore: ObservableObject {
    @Published private(set) var items: [PendingUpload] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("pending_uploads.json")
        load()
    }

    /// Persists the queue item *before* an upload starts. Returning the
    /// existing item makes this operation idempotent across app relaunches.
    @discardableResult
    func add(audioFilename: String, source: HistorySource, durationSeconds: TimeInterval, recordingID: String?) -> PendingUpload {
        if let existing = items.first(where: { $0.audioFilename == audioFilename }) {
            return existing
        }
        let pending = PendingUpload(
            id: UUID(),
            audioFilename: audioFilename,
            source: source,
            durationSeconds: durationSeconds,
            createdAt: Date(),
            recordingID: recordingID
        )
        items.append(pending)
        save()
        return pending
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([PendingUpload].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
