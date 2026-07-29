import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Marks a view as a Command-Tab-style drag hover target.
/// Does not accept the drop into Kehai; it only reports enter/exit so the app can
/// select and dwell-activate the underlying window or app icon.
struct DragHoverCatcher: ViewModifier {
    var onEntered: () -> Void
    var onExited: () -> Void
    var onEnded: () -> Void

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
                onEnded: onEnded
            )
        )
    }
}

extension View {
    func dragHoverCatcher(
        onEntered: @escaping () -> Void,
        onExited: @escaping () -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        modifier(DragHoverCatcher(onEntered: onEntered, onExited: onExited, onEnded: onEnded))
    }
}

private struct DragHoverDropDelegate: DropDelegate {
    let onEntered: () -> Void
    let onExited: () -> Void
    let onEnded: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        // Advertise as a valid target so the system keeps sending hover updates.
        // We still reject the actual drop in performDrop.
        true
    }

    func dropEntered(info: DropInfo) {
        onEntered()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // .move keeps the drag alive without promising Kehai will consume files.
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        // Never ingest the payload. If dwell already activated a target and hid
        // Kehai, the drop lands on that app; if not, rejecting here is correct.
        onEnded()
        return false
    }
}
