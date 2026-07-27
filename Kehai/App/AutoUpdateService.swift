import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AutoUpdateService {
    private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    init(startingUpdater: Bool = true) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdatesObservation = updaterController.updater.observe(
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
        SafeDiagnosticLog.shared.record("updater: manual check requested")
        updaterController.checkForUpdates(nil)
    }
}
