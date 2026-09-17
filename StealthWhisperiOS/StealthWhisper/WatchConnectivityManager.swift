import Foundation
import os
import WatchConnectivity

private let watchConnectivityLog = Logger(subsystem: "com.stealth.whisper", category: "watch-connectivity")

/// Receives finished recordings transferred from the paired Apple Watch.
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    /// Called on the main thread with a locally-copied file (and, if the
    /// watch attached one, its own recording ID so status updates can be
    /// reported back) whenever the watch finishes transferring a recording.
    var onFileReceived: ((URL, String?) -> Void)? {
        didSet {
            guard onFileReceived != nil else { return }
            // A background WatchConnectivity launch can deliver the file
            // before AppCoordinator exists. Drain anything saved by that
            // early callback as soon as the coordinator attaches.
            DispatchQueue.main.async { [weak self] in
                self?.deliverPendingFiles()
            }
        }
    }

    private struct Receipt: Codable {
        let recordingID: String?
    }

    private static var incomingFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IncomingWatchRecordings", isDirectory: true)
    }

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// The watch delivers finished recordings as file transfers (not
    /// messages), so the transfer survives the phone being unreachable
    /// at the moment recording stopped.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // `file.fileURL` is deleted as soon as this method returns, so
        // first copy it into a durable inbox. AppCoordinator may not exist
        // yet during a background launch, and keeping this extra copy until
        // it has queued the upload closes that launch-time race completely.
        let inbox = Self.incomingFolder
        let destination = inbox
            .appendingPathComponent(file.fileURL.lastPathComponent)
        let receiptURL = destination.appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
            let recordingID = file.metadata?["recordingID"] as? String
            if let data = try? JSONEncoder().encode(Receipt(recordingID: recordingID)) {
                try? data.write(to: receiptURL, options: .atomic)
            }
            watchConnectivityLog.notice("saved watch recording to durable inbox: \(destination.lastPathComponent, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.deliverPendingFiles()
            }
        } catch {
            watchConnectivityLog.error("could not preserve incoming watch recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies every durable inbox item into the app's regular Recordings
    /// folder, queues it through AppCoordinator, and only then removes the
    /// inbox copy. PendingUploadStore is written synchronously by the handler,
    /// so an app termination at any point leaves at least one recoverable copy.
    private func deliverPendingFiles() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let onFileReceived else { return }

        let manager = FileManager.default
        let inbox = Self.incomingFolder
        guard let files = try? manager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let recordings = files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }

        for inboxURL in recordings {
            let receiptURL = inboxURL.appendingPathExtension("json")
            let receipt = (try? Data(contentsOf: receiptURL))
                .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
            let destination = AudioRecorderManager.recordingsFolder
                .appendingPathComponent(inboxURL.lastPathComponent)

            do {
                if !manager.fileExists(atPath: destination.path) {
                    try manager.copyItem(at: inboxURL, to: destination)
                }
                // The handler adds its durable PendingUpload entry before it
                // starts networking, so it is safe to clear our inbox after
                // this synchronous call returns.
                onFileReceived(destination, receipt?.recordingID)
                try manager.removeItem(at: inboxURL)
                try? manager.removeItem(at: receiptURL)
                watchConnectivityLog.notice("queued watch recording automatically: \(destination.lastPathComponent, privacy: .public)")
            } catch {
                watchConnectivityLog.error("watch inbox delivery will retry: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
