import AppKit
import SwiftUI

struct AboutView: View {
    let reportBug: () -> Void
    @State private var reportError: String?

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }
            Text("Kehai")
                .font(.system(size: 26, weight: .semibold))
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Made in Japan")
                .font(.callout)
            Button("Report a Bug…") {
                reportError = nil
                reportBug()
            }
            .buttonStyle(.borderedProminent)
            if let reportError {
                Text(reportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 360, height: 300)
    }
}

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init(reportBug: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Kehai"
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView(reportBug: reportBug))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        window.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
