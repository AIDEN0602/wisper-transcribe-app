import Foundation
import os

/// Where history is stored and whether it reached iCloud — the questions
/// that took a filesystem autopsy to answer the first time this broke.
/// Read with: `log show --predicate 'subsystem == "com.stealth.whisper"' --last 10m`
let historyLog = Logger(subsystem: "com.stealth.whisper", category: "history")

/// Which device produced a history entry. Encodes/decodes as the same
/// plain "mac"/"iphone"/"watch" string the Mac app's `HistoryEntry.source`
/// uses, so the two Swift types stay wire-compatible.
enum HistorySource: String, Codable {
    case mac
    case iphone
    case watch
}

/// One timestamped chunk of transcribed speech, mirroring WhisperCore's
/// `TranscriptSegment` without depending on that package (this file is
/// shared by the watchOS target, which never links WhisperCore/WhisperKit).
struct HistorySegment: Codable, Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// One finished transcription, in the schema shared by the Mac, iPhone, and
/// Watch apps via the iCloud container (`Documents/History/<uuid>.json`).
/// Field names/types must match `StealthWhisperMac/.../HistoryStore.swift`'s
/// `HistoryEntry` exactly.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let source: HistorySource
    let durationSeconds: TimeInterval
    let language: String
    let text: String
    let segments: [HistorySegment]
    let audioFilename: String?
    /// Short human title assigned when the transcription finishes (LLM
    /// summary first line in server mode, first spoken sentence
    /// otherwise). Optional so entries written before this field existed
    /// still decode; the Mac app ignores the extra key.
    let title: String?

    /// What list rows show: the assigned title, falling back to the first
    /// transcript line for pre-title entries.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return preview
    }

    var preview: String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        if firstLine.isEmpty { return "(no speech detected)" }
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, source, durationSeconds, language, text, segments, audioFilename, title
    }

    init(
        id: UUID, createdAt: Date, source: HistorySource, durationSeconds: TimeInterval,
        language: String, text: String, segments: [HistorySegment],
        audioFilename: String?, title: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.durationSeconds = durationSeconds
        self.language = language
        self.text = text
        self.segments = segments
        self.audioFilename = audioFilename
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        source = try container.decode(HistorySource.self, forKey: .source)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        language = try container.decode(String.self, forKey: .language)
        text = try container.decode(String.self, forKey: .text)
        segments = try container.decode([HistorySegment].self, forKey: .segments)
        audioFilename = try container.decodeIfPresent(String.self, forKey: .audioFilename)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

/// Reads and writes transcription history from the shared iCloud Documents
/// container (`iCloud.com.stealth.whisper`), one JSON file per entry under
/// `Documents/History/`, plus optional audio under `Documents/History/audio/`.
/// iCloud Documents (not CloudKit) syncs these files to every device signed
/// into the same iCloud account, so iPhone, Watch, and Mac converge on the
/// same list. Falls back to a local folder when iCloud Drive isn't
/// available (e.g. a fresh simulator with no iCloud account signed in), and
/// sweeps any entries written during a local-fallback period into the
/// shared folder the first time it becomes available.
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var isUsingICloud = false

    static let containerID = "iCloud.com.stealth.whisper"

    private var folder: URL
    private(set) var audioFolder: URL
    private var metadataQuery: NSMetadataQuery?
    /// Backoff schedule (seconds) for re-asking where the iCloud container is.
    private static let retryDelays: [TimeInterval] = [2, 5, 15, 60, 300]
    private var retryIndex = 0

    /// Always-local fallback location, independent of whether iCloud is
    /// actually in use this launch — needed both as the fallback itself
    /// and as the source for the one-time sweep once iCloud appears.
    private static var localFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("History", isDirectory: true)
    }

    init() {
        folder = Self.localFolder
        audioFolder = folder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        reload()
        attachToICloud()
    }

    // MARK: - iCloud attachment

    /// Finds the shared container off the main thread and switches storage
    /// over to it once it exists.
    ///
    /// `url(forUbiquityContainerIdentifier:)` is documented as slow enough
    /// that Apple tells callers never to run it on the main thread, and it
    /// returns nil until the iCloud daemon has finished setting the
    /// container up — routinely the case during app launch. Asking once,
    /// synchronously, in `init` therefore pinned the app to local-only
    /// storage for the entire session with no way back, which is why
    /// transcripts stayed on the device that made them. Ask off-thread
    /// instead, retry with backoff, and promote anything written meanwhile.
    private func attachToICloud(after delay: TimeInterval = 0) {
        guard !isUsingICloud else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let documents = FileManager.default
                .url(forUbiquityContainerIdentifier: Self.containerID)?
                .appendingPathComponent("Documents", isDirectory: true)
            DispatchQueue.main.async {
                if let documents {
                    self.adopt(documents.appendingPathComponent("History", isDirectory: true))
                } else {
                    let next = Self.retryDelays[min(self.retryIndex, Self.retryDelays.count - 1)]
                    self.retryIndex += 1
                    historyLog.error("iCloud container unavailable (attempt \(self.retryIndex)); retrying in \(next, format: .fixed(precision: 0))s")
                    self.attachToICloud(after: next)
                }
            }
        }
    }

    private func adopt(_ sharedFolder: URL) {
        guard !isUsingICloud else { return }
        let audio = sharedFolder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        folder = sharedFolder
        audioFolder = audio
        isUsingICloud = true
        sweepLocalEntriesIntoSharedFolder()
        reload()
        startWatchingForChanges()
        historyLog.notice("history attached to iCloud at \(sharedFolder.path, privacy: .public) — \(self.entries.count) entries")
    }

    /// Re-reads history now, and retries the iCloud hookup if it never
    /// landed — what a pull-to-refresh or a foreground event should call.
    func refresh() {
        reload()
        if !isUsingICloud {
            retryIndex = 0
            attachToICloud()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        metadataQuery?.stop()
    }

    /// Appends a finished transcription to shared history and returns it.
    /// `audioURL`, if provided, is copied into the shared audio folder
    /// (matching the Mac app's `<uuid>.<original extension>` naming).
    @discardableResult
    func addEntry(
        source: HistorySource,
        durationSeconds: TimeInterval,
        language: String,
        text: String,
        segments: [HistorySegment],
        audioURL: URL? = nil,
        title: String? = nil,
        /// Pass the server-job-derived id for a recording the Mac mini
        /// processed, so pulling that same job back later recognises it
        /// as this entry instead of adding a second copy.
        id: UUID = UUID()
    ) -> HistoryEntry {
        var audioFilename: String?
        if let audioURL {
            let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension
            let name = "\(id.uuidString).\(ext)"
            let dest = audioFolder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: audioURL, to: dest)) != nil {
                audioFilename = name
            }
        }

        let entry = HistoryEntry(
            id: id,
            createdAt: Date(),
            source: source,
            durationSeconds: durationSeconds,
            language: language,
            text: text,
            segments: segments,
            audioFilename: audioFilename,
            title: Self.normalizedTitle(title) ?? Self.makeTitle(from: text)
        )
        write(entry)
        entries = merge(entries, adding: entry)
        return entry
    }

    /// Trims a caller-supplied title (server LLM summary line) down to one
    /// clean row; returns nil for empty/whitespace input so the fallback
    /// generator runs instead.
    private static func normalizedTitle(_ title: String?) -> String? {
        guard let firstLine = title?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !firstLine.isEmpty
        else { return nil }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    /// Fallback title from the transcript itself: the first spoken
    /// sentence, with diarization decorations ("[00:01 - 00:07]",
    /// "SPEAKER_00:") stripped so titles read like content, not logs.
    static func makeTitle(from text: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine)
            if let bracketEnd = line.firstIndex(of: "]"), line.hasPrefix("[") {
                line = String(line[line.index(after: bracketEnd)...])
            }
            if let range = line.range(of: #"^\s*SPEAKER[_ ]?\d+\s*:"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let sentence = line
                .split(whereSeparator: { ".!?。".contains($0) })
                .first.map(String.init) ?? line
            // Whisper repeats itself on near-silent audio ("version
            // version version …"), which made whole stretches of the list
            // look identical. Collapse runs of the same word.
            var words: [String] = []
            for word in sentence.components(separatedBy: .whitespacesAndNewlines) where !word.isEmpty {
                if words.last?.caseInsensitiveCompare(word) != .orderedSame { words.append(word) }
            }
            let compact = words.joined(separator: " ")
            guard !compact.isEmpty else { continue }
            return compact.count > 60 ? String(compact.prefix(60)) + "…" : compact
        }
        return nil
    }

    /// True if this entry is already stored — the guard that keeps repeated
    /// server imports from duplicating the same transcript.
    func contains(_ id: UUID) -> Bool {
        entries.contains { $0.id == id } || FileManager.default.fileExists(atPath: jsonFileURL(for: id).path)
    }

    /// Catches the same recording arriving under a different id — entries
    /// this device saved before local entries and server jobs shared an
    /// identity can only be recognised by what they say.
    func containsSimilar(text: String) -> Bool {
        let key = Self.dedupKey(text)
        guard key.count > 20 else { return false }
        return entries.contains { Self.dedupKey($0.text) == key }
    }

    private static func dedupKey(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace }.prefix(120))
    }

    /// Adds an entry that was produced elsewhere (a finished job pulled off
    /// the Mac mini) without re-deriving its identity or title.
    func importEntry(_ entry: HistoryEntry) {
        guard !contains(entry.id) else { return }
        write(entry)
        entries = merge(entries, adding: entry)
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        try? FileManager.default.removeItem(at: jsonFileURL(for: entry.id))
        if let filename = entry.audioFilename {
            try? FileManager.default.removeItem(at: audioFolder.appendingPathComponent(filename))
        }
    }

    /// Returns the original audio that belongs to a transcript, when this
    /// device has it. Audio may be an iCloud placeholder on first access; in
    /// that case request the download and let the caller try again once the
    /// history view refreshes.
    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let filename = entry.audioFilename else { return nil }
        let url = audioFolder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return nil
    }

    // MARK: - Disk I/O

    private func jsonFileURL(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    private func write(_ entry: HistoryEntry) {
        let url = jsonFileURL(for: entry.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { safeURL in
            try? data.write(to: safeURL, options: .atomic)
        }
    }

    /// Re-reads every entry file; also nudges iCloud to download files that
    /// only exist as `.icloud` placeholders on this device so far.
    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [HistoryEntry] = []
        for file in files {
            if file.lastPathComponent.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                continue
            }
            guard file.pathExtension == "json" else { continue }

            var readData: Data?
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) { safeURL in
                readData = try? Data(contentsOf: safeURL)
            }
            if let readData, let entry = try? decoder.decode(HistoryEntry.self, from: readData) {
                loaded.append(entry)
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        if loaded != entries {
            entries = loaded
        }
    }

    private func merge(_ current: [HistoryEntry], adding entry: HistoryEntry) -> [HistoryEntry] {
        var byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        byID[entry.id] = entry
        return byID.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// If entries were saved locally before the iCloud container became
    /// available on this device, move them into the shared folder once so
    /// nothing is stranded outside the synced history.
    private func sweepLocalEntriesIntoSharedFolder() {
        let local = Self.localFolder
        guard local != folder,
              let files = try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
        else { return }

        for file in files where file.pathExtension == "json" {
            let dest = folder.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.moveItem(at: file, to: dest)
            }
        }
        let localAudio = local.appendingPathComponent("audio", isDirectory: true)
        if let audioFiles = try? FileManager.default.contentsOfDirectory(at: localAudio, includingPropertiesForKeys: nil) {
            for file in audioFiles {
                let dest = audioFolder.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.moveItem(at: file, to: dest)
                }
            }
        }
    }

    // MARK: - iCloud change notifications

    /// Watches the ubiquitous container for JSON files written by other
    /// devices and reloads the merged list when they show up.
    private func startWatchingForChanges() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.json")

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQueryUpdate),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQueryUpdate),
            name: .NSMetadataQueryDidUpdate, object: query
        )
        query.start()
        metadataQuery = query
    }

    @objc private func handleQueryUpdate(_ notification: Notification) {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        let items = (query.results as? [NSMetadataItem]) ?? []
        for item in items {
            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        query.enableUpdates()

        // Give iCloud a brief moment to materialize newly-downloaded files.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reload()
        }
    }
}
