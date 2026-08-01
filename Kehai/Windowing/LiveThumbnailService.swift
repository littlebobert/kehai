import AppKit
import CoreImage
import CoreMedia
import OSLog
import ScreenCaptureKit

@MainActor
final class LiveThumbnailService {
    private let logger = Logger(subsystem: "com.justin.Kehai", category: "LiveThumbnail")
    private var stream: SCStream?
    private var output: LiveStreamOutput?
    private var generation = 0
    private var isTerminating = false

    func start(windowID: CGWindowID, maximumSize: CGSize, frame: @escaping @MainActor (NSImage) -> Void) async {
        guard !isTerminating, !Task.isCancelled else { return }
        await stop()
        guard !isTerminating, !Task.isCancelled else { return }
        generation += 1
        let currentGeneration = generation

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard !isTerminating,
                  !Task.isCancelled,
                  currentGeneration == generation,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else { return }

            let scale = min(
                maximumSize.width / max(window.frame.width, 1),
                maximumSize.height / max(window.frame.height, 1),
                1
            )
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            let output = LiveStreamOutput { image in
                Task { @MainActor in
                    guard currentGeneration == self.generation else { return }
                    frame(image)
                }
            }
            let stream = SCStream(
                filter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration,
                delegate: output
            )
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.justin.Kehai.live-thumbnail", qos: .userInteractive)
            )
            guard !isTerminating, !Task.isCancelled else { return }
            self.output = output
            self.stream = stream
            try await stream.startCapture()
            guard !isTerminating, !Task.isCancelled else {
                await stop()
                return
            }
            logger.notice("Live capture started")
        } catch {
            guard currentGeneration == generation else { return }
            logger.error("Live capture failed")
            SafeDiagnosticLog.shared.record("live-thumbnail: capture failed")
            stream = nil
            output = nil
        }
    }

    func stop() async {
        generation += 1
        guard let stream else {
            output = nil
            return
        }
        self.stream = nil
        output = nil
        try? await stream.stopCapture()
        logger.notice("Live capture stopped")
    }

    /// Best-effort synchronous teardown for app termination, where awaiting
    /// an async `stop()` would never get a chance to run before process exit.
    func prepareForTermination() {
        isTerminating = true
        generation += 1
        guard let stream else {
            output = nil
            return
        }
        self.stream = nil
        output = nil
        stream.stopCapture { _ in }
        logger.notice("Live capture stopped for termination")
    }
}

private final class LiveStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let receive: @Sendable (NSImage) -> Void
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(receive: @escaping @Sendable (NSImage) -> Void) {
        self.receive = receive
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
        receive(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
    }
}
