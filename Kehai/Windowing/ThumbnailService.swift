import AppKit
import OSLog
import ScreenCaptureKit

struct CapturedThumbnail {
    let image: NSImage
    let isUsable: Bool
    let luminanceVariance: Double
    let edgeRatio: Double
    let detailCoverage: Double
    let rejectionReason: String?
}

@MainActor
final class ThumbnailService {
    private let logger = Logger(subsystem: "com.justin.Kehai", category: "Thumbnails")

    func image(for window: SCWindow, maximumSize: CGSize = CGSize(width: 640, height: 400)) async -> CapturedThumbnail? {
        let scale = min(maximumSize.width / max(window.frame.width, 1), maximumSize.height / max(window.frame.height, 1), 1)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
            logger.notice("Thumbnail capture started size=\(configuration.width)x\(configuration.height)")
        do {
            let source = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let flattened = flatten(source)
            let analysis = Self.analyze(flattened)
            let appName = window.owningApplication?.applicationName ?? "Unknown"
            let terminalCoverageIsUsable = appName != "Terminal" || analysis.detailCoverage >= 0.55
            let isUsable = analysis.isUsable && terminalCoverageIsUsable
            let rejectionReason: String? = if !analysis.isUsable {
                "insufficient image detail"
            } else if !terminalCoverageIsUsable {
                "terminal detail is confined to too little of the capture"
            } else {
                nil
            }
                logger.notice("Thumbnail analyzed accepted=\(isUsable) variance=\(analysis.luminanceVariance, format: .fixed(precision: 1)) edges=\(analysis.edgeRatio, format: .fixed(precision: 4)) coverage=\(analysis.detailCoverage, format: .fixed(precision: 3))")
            return CapturedThumbnail(
                image: NSImage(cgImage: flattened, size: NSSize(width: flattened.width, height: flattened.height)),
                isUsable: isUsable,
                luminanceVariance: analysis.luminanceVariance,
                edgeRatio: analysis.edgeRatio,
                detailCoverage: analysis.detailCoverage,
                rejectionReason: rejectionReason
            )
        } catch {
            logger.error("Thumbnail capture failed")
            SafeDiagnosticLog.shared.record("thumbnail: capture failed")
            return nil
        }
    }

    nonisolated static func isUsable(_ image: CGImage) -> Bool {
        analyze(image).isUsable
    }

    nonisolated private static func analyze(_ image: CGImage) -> (isUsable: Bool, luminanceVariance: Double, edgeRatio: Double, detailCoverage: Double) {
        let width = 48
        let height = 30
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return (false, 0, 0, 0) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var luminances = [Double](repeating: 0, count: width * height)
        var sum = 0.0
        for index in 0..<(width * height) {
            let offset = index * 4
            let luminance = 0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])
            luminances[index] = luminance
            sum += luminance
        }
        let mean = sum / Double(luminances.count)
        let variance = luminances.reduce(0) { $0 + pow($1 - mean, 2) } / Double(luminances.count)

        var edgeCount = 0
        var comparisons = 0
        var detailedTiles = Set<Int>()
        let tileColumns = 6
        let tileRows = 5
        for y in 1..<height {
            for x in 1..<width {
                let current = luminances[y * width + x]
                let left = luminances[y * width + x - 1]
                let above = luminances[(y - 1) * width + x]
                if abs(current - left) > 18 || abs(current - above) > 18 {
                    edgeCount += 1
                    let tileX = min(tileColumns - 1, x * tileColumns / width)
                    let tileY = min(tileRows - 1, y * tileRows / height)
                    detailedTiles.insert(tileY * tileColumns + tileX)
                }
                comparisons += 1
            }
        }
        let edgeRatio = Double(edgeCount) / Double(comparisons)
        let detailCoverage = Double(detailedTiles.count) / Double(tileColumns * tileRows)
        let usable = detailCoverage >= 0.20 && ((variance >= 90 && edgeRatio >= 0.02) || edgeRatio >= 0.055)
        return (usable, variance, edgeRatio, detailCoverage)
    }

    private func flatten(_ source: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return source }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage() ?? source
    }
}
