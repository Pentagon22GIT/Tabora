import CoreGraphics
import Foundation

enum ConstraintProbeAxis: Hashable {
    case width
    case height
}

struct ConstraintProbeContext {
    let identity: AppConstraintIdentity
    let displayName: String
    let requestedFrame: CGRect
    let acceptedFrame: CGRect
    let activeAxes: Set<ConstraintProbeAxis>
    let mutationWasSent: Bool
    let sizeMutationSucceeded: Bool
    let acceptedFrameIsSettled: Bool
    let liveness: WindowLiveness
    let screenLimitedAxes: Set<ConstraintProbeAxis>
    let systemLimitedAxes: Set<ConstraintProbeAxis>
    let peerLimitedAxes: Set<ConstraintProbeAxis>
    let measurementEpsilon: CGFloat
    let operationGeneration: Int
}

struct ConstraintProbeAnalysis {
    let confirmedRejections: [ConfirmedConstraintRejection]
    let requiresAxisIsolatedCalibration: Bool
}

enum ConstraintProbe {
    static func confirmedRejections(
        from context: ConstraintProbeContext
    ) -> [ConfirmedConstraintRejection] {
        analyze(context).confirmedRejections
    }

    static func analyze(
        _ context: ConstraintProbeContext
    ) -> ConstraintProbeAnalysis {
        guard context.mutationWasSent,
              context.sizeMutationSucceeded,
              context.acceptedFrameIsSettled,
              context.liveness == .alive,
              context.measurementEpsilon.isFinite,
              context.measurementEpsilon > 0 else {
            return ConstraintProbeAnalysis(
                confirmedRejections: [],
                requiresAxisIsolatedCalibration: false
            )
        }

        let widthMismatch = abs(
            context.requestedFrame.width - context.acceptedFrame.width
        ) > context.measurementEpsilon
        let heightMismatch = abs(
            context.requestedFrame.height - context.acceptedFrame.height
        ) > context.measurementEpsilon

        // A single-axis operation that also moves the orthogonal dimension is
        // not attributable enough to learn an app-wide bound. Preserve the
        // historical fail-closed behavior rather than manufacturing evidence.
        if context.activeAxes == [.width], heightMismatch {
            return ConstraintProbeAnalysis(
                confirmedRejections: [],
                requiresAxisIsolatedCalibration: false
            )
        }
        if context.activeAxes == [.height], widthMismatch {
            return ConstraintProbeAnalysis(
                confirmedRejections: [],
                requiresAxisIsolatedCalibration: false
            )
        }

        // When both actively-mutated axes reject at once, the mutation is
        // strong evidence that the attempted geometry was not accepted, but it
        // is not evidence for *which* app bound caused the rejection. Trigger
        // user-authorized axis-isolated calibration without persisting either
        // axis from this ambiguous observation. Screen/system/peer explained
        // mismatches do not trigger app calibration.
        if context.activeAxes.count > 1, widthMismatch && heightMismatch {
            let unexplainedWidth = context.activeAxes.contains(.width)
                && !context.screenLimitedAxes.contains(.width)
                && !context.systemLimitedAxes.contains(.width)
                && !context.peerLimitedAxes.contains(.width)
            let unexplainedHeight = context.activeAxes.contains(.height)
                && !context.screenLimitedAxes.contains(.height)
                && !context.systemLimitedAxes.contains(.height)
                && !context.peerLimitedAxes.contains(.height)
            return ConstraintProbeAnalysis(
                confirmedRejections: [],
                requiresAxisIsolatedCalibration:
                    unexplainedWidth || unexplainedHeight
            )
        }

        var result: [ConfirmedConstraintRejection] = []
        if context.activeAxes.contains(.width), widthMismatch,
           !context.screenLimitedAxes.contains(.width),
           !context.systemLimitedAxes.contains(.width),
           !context.peerLimitedAxes.contains(.width),
           let bound = bound(
               requested: context.requestedFrame.width,
               accepted: context.acceptedFrame.width,
               minimum: .minWidth,
               maximum: .maxWidth,
               epsilon: context.measurementEpsilon
           ) {
            result.append(ConfirmedConstraintRejection(
                identity: context.identity,
                displayName: context.displayName,
                bound: bound,
                acceptedValue: context.acceptedFrame.width,
                measurementEpsilon: context.measurementEpsilon,
                operationGeneration: context.operationGeneration
            ))
        }
        if context.activeAxes.contains(.height), heightMismatch,
           !context.screenLimitedAxes.contains(.height),
           !context.systemLimitedAxes.contains(.height),
           !context.peerLimitedAxes.contains(.height),
           let bound = bound(
               requested: context.requestedFrame.height,
               accepted: context.acceptedFrame.height,
               minimum: .minHeight,
               maximum: .maxHeight,
               epsilon: context.measurementEpsilon
           ) {
            result.append(ConfirmedConstraintRejection(
                identity: context.identity,
                displayName: context.displayName,
                bound: bound,
                acceptedValue: context.acceptedFrame.height,
                measurementEpsilon: context.measurementEpsilon,
                operationGeneration: context.operationGeneration
            ))
        }
        return ConstraintProbeAnalysis(
            confirmedRejections: result,
            requiresAxisIsolatedCalibration: false
        )
    }

    private static func bound(
        requested: CGFloat,
        accepted: CGFloat,
        minimum: AppConstraintBound,
        maximum: AppConstraintBound,
        epsilon: CGFloat
    ) -> AppConstraintBound? {
        if accepted > requested + epsilon { return minimum }
        if accepted < requested - epsilon { return maximum }
        return nil
    }
}

enum SystemGeometryPolicy {
    static let minimumWindowLength: CGFloat = 1

    static func measurementEpsilon(backingScaleFactor: CGFloat) -> CGFloat {
        let scale = max(backingScaleFactor, 1)
        // Derive the comparison tolerance from backing-pixel resolution rather
        // than an app-specific or split-count-specific magic threshold.
        return max(2 / scale, 0.5)
    }

    static func screenLimitedAxes(
        requestedFrame: CGRect,
        acceptedFrame: CGRect,
        activeAxes: Set<ConstraintProbeAxis>,
        screenFrame: CGRect,
        epsilon: CGFloat
    ) -> Set<ConstraintProbeAxis> {
        var result = Set<ConstraintProbeAxis>()
        if activeAxes.contains(.width),
           acceptedFrame.width < requestedFrame.width - epsilon,
           requestedFrame.width >= screenFrame.width - epsilon {
            result.insert(.width)
        }
        if activeAxes.contains(.height),
           acceptedFrame.height < requestedFrame.height - epsilon,
           requestedFrame.height >= screenFrame.height - epsilon {
            result.insert(.height)
        }
        return result
    }

    static func systemLimitedAxes(
        requestedFrame: CGRect,
        acceptedFrame: CGRect,
        activeAxes: Set<ConstraintProbeAxis>,
        epsilon: CGFloat
    ) -> Set<ConstraintProbeAxis> {
        var result = Set<ConstraintProbeAxis>()
        if activeAxes.contains(.width),
           acceptedFrame.width > requestedFrame.width + epsilon,
           requestedFrame.width <= minimumWindowLength + epsilon {
            result.insert(.width)
        }
        if activeAxes.contains(.height),
           acceptedFrame.height > requestedFrame.height + epsilon,
           requestedFrame.height <= minimumWindowLength + epsilon {
            result.insert(.height)
        }
        return result
    }
}
