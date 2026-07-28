import AppKit
import SwiftUI

@MainActor
final class InstallationLocationWindowController: NSWindowController, NSWindowDelegate {
    private let continueLaunch: () -> Void
    private var keyMonitor: Any?
    private var selectedIndex = 0 {
        didSet { updateContent() }
    }
    private var errorMessage: String?

    init(continueLaunch: @escaping () -> Void) {
        self.continueLaunch = continueLaunch
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Install Kehai")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        updateContent()
    }

    required init?(coder: NSCoder) { nil }

    static var shouldOfferMove: Bool {
        #if DEBUG
        return false
        #else
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
        return appURL.deletingLastPathComponent() != applicationsURL
        #endif
    }

    func present() {
        guard let window else { return }
        selectedIndex = 0
        errorMessage = nil
        updateContent()
        window.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        continueLaunch()
    }

    private func updateContent() {
        window?.contentView = NSHostingView(rootView: InstallationLocationView(
            selectedIndex: selectedIndex,
            errorMessage: errorMessage,
            choose: { [weak self] index in
                self?.selectedIndex = index
                self?.confirmSelection()
            }
        ))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.keyCode {
            case 53:
                self.finishWithoutMoving()
            case 36, 76:
                self.confirmSelection()
            case 123, 126:
                self.selectedIndex = max(0, self.selectedIndex - 1)
            case 124, 125:
                self.selectedIndex = min(1, self.selectedIndex + 1)
            default:
                return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func confirmSelection() {
        selectedIndex == 0 ? moveToApplications() : finishWithoutMoving()
    }

    private func finishWithoutMoving() {
        removeKeyMonitor()
        window?.delegate = nil
        window?.close()
        continueLaunch()
    }

    private func moveToApplications() {
        let sourceURL = Bundle.main.bundleURL.standardizedFileURL
        let destinationURL = URL(fileURLWithPath: "/Applications/Kehai.app", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: destinationURL, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error {
                        self.errorMessage = L10n.format("Kehai was copied, but could not be reopened: %@", error.localizedDescription)
                        self.updateContent()
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            errorMessage = L10n.format("Kehai could not be moved automatically. Move it to Applications in Finder, then open it again. %@", error.localizedDescription)
            updateContent()
        }
    }
}

private struct InstallationLocationView: View {
    let selectedIndex: Int
    let errorMessage: String?
    let choose: (Int) -> Void

    private var choices: [(String, String)] {
        [
            (L10n.string("Move to Applications"), L10n.string("Copy Kehai to /Applications and reopen it from there.")),
            (L10n.string("Not Now"), L10n.string("Continue running Kehai from its current location."))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Move Kehai to Applications?", systemImage: "folder.badge.plus")
                .font(.title2.weight(.semibold))
            Text("Running Kehai from Applications keeps permissions, updates, Dock shortcuts, and launches tied to one stable copy.")
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Button { choose(index) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedIndex == index ? "circle.inset.filled" : "circle")
                                .foregroundStyle(selectedIndex == index ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.0).fontWeight(.medium)
                                Text(choice.1).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(selectedIndex == index ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            } else {
                Text("Use the arrow keys, then press Return. Escape chooses Not Now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460, height: 250)
    }
}
