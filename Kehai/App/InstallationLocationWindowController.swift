import AppKit
import SwiftUI

@MainActor
final class InstallationLocationWindowController: NSWindowController, NSWindowDelegate {
    private static let suppressMovePromptKey = "installation.suppressMovePrompt"
    private let continueLaunch: () -> Void
    private var keyMonitor: Any?
    private var selectedIndex = 0 {
        didSet { updateContent() }
    }
    private var errorMessage: String?
    private var installationComplete = false

    init(continueLaunch: @escaping () -> Void) {
        self.continueLaunch = continueLaunch
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
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
        guard !UserDefaults.standard.bool(forKey: suppressMovePromptKey) else { return false }
        let appURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let parentURL = appURL.deletingLastPathComponent()
        return parentURL != applicationsURL
            && !parentURL.path.hasSuffix("/Applications")
        #endif
    }

    func present() {
        guard let window else { return }
        selectedIndex = 0
        errorMessage = nil
        installationComplete = false
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
            installationComplete: installationComplete,
            choose: { [weak self] index in
                self?.selectedIndex = index
                self?.confirmSelection()
            },
            quit: { NSApp.terminate(nil) }
        ))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if self.installationComplete {
                if event.keyCode == 36 || event.keyCode == 76 {
                    NSApp.terminate(nil)
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 53:
                self.finishWithoutMoving()
            case 36, 76:
                self.confirmSelection()
            case 123, 126:
                self.selectedIndex = max(0, self.selectedIndex - 1)
            case 124, 125:
                self.selectedIndex = min(2, self.selectedIndex + 1)
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
        switch selectedIndex {
        case 0:
            moveToApplications()
        case 2:
            UserDefaults.standard.set(true, forKey: Self.suppressMovePromptKey)
            finishWithoutMoving()
        default:
            finishWithoutMoving()
        }
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
            UserDefaults.standard.set(true, forKey: Self.suppressMovePromptKey)
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
            installationComplete = true
            errorMessage = nil
            updateContent()
        } catch {
            errorMessage = L10n.format("Kehai could not be moved automatically. Move it to Applications in Finder, then open it again. %@", error.localizedDescription)
            updateContent()
        }
    }
}

private struct InstallationLocationView: View {
    let selectedIndex: Int
    let errorMessage: String?
    let installationComplete: Bool
    let choose: (Int) -> Void
    let quit: () -> Void

    private var choices: [(String, String)] {
        [
            (L10n.string("Move to Applications"), L10n.string("Copy Kehai to /Applications and reopen it from there.")),
            (L10n.string("Not Now"), L10n.string("Continue running Kehai from its current location.")),
            (L10n.string("Don’t Ask Again"), L10n.string("Continue from this location and stop showing this prompt."))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if installationComplete {
                Spacer()
                Label("Kehai is in Applications", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
                Text("Next, quit this copy and open Kehai from Applications. Finder has selected it for you.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Quit Kehai", action: quit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
            } else {
                Label("Move Kehai to Applications?", systemImage: "folder.badge.plus")
                    .font(.title2.weight(.semibold))
                Text("Running Kehai from Applications keeps permissions, updates, Dock shortcuts, and launches tied to one stable copy.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Button { choose(index) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedIndex == index ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(selectedIndex == index ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.0).fontWeight(.medium)
                                    Text(choice.1)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
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
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Use the arrow keys, then press Return. Escape chooses Not Now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 330)
    }
}
