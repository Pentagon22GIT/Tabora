import CoreGraphics

enum SnapInput {
    case drag, shortcut, menu, gesture, assist
}

enum LockedGestureRoute: Equatable {
    case ignored, subdivision, exchange(SnapZone)

    static func resolve(source: SnapZone, direction: SnapZone, layout: [String: SnapZone],
                        subdivisionEnabled: Bool) -> Self {
        guard SplitCoverage(layout.values) == .full, direction != .maximize else { return .ignored }
        let origin = source.occupiedQuarters
        let target = direction.occupiedQuarters
        if origin.count == 2 {
            if target.count == 1 && target.isSubset(of: origin) {
                return subdivisionEnabled ? .subdivision : .ignored
            }
            guard origin.isDisjoint(with: target) else { return .ignored }
            if target.count == 2 { return .exchange(direction) }
        } else if !origin.isDisjoint(with: target) { return .ignored }
        let anchor = source.sizeConstraintAnchor
        let adjacent = target.filter { cell in
            let point = cell.sizeConstraintAnchor
            return origin.count == 2 || abs(anchor.x - point.x) + abs(anchor.y - point.y) == 1
        }
        guard adjacent.count == 1, let cell = adjacent.first,
              let peer = layout.values.first(where: { $0.occupiedQuarters.contains(cell) })
        else { return .ignored }
        return .exchange(peer)
    }
}

struct GroupSlotExchange {
    struct Move {
        let oldZone: SnapZone
        let newZone: SnapZone
        let frame: CGRect
    }
    let groupID: SnapGroupID
    let placementRevision: UInt64
    let sourceID: String
    let sourceZone: SnapZone
    let peers: [String: Move]
    let sourceFrame: CGRect
    let destinationFrame: CGRect

    static func resolve(group: SnapGroup, sourceID: String, destination: SnapZone,
                        placements: [String: LockedPlacement], allowCombined: Bool = false) -> Self? {
        guard group.state == .active, let source = placements[sourceID],
              source.displayID == group.displayID, group.layout.zonesByMemberID[sourceID] == source.zone,
              source.zone != destination else { return nil }
        let targets = group.layout.zonesByMemberID.filter { id, zone in
            id != sourceID && zone.occupiedQuarters.isSubset(of: destination.occupiedQuarters)
        }
        let single = targets.count == 1 && targets.values.first == destination
        guard single || (allowCombined && targets.count == 2 && source.zone.occupiedQuarters.count == 2
            && destination.occupiedQuarters.count == 2 && source.zone.occupiedQuarters.isDisjoint(with: destination.occupiedQuarters))
        else { return nil }
        var moves: [String: Move] = [:]
        var combined = CGRect.null
        for (id, zone) in targets {
            guard let peer = placements[id], peer.zone == zone, peer.displayID == group.displayID else { return nil }
            let old = peer.appliedFrame
            combined = combined.union(old)
            var newZone = source.zone
            var frame = source.appliedFrame
            if !single {
                let horizontal = source.zone.sizeConstraintAnchor.x != destination.sizeConstraintAnchor.x
                guard let corner = source.zone.occupiedQuarters.first(where: {
                    horizontal ? $0.sizeConstraintAnchor.y == zone.sizeConstraintAnchor.y
                               : $0.sizeConstraintAnchor.x == zone.sizeConstraintAnchor.x
                }) else { return nil }
                newZone = corner
                if horizontal { frame.origin.y = old.minY; frame.size.height = old.height }
                else { frame.origin.x = old.minX; frame.size.width = old.width }
            }
            moves[id] = Move(oldZone: zone, newZone: newZone, frame: frame)
        }
        return Self(groupID: group.id, placementRevision: group.placementRevision, sourceID: sourceID,
                    sourceZone: source.zone, peers: moves, sourceFrame: source.appliedFrame, destinationFrame: combined)
    }

    func isCurrent(in group: SnapGroup?) -> Bool {
        group?.id == groupID && group?.placementRevision == placementRevision && group?.state == .active
            && group?.layout.zonesByMemberID[sourceID] == sourceZone
            && peers.allSatisfy { group?.layout.zonesByMemberID[$0.key] == $0.value.oldZone }
    }
}

enum OccupiedSplitPolicy {
    static func permits(existing: SnapZone, incoming: SnapZone, replacementEnabled: Bool) -> Bool {
        replacementEnabled
            || !SnapPlacementLayerPolicy.conflicts(existing: existing, incoming: incoming)
    }
}
