import CoreGraphics
import Foundation
import TaboraSkyLightBridge

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

    func hasSufficientPixelDimensions(_ image: CGImage) -> Bool {
        // Only decides whether the fallback is worth trying. Never suppresses
        // HOT publication on its own. A 1x source and pixel rounding are valid.
        CGFloat(image.width) + 1 >= min(windowSize.width, targetPixelSize.width)
            && CGFloat(image.height) + 1 >= min(windowSize.height, targetPixelSize.height)
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

enum PreviewCaptureRoutingPolicy {
    /// Transformed scenes need full-size source semantics, not a comparison of
    /// canvas dimensions. A reduced surface can occupy a nominal-size canvas.
    /// Normal/Assist requests keep their legacy path. Each backend is called at
    /// most once, under the caller's single physical admission lease.
    static func capture(
        fullSizeRequest: PreviewFullSizeRequest?,
        shouldCapture: () -> Bool,
        legacy: () -> CGImage?,
        fullSize: () -> CGImage?
    ) -> CGImage? {
        guard shouldCapture() else { return nil }
        guard let request = fullSizeRequest, request.isValid else {
            let original = legacy()
            return shouldCapture() ? original : nil
        }
        let captured = fullSize()
        guard shouldCapture() else { return nil }
        let candidate = captured.flatMap {
            PreviewImageContentPolicy.windowContent(in: $0, expectedSize: request.windowSize)
        }
        guard shouldCapture() else { return nil }
        let candidateIsCompatible = candidate.map {
            request.hasCompatibleAspect($0)
        } ?? false
        if let candidate, candidateIsCompatible,
           request.hasSufficientPixelDimensions(candidate) {
            return candidate
        }
        let fallback = legacy()
        guard shouldCapture() else { return nil }
        // The fallback can also become transparent while WindowServer changes
        // scenes. Do not let its larger canvas replace a usable candidate.
        let original = fallback.flatMap {
            PreviewImageContentPolicy.windowContent(in: $0, expectedSize: request.windowSize)
        }
        let selected: CGImage?
        if let candidate, candidateIsCompatible {
            if let original, request.hasCompatibleAspect(original),
               original.width > candidate.width || original.height > candidate.height {
                selected = original
            } else {
                // Equal canvas size must not veto the full-size source.
                selected = candidate
            }
        } else {
            selected = original.flatMap { request.hasCompatibleAspect($0) ? $0 : nil }
        }
        return shouldCapture() ? selected : nil
    }
}

enum PreviewCaptureAdmissionPolicy {
    /// Normal preview, transient preview and Assist are derived background
    /// work. If another lane briefly owns both global capture slots, wait
    /// off-main for one
    /// established interactive readiness interval instead of consuming a
    /// finite retry as an immediate contention failure.
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

/// Shared physical capture boundary; owns no HOT/COLD or presentation state.
enum WindowPreviewCaptureService {
    // Preview capture is derived state. Bound cross-subsystem capture
    // concurrency without holding a lock across the legacy synchronous Window
    // Server capture call. At most two captures may be active. Callers may wait
    // off-main for one bounded readiness interval so brief cross-subsystem
    // contention does not consume their finite image retries.
    private static let maximumConcurrentPreviewCaptures = 2
    private static let previewCaptureAdmission = DispatchSemaphore(
        value: maximumConcurrentPreviewCaptures
    )

    static func capture(
        for windowID: CGWindowID?,
        capacityWait requestedCapacityWait: TimeInterval,
        resolution: PreviewCaptureResolution = .nominal,
        fullSizeRequest: PreviewFullSizeRequest? = nil,
        expectedOwnerPID: pid_t? = nil,
        shouldCapture: (() -> Bool)? = nil
    ) -> CGImage? {
        guard let windowID else { return nil }
        let capacityWait = PreviewCaptureAdmissionPolicy.effectiveWait(
            requested: requestedCapacityWait,
            isMainThread: Thread.isMainThread
        )
        guard Self.beginPreviewCapture(waitingUpTo: capacityWait) else {
            return nil
        }
        defer { Self.endPreviewCapture() }
        // Authorization may change while this request waits for the shared
        // Mission Control / Assist capture slot. Recheck after admission and
        // immediately before Window Server capture so a disabled Preview, a
        // cancelled Normal/Assist operation, or an invalid transient session
        // cannot leave an already-reserved request executable.
        guard shouldCapture?() ?? true else { return nil }
        guard let ownerPID = expectedOwnerPID ?? fullSizeRequest?.ownerPID,
              ownerPID > 0, CGPreflightScreenCaptureAccess() else { return nil }
        let resolutionOption: CGWindowImageOption
        switch resolution {
        case .nominal:
            resolutionOption = .nominalResolution
        case .best:
            resolutionOption = .bestResolution
        }
        let isAuthorized: () -> Bool = {
            guard shouldCapture?() ?? true else { return false }
            guard CGPreflightScreenCaptureAccess(),
                  let descriptions = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                    as? [[String: Any]], descriptions.count == 1,
                  let item = descriptions.first else { return false }
            return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                && (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
                && (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        return PreviewCaptureRoutingPolicy.capture(
            fullSizeRequest: fullSizeRequest,
            shouldCapture: isAuthorized,
            legacy: {
                CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    windowID,
                    [.boundsIgnoreFraming, resolutionOption]
                )
            },
            fullSize: {
                guard let request = fullSizeRequest else { return nil }
                return TSLBridgeCreateFullSizeWindowImage(
                    windowID, request.ownerPID
                )
            }
        )
    }

    private static func beginPreviewCapture(
        waitingUpTo wait: TimeInterval
    ) -> Bool {
        let deadline: DispatchTime = wait > 0 ? .now() + wait : .now()
        return previewCaptureAdmission.wait(timeout: deadline) == .success
    }

    private static func endPreviewCapture() {
        previewCaptureAdmission.signal()
    }

}
