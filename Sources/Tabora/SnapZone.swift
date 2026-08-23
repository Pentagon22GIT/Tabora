import AppKit

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
