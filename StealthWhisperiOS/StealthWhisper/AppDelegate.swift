import UIKit

/// Only exists to receive the background-URLSession wake-up event so a
/// server upload started before the app was backgrounded/killed can still
/// hand its result back once it finishes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // WatchConnectivity can relaunch the app in the background to deliver
        // a queued recording. Activate the session from the application
        // delegate, before SwiftUI builds its scene, so that delivery does not
        // wait for the user to open the app.
        _ = WatchConnectivityManager.shared
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        ServerUploadManager.shared.backgroundCompletionHandler = completionHandler
    }
}
