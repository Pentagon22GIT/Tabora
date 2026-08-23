import AppKit

enum PointerInteractionPolicy {
    static let maximumPlainClickTravel: CGFloat = 4

    static func isDrag(maximumDistance: CGFloat) -> Bool {
        maximumDistance.isFinite
            && maximumDistance > maximumPlainClickTravel
    }
}

enum ExpandedSideSelectionPolicy {
    static func zone(relativeY: CGFloat, isLeftEdge: Bool) -> SnapZone {
        let usesTopHalf = relativeY.isFinite && relativeY >= 0.5
        switch (isLeftEdge, usesTopHalf) {
        case (true, true): return .topLeft
        case (true, false): return .bottomLeft
        case (false, true): return .topRight
        case (false, false): return .bottomRight
        }
    }

    static func candidateZones(isLeftEdge: Bool) -> [SnapZone] {
        isLeftEdge
            ? [.topLeft, .bottomLeft]
            : [.topRight, .bottomRight]
    }

    static func guideFrames(
        candidateFrames: [CGRect],
        outerInset: CGFloat
    ) -> [CGRect] {
        guard candidateFrames.count == 2,
              outerInset.isFinite,
              outerInset >= 0,
              candidateFrames.allSatisfy({ frame in
                  frame.minX.isFinite && frame.minY.isFinite
                      && frame.width.isFinite && frame.height.isFinite
                      && frame.width >= outerInset * 2
                      && frame.height >= outerInset
              }) else { return [] }

        let lowerIndex = candidateFrames[0].minY
            <= candidateFrames[1].minY ? 0 : 1
        return candidateFrames.enumerated().map { index, frame in
            // Preserve the outer margin but keep the shared horizontal edge
            // continuous. Insetting both rectangles on every side created an
            // artificial 12-point seam that was not part of snap geometry.
            CGRect(
                x: frame.minX + outerInset,
                y: frame.minY + (index == lowerIndex ? outerInset : 0),
                width: frame.width - outerInset * 2,
                height: frame.height - outerInset
            )
        }
    }
}

struct SplitPlacementGeometry {
    let stableIdentity: String
    let zone: SnapZone
    let frame: CGRect
}

struct CanonicalSplitPartitionMember {
    let stableIdentity: String
    let zone: SnapZone
    let referenceFrame: CGRect
    let limits: AppConstraintLimits
}

enum CanonicalSplitPartitionResolution {
    case ready(frames: [String: CGRect])
    case confirmedInfeasible
    case indeterminate
}

struct SplitResizeHandleGeometry: Equatable {
    let axis: SplitAxis
    let coordinate: CGFloat
    let span: ClosedRange<CGFloat>
    let participantIDs: Set<String>
}

struct SplitResizeParticipantGeometry {
    let stableIdentity: String
    let frame: CGRect
    let side: SplitBoundarySide
    let minimumLength: CGFloat
    let maximumLength: CGFloat?

    init(
        stableIdentity: String,
        frame: CGRect,
        side: SplitBoundarySide,
        minimumLength: CGFloat = SystemGeometryPolicy.minimumWindowLength,
        maximumLength: CGFloat? = nil
    ) {
        self.stableIdentity = stableIdentity
        self.frame = frame
        self.side = side
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
    }
}

struct SplitZOrderWindow {
    let stableIdentity: String
    let frame: CGRect
}

struct RecoveryWindowSceneItem: Equatable {
    let relativeZIndex: Int
    let windowID: CGWindowID
    let pid: pid_t
    let minXHalfPoints: Int
    let minYHalfPoints: Int
    let widthHalfPoints: Int
    let heightHalfPoints: Int
}

struct SplitHitTestSurface {
    let windowID: CGWindowID
    let frame: CGRect
}

enum SplitAxis: CaseIterable, Hashable {
    case horizontal
    case vertical
}

enum SplitBoundarySide: Hashable {
    case nearOrigin
    case farOrigin
}

enum SplitPerpendicularBand: Hashable {
    case first
    case second
}

enum SplitRelationDirection: CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom

    var isHorizontal: Bool {
        self == .left || self == .right
    }

    var followerAnchor: CGPoint {
        switch self {
        case .left: return CGPoint(x: 0, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .top: return CGPoint(x: 0.5, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 0)
        }
    }
}

struct SplitConnectionKey: Hashable {
    let first: String
    let second: String

    init(_ lhs: String, _ rhs: String) {
        if lhs <= rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }

    func contains(_ identity: String) -> Bool {
        first == identity || second == identity
    }
}

enum SplitLayoutGeometry {
    /// Plan a new split from logical cells, not from currently-existing shared
    /// resize handles. Empty cells are intentional layout slack, so a quarter
    /// can expand beyond 50% before its sibling exists. Runtime handle geometry
    /// remains a separate concern and may tolerate small observed skew.
    static func canonicalConstraintPartition(
        members: [CanonicalSplitPartitionMember],
        incomingIdentity: String,
        in visibleFrame: CGRect
    ) -> CanonicalSplitPartitionResolution {
        guard !members.isEmpty,
              visibleFrame.width.isFinite, visibleFrame.height.isFinite,
              visibleFrame.width > 0, visibleFrame.height > 0 else {
            return .indeterminate
        }
        guard Set(members.map(\.stableIdentity)).count == members.count else {
            return .indeterminate
        }

        if members.contains(where: { $0.zone == .maximize }) {
            guard members.count == 1, members[0].zone == .maximize else {
                return .indeterminate
            }
            let member = members[0]
            return frameSatisfiesLimits(
                visibleFrame, limits: member.limits
            ) ? .ready(frames: [member.stableIdentity: visibleFrame])
                : .confirmedInfeasible
        }

        // Logical occupancy is structural intent. Overlap means the caller did
        // not remove a replacement predecessor before planning; do not guess a
        // different structure here.
        var occupiedCells = Set<SnapZone>()
        for member in members {
            let cells = logicalQuarterCells(for: member.zone)
            guard !cells.isEmpty, occupiedCells.isDisjoint(with: cells) else {
                return .indeterminate
            }
            occupiedCells.formUnion(cells)
        }
        if members.count >= 2, !logicalCellsAreConnected(occupiedCells) {
            return .confirmedInfeasible
        }

        let minimumLength = SystemGeometryPolicy.minimumWindowLength
        var xLower = visibleFrame.minX + minimumLength
        var xUpper = visibleFrame.maxX - minimumLength
        var yLower = visibleFrame.minY + minimumLength
        var yUpper = visibleFrame.maxY - minimumLength
        var usesXDivider = false
        var usesYDivider = false

        for member in members {
            let limits = member.limits
            guard limitsAreCoherent(limits) else {
                return .confirmedInfeasible
            }

            switch horizontalPartitionSide(for: member.zone) {
            case .nearOrigin?:
                usesXDivider = true
                let minimum = max(limits.minWidth ?? minimumLength, minimumLength)
                xLower = max(xLower, visibleFrame.minX + minimum)
                if let maximum = limits.maxWidth {
                    xUpper = min(xUpper, visibleFrame.minX + maximum)
                }
            case .farOrigin?:
                usesXDivider = true
                let minimum = max(limits.minWidth ?? minimumLength, minimumLength)
                xUpper = min(xUpper, visibleFrame.maxX - minimum)
                if let maximum = limits.maxWidth {
                    xLower = max(xLower, visibleFrame.maxX - maximum)
                }
            case nil:
                guard length(visibleFrame.width, satisfiesMinimum: limits.minWidth, maximum: limits.maxWidth) else {
                    return .confirmedInfeasible
                }
            }

            switch verticalPartitionSide(for: member.zone) {
            case .nearOrigin?:
                usesYDivider = true
                let minimum = max(limits.minHeight ?? minimumLength, minimumLength)
                yLower = max(yLower, visibleFrame.minY + minimum)
                if let maximum = limits.maxHeight {
                    yUpper = min(yUpper, visibleFrame.minY + maximum)
                }
            case .farOrigin?:
                usesYDivider = true
                let minimum = max(limits.minHeight ?? minimumLength, minimumLength)
                yUpper = min(yUpper, visibleFrame.maxY - minimum)
                if let maximum = limits.maxHeight {
                    yLower = max(yLower, visibleFrame.maxY - maximum)
                }
            case nil:
                guard length(visibleFrame.height, satisfiesMinimum: limits.minHeight, maximum: limits.maxHeight) else {
                    return .confirmedInfeasible
                }
            }
        }

        if usesXDivider, xLower > xUpper { return .confirmedInfeasible }
        if usesYDivider, yLower > yUpper { return .confirmedInfeasible }

        let existingMembers = members.filter { $0.stableIdentity != incomingIdentity }
        let incoming = members.first { $0.stableIdentity == incomingIdentity }

        let xReference = dividerReferenceCoordinate(
            axis: .horizontal,
            members: existingMembers,
            fallbackMember: incoming,
            visibleFrame: visibleFrame
        )
        let yReference = dividerReferenceCoordinate(
            axis: .vertical,
            members: existingMembers,
            fallbackMember: incoming,
            visibleFrame: visibleFrame
        )

        let xDivider = usesXDivider
            ? min(max(xReference, xLower), xUpper)
            : visibleFrame.midX
        let yDivider = usesYDivider
            ? min(max(yReference, yLower), yUpper)
            : visibleFrame.midY

        var frames: [String: CGRect] = [:]
        for member in members {
            let frame = canonicalFrame(
                for: member.zone,
                in: visibleFrame,
                xDivider: xDivider,
                yDivider: yDivider
            )
            guard frameSatisfiesLimits(frame, limits: member.limits),
                  containsFrame(visibleFrame, frame: frame, tolerance: 1) else {
                return .confirmedInfeasible
            }
            frames[member.stableIdentity] = frame
        }
        return .ready(frames: frames)
    }

    /// Plans a split from the logical shared-boundary graph. The incoming
    /// half/quarter geometry is the preferred coordinate for every shared
    /// boundary it actually participates in; known constraints may clamp that
    /// coordinate, while unrelated existing boundaries preserve their current
    /// geometry. Only participants on a solved shared boundary are resized.
    /// A completed four-quarter layout shares both divider axes so every
    /// adjacent edge remains continuous and no central step can survive.
    static func adaptiveConstraintPartition(
        members: [CanonicalSplitPartitionMember],
        incomingIdentity: String,
        preferredIncomingFrame: CGRect,
        in visibleFrame: CGRect
    ) -> CanonicalSplitPartitionResolution {
        guard !members.isEmpty,
              visibleFrame.width.isFinite, visibleFrame.height.isFinite,
              visibleFrame.width > 0, visibleFrame.height > 0,
              Set(members.map(\.stableIdentity)).count == members.count,
              let incoming = members.first(where: {
                  $0.stableIdentity == incomingIdentity
              }) else {
            return .indeterminate
        }

        if members.contains(where: { $0.zone == .maximize }) {
            guard members.count == 1, incoming.zone == .maximize else {
                return .indeterminate
            }
            return frameSatisfiesLimits(visibleFrame, limits: incoming.limits)
                ? .ready(frames: [incomingIdentity: visibleFrame])
                : .confirmedInfeasible
        }

        var occupiedCells = Set<SnapZone>()
        for member in members {
            let cells = logicalQuarterCells(for: member.zone)
            guard !cells.isEmpty, occupiedCells.isDisjoint(with: cells) else {
                return .indeterminate
            }
            occupiedCells.formUnion(cells)
        }
        if members.count >= 2, !logicalCellsAreConnected(occupiedCells) {
            return .confirmedInfeasible
        }

        var zones: [String: SnapZone] = [:]
        var frames: [String: CGRect] = [:]
        var limitsByIdentity: [String: AppConstraintLimits] = [:]
        for member in members {
            guard limitsAreCoherent(member.limits) else {
                return .confirmedInfeasible
            }
            zones[member.stableIdentity] = member.zone
            frames[member.stableIdentity] = member.referenceFrame
            limitsByIdentity[member.stableIdentity] = member.limits
        }

        // Empty sibling cells are real layout slack. Clamp the incoming size
        // itself before solving shared boundaries so, for example, a top-right
        // window with a known 600pt minimum height may consume 600pt while the
        // empty bottom-right cell absorbs the difference without resizing a
        // non-adjacent member.
        var incomingSize = preferredIncomingFrame.size
        for axis in splitAxes(for: incoming.zone) {
            let limits = incoming.limits
            let minimum: CGFloat
            let maximum: CGFloat
            switch axis {
            case .horizontal:
                minimum = max(
                    limits.minWidth ?? SystemGeometryPolicy.minimumWindowLength,
                    SystemGeometryPolicy.minimumWindowLength
                )
                maximum = min(
                    limits.maxWidth ?? visibleFrame.width,
                    visibleFrame.width
                )
                guard minimum <= maximum else { return .confirmedInfeasible }
                incomingSize.width = min(max(incomingSize.width, minimum), maximum)
            case .vertical:
                minimum = max(
                    limits.minHeight ?? SystemGeometryPolicy.minimumWindowLength,
                    SystemGeometryPolicy.minimumWindowLength
                )
                maximum = min(
                    limits.maxHeight ?? visibleFrame.height,
                    visibleFrame.height
                )
                guard minimum <= maximum else { return .confirmedInfeasible }
                incomingSize.height = min(max(incomingSize.height, minimum), maximum)
            }
        }
        let incomingPreferredFrame = anchoredFrame(
            around: preferredIncomingFrame,
            size: incomingSize,
            anchor: incoming.zone.sizeConstraintAnchor
        )
        guard containsFrame(
            visibleFrame,
            frame: incomingPreferredFrame,
            tolerance: 1
        ) else {
            return .confirmedInfeasible
        }
        frames[incomingIdentity] = incomingPreferredFrame

        func validate(
            _ candidateFrames: [String: CGRect]
        ) -> (frames: [String: CGRect], score: CGFloat)? {
            guard candidateFrames.count == members.count else { return nil }
            for member in members {
                guard let frame = candidateFrames[member.stableIdentity],
                      containsFrame(visibleFrame, frame: frame, tolerance: 1),
                      frameSatisfiesLimits(frame, limits: member.limits) else {
                    return nil
                }
            }

            // Logical cells may leave intentional empty slack, but two live
            // members must never be made to overlap by a proposed topology.
            for (index, lhs) in members.enumerated() {
                guard let lhsFrame = candidateFrames[lhs.stableIdentity] else {
                    return nil
                }
                for rhs in members.dropFirst(index + 1) {
                    guard let rhsFrame = candidateFrames[rhs.stableIdentity] else {
                        return nil
                    }
                    let overlap = lhsFrame.intersection(rhsFrame)
                    if !overlap.isNull, overlap.width > 1, overlap.height > 1 {
                        return nil
                    }
                }
            }

            let score = members.reduce(CGFloat.zero) { partial, member in
                guard let target = candidateFrames[member.stableIdentity] else {
                    return partial + .greatestFiniteMagnitude
                }
                let reference = member.stableIdentity == incomingIdentity
                    ? incomingPreferredFrame
                    : member.referenceFrame
                return partial
                    + abs(target.minX - reference.minX)
                    + abs(target.minY - reference.minY)
                    + abs(target.width - reference.width)
                    + abs(target.height - reference.height)
            }
            return (candidateFrames, score)
        }

        let topologyCandidates = proposedConstraintTopologyCandidates(
            zonesByIdentity: zones,
            in: visibleFrame
        )
        var best: (frames: [String: CGRect], score: CGFloat)?
        var sawTopology = false

        for topology in topologyCandidates {
            let connectedIDs = connectedParticipantIDs(
                startingWith: incomingIdentity,
                handles: topology
            )
            guard connectedIDs.contains(incomingIdentity) else { continue }
            sawTopology = true

            var boundaries: [HandleResizeBoundaryGeometry] = []
            var topologyFailed = false
            for geometry in topology
                where !geometry.participantIDs.isDisjoint(with: connectedIDs) {
                var sides: [String: SplitBoundarySide] = [:]
                var participants: [SplitResizeParticipantGeometry] = []
                var existingCoordinates: [CGFloat] = []
                var incomingCoordinate: CGFloat?

                for identity in geometry.participantIDs {
                    guard let frame = frames[identity],
                          let memberZone = zones[identity],
                          let side = boundarySide(
                              for: memberZone,
                              axis: geometry.axis
                          ) else {
                        topologyFailed = true
                        break
                    }
                    let limits = limitsByIdentity[identity] ?? .unknown
                    let minimum: CGFloat
                    let maximum: CGFloat?
                    switch geometry.axis {
                    case .horizontal:
                        minimum = limits.minWidth
                            ?? SystemGeometryPolicy.minimumWindowLength
                        maximum = limits.maxWidth
                    case .vertical:
                        minimum = limits.minHeight
                            ?? SystemGeometryPolicy.minimumWindowLength
                        maximum = limits.maxHeight
                    }
                    sides[identity] = side
                    participants.append(SplitResizeParticipantGeometry(
                        stableIdentity: identity,
                        frame: frame,
                        side: side,
                        minimumLength: minimum,
                        maximumLength: maximum
                    ))
                    let coordinate = boundaryCoordinate(
                        of: frame,
                        side: side,
                        axis: geometry.axis
                    )
                    if identity == incomingIdentity {
                        incomingCoordinate = coordinate
                    } else {
                        existingCoordinates.append(coordinate)
                    }
                }
                if topologyFailed { break }
                guard let legalRange = allowedBoundaryRange(
                    axis: geometry.axis,
                    participants: participants,
                    screenFrame: visibleFrame
                ) else {
                    topologyFailed = true
                    break
                }

                let desiredCoordinate: CGFloat
                // The user's incoming snap target owns any shared boundary it
                // actually participates in. Known min/max constraints may clamp
                // that preferred coordinate, but pre-existing geometry must not
                // silently replace an otherwise-legal incoming 50%/quarter
                // target. Boundaries not involving the incoming member preserve
                // their existing coordinate.
                if let incomingCoordinate {
                    desiredCoordinate = incomingCoordinate
                } else if !existingCoordinates.isEmpty {
                    desiredCoordinate = existingCoordinates.reduce(0, +)
                        / CGFloat(existingCoordinates.count)
                } else {
                    desiredCoordinate = geometry.coordinate
                }
                let coordinate = min(
                    max(desiredCoordinate, legalRange.lowerBound),
                    legalRange.upperBound
                )
                boundaries.append(HandleResizeBoundaryGeometry(
                    axis: geometry.axis,
                    coordinate: coordinate,
                    sides: sides
                ))
            }
            if topologyFailed { continue }

            let candidateFrames = HandleResizeGeometry.resizedFrames(
                originalFrames: frames,
                boundaries: boundaries
            )
            guard let solved = validate(candidateFrames) else { continue }
            if best == nil || solved.score < best!.score {
                best = solved
            }
        }

        if let best { return .ready(frames: best.frames) }
        return sawTopology ? .confirmedInfeasible : .indeterminate
    }

    static func logicalSplitTopologyIsConnectedAndNonOverlapping(
        zonesByIdentity: [String: SnapZone]
    ) -> Bool {
        guard zonesByIdentity.count >= 2,
              !zonesByIdentity.values.contains(.maximize) else { return false }
        var occupiedCells = Set<SnapZone>()
        for zone in zonesByIdentity.values {
            let cells = logicalQuarterCells(for: zone)
            guard !cells.isEmpty, occupiedCells.isDisjoint(with: cells) else {
                return false
            }
            occupiedCells.formUnion(cells)
        }
        return logicalCellsAreConnected(occupiedCells)
    }

    private static func logicalQuarterCells(for zone: SnapZone) -> Set<SnapZone> {
        switch zone {
        case .leftHalf: return [.topLeft, .bottomLeft]
        case .rightHalf: return [.topRight, .bottomRight]
        case .topHalf: return [.topLeft, .topRight]
        case .bottomHalf: return [.bottomLeft, .bottomRight]
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return [zone]
        case .maximize: return []
        }
    }

    private static func logicalCellsAreConnected(_ cells: Set<SnapZone>) -> Bool {
        guard let first = cells.first else { return false }
        var reached: Set<SnapZone> = [first]
        var frontier: [SnapZone] = [first]
        while let cell = frontier.popLast() {
            for neighbor in logicalNeighbors(of: cell)
                where cells.contains(neighbor) && reached.insert(neighbor).inserted {
                frontier.append(neighbor)
            }
        }
        return reached == cells
    }

    private static func logicalNeighbors(of zone: SnapZone) -> Set<SnapZone> {
        switch zone {
        case .topLeft: return [.topRight, .bottomLeft]
        case .topRight: return [.topLeft, .bottomRight]
        case .bottomLeft: return [.topLeft, .bottomRight]
        case .bottomRight: return [.topRight, .bottomLeft]
        default: return []
        }
    }

    private static func horizontalPartitionSide(
        for zone: SnapZone
    ) -> SplitBoundarySide? {
        switch zone {
        case .leftHalf, .topLeft, .bottomLeft: return .nearOrigin
        case .rightHalf, .topRight, .bottomRight: return .farOrigin
        case .topHalf, .bottomHalf, .maximize: return nil
        }
    }

    private static func verticalPartitionSide(
        for zone: SnapZone
    ) -> SplitBoundarySide? {
        switch zone {
        case .bottomHalf, .bottomLeft, .bottomRight: return .nearOrigin
        case .topHalf, .topLeft, .topRight: return .farOrigin
        case .leftHalf, .rightHalf, .maximize: return nil
        }
    }

    private static func dividerReferenceCoordinate(
        axis: SplitAxis,
        members: [CanonicalSplitPartitionMember],
        fallbackMember: CanonicalSplitPartitionMember?,
        visibleFrame: CGRect
    ) -> CGFloat {
        let coordinates = members.compactMap { member -> CGFloat? in
            partitionBoundaryCoordinate(
                axis: axis, zone: member.zone, frame: member.referenceFrame
            )
        }.filter(\.isFinite)
        if !coordinates.isEmpty {
            return coordinates.reduce(0, +) / CGFloat(coordinates.count)
        }
        if let fallbackMember,
           let coordinate = partitionBoundaryCoordinate(
               axis: axis,
               zone: fallbackMember.zone,
               frame: fallbackMember.referenceFrame
           ), coordinate.isFinite {
            return coordinate
        }
        return axis == .horizontal ? visibleFrame.midX : visibleFrame.midY
    }

    private static func partitionBoundaryCoordinate(
        axis: SplitAxis,
        zone: SnapZone,
        frame: CGRect
    ) -> CGFloat? {
        let side = axis == .horizontal
            ? horizontalPartitionSide(for: zone)
            : verticalPartitionSide(for: zone)
        guard let side else { return nil }
        return boundaryCoordinate(of: frame, side: side, axis: axis)
    }

    private static func canonicalFrame(
        for zone: SnapZone,
        in visibleFrame: CGRect,
        xDivider: CGFloat,
        yDivider: CGFloat
    ) -> CGRect {
        switch zone {
        case .leftHalf:
            return CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: xDivider - visibleFrame.minX,
                height: visibleFrame.height
            )
        case .rightHalf:
            return CGRect(
                x: xDivider, y: visibleFrame.minY,
                width: visibleFrame.maxX - xDivider,
                height: visibleFrame.height
            )
        case .topHalf:
            return CGRect(
                x: visibleFrame.minX, y: yDivider,
                width: visibleFrame.width,
                height: visibleFrame.maxY - yDivider
            )
        case .bottomHalf:
            return CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: visibleFrame.width,
                height: yDivider - visibleFrame.minY
            )
        case .topLeft:
            return CGRect(
                x: visibleFrame.minX, y: yDivider,
                width: xDivider - visibleFrame.minX,
                height: visibleFrame.maxY - yDivider
            )
        case .topRight:
            return CGRect(
                x: xDivider, y: yDivider,
                width: visibleFrame.maxX - xDivider,
                height: visibleFrame.maxY - yDivider
            )
        case .bottomLeft:
            return CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: xDivider - visibleFrame.minX,
                height: yDivider - visibleFrame.minY
            )
        case .bottomRight:
            return CGRect(
                x: xDivider, y: visibleFrame.minY,
                width: visibleFrame.maxX - xDivider,
                height: yDivider - visibleFrame.minY
            )
        case .maximize:
            return visibleFrame
        }
    }

    private static func limitsAreCoherent(_ limits: AppConstraintLimits) -> Bool {
        let values = [limits.minWidth, limits.minHeight, limits.maxWidth, limits.maxHeight]
            .compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return false }
        if let minimum = limits.minWidth, let maximum = limits.maxWidth, minimum > maximum {
            return false
        }
        if let minimum = limits.minHeight, let maximum = limits.maxHeight, minimum > maximum {
            return false
        }
        return true
    }

    private static func length(
        _ value: CGFloat,
        satisfiesMinimum minimum: CGFloat?,
        maximum: CGFloat?
    ) -> Bool {
        if let minimum, value + 1 < minimum { return false }
        if let maximum, value - 1 > maximum { return false }
        return true
    }

    private static func frameSatisfiesLimits(
        _ frame: CGRect,
        limits: AppConstraintLimits
    ) -> Bool {
        limitsAreCoherent(limits)
            && length(frame.width, satisfiesMinimum: limits.minWidth, maximum: limits.maxWidth)
            && length(frame.height, satisfiesMinimum: limits.minHeight, maximum: limits.maxHeight)
    }

    private static func containsFrame(
        _ outer: CGRect,
        frame: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        guard frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return false }
        let expanded = outer.insetBy(dx: -tolerance, dy: -tolerance)
        return expanded.contains(CGPoint(x: frame.minX, y: frame.minY))
            && expanded.contains(CGPoint(x: frame.maxX, y: frame.maxY))
    }

    static func frontmostHitWindowID(
        at point: CGPoint,
        orderedSurfaces: [SplitHitTestSurface]
    ) -> CGWindowID? {
        orderedSurfaces.first(where: { $0.frame.contains(point) })?.windowID
    }

    static func recoverySceneSignature(
        for snapshot: [WindowOcclusionSnapshot],
        managedWindowIDs: Set<CGWindowID> = [],
        interactionRegions: [CGRect] = []
    ) -> [RecoveryWindowSceneItem] {
        let layerZero = snapshot.filter { $0.layer == 0 }
        let relevant: [WindowOcclusionSnapshot]
        if managedWindowIDs.isEmpty && interactionRegions.isEmpty {
            // Preserve the generic policy helper used by existing tests. The
            // controller always supplies a scoped recovery scene.
            relevant = layerZero
        } else {
            relevant = layerZero.filter { window in
                managedWindowIDs.contains(window.windowID)
                    || interactionRegions.contains { region in
                        let intersection = region.intersection(window.frame)
                        return !intersection.isNull
                            && intersection.width > 0
                            && intersection.height > 0
                    }
            }
        }
        return relevant.enumerated().map { relativeZIndex, window in
            RecoveryWindowSceneItem(
                relativeZIndex: relativeZIndex,
                windowID: window.windowID,
                pid: window.pid,
                minXHalfPoints: Int((window.frame.minX * 2).rounded()),
                minYHalfPoints: Int((window.frame.minY * 2).rounded()),
                widthHalfPoints: Int((window.frame.width * 2).rounded()),
                heightHalfPoints: Int((window.frame.height * 2).rounded())
            )
        }
    }

    static func connectedGroupIsFrontmost(
        groupIDs: Set<String>,
        orderedWindows: [SplitZOrderWindow]
    ) -> Bool {
        guard !groupIDs.isEmpty else { return true }
        let groupWindows = orderedWindows.filter {
            groupIDs.contains($0.stableIdentity)
        }
        // An incomplete operation-eligible scene is not sufficient evidence to
        // reorder the group. Waiting is safer than raising through an excluded
        // non-resizable surface.
        guard groupWindows.count == groupIDs.count else { return true }

        let groupBounds = groupWindows.dropFirst().reduce(
            groupWindows[0].frame
        ) { bounds, window in
            bounds.union(window.frame)
        }
        guard let rearmostGroupIndex = orderedWindows.lastIndex(where: {
            groupIDs.contains($0.stableIdentity)
        }) else { return true }

        return !orderedWindows[..<rearmostGroupIndex].contains { window in
            guard !groupIDs.contains(window.stableIdentity) else { return false }
            let intersection = groupBounds.intersection(window.frame)
            return !intersection.isNull
                && intersection.width > 1
                && intersection.height > 1
        }
    }

    static let contactTolerance: CGFloat = 8
    static let boundaryMergeTolerance: CGFloat = 1.5
    static let ratioHysteresis: CGFloat = 0.05

    static func resizeAxis(
        forDragDelta delta: CGPoint,
        minimumDistance: CGFloat = 4
    ) -> SplitAxis? {
        guard hypot(delta.x, delta.y) >= minimumDistance else { return nil }
        return abs(delta.x) >= abs(delta.y) ? .horizontal : .vertical
    }

    static func remainsSuspended(
        wasSuspended: Bool,
        compressionRatios: [CGFloat],
        tolerance: CGFloat
    ) -> Bool {
        guard tolerance.isFinite,
              compressionRatios.allSatisfy({ $0.isFinite }) else { return true }
        if wasSuspended {
            let resumeTolerance = max(tolerance - ratioHysteresis, 0)
            return !compressionRatios.allSatisfy { $0 <= resumeTolerance }
        }
        return compressionRatios.contains { $0 > tolerance }
    }

    /// Returns true only when the boundary between the displaced and retained
    /// partitions can be represented as one continuous straight line.
    ///
    /// This is intentionally a cross-partition check. Internal boundaries
    /// inside either partition must never authorize a multi-member
    /// replacement. Single-member replacement does not use this policy.
    static func hasStraightSharedBoundaryBetweenPartitions(
        displacedPlacements: [SplitPlacementGeometry],
        retainedPlacements: [SplitPlacementGeometry],
        tolerance: CGFloat = contactTolerance,
        coordinateTolerance: CGFloat = boundaryMergeTolerance
    ) -> Bool {
        struct Segment {
            let axis: SplitAxis
            let coordinate: CGFloat
            let span: ClosedRange<CGFloat>
        }

        guard displacedPlacements.count >= 2,
              !retainedPlacements.isEmpty,
              tolerance.isFinite, tolerance >= 0,
              coordinateTolerance.isFinite, coordinateTolerance >= 0 else {
            return false
        }

        let allPlacements = displacedPlacements + retainedPlacements
        guard allPlacements.allSatisfy({ placement in
            let frame = placement.frame
            return placement.zone != .maximize
                && frame.minX.isFinite && frame.minY.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }) else {
            return false
        }

        func span(
            for frame: CGRect,
            axis: SplitAxis
        ) -> ClosedRange<CGFloat> {
            switch axis {
            case .horizontal:
                return frame.minY...frame.maxY
            case .vertical:
                return frame.minX...frame.maxX
            }
        }

        var segments: [Segment] = []
        for displaced in displacedPlacements {
            for retained in retainedPlacements {
                for axis in SplitAxis.allCases {
                    guard let displacedSide = boundarySide(
                        for: displaced.zone,
                        axis: axis
                    ),
                          let retainedSide = boundarySide(
                            for: retained.zone,
                            axis: axis
                          ),
                          displacedSide != retainedSide else {
                        continue
                    }

                    let displacedCoordinate = boundaryCoordinate(
                        of: displaced.frame,
                        side: displacedSide,
                        axis: axis
                    )
                    let retainedCoordinate = boundaryCoordinate(
                        of: retained.frame,
                        side: retainedSide,
                        axis: axis
                    )
                    guard abs(displacedCoordinate - retainedCoordinate)
                            <= tolerance else {
                        continue
                    }

                    let displacedSpan = span(
                        for: displaced.frame,
                        axis: axis
                    )
                    let retainedSpan = span(
                        for: retained.frame,
                        axis: axis
                    )
                    let lower = max(
                        displacedSpan.lowerBound,
                        retainedSpan.lowerBound
                    )
                    let upper = min(
                        displacedSpan.upperBound,
                        retainedSpan.upperBound
                    )
                    guard upper - lower > tolerance else { continue }

                    segments.append(Segment(
                        axis: axis,
                        coordinate: (
                            displacedCoordinate + retainedCoordinate
                        ) / 2,
                        span: lower...upper
                    ))
                }
            }
        }

        guard let first = segments.first else { return false }
        guard segments.allSatisfy({ segment in
            segment.axis == first.axis
                && abs(segment.coordinate - first.coordinate)
                    <= coordinateTolerance
        }) else {
            return false
        }

        let orderedSpans = segments.map(\.span).sorted { lhs, rhs in
            if lhs.lowerBound != rhs.lowerBound {
                return lhs.lowerBound < rhs.lowerBound
            }
            return lhs.upperBound < rhs.upperBound
        }
        guard var mergedUpper = orderedSpans.first?.upperBound else {
            return false
        }
        for next in orderedSpans.dropFirst() {
            guard next.lowerBound <= mergedUpper + tolerance else {
                return false
            }
            mergedUpper = max(mergedUpper, next.upperBound)
        }
        return true
    }

    static func resizeHandleGeometries(
        placements: [SplitPlacementGeometry],
        detachedConnections: Set<SplitConnectionKey> = [],
        tolerance: CGFloat = contactTolerance,
        mergeTolerance: CGFloat = boundaryMergeTolerance
    ) -> [SplitResizeHandleGeometry] {
        struct Member {
            let identity: String
            let axis: SplitAxis
            let side: SplitBoundarySide
            let coordinate: CGFloat
            let span: ClosedRange<CGFloat>
        }

        var members: [Member] = []
        for placement in placements where placement.zone != .maximize {
            for axis in SplitAxis.allCases {
                guard let side = boundarySide(for: placement.zone, axis: axis) else {
                    continue
                }
                let span: ClosedRange<CGFloat>
                switch axis {
                case .horizontal:
                    span = placement.frame.minY...placement.frame.maxY
                case .vertical:
                    span = placement.frame.minX...placement.frame.maxX
                }
                members.append(Member(
                    identity: placement.stableIdentity,
                    axis: axis,
                    side: side,
                    coordinate: boundaryCoordinate(
                        of: placement.frame,
                        side: side,
                        axis: axis
                    ),
                    span: span
                ))
            }
        }

        var candidates: [SplitResizeHandleGeometry] = []
        let nearMembers = members.filter { $0.side == .nearOrigin }
        let farMembers = members.filter { $0.side == .farOrigin }
        for near in nearMembers {
            for far in farMembers where far.axis == near.axis {
                guard near.identity != far.identity,
                      abs(near.coordinate - far.coordinate) <= tolerance,
                      !detachedConnections.contains(
                          SplitConnectionKey(near.identity, far.identity)
                      ) else { continue }
                let lower = max(near.span.lowerBound, far.span.lowerBound)
                let upper = min(near.span.upperBound, far.span.upperBound)
                guard upper - lower > tolerance else { continue }
                candidates.append(SplitResizeHandleGeometry(
                    axis: near.axis,
                    coordinate: (near.coordinate + far.coordinate) / 2,
                    span: lower...upper,
                    participantIDs: [near.identity, far.identity]
                ))
            }
        }

        let sorted = candidates.sorted {
            if $0.axis != $1.axis {
                return $0.axis == .horizontal
            }
            if abs($0.coordinate - $1.coordinate) > mergeTolerance {
                return $0.coordinate < $1.coordinate
            }
            return $0.span.lowerBound < $1.span.lowerBound
        }
        var merged: [SplitResizeHandleGeometry] = []
        for candidate in sorted {
            guard let last = merged.last,
                  last.axis == candidate.axis,
                  abs(last.coordinate - candidate.coordinate) <= mergeTolerance,
                  candidate.span.lowerBound <= last.span.upperBound + tolerance else {
                merged.append(candidate)
                continue
            }
            let mergedLowerBound = min(
                last.span.lowerBound,
                candidate.span.lowerBound
            )
            let mergedUpperBound = max(
                last.span.upperBound,
                candidate.span.upperBound
            )
            merged[merged.count - 1] = SplitResizeHandleGeometry(
                axis: last.axis,
                coordinate: (last.coordinate + candidate.coordinate) / 2,
                span: mergedLowerBound...mergedUpperBound,
                participantIDs: last.participantIDs.union(candidate.participantIDs)
            )
        }
        return merged
    }

    /// Builds the logical shared-boundary graph for a proposed split. A full
    /// half spans two perpendicular logical bands and therefore couples them;
    /// independent quarter cells remain separate even when their nominal 50%
    /// coordinates happen to match. Runtime handle presentation still uses
    /// `resizeHandleGeometries` and may merge physically aligned boundaries.
    static func proposedResizeHandleGeometries(
        zonesByIdentity: [String: SnapZone],
        in visibleFrame: CGRect
    ) -> [SplitResizeHandleGeometry] {
        struct Cell: Hashable {
            let column: Int
            let row: Int
        }
        struct AtomicBoundary {
            let axis: SplitAxis
            let coordinate: CGFloat
            let span: ClosedRange<CGFloat>
            let participantIDs: Set<String>
        }

        func cells(for zone: SnapZone) -> Set<Cell> {
            switch zone {
            case .leftHalf:
                return [Cell(column: 0, row: 0), Cell(column: 0, row: 1)]
            case .rightHalf:
                return [Cell(column: 1, row: 0), Cell(column: 1, row: 1)]
            case .topHalf:
                return [Cell(column: 0, row: 1), Cell(column: 1, row: 1)]
            case .bottomHalf:
                return [Cell(column: 0, row: 0), Cell(column: 1, row: 0)]
            case .topLeft:
                return [Cell(column: 0, row: 1)]
            case .topRight:
                return [Cell(column: 1, row: 1)]
            case .bottomLeft:
                return [Cell(column: 0, row: 0)]
            case .bottomRight:
                return [Cell(column: 1, row: 0)]
            case .maximize:
                return []
            }
        }

        var owners: [Cell: [String]] = [:]
        for (identity, zone) in zonesByIdentity where zone != .maximize {
            for cell in cells(for: zone) {
                owners[cell, default: []].append(identity)
            }
        }
        func uniqueOwner(_ cell: Cell) -> String? {
            guard let values = owners[cell], values.count == 1 else { return nil }
            return values[0]
        }

        let midX = visibleFrame.minX + floor(visibleFrame.width / 2)
        let midY = visibleFrame.minY + floor(visibleFrame.height / 2)
        var atomic: [AtomicBoundary] = []

        for row in 0...1 {
            let left = Cell(column: 0, row: row)
            let right = Cell(column: 1, row: row)
            if let leftOwner = uniqueOwner(left),
               let rightOwner = uniqueOwner(right),
               leftOwner != rightOwner {
                let span: ClosedRange<CGFloat> = row == 0
                    ? visibleFrame.minY...midY
                    : midY...visibleFrame.maxY
                atomic.append(AtomicBoundary(
                    axis: .horizontal,
                    coordinate: midX,
                    span: span,
                    participantIDs: [leftOwner, rightOwner]
                ))
            }
        }

        for column in 0...1 {
            let bottom = Cell(column: column, row: 0)
            let top = Cell(column: column, row: 1)
            if let bottomOwner = uniqueOwner(bottom),
               let topOwner = uniqueOwner(top),
               bottomOwner != topOwner {
                let span: ClosedRange<CGFloat> = column == 0
                    ? visibleFrame.minX...midX
                    : midX...visibleFrame.maxX
                atomic.append(AtomicBoundary(
                    axis: .vertical,
                    coordinate: midY,
                    span: span,
                    participantIDs: [bottomOwner, topOwner]
                ))
            }
        }

        // Within one axis, only a participant that itself spans multiple bands
        // can force those atomic boundaries to share one coordinate. This is
        // the key distinction between a three-member half+quarters layout and
        // four independent quarter members.
        var unvisited = Set(atomic.indices)
        var result: [SplitResizeHandleGeometry] = []
        while let seed = unvisited.first {
            unvisited.remove(seed)
            let axis = atomic[seed].axis
            var component = Set([seed])
            var participants = atomic[seed].participantIDs
            var expanded = true
            while expanded {
                expanded = false
                for index in Array(unvisited) where atomic[index].axis == axis {
                    if !atomic[index].participantIDs.isDisjoint(with: participants) {
                        unvisited.remove(index)
                        component.insert(index)
                        participants.formUnion(atomic[index].participantIDs)
                        expanded = true
                    }
                }
            }
            let members = component.map { atomic[$0] }
            let lower = members.map { $0.span.lowerBound }.min() ?? 0
            let upper = members.map { $0.span.upperBound }.max() ?? lower
            let coordinate = members.map(\.coordinate).reduce(0, +)
                / CGFloat(max(members.count, 1))
            result.append(SplitResizeHandleGeometry(
                axis: axis,
                coordinate: coordinate,
                span: lower...upper,
                participantIDs: participants
            ))
        }
        return result.sorted {
            if $0.axis != $1.axis { return $0.axis == .horizontal }
            if $0.coordinate != $1.coordinate { return $0.coordinate < $1.coordinate }
            return $0.span.lowerBound < $1.span.lowerBound
        }
    }

    /// A completed four-quarter layout owns one vertical and one horizontal
    /// divider. Keeping either axis split into independent row/column segments
    /// lets the final placement expose a visible step or central void. Partial
    /// layouts retain their existing logical topology until the fourth cell is
    /// committed.
    static func proposedConstraintTopologyCandidates(
        zonesByIdentity: [String: SnapZone],
        in visibleFrame: CGRect
    ) -> [[SplitResizeHandleGeometry]] {
        let logical = proposedResizeHandleGeometries(
            zonesByIdentity: zonesByIdentity,
            in: visibleFrame
        )
        let quarterZones: Set<SnapZone> = [
            .topLeft, .topRight, .bottomLeft, .bottomRight
        ]
        // This is a topology check, not a member-count mode: the shared grid
        // exists only when every quarter zone is present.
        guard Set(zonesByIdentity.values) == quarterZones else {
            return [logical]
        }

        var unified: [SplitResizeHandleGeometry] = []
        for axis in SplitAxis.allCases {
            let members = logical.filter { $0.axis == axis }
            guard !members.isEmpty else { continue }
            let lower = members.map { $0.span.lowerBound }.min() ?? 0
            let upper = members.map { $0.span.upperBound }.max() ?? lower
            let coordinate = members.map(\.coordinate).reduce(0, +)
                / CGFloat(members.count)
            let participants = members.reduce(into: Set<String>()) {
                result, item in
                result.formUnion(item.participantIDs)
            }
            unified.append(SplitResizeHandleGeometry(
                axis: axis,
                coordinate: coordinate,
                span: lower...upper,
                participantIDs: participants
            ))
        }
        return [unified.sorted {
            if $0.axis != $1.axis { return $0.axis == .horizontal }
            if $0.coordinate != $1.coordinate {
                return $0.coordinate < $1.coordinate
            }
            return $0.span.lowerBound < $1.span.lowerBound
        }]
    }

    static func connectedParticipantIDs(
        startingWith identity: String,
        handles: [SplitResizeHandleGeometry]
    ) -> Set<String> {
        var connected: Set<String> = [identity]
        var didExpand = true
        while didExpand {
            didExpand = false
            for handle in handles
                where !handle.participantIDs.isDisjoint(with: connected) {
                let previousCount = connected.count
                connected.formUnion(handle.participantIDs)
                if connected.count != previousCount {
                    didExpand = true
                }
            }
        }
        return connected
    }

    static func allowedBoundaryRange(
        axis: SplitAxis,
        participants: [SplitResizeParticipantGeometry],
        screenFrame: CGRect
    ) -> ClosedRange<CGFloat>? {
        guard !participants.isEmpty else { return nil }
        var lower = axis == .horizontal ? screenFrame.minX : screenFrame.minY
        var upper = axis == .horizontal ? screenFrame.maxX : screenFrame.maxY

        for participant in participants {
            let minimum = max(
                participant.minimumLength,
                SystemGeometryPolicy.minimumWindowLength
            )
            let maximum: CGFloat?
            if let value = participant.maximumLength {
                guard value.isFinite, value >= minimum else { return nil }
                maximum = value
            } else {
                maximum = nil
            }
            switch (axis, participant.side) {
            case (.horizontal, .nearOrigin):
                lower = max(lower, participant.frame.minX + minimum)
                if let maximum {
                    upper = min(upper, participant.frame.minX + maximum)
                }
            case (.horizontal, .farOrigin):
                upper = min(upper, participant.frame.maxX - minimum)
                if let maximum {
                    lower = max(lower, participant.frame.maxX - maximum)
                }
            case (.vertical, .nearOrigin):
                lower = max(lower, participant.frame.minY + minimum)
                if let maximum {
                    upper = min(upper, participant.frame.minY + maximum)
                }
            case (.vertical, .farOrigin):
                upper = min(upper, participant.frame.maxY - minimum)
                if let maximum {
                    lower = max(lower, participant.frame.maxY - maximum)
                }
            }
        }
        guard lower <= upper else { return nil }
        return lower...upper
    }

    static func resizedFrames(
        meetingBoundary coordinate: CGFloat,
        axis: SplitAxis,
        participants: [SplitResizeParticipantGeometry]
    ) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: participants.map { participant in
            (
                participant.stableIdentity,
                frame(
                    participant.frame,
                    meetingBoundary: coordinate,
                    side: participant.side,
                    axis: axis
                )
            )
        })
    }

    static func splitAxes(for zone: SnapZone) -> Set<SplitAxis> {
        switch zone {
        case .leftHalf, .rightHalf:
            return [.horizontal]
        case .topHalf, .bottomHalf:
            return [.vertical]
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return [.horizontal, .vertical]
        case .maximize:
            return []
        }
    }

    static func boundarySide(
        for zone: SnapZone,
        axis: SplitAxis
    ) -> SplitBoundarySide? {
        switch (axis, zone) {
        case (.horizontal, .leftHalf),
             (.horizontal, .topLeft),
             (.horizontal, .bottomLeft),
             (.vertical, .bottomHalf),
             (.vertical, .bottomLeft),
             (.vertical, .bottomRight):
            return .nearOrigin

        case (.horizontal, .rightHalf),
             (.horizontal, .topRight),
             (.horizontal, .bottomRight),
             (.vertical, .topHalf),
             (.vertical, .topLeft),
             (.vertical, .topRight):
            return .farOrigin

        default:
            return nil
        }
    }

    static func perpendicularBands(
        for zone: SnapZone,
        axis: SplitAxis
    ) -> Set<SplitPerpendicularBand> {
        switch (axis, zone) {
        case (.horizontal, .topLeft), (.horizontal, .topRight),
             (.vertical, .bottomLeft), (.vertical, .topLeft):
            return [.first]

        case (.horizontal, .bottomLeft), (.horizontal, .bottomRight),
             (.vertical, .bottomRight), (.vertical, .topRight):
            return [.second]

        case (.horizontal, .leftHalf), (.horizontal, .rightHalf),
             (.vertical, .bottomHalf), (.vertical, .topHalf):
            return [.first, .second]

        default:
            return []
        }
    }

    static func boundaryCoordinate(
        of frame: CGRect,
        side: SplitBoundarySide,
        axis: SplitAxis
    ) -> CGFloat {
        switch (axis, side) {
        case (.horizontal, .nearOrigin): return frame.maxX
        case (.horizontal, .farOrigin): return frame.minX
        case (.vertical, .nearOrigin): return frame.maxY
        case (.vertical, .farOrigin): return frame.minY
        }
    }

    static func frame(
        _ frame: CGRect,
        meetingBoundary coordinate: CGFloat,
        side: SplitBoundarySide,
        axis: SplitAxis
    ) -> CGRect {
        switch (axis, side) {
        case (.horizontal, .nearOrigin):
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: max(coordinate - frame.minX, 0),
                height: frame.height
            )
        case (.horizontal, .farOrigin):
            return CGRect(
                x: coordinate,
                y: frame.minY,
                width: max(frame.maxX - coordinate, 0),
                height: frame.height
            )
        case (.vertical, .nearOrigin):
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: max(coordinate - frame.minY, 0)
            )
        case (.vertical, .farOrigin):
            return CGRect(
                x: frame.minX,
                y: coordinate,
                width: frame.width,
                height: max(frame.maxY - coordinate, 0)
            )
        }
    }

    /// Returns the stable outer-edge anchor for a frame mutation that moves
    /// one or both shared boundaries. This is shared by snap-invasion reflow
    /// and any future controller-owned boundary transaction; it must not live
    /// inside the native window-edge interaction path.
    static func boundaryAnchor(
        sides: [SplitAxis: SplitBoundarySide],
        activeAxes: Set<SplitAxis>
    ) -> CGPoint {
        var anchor = CGPoint(x: 0.5, y: 0.5)
        if activeAxes.contains(.horizontal), let side = sides[.horizontal] {
            anchor.x = side == .nearOrigin ? 0 : 1
        }
        if activeAxes.contains(.vertical), let side = sides[.vertical] {
            anchor.y = side == .nearOrigin ? 0 : 1
        }
        return anchor
    }

    static func hasReachedBoundary(
        initialCoordinate: CGFloat,
        currentCoordinate: CGFloat,
        participantCoordinates: [CGFloat],
        tolerance: CGFloat = contactTolerance
    ) -> Bool {
        guard !participantCoordinates.isEmpty else { return false }
        if participantCoordinates.allSatisfy({ abs($0 - initialCoordinate) <= tolerance }) {
            return true
        }

        if currentCoordinate > initialCoordinate + tolerance {
            let forward = participantCoordinates.filter { $0 > initialCoordinate + tolerance }
            guard let threshold = forward.max() else { return false }
            return currentCoordinate >= threshold - tolerance
        }
        if currentCoordinate < initialCoordinate - tolerance {
            let backward = participantCoordinates.filter { $0 < initialCoordinate - tolerance }
            guard let threshold = backward.min() else { return false }
            return currentCoordinate <= threshold + tolerance
        }
        return false
    }

    static func resolvedFrame(
        for zone: SnapZone,
        in visibleFrame: CGRect,
        placements: [SplitPlacementGeometry],
        excluding excludedIdentity: String? = nil
    ) -> CGRect {
        guard zone != .maximize else { return visibleFrame }
        var target = zone.frame(in: visibleFrame)
        let nominal = target
        let candidates = placements.filter {
            $0.stableIdentity != excludedIdentity
                && $0.frame.width > 0
                && $0.frame.height > 0
        }

        if isQuarterZone(zone) {
            let xDivider = preferredQuarterDividerCoordinate(
                axis: .horizontal,
                targetZone: zone,
                placements: candidates,
                visibleFrame: visibleFrame
            )
            let yDivider = preferredQuarterDividerCoordinate(
                axis: .vertical,
                targetZone: zone,
                placements: candidates,
                visibleFrame: visibleFrame
            )
            return canonicalFrame(
                for: zone,
                in: visibleFrame,
                xDivider: xDivider,
                yDivider: yDivider
            ).intersectionOrFallback(with: visibleFrame)
        }

        switch zone {
        case .leftHalf, .topLeft, .bottomLeft:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .right,
                      verticalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.minX
            }
            if let boundary = boundaries.min() {
                target.size.width = max(boundary - target.minX, 1)
            }

        case .rightHalf, .topRight, .bottomRight:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .left,
                      verticalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.maxX
            }
            if let boundary = boundaries.max() {
                let right = target.maxX
                target.origin.x = min(boundary, right - 1)
                target.size.width = max(right - target.minX, 1)
            }

        case .topHalf:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .bottom,
                      horizontalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.maxY
            }
            if let boundary = boundaries.max() {
                let top = target.maxY
                target.origin.y = min(boundary, top - 1)
                target.size.height = max(top - target.minY, 1)
            }

        case .bottomHalf:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .top,
                      horizontalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.minY
            }
            if let boundary = boundaries.min() {
                target.size.height = max(boundary - target.minY, 1)
            }

        case .maximize:
            break
        }

        return target.intersectionOrFallback(with: visibleFrame)
    }

    private static func preferredQuarterDividerCoordinate(
        axis: SplitAxis,
        targetZone: SnapZone,
        placements: [SplitPlacementGeometry],
        visibleFrame: CGRect
    ) -> CGFloat {
        guard let targetColumn = quarterColumn(targetZone),
              let targetRow = quarterRow(targetZone) else {
            return axis == .horizontal ? visibleFrame.midX : visibleFrame.midY
        }
        let ranked = placements.compactMap { placement
            -> (rank: Int, coordinate: CGFloat)? in
            guard let coordinate = partitionBoundaryCoordinate(
                axis: axis,
                zone: placement.zone,
                frame: placement.frame
            ), coordinate.isFinite else { return nil }
            if let column = quarterColumn(placement.zone),
               let row = quarterRow(placement.zone) {
                let rank: Int
                switch axis {
                case .horizontal:
                    rank = column == targetColumn
                        ? 0 : (row == targetRow ? 1 : 2)
                case .vertical:
                    rank = row == targetRow
                        ? 0 : (column == targetColumn ? 1 : 2)
                }
                return (rank, coordinate)
            }
            return (3, coordinate)
        }
        guard let bestRank = ranked.map(\.rank).min() else {
            return axis == .horizontal ? visibleFrame.midX : visibleFrame.midY
        }
        let coordinates = ranked.filter { $0.rank == bestRank }
            .map(\.coordinate)
        guard !coordinates.isEmpty else {
            return axis == .horizontal ? visibleFrame.midX : visibleFrame.midY
        }
        let average = coordinates.reduce(0, +) / CGFloat(coordinates.count)
        switch axis {
        case .horizontal:
            return min(max(average, visibleFrame.minX + 1), visibleFrame.maxX - 1)
        case .vertical:
            return min(max(average, visibleFrame.minY + 1), visibleFrame.maxY - 1)
        }
    }

    private static func isQuarterZone(_ zone: SnapZone) -> Bool {
        quarterColumn(zone) != nil && quarterRow(zone) != nil
    }

    private static func quarterColumn(_ zone: SnapZone) -> Int? {
        switch zone {
        case .topLeft, .bottomLeft: return 0
        case .topRight, .bottomRight: return 1
        default: return nil
        }
    }

    private static func quarterRow(_ zone: SnapZone) -> Int? {
        switch zone {
        case .bottomLeft, .bottomRight: return 0
        case .topLeft, .topRight: return 1
        default: return nil
        }
    }

    static func relationDirection(
        driverZone: SnapZone,
        followerZone: SnapZone,
        in visibleFrame: CGRect
    ) -> SplitRelationDirection? {
        guard driverZone != .maximize, followerZone != .maximize else { return nil }
        let driver = driverZone.frame(in: visibleFrame)
        let follower = followerZone.frame(in: visibleFrame)
        let tolerance: CGFloat = 1

        if verticalOverlap(driver, follower) > contactTolerance {
            if abs(driver.minX - follower.maxX) <= tolerance { return .left }
            if abs(driver.maxX - follower.minX) <= tolerance { return .right }
        }
        if horizontalOverlap(driver, follower) > contactTolerance {
            if abs(driver.maxY - follower.minY) <= tolerance { return .top }
            if abs(driver.minY - follower.maxY) <= tolerance { return .bottom }
        }
        return nil
    }

    static func edgeChanged(
        _ direction: SplitRelationDirection,
        from original: CGRect,
        to current: CGRect,
        tolerance: CGFloat = 1.5
    ) -> Bool {
        switch direction {
        case .left: return abs(current.minX - original.minX) > tolerance
        case .right: return abs(current.maxX - original.maxX) > tolerance
        case .top: return abs(current.maxY - original.maxY) > tolerance
        case .bottom: return abs(current.minY - original.minY) > tolerance
        }
    }

    static func signedContactMismatch(
        direction: SplitRelationDirection,
        driverFrame: CGRect,
        followerFrame: CGRect
    ) -> CGFloat {
        switch direction {
        case .left: return followerFrame.maxX - driverFrame.minX
        case .right: return driverFrame.maxX - followerFrame.minX
        case .top: return driverFrame.maxY - followerFrame.minY
        case .bottom: return followerFrame.maxY - driverFrame.minY
        }
    }

    static func hasReachedContact(initialMismatch: CGFloat, currentMismatch: CGFloat) -> Bool {
        if abs(initialMismatch) <= contactTolerance { return true }
        if initialMismatch > 0 {
            return currentMismatch <= contactTolerance
        }
        return currentMismatch >= -contactTolerance
    }

    static func followerTarget(
        direction: SplitRelationDirection,
        driverFrame: CGRect,
        followerFrame: CGRect
    ) -> CGRect {
        switch direction {
        case .left:
            return CGRect(
                x: followerFrame.minX,
                y: followerFrame.minY,
                width: max(driverFrame.minX - followerFrame.minX, 0),
                height: followerFrame.height
            )
        case .right:
            return CGRect(
                x: driverFrame.maxX,
                y: followerFrame.minY,
                width: max(followerFrame.maxX - driverFrame.maxX, 0),
                height: followerFrame.height
            )
        case .top:
            return CGRect(
                x: followerFrame.minX,
                y: driverFrame.maxY,
                width: followerFrame.width,
                height: max(followerFrame.maxY - driverFrame.maxY, 0)
            )
        case .bottom:
            return CGRect(
                x: followerFrame.minX,
                y: followerFrame.minY,
                width: followerFrame.width,
                height: max(driverFrame.minY - followerFrame.minY, 0)
            )
        }
    }

    static func invasionRatio(
        requestedLength: CGFloat,
        acceptedLength: CGFloat,
        referenceLength: CGFloat
    ) -> CGFloat {
        let reference = max(referenceLength, 1)
        let acceptedOverflow = max(acceptedLength - requestedLength, 0)
        let capacityShortage = max(reference - requestedLength, 0)
        return max(acceptedOverflow, capacityShortage) / reference
    }

    static func compressionRatio(targetLength: CGFloat, referenceLength: CGFloat) -> CGFloat {
        let reference = max(referenceLength, 1)
        return max(reference - max(targetLength, 0), 0) / reference
    }

    static func isBeyondTolerance(
        targetFrame: CGRect,
        direction: SplitRelationDirection,
        referenceSize: CGSize,
        tolerance: CGFloat
    ) -> Bool {
        let targetLength = direction.isHorizontal ? targetFrame.width : targetFrame.height
        let referenceLength = direction.isHorizontal ? referenceSize.width : referenceSize.height
        return compressionRatio(
            targetLength: targetLength,
            referenceLength: referenceLength
        ) > tolerance
    }

    static func canResume(
        targetFrame: CGRect,
        direction: SplitRelationDirection,
        referenceSize: CGSize,
        tolerance: CGFloat
    ) -> Bool {
        let resumeTolerance = max(tolerance - ratioHysteresis, 0)
        let targetLength = direction.isHorizontal ? targetFrame.width : targetFrame.height
        let referenceLength = direction.isHorizontal ? referenceSize.width : referenceSize.height
        return compressionRatio(
            targetLength: targetLength,
            referenceLength: referenceLength
        ) <= resumeTolerance
    }

    static func anchoredFrame(
        around targetFrame: CGRect,
        size: CGSize,
        anchor: CGPoint
    ) -> CGRect {
        CGRect(
            x: targetFrame.minX + (targetFrame.width - size.width) * anchor.x,
            y: targetFrame.minY + (targetFrame.height - size.height) * anchor.y,
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    static func additionalMismatchDegree(
        initialMismatch: CGFloat,
        finalMismatch: CGFloat,
        referenceLength: CGFloat
    ) -> CGFloat {
        let additional = max(abs(finalMismatch) - abs(initialMismatch), 0)
        return additional / max(referenceLength, 1)
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY), 0)
    }

    private static func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX), 0)
    }
}

private extension CGRect {
    func intersectionOrFallback(with bounds: CGRect) -> CGRect {
        let clipped = intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1)
        }
        return clipped
    }
}
