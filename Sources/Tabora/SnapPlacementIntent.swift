import CoreGraphics

enum SnapInput {
    case drag, shortcut, menu, gesture, assist
}

struct GroupSlotExchange {
    let groupID: SnapGroupID
    let revision: UInt64
    let sourceID: String
    let sourceZone: SnapZone
    let peerID: String
    let peerZone: SnapZone
    let sourceFrame: CGRect
    let destinationFrame: CGRect

    static func resolve(group: SnapGroup, sourceID: String,
                        destination: SnapZone, placements: [String: LockedPlacement]) -> Self? {
        guard group.state == .active,
              let source = placements[sourceID], source.zone != destination,
              group.layout.zonesByMemberID[sourceID] == source.zone,
              let peerID = group.layout.zonesByMemberID.first(where: { $0.value == destination })?.key,
              let peer = placements[peerID], peer.zone == destination,
              source.displayID == group.displayID, peer.displayID == group.displayID
        else { return nil }
        return Self(groupID: group.id, revision: group.revision, sourceID: sourceID,
                    sourceZone: source.zone, peerID: peerID, peerZone: destination,
                    sourceFrame: source.appliedFrame, destinationFrame: peer.appliedFrame)
    }

    func isCurrent(in group: SnapGroup?) -> Bool {
        group?.id == groupID && group?.revision == revision && group?.state == .active
            && group?.layout.zonesByMemberID[sourceID] == sourceZone
            && group?.layout.zonesByMemberID[peerID] == peerZone
    }
}

enum OccupiedSplitPolicy {
    static func permits(existing: SnapZone, incoming: SnapZone, replacementEnabled: Bool) -> Bool {
        existing == .maximize || incoming == .maximize || replacementEnabled
            || !SnapPlacementLayerPolicy.conflicts(existing: existing, incoming: incoming)
    }
}
