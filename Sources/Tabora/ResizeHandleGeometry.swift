import AppKit
import CoreGraphics

enum ResizeHandlePresentationSignal {
    case applicationDeactivated
    case applicationActivated
    case accessibilityFocusChanged
    case windowServerSelectionChanged
}

enum ResizeHandlePresentationPolicy {
    /// Only real application lifecycle boundaries invalidate the currently
    /// presented overlay. Focused-window and Window Server selection signals
    /// are intentionally excluded because tab changes can emit them in bursts.
    static func shouldSuspend(for signal: ResizeHandlePresentationSignal) -> Bool {
        switch signal {
        case .applicationDeactivated, .applicationActivated:
            return true
        case .accessibilityFocusChanged, .windowServerSelectionChanged:
            return false
        }
    }
}

enum ResizeHandleDragPresentationPolicy {
    static func hidesOriginalGeometryUntilFirstUpdate(
        for _: LinkedResizePresentationStyle
    ) -> Bool {
        return true
    }
}

enum ResizeCursorAdornmentKind: Equatable {
    case horizontal
    case vertical
    case junction

    static func kind(for axis: SplitAxis) -> ResizeCursorAdornmentKind {
        switch axis {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

enum ResizeHandleHoverPolicy {
    /// A short one-shot dwell prevents a boundary from flashing fully active
    /// when the pointer merely crosses it. No repeating monitor is introduced.
    static let activationDelay: TimeInterval = 0.11
}

enum ResizeHandleSystemCursorPolicy {
    // A finite post-drag lease covers AppKit's cursor re-evaluation after the
    // active nonactivating panel is ordered out. This is not a monitor/timer.
    static let restorationDelays: [TimeInterval] = [0, 0.016, 0.035, 0.07, 0.12, 0.20]
    static let restorationContainmentPadding: CGFloat = 2

    /// Every Tabora handle panel sits over a native window resize edge, so
    /// every presentation style must explicitly own the arrow cursor rect.
    /// Letting mac-style controls inherit the underlying cursor is precisely
    /// what exposes the native double-arrow after a snap or shared resize.
    static func usesArrowCursorRect(
        for _: LinkedResizePresentationStyle
    ) -> Bool {
        true
    }
}

enum ResizeHandleJunctionTrackingGeometry {
    /// Static junctions exist only where both boundary spans intersect. Once a
    /// junction owns an active drag, however, those spans still describe the
    /// pre-drag layout and must not strand the input panel at its old endpoint.
    static func frame(
        at point: CGPoint,
        horizontalSpan: ClosedRange<CGFloat>,
        verticalSpan: ClosedRange<CGFloat>,
        screenFrame: CGRect,
        radius: CGFloat,
        isActive: Bool
    ) -> CGRect? {
        guard isActive
                || (horizontalSpan.contains(point.y)
                    && verticalSpan.contains(point.x)) else {
            return nil
        }
        let xLimits = isActive
            ? screenFrame.minX...screenFrame.maxX
            : verticalSpan
        let yLimits = isActive
            ? screenFrame.minY...screenFrame.maxY
            : horizontalSpan
        let minX = max(point.x - radius, xLimits.lowerBound)
        let maxX = min(point.x + radius, xLimits.upperBound)
        let minY = max(point.y - radius, yLimits.lowerBound)
        let maxY = min(point.y + radius, yLimits.upperBound)
        guard maxX - minX >= 4, maxY - minY >= 4 else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}

enum ResizeCursorAdornmentMetrics {
    static let distanceRange: ClosedRange<CGFloat> = 4...12
    // Tuned against the standard macOS left-right resize cursor at the same
    // capture scale. The directional height grows more than the base, and the
    // tip uses its own stronger rounding instead of over-rounding the base.
    static let triangleDepth: CGFloat = 8.20
    static let triangleBase: CGFloat = 8.70
    static let triangleBaseCornerInset: CGFloat = 1.00
    static let triangleTipCornerInset: CGFloat = 1.55
    static let outlineWidth: CGFloat = 1
    // NSEvent.mouseLocation is the cursor hotspot, while the standard resize
    // cursor's visual center sits about one backing pixel above it on Retina.
    static let horizontalPairVerticalAlignment: CGFloat = 0.5
    // Keep the vertical pair centered on the same hotspot as the boundary.
    // A visual-only left shift made the up/down affordance look detached from
    // the resize control even though its hit target remained centered.
    static let verticalPairHorizontalAlignment: CGFloat = 0

    static func normalizedDistance(_ distance: CGFloat) -> CGFloat {
        min(max(distance, distanceRange.lowerBound), distanceRange.upperBound)
    }

    static func centerOffset(for distance: CGFloat) -> CGFloat {
        normalizedDistance(distance) + triangleDepth / 2
    }
}

enum ResizeHandleGroupPresentationPolicy {
    /// A partial boundary from a degraded explicit group must never own input.
    /// Native window edges remain application-owned; only a fully validated
    /// explicit group may expose Tabora's separate shared-resize controls.
    static func presentsCompleteGroup(
        memberIDs: Set<String>,
        preferredMemberID: String,
        geometries: [SplitResizeHandleGeometry]
    ) -> Bool {
        guard memberIDs.count >= 2,
              memberIDs.contains(preferredMemberID) else { return false }
        return SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: preferredMemberID,
            handles: geometries
        ) == memberIDs
    }
}

enum NativeWindowResizePolicy {
    struct FrameObservation {
        let stableIdentity: String
        let original: CGRect
        let current: CGRect
    }

    static func didResize(
        from original: CGRect,
        to current: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        guard tolerance.isFinite, tolerance >= 0,
              isValidWindowFrame(original),
              isValidWindowFrame(current) else {
            return false
        }
        return abs(current.width - original.width) > tolerance
            || abs(current.height - original.height) > tolerance
    }

    static func resizedIdentities(
        in observations: [FrameObservation],
        tolerance: CGFloat
    ) -> Set<String> {
        Set(observations.compactMap { observation in
            didResize(
                from: observation.original,
                to: observation.current,
                tolerance: tolerance
            ) ? observation.stableIdentity : nil
        })
    }

    static func isNearResizeEdge(
        _ point: CGPoint,
        frame: CGRect,
        tolerance: CGFloat = 8
    ) -> Bool {
        guard tolerance.isFinite, tolerance >= 0,
              isValidWindowFrame(frame),
              point.x.isFinite,
              point.y.isFinite,
              frame.insetBy(
                  dx: -tolerance,
                  dy: -tolerance
              ).contains(point) else { return false }
        return abs(point.x - frame.minX) <= tolerance
            || abs(point.x - frame.maxX) <= tolerance
            || abs(point.y - frame.minY) <= tolerance
            || abs(point.y - frame.maxY) <= tolerance
    }

    /// AX can expose transient or malformed geometry while a window changes
    /// Spaces, minimizes, or is destroyed. Such samples must never be strong
    /// enough evidence to retire a snap group.
    private static func isValidWindowFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

struct HandleResizeBoundaryGeometry {
    let axis: SplitAxis
    let coordinate: CGFloat
    let sides: [String: SplitBoundarySide]
}

enum HandleResizeGeometry {
    /// Applies orthogonal boundaries to one frame map. Each pass changes only
    /// its own dimension, so a corner participant receives both changes while
    /// single-axis participants retain the untouched dimension.
    static func resizedFrames(
        originalFrames: [String: CGRect],
        boundaries: [HandleResizeBoundaryGeometry]
    ) -> [String: CGRect] {
        var frames = originalFrames
        for boundary in boundaries {
            let participants = boundary.sides.compactMap { identity, side
                -> SplitResizeParticipantGeometry? in
                guard let frame = frames[identity] else { return nil }
                return SplitResizeParticipantGeometry(
                    stableIdentity: identity,
                    frame: frame,
                    side: side,
                    minimumLength: 1
                )
            }
            let resized = SplitLayoutGeometry.resizedFrames(
                meetingBoundary: boundary.coordinate,
                axis: boundary.axis,
                participants: participants
            )
            for (identity, frame) in resized {
                frames[identity] = frame
            }
        }
        return frames
    }
}

enum ResizeHandleInteraction: Equatable {
    case boundary(ResizeHandleDescriptor)
    case junction(
        id: String,
        horizontal: ResizeHandleDescriptor,
        vertical: ResizeHandleDescriptor
    )

    var id: String {
        switch self {
        case .boundary(let descriptor): return descriptor.id
        case .junction(let id, _, _): return id
        }
    }

    var descriptors: [ResizeHandleDescriptor] {
        switch self {
        case .boundary(let descriptor): return [descriptor]
        case .junction(_, let horizontal, let vertical):
            return [horizontal, vertical]
        }
    }

    var participantIDs: Set<String> {
        descriptors.reduce(into: Set<String>()) { result, descriptor in
            result.formUnion(descriptor.participantIDs)
        }
    }
}

struct ResizeHandleDescriptor: Equatable {
    static let macControlThickness: CGFloat = 8
    static let macControlLength: CGFloat = 44
    // Six points on either side of the shared edge is still narrow enough to
    // avoid nearby content, but reliably wins hit-testing over the standard
    // window resize region. The visible guide remains capped independently.
    static let sharedBoundaryHitThickness: CGFloat = 12
    static let windowsBoundaryIdleThickness: CGFloat = 2
    static let windowsBoundaryActiveThickness: CGFloat = 6
    static let combinedBoundaryIdleThickness: CGFloat = 1
    static let combinedBoundaryActiveThickness: CGFloat = 3

    let id: String
    let displayID: CGDirectDisplayID
    let axis: SplitAxis
    let coordinate: CGFloat
    let span: ClosedRange<CGFloat>
    let screenFrame: CGRect
    let participantIDs: Set<String>
    let occlusionParticipants: [WindowOcclusionParticipant]
    let presentationStyle: LinkedResizePresentationStyle
    let showsResizeCursorAdornment: Bool
    let resizeCursorAdornmentDistance: CGFloat

    init(
        id: String,
        displayID: CGDirectDisplayID,
        axis: SplitAxis,
        coordinate: CGFloat,
        span: ClosedRange<CGFloat>,
        screenFrame: CGRect,
        participantIDs: Set<String>,
        occlusionParticipants: [WindowOcclusionParticipant] = [],
        presentationStyle: LinkedResizePresentationStyle = .combined,
        showsResizeCursorAdornment: Bool = false,
        resizeCursorAdornmentDistance: CGFloat = CGFloat(
            AppSettings.defaultResizeCursorAdornmentDistance
        )
    ) {
        self.id = id
        self.displayID = displayID
        self.axis = axis
        self.coordinate = coordinate
        self.span = span
        self.screenFrame = screenFrame
        self.participantIDs = participantIDs
        self.occlusionParticipants = occlusionParticipants
        self.presentationStyle = presentationStyle
        self.showsResizeCursorAdornment = showsResizeCursorAdornment
        self.resizeCursorAdornmentDistance = resizeCursorAdornmentDistance
    }

    var spanLength: CGFloat {
        max(span.upperBound - span.lowerBound, 1)
    }

    func interactionFrame() -> CGRect {
        if presentationStyle == .mac {
            let controlLength = min(Self.macControlLength, spanLength)
            switch axis {
            case .horizontal:
                return CGRect(
                    x: coordinate - Self.macControlThickness / 2,
                    y: (span.lowerBound + span.upperBound) / 2
                        - controlLength / 2,
                    width: Self.macControlThickness,
                    height: controlLength
                )
            case .vertical:
                return CGRect(
                    x: (span.lowerBound + span.upperBound) / 2
                        - controlLength / 2,
                    y: coordinate - Self.macControlThickness / 2,
                    width: controlLength,
                    height: Self.macControlThickness
                )
            }
        }

        switch axis {
        case .horizontal:
            return CGRect(
                x: coordinate - Self.sharedBoundaryHitThickness / 2,
                y: span.lowerBound,
                width: Self.sharedBoundaryHitThickness,
                height: spanLength
            )
        case .vertical:
            return CGRect(
                x: span.lowerBound,
                y: coordinate - Self.sharedBoundaryHitThickness / 2,
                width: spanLength,
                height: Self.sharedBoundaryHitThickness
            )
        }
    }

    func isOccluded(by frames: [CGRect]) -> Bool {
        let handleFrame = interactionFrame()
        return frames.contains { frame in
            let intersection = handleFrame.intersection(frame)
            return !intersection.isNull
                && intersection.width > 1
                && intersection.height > 1
        }
    }
}

struct ResizeHandlePresentationSignature: Equatable {
    let id: String
    let axis: SplitAxis
    let coordinate: CGFloat
    let lowerBound: CGFloat
    let upperBound: CGFloat
    let presentationStyle: LinkedResizePresentationStyle
    let showsResizeCursorAdornment: Bool
    let resizeCursorAdornmentDistance: CGFloat

    init(_ descriptor: ResizeHandleDescriptor) {
        id = descriptor.id
        axis = descriptor.axis
        coordinate = descriptor.coordinate
        lowerBound = descriptor.span.lowerBound
        upperBound = descriptor.span.upperBound
        presentationStyle = descriptor.presentationStyle
        showsResizeCursorAdornment = descriptor.showsResizeCursorAdornment
        resizeCursorAdornmentDistance = descriptor.resizeCursorAdornmentDistance
    }
}
