import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Marks a view as a Command-Tab-style drag hover target.
/// Reports enter/exit so the app can select and dwell-activate the underlying
/// window or app icon. Dropping files or links right away hands them to `onDrop`,
/// which opens them in the target's app; other payloads are rejected.
struct DragHoverCatcher: ViewModifier {
    var onEntered: () -> Void
    var onExited: () -> Void
    var onDrop: ([URL]) -> Void

    private static let acceptedTypes: [UTType] = [
        .item,
        .content,
        .data,
        .fileURL,
        .url,
        .text,
        .plainText,
        .utf8PlainText,
        .html,
        .rtf,
        .image,
        .png,
        .jpeg,
        .tiff
    ]

    func body(content: Content) -> some View {
        content.onDrop(
            of: Self.acceptedTypes,
            delegate: DragHoverDropDelegate(
                onEntered: onEntered,
                onExited: onExited,
                onDrop: onDrop
            )
        )
    }
}

extension View {
    func dragHoverCatcher(
        onEntered: @escaping () -> Void,
        onExited: @escaping () -> Void,
        onDrop: @escaping ([URL]) -> Void
    ) -> some View {
        modifier(DragHoverCatcher(onEntered: onEntered, onExited: onExited, onDrop: onDrop))
    }
}

private struct DragHoverDropDelegate: DropDelegate {
    /// Payloads Kehai can hand to another app. Files win over links, since a
    /// Finder drag often carries both.
    private static let openableTypes: [UTType] = [.fileURL, .url]

    let onEntered: () -> Void
    let onExited: () -> Void
    let onDrop: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        // Advertise as a valid target so the system keeps sending hover updates,
        // even for payloads performDrop will reject.
        true
    }

    func dropEntered(info: DropInfo) {
        onEntered()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // .copy for openable payloads shows the green "+" badge; .move keeps other
        // drags alive without promising Kehai will consume them.
        DropProposal(operation: info.hasItemsConforming(to: Self.openableTypes) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        onExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        let fileProviders = info.itemProviders(for: [.fileURL])
        let providers = fileProviders.isEmpty ? info.itemProviders(for: [.url]) : fileProviders
        guard !providers.isEmpty else { return false }
        let onDrop = onDrop
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            onDrop(urls)
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
