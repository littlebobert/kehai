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
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }
            Text("Kehai")
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, -5)
            Text("Browse windows intelligently grouped by task.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Made in Japan", destination: URL(string: "https://littlebobert.github.io/kehai.html")!)
                .font(.callout)
                .foregroundStyle(.link)
            Link("Open source under the MIT License", destination: URL(string: "https://github.com/littlebobert/kehai/blob/main/LICENSE")!)
                .font(.caption)
                .foregroundStyle(.link)
            Button("Report a Bug…") {
                reportError = nil
                reportBug()
            }
            .buttonStyle(.bordered)
            if let reportError {
                Text(reportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 320, height: 300)
    }
}

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init(reportBug: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Kehai"
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        if let closeButton = window.standardWindowButton(.closeButton),
           let titlebarView = closeButton.superview {
            let titleLabel = NSTextField(labelWithString: "About Kehai")
            titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            titleLabel.alignment = .center
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titlebarView.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
            ])
        }

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
