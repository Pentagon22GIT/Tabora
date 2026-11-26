import CoreGraphics
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Geometry captured before desktop transforms, never the Mission Control tile.
struct PreviewFullSizeRequest {
    let ownerPID: pid_t
    let windowSize: CGSize
    let targetPixelSize: CGSize

    var isValid: Bool {
        ownerPID > 0
            && [windowSize.width, windowSize.height,
                targetPixelSize.width, targetPixelSize.height].allSatisfy {
                    $0.isFinite && $0 > 1
                }
    }

    func hasCompatibleAspect(_ image: CGImage) -> Bool {
        MissionControlTransientPreviewValidationPolicy.aspectRatioIsCompatible(
            capturedSize: CGSize(width: image.width, height: image.height),
            expectedSize: windowSize
        )
    }
}

/// A full-sized transparent canvas is not a usable full-sized window capture.
/// A bounded alpha reduction checks occupancy without retaining another image.
enum PreviewImageContentPolicy {
    static func windowContent(in image: CGImage, expectedSize: CGSize) -> CGImage? {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var minX = side, minY = side, maxX = -1, maxY = -1, occupied = 0
            for y in 0..<side {
                for x in 0..<side where buffer[(y * side + x) * 4 + 3] >= 8 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    occupied += 1
                }
            }
            guard occupied > 0 else { return nil }
            let width = maxX - minX + 1, height = maxY - minY + 1
            // A rectangular window tile surrounded by transparent padding on
            // both axes. Keep full-span and intentionally sparse surfaces intact.
            guard max(width, height) < side * 7 / 8,
                  occupied >= width * height * 9 / 10 else { return image }
            let sx = CGFloat(image.width) / CGFloat(side)
            let sy = CGFloat(image.height) / CGFloat(side)
            let bounds = CGRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                width: CGFloat(width) * sx, height: CGFloat(height) * sy).integral
            guard MissionControlTransientPreviewValidationPolicy.aspectRatioIsCompatible(
                capturedSize: bounds.size, expectedSize: expectedSize
            ) else { return nil }
            return image.cropping(to: bounds)
        }
    }
}

enum PreviewCaptureValidation {
    static func image(_ captured: CGImage?, request: PreviewFullSizeRequest?,
                      expectedSize: CGSize, shouldCapture: () -> Bool) -> CGImage? {
        guard shouldCapture(), let captured,
              let image = PreviewImageContentPolicy.windowContent(in: captured, expectedSize: expectedSize),
              request?.hasCompatibleAspect(image) != false, shouldCapture() else { return nil }
        return image
    }
}

enum PreviewCaptureAdmissionPolicy {
    /// Bound background waiting when another request occupies the same lane.
    static let maximumCapacityWait: TimeInterval = 0.45
    static let assistCapacityWait = maximumCapacityWait
    static let missionControlCapacityWait = maximumCapacityWait

    static func effectiveWait(
        requested: TimeInterval,
        isMainThread: Bool
    ) -> TimeInterval {
        guard !isMainThread, requested.isFinite, requested > 0 else { return 0 }
        return min(requested, maximumCapacityWait)
    }
}

enum PreviewCaptureResolution: Equatable {
    case nominal
    case best
}

struct PreviewCaptureLanes {
    private let assistAdmission = DispatchSemaphore(value: 1)
    private let groupAdmission = DispatchSemaphore(value: 1)
    private let sharedBurst = DispatchSemaphore(value: 1)
    private let transientAdmission = DispatchSemaphore(value: 1)

    func acquire(group: Bool, transient: Bool, wait: TimeInterval) -> DispatchSemaphore? {
        let reserved = transient ? transientAdmission : (group ? groupAdmission : assistAdmission)
        if reserved.wait(timeout: .now()) == .success { return reserved }
        if !transient && sharedBurst.wait(timeout: .now()) == .success { return sharedBurst }
        return reserved.wait(timeout: .now() + wait) == .success ? reserved : nil
    }
}

/// Shared physical capture boundary; owns no HOT/COLD or presentation state.
enum WindowPreviewCaptureService {
    private static let lanes = PreviewCaptureLanes()

    // A caller can time out before the framework completes. Only the physical
    // completion releases capacity; a late image cannot reach the caller.
    private final class Reply {
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
    }

    static func capture(
        for windowID: CGWindowID?, capacityWait requestedCapacityWait: TimeInterval,
        isGroupPreview: Bool = false, resolution: PreviewCaptureResolution = .nominal,
        fullSizeRequest: PreviewFullSizeRequest? = nil,
        expectedOwnerPID: pid_t? = nil, shouldCapture: (() -> Bool)? = nil
    ) -> CGImage? {
        guard !Thread.isMainThread, let windowID, windowID != kCGNullWindowID,
              let pid = expectedOwnerPID ?? fullSizeRequest?.ownerPID, pid > 0,
              fullSizeRequest.map({ $0.isValid && $0.ownerPID == pid }) != false,
              shouldCapture?() != false else { return nil }
        let wait = PreviewCaptureAdmissionPolicy.effectiveWait(requested: requestedCapacityWait, isMainThread: false)
        // Reserve capacity by consumer. A stalled framework request keeps only
        // its own lane occupied until the physical operation actually returns.
        guard let admission = lanes.acquire(group: isGroupPreview, transient: fullSizeRequest != nil, wait: wait) else { return nil }
        let deadline = DispatchTime.now() + 3
        let isCurrent = { DispatchTime.now() < deadline && shouldCapture?() != false }
        let authorized = {
            guard isCurrent(), CGPreflightScreenCaptureAccess(),
                  let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
                  records.count == 1, let record = records.first else { return false }
            return (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                && (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        let reply = Reply()
        Task.detached(priority: .userInitiated) {
            defer {
                admission.signal()
                reply.done.signal()
            }
            guard isCurrent(), CGPreflightScreenCaptureAccess(),
                  let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
                  let window = content.windows.first(where: {
                      $0.windowID == windowID && $0.owningApplication?.processID == pid && $0.windowLayer == 0
                  }), isCurrent() else { return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size: CGSize
            if #available(macOS 14, *) { size = filter.contentRect.size }
            else { size = window.frame.size }
            // Never stretch a mismatched source to the expected aspect: the
            // resulting canvas would falsely pass downstream geometry checks.
            if let plan = fullSizeRequest {
                guard MissionControlTransientPreviewValidationPolicy.aspectRatioIsCompatible(
                    capturedSize: size, expectedSize: plan.windowSize) else { return }
            }
            let scale: CGFloat
            if resolution == .nominal {
                scale = 1
            } else if #available(macOS 14, *) {
                scale = CGFloat(filter.pointPixelScale)
            } else {
                let display = content.displays.max {
                    let a = $0.frame.intersection(window.frame), b = $1.frame.intersection(window.frame)
                    return a.width * a.height < b.width * b.height
                }
                let mode = display.flatMap { CGDisplayCopyDisplayMode($0.displayID) }
                scale = mode.map { CGFloat($0.pixelWidth) / CGFloat(max(1, $0.width)) } ?? 1
            }
            guard let pixels = pixelSize(size: size, scale: scale, target: fullSizeRequest?.targetPixelSize) else { return }
            let image = try? await screenshot(filter: filter, pixels: pixels, deadline: deadline, authorized: authorized)
            guard let validated = PreviewCaptureValidation.image(image, request: fullSizeRequest,
                expectedSize: fullSizeRequest?.windowSize ?? size, shouldCapture: isCurrent),
                  authorized() else { return }
            reply.image = validated
        }
        guard reply.done.wait(timeout: deadline) == .success, isCurrent() else { return nil }
        return reply.image
    }

    static func pixelSize(size: CGSize, scale: CGFloat, target: CGSize?) -> CGSize? {
        guard [size.width, size.height, scale].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var factor = scale
        if let target { factor = min(factor, target.width / size.width, target.height / size.height) }
        // Limit transient allocation, including for extreme external-window geometry.
        factor = min(factor, 8192 / max(size.width, size.height), sqrt(16_777_216 / size.width / size.height))
        let result = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        return result.width >= 2 && result.height >= 2 ? result : nil
    }

    private static func screenshot(filter: SCContentFilter, pixels: CGSize, deadline: DispatchTime,
                                   authorized: @escaping () -> Bool) async throws -> CGImage? {
        if #available(macOS 26, *) {
            let config = SCScreenshotConfiguration()
            config.width = Int(pixels.width)
            config.height = Int(pixels.height)
            config.dynamicRange = .sdr
            config.showsCursor = false
            config.ignoreShadows = true
            config.includeChildWindows = false
            guard authorized() else { return nil }
            return try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config).sdrImage
        }
        let config = SCStreamConfiguration()
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        if #available(macOS 14, *) {
            config.ignoreShadowsSingleWindow = true
            guard authorized() else { return nil }
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        // macOS 13 has ScreenCaptureKit but no screenshot manager.
        let output = SingleFrameOutput()
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        let queue = DispatchQueue(label: "Tabora.preview.singleFrame")
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        let frames = output.frames
        queue.asyncAfter(deadline: deadline) { frames.finish() }
        guard authorized() else { return nil }
        try await stream.startCapture()
        var iterator = output.images.makeAsyncIterator()
        let image = await iterator.next()
        try await stream.stopCapture()
        return image
    }
}

private final class SingleFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let images: AsyncStream<CGImage>
    let frames: AsyncStream<CGImage>.Continuation

    override init() {
        var continuation: AsyncStream<CGImage>.Continuation!
        images = AsyncStream(bufferingPolicy: .bufferingOldest(1)) { continuation = $0 }
        frames = continuation
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { frames.finish() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer else { return }
        var image: CGImage?
        if VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image {
            frames.yield(image)
            frames.finish()
        }
    }
}
