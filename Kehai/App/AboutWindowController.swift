import AppKit
import SwiftUI

struct AboutView: View {
    let reportBug: () -> Void
    @State private var reportError: String?

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return L10n.format("Version %@", version)
    }

    var body: some View {
        VStack(spacing: 7) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }
            Text("Kehai")
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, -3)
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 1)
            Text("A faster way to switch apps and find windows.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("Made in Japan", destination: URL(string: "https://kehai.jp/")!)
                .font(.callout)
                .foregroundStyle(.link)
            Button("Report a Bug…") {
                reportError = nil
                reportBug()
            }
            .buttonStyle(.bordered)
            Link("Open source under the MIT License", destination: URL(string: "https://github.com/littlebobert/kehai/blob/main/LICENSE")!)
                .font(.callout)
                .foregroundStyle(.link)
                .padding(.top, 5)
            if let reportError {
                Text(reportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 24)
        .frame(width: 320, height: 300, alignment: .top)
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
        window.title = L10n.string("About Kehai")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        if let closeButton = window.standardWindowButton(.closeButton),
           let titlebarView = closeButton.superview {
            let titleLabel = NSTextField(labelWithString: L10n.string("About Kehai"))
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
