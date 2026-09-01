import AppKit
import CoreGraphics

struct SnapOuterEdges: OptionSet {
    let rawValue: Int

    static let left = SnapOuterEdges(rawValue: 1 << 0)
    static let right = SnapOuterEdges(rawValue: 1 << 1)
    static let top = SnapOuterEdges(rawValue: 1 << 2)
    static let bottom = SnapOuterEdges(rawValue: 1 << 3)

    static let horizontal: SnapOuterEdges = [.left, .right]
    static let vertical: SnapOuterEdges = [.top, .bottom]
    static let all: SnapOuterEdges = [.left, .right, .top, .bottom]
}

enum SnapZone: String, Equatable, CaseIterable, Codable {
    case leftHalf, rightHalf
    case topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize

    var displayName: String {
        switch self {
        case .leftHalf: return "左半分"
        case .rightHalf: return "右半分"
        case .topHalf: return "上半分"
        case .bottomHalf: return "下半分"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .maximize: return "最大化"
        }
    }

    func frame(in screen: NSScreen) -> CGRect {
        frame(in: screen.visibleFrame)
    }

    func frame(in f: CGRect) -> CGRect {
        let halfW = floor(f.width / 2)
        let halfH = floor(f.height / 2)

        switch self {
        case .leftHalf:
            return CGRect(x: f.minX, y: f.minY, width: halfW, height: f.height)
        case .rightHalf:
            return CGRect(x: f.minX + halfW, y: f.minY, width: f.width - halfW, height: f.height)
        case .topHalf:
            return CGRect(x: f.minX, y: f.minY + halfH, width: f.width, height: f.height - halfH)
        case .bottomHalf:
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: halfH)
        case .topLeft:
            return CGRect(x: f.minX, y: f.minY + halfH, width: halfW, height: f.height - halfH)
        case .topRight:
            return CGRect(x: f.minX + halfW, y: f.minY + halfH, width: f.width - halfW, height: f.height - halfH)
        case .bottomLeft:
            return CGRect(x: f.minX, y: f.minY, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: f.minX + halfW, y: f.minY, width: f.width - halfW, height: halfH)
        case .maximize:
            return f
        }
    }

    var sizeConstraintAnchor: CGPoint {
        switch self {
        case .leftHalf:
            return CGPoint(x: 0, y: 0.5)
        case .rightHalf:
            return CGPoint(x: 1, y: 0.5)
        case .topHalf:
            return CGPoint(x: 0.5, y: 1)
        case .bottomHalf:
            return CGPoint(x: 0.5, y: 0)
        case .topLeft:
            return CGPoint(x: 0, y: 1)
        case .topRight:
            return CGPoint(x: 1, y: 1)
        case .bottomLeft:
            return CGPoint(x: 0, y: 0)
        case .bottomRight:
            return CGPoint(x: 1, y: 0)
        case .maximize:
            return CGPoint(x: 0.5, y: 0.5)
        }
    }

    var requiredOuterEdges: SnapOuterEdges {
        switch self {
        case .leftHalf:
            return [.left, .top, .bottom]
        case .rightHalf:
            return [.right, .top, .bottom]
        case .topHalf:
            return [.left, .right, .top]
        case .bottomHalf:
            return [.left, .right, .bottom]
        case .topLeft:
            return [.left, .top]
        case .topRight:
            return [.right, .top]
        case .bottomLeft:
            return [.left, .bottom]
        case .bottomRight:
            return [.right, .bottom]
        case .maximize:
            return .all
        }
    }

    var verticalSibling: SnapZone {
        switch self {
        case .topLeft: return .bottomLeft
        case .bottomLeft: return .topLeft
        case .topRight: return .bottomRight
        case .bottomRight: return .topRight
        default: return self
        }
    }

    static func detect(
        at point: CGPoint,
        on screen: NSScreen,
        edgeThreshold: CGFloat = 26,
        cornerBand: CGFloat = 120
    ) -> SnapZone? {
        detect(
            at: point,
            in: screen.frame,
            edgeThreshold: edgeThreshold,
            cornerBand: cornerBand
        )
    }

    static func detect(
        at point: CGPoint,
        in frame: CGRect,
        edgeThreshold: CGFloat = 26,
        cornerBand: CGFloat = 120
    ) -> SnapZone? {
        let f = frame
        let safeEdgeThreshold = max(edgeThreshold, 0)
        let safeCornerBand = max(cornerBand, 0)
        let nearLeft = point.x <= f.minX + safeEdgeThreshold
        let nearRight = point.x >= f.maxX - safeEdgeThreshold
        let nearTop = point.y >= f.maxY - safeEdgeThreshold
        let nearBottom = point.y <= f.minY + safeEdgeThreshold

        if nearLeft && point.y >= f.maxY - safeCornerBand { return .topLeft }
        if nearRight && point.y >= f.maxY - safeCornerBand { return .topRight }
        if nearLeft && point.y <= f.minY + safeCornerBand { return .bottomLeft }
        if nearRight && point.y <= f.minY + safeCornerBand { return .bottomRight }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        if nearTop { return .maximize }
        if nearBottom { return nil }
        return nil
    }
}

enum SnapPlacementLayerPolicy {
    /// A maximized snap is a non-connected upper layer. It replaces only an
    /// earlier maximized snap on the same display and preserves the one split
    /// layout below it. Returning to a split zone removes that upper layer and
    /// resumes the existing single split graph; it never creates a second one.
    static func conflicts(existing: SnapZone, incoming: SnapZone) -> Bool {
        if incoming == .maximize {
            return existing == .maximize
        }
        if existing == .maximize {
            return true
        }
        return !logicalCells(for: existing).isDisjoint(
            with: logicalCells(for: incoming)
        )
    }

    static func countsTowardConnectedLayout(_ zone: SnapZone) -> Bool {
        zone != .maximize
    }

    static func incomingExactlyCovers(
        existingZones: Set<SnapZone>,
        incoming: SnapZone
    ) -> Bool {
        guard incoming != .maximize, !existingZones.isEmpty else {
            return false
        }
        var existingCells: Set<SnapZone> = []
        for zone in existingZones {
            let cells = logicalCells(for: zone)
            // Exact-cover replacement is an authorization boundary. Reject
            // malformed/overlapping source layouts instead of letting a union
            // operation hide duplicate ownership of the same logical cell.
            guard existingCells.isDisjoint(with: cells) else { return false }
            existingCells.formUnion(cells)
        }
        return existingCells == logicalCells(for: incoming)
    }

    private static func logicalCells(for zone: SnapZone) -> Set<SnapZone> {
        switch zone {
        case .leftHalf:
            return [.topLeft, .bottomLeft]
        case .rightHalf:
            return [.topRight, .bottomRight]
        case .topHalf:
            return [.topLeft, .topRight]
        case .bottomHalf:
            return [.bottomLeft, .bottomRight]
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return [zone]
        case .maximize:
            return []
        }
    }
}

enum AssistLayoutPolicy {
    static func layoutZones(
        startingWith zone: SnapZone,
        occupiedZones: Set<SnapZone>
    ) -> [SnapZone] {
        switch zone {
        case .leftHalf:
            return occupiedZones.isDisjoint(with: [.topRight, .bottomRight])
                ? [.leftHalf, .rightHalf]
                : [.leftHalf, .topRight, .bottomRight]
        case .rightHalf:
            return occupiedZones.isDisjoint(with: [.topLeft, .bottomLeft])
                ? [.leftHalf, .rightHalf]
                : [.topLeft, .bottomLeft, .rightHalf]
        case .topHalf:
            return occupiedZones.isDisjoint(with: [.bottomLeft, .bottomRight])
                ? [.topHalf, .bottomHalf]
                : [.topHalf, .bottomLeft, .bottomRight]
        case .bottomHalf:
            return occupiedZones.isDisjoint(with: [.topLeft, .topRight])
                ? [.topHalf, .bottomHalf]
                : [.topLeft, .topRight, .bottomHalf]
        case .topLeft, .bottomLeft:
            if occupiedZones.contains(.rightHalf) {
                return [.rightHalf, zone, zone.verticalSibling]
            }
            if zone == .topLeft, occupiedZones.contains(.bottomHalf) {
                return [.topLeft, .topRight, .bottomHalf]
            }
            if zone == .bottomLeft, occupiedZones.contains(.topHalf) {
                return [.topHalf, .bottomLeft, .bottomRight]
            }
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .topRight, .bottomRight:
            if occupiedZones.contains(.leftHalf) {
                return [.leftHalf, zone, zone.verticalSibling]
            }
            if zone == .topRight, occupiedZones.contains(.bottomHalf) {
                return [.topLeft, .topRight, .bottomHalf]
            }
            if zone == .bottomRight, occupiedZones.contains(.topHalf) {
                return [.topHalf, .bottomLeft, .bottomRight]
            }
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .maximize:
            return []
        }
    }
}

enum AssistCompletionLayoutPolicy {
    static let fourWindowZones: [SnapZone] = [
        .topLeft, .topRight, .bottomLeft, .bottomRight
    ]

    static func threeWindowZones(
        occupiedZones: Set<SnapZone>
    ) -> [SnapZone]? {
        guard occupiedZones.count == 2 else { return nil }
        if occupiedZones == Set([.topLeft, .topRight]) {
            return [.topLeft, .topRight, .bottomHalf]
        }
        if occupiedZones == Set([.bottomLeft, .bottomRight]) {
            return [.topHalf, .bottomLeft, .bottomRight]
        }
        if occupiedZones == Set([.topLeft, .bottomLeft]) {
            return [.topLeft, .bottomLeft, .rightHalf]
        }
        if occupiedZones == Set([.topRight, .bottomRight]) {
            return [.leftHalf, .topRight, .bottomRight]
        }
        return nil
    }

    /// Returns the ordinary three-window partition obtained by keeping one
    /// occupied Half and splitting only the opposite Half into two Quarters.
    /// This is deliberately limited to an exact, single-Half starting state;
    /// mixed or already-completed layouts continue through the normal Assist
    /// policy instead of being reinterpreted by the Option surface.
    static func threeWindowZonesStartingFromHalf(
        occupiedZones: Set<SnapZone>
    ) -> [SnapZone]? {
        guard occupiedZones.count == 1,
              let occupied = occupiedZones.first else { return nil }
        switch occupied {
        case .leftHalf:
            return [.leftHalf, .topRight, .bottomRight]
        case .rightHalf:
            return [.topLeft, .bottomLeft, .rightHalf]
        case .topHalf:
            return [.topHalf, .bottomLeft, .bottomRight]
        case .bottomHalf:
            return [.topLeft, .topRight, .bottomHalf]
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize:
            return nil
        }
    }

    static func twoWindowZones(
        occupiedZones: Set<SnapZone>
    ) -> [SnapZone]? {
        guard occupiedZones.count == 1,
              let occupied = occupiedZones.first else { return nil }
        switch occupied {
        case .leftHalf, .rightHalf:
            return [.leftHalf, .rightHalf]
        case .topHalf, .bottomHalf:
            return [.topHalf, .bottomHalf]
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize:
            return nil
        }
    }

    static func layoutForModifierState(
        occupiedZones: Set<SnapZone>,
        currentLayout: [SnapZone],
        modifierIsPressed: Bool
    ) -> [SnapZone]? {
        let current = Set(currentLayout)
        if let threeWindow = threeWindowZones(
            occupiedZones: occupiedZones
        ), current == Set(fourWindowZones)
                || current == Set(threeWindow) {
            return modifierIsPressed ? threeWindow : fourWindowZones
        }
        if let twoWindow = twoWindowZones(occupiedZones: occupiedZones),
           let threeWindow = threeWindowZonesStartingFromHalf(
               occupiedZones: occupiedZones
           ), current == Set(twoWindow) || current == Set(threeWindow) {
            return modifierIsPressed ? threeWindow : twoWindow
        }
        return nil
    }

    /// Resolves the visible completion surface after both structural layouts
    /// have been evaluated with their own candidate constraints.
    static func completionLayout(
        occupiedZones: Set<SnapZone>,
        modifierIsPressed: Bool,
        maximumDistinctFourWindowAssignments: Int,
        mergedHalfCandidateCount: Int
    ) -> [SnapZone]? {
        guard let threeWindow = threeWindowZones(
            occupiedZones: occupiedZones
        ) else { return nil }
        if modifierIsPressed {
            return mergedHalfCandidateCount > 0 ? threeWindow : nil
        }
        if maximumDistinctFourWindowAssignments >= 2 {
            return fourWindowZones
        }
        return mergedHalfCandidateCount > 0 ? threeWindow : nil
    }

    /// Resolves the inverse Option surface: the default remains the opposite
    /// Half, while Option may split it only when two distinct windows can
    /// actually occupy the two Quarter zones. If that stronger condition is
    /// unavailable, the ordinary two-window Assist remains usable.
    static func completionLayoutStartingFromHalf(
        occupiedZones: Set<SnapZone>,
        modifierIsPressed: Bool,
        oppositeHalfCandidateCount: Int,
        maximumDistinctSplitAssignments: Int
    ) -> [SnapZone]? {
        guard let twoWindow = twoWindowZones(
            occupiedZones: occupiedZones
        ), let threeWindow = threeWindowZonesStartingFromHalf(
            occupiedZones: occupiedZones
        ) else { return nil }
        if modifierIsPressed, maximumDistinctSplitAssignments >= 2 {
            return threeWindow
        }
        return oppositeHalfCandidateCount > 0 ? twoWindow : nil
    }
}

enum AssistLayoutModifierPolicy {
    static func isPressed(in flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
    }
}

enum AssistCandidateAssignmentPolicy {
    /// The same window may appear in both quarter candidate lists. Count a
    /// completable four-way surface only when two distinct windows can be
    /// assigned to the two remaining zones.
    static func maximumDistinctAssignmentCount(
        zones: [SnapZone],
        candidateIDsByZone: [SnapZone: Set<String>]
    ) -> Int {
        func search(
            zoneIndex: Int,
            usedCandidateIDs: Set<String>
        ) -> Int {
            guard zoneIndex < zones.count else { return 0 }
            let zone = zones[zoneIndex]
            var best = search(
                zoneIndex: zoneIndex + 1,
                usedCandidateIDs: usedCandidateIDs
            )
            for candidateID in candidateIDsByZone[zone] ?? [] where
                !usedCandidateIDs.contains(candidateID) {
                best = max(
                    best,
                    1 + search(
                        zoneIndex: zoneIndex + 1,
                        usedCandidateIDs:
                            usedCandidateIDs.union([candidateID])
                    )
                )
            }
            return best
        }
        return search(zoneIndex: 0, usedCandidateIDs: [])
    }
}

enum SnapDropTargetPolicy {
    /// The physical mouse-up zone wins over a preview sampled on an earlier
    /// drag event. A sticky preview is only a fallback just outside the band.
    static func preferredZone(
        detectedZone: SnapZone?,
        activeZone: SnapZone?,
        activeZoneIsStillValid: Bool
    ) -> SnapZone? {
        detectedZone ?? (activeZoneIsStillValid ? activeZone : nil)
    }
}
