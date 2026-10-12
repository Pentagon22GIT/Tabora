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
        let candidate = fullSize()
        guard shouldCapture() else { return nil }
        let candidateIsCompatible = candidate.map(request.hasCompatibleAspect) ?? false
        if let candidate, candidateIsCompatible,
           request.hasSufficientPixelDimensions(candidate) {
            return candidate
        }
        let original = legacy()
        guard shouldCapture() else { return nil }
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
            selected = original
        }
        return selected
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
        let resolutionOption: CGWindowImageOption
        switch resolution {
        case .nominal:
            resolutionOption = .nominalResolution
        case .best:
            resolutionOption = .bestResolution
        }
        return PreviewCaptureRoutingPolicy.capture(
            fullSizeRequest: fullSizeRequest,
            shouldCapture: { shouldCapture?() ?? true },
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
