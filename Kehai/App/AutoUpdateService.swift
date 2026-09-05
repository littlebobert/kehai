import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AutoUpdateService {
    private(set) var canCheckForUpdates = false

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    func start() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        canCheckForUpdatesObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
                SafeDiagnosticLog.shared.record("updater: availability changed")
            }
        }
    }

    func checkForUpdates() {
        start()
        SafeDiagnosticLog.shared.record("updater: manual check requested")
        updaterController?.checkForUpdates(nil)
    }
}
