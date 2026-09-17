import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardRootView>?
    private lazy var engine = DictationEngine(
        hasFullAccess: { [weak self] in self?.hasFullAccess ?? false },
        insertText: { [weak self] text in self?.textDocumentProxy.insertText(text) }
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = KeyboardRootView(
            engine: engine,
            onMic: { [weak self] in self?.handleMic() },
            onCancel: { [weak self] in self?.engine.cancel() },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onGlobe: { [weak self] in self?.advanceToNextInputMode() },
            onStartSession: { [weak self] in self?.openKeyboardSession() }
        )

        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 248)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        engine.startMonitoring()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        engine.stopMonitoring()
    }

    private func handleMic() {
        switch engine.state {
        case .recording:
            engine.stopDictation()
        case .sessionUnavailable:
            openKeyboardSession()
        case .starting, .transcribingLocal, .transcribing:
            break
        default:
            engine.requestDictation()
        }
    }

    /// Some host apps allow this user-initiated URL handoff and others do not.
    /// The keyboard never pretends recording started: only a fresh heartbeat
    /// from the containing app changes the UI to "Session live".
    private func openKeyboardSession() {
        guard let url = URL(string: "stealthwhisper://keyboard-session") else { return }
        engine.reportAppLaunchAttempt()
        extensionContext?.open(url) { [weak self] opened in
            guard !opened, let self else { return }
            DispatchQueue.main.async {
                let selector = NSSelectorFromString("openURL:")
                var responder: UIResponder? = self
                while let current = responder {
                    if current.responds(to: selector) {
                        _ = current.perform(selector, with: url)
                        return
                    }
                    responder = current.next
                }
            }
        }
    }
}
