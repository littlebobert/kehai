import AppKit
import AVFoundation
import SwiftUI

/// The landing page's pencil sketch of the icon, in the icon's shape, as in Karui for Mac's
/// About window. The still stays underneath and is all that shows with Reduce Motion on;
/// the video plays only while its window is on screen.
struct AnimatedAppIcon: View {
    /// The bundled sketch: `<name>.jpg` for the still and `<name>.mp4` for the flipbook.
    let name: String
    /// Shown under the video while it starts, when that's not the finished still.
    var firstFrameName: String?
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: NSImage {
        let stillName = reduceMotion ? name : firstFrameName ?? name
        return Bundle.main.url(forResource: stillName, withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
            ?? NSApp.applicationIconImage
    }

    var body: some View {
        ZStack {
            Image(nsImage: still)
                .resizable()
            if !reduceMotion, let url = Bundle.main.url(forResource: name, withExtension: "mp4") {
                LoopingVideo(url: url)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }
}

private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingVideoView { LoopingVideoView(url: url) }
    func updateNSView(_ view: LoopingVideoView, context: Context) {}
}

/// Plays while its window is visible and pauses when it's closed, hidden, or covered, as the
/// landing page pauses while the page is hidden.
private final class LoopingVideoView: NSView {
    private let player = AVQueuePlayer()
    private let looper: AVPlayerLooper

    init(url: URL) {
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        super.init(frame: .zero)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        self.layer = layer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(syncPlayback),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        syncPlayback()
    }

    @objc private func syncPlayback() {
        if window?.occlusionState.contains(.visible) == true {
            player.play()
        } else {
            player.pause()
        }
    }
}
