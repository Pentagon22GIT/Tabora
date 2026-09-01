import CoreGraphics
import Foundation

struct GroupMigrationLayoutMember {
    let stableIdentity: String
    let zone: SnapZone
    let sourceFrame: CGRect
    let limits: AppConstraintLimits
}

enum GroupMigrationLayoutResolution: Equatable {
    case exact([String: CGRect])
    case adjusted([String: CGRect])
    case impossible
    case indeterminate

    var frames: [String: CGRect]? {
        switch self {
        case .exact(let frames), .adjusted(let frames): return frames
        case .impossible, .indeterminate: return nil
        }
    }
}

enum GroupMigrationLayoutPlanner {
    private static let frameTolerance: CGFloat = 1

    static func plan(
        members: [GroupMigrationLayoutMember],
        sourceVisibleFrame: CGRect,
        destinationVisibleFrame: CGRect
    ) -> GroupMigrationLayoutResolution {
        guard members.count >= 2,
              Set(members.map(\.stableIdentity)).count == members.count,
              valid(sourceVisibleFrame),
              valid(destinationVisibleFrame),
              SplitLayoutGeometry.logicalSplitTopologyIsConnectedAndNonOverlapping(
                  zonesByIdentity: Dictionary(
                      uniqueKeysWithValues: members.map {
                          ($0.stableIdentity, $0.zone)
                      }
                  )
              ) else {
            return .indeterminate
        }

        let projectedFrames = Dictionary(
            uniqueKeysWithValues: members.map { member in
                (
                    member.stableIdentity,
                    projected(
                        member.sourceFrame,
                        from: sourceVisibleFrame,
                        to: destinationVisibleFrame
                    )
                )
            }
        )
        guard projectedFrames.values.allSatisfy({ valid($0) }) else {
            return .indeterminate
        }
        if validate(
            projectedFrames,
            members: members,
            destinationVisibleFrame: destinationVisibleFrame
        ) {
            return .exact(projectedFrames)
        }

        let partitionMembers = members.compactMap { member
            -> CanonicalSplitPartitionMember? in
            guard let projectedFrame = projectedFrames[member.stableIdentity]
            else { return nil }
            return CanonicalSplitPartitionMember(
                stableIdentity: member.stableIdentity,
                zone: member.zone,
                referenceFrame: projectedFrame,
                limits: member.limits
            )
        }
        guard partitionMembers.count == members.count,
              let preferred = partitionMembers.first else {
            return .indeterminate
        }
        switch SplitLayoutGeometry.canonicalConstraintPartition(
            members: partitionMembers,
            incomingIdentity: preferred.stableIdentity,
            in: destinationVisibleFrame
        ) {
        case .ready(let frames):
            return validate(
                frames,
                members: members,
                destinationVisibleFrame: destinationVisibleFrame
            ) ? .adjusted(frames) : .indeterminate
        case .confirmedInfeasible:
            return .impossible
        case .indeterminate:
            return .indeterminate
        }
    }

    private static func projected(
        _ frame: CGRect,
        from source: CGRect,
        to destination: CGRect
    ) -> CGRect {
        let x = (frame.minX - source.minX) / source.width
        let y = (frame.minY - source.minY) / source.height
        let width = frame.width / source.width
        let height = frame.height / source.height
        return CGRect(
            x: destination.minX + x * destination.width,
            y: destination.minY + y * destination.height,
            width: width * destination.width,
            height: height * destination.height
        )
    }

    private static func validate(
        _ frames: [String: CGRect],
        members: [GroupMigrationLayoutMember],
        destinationVisibleFrame: CGRect
    ) -> Bool {
        guard frames.count == members.count else { return false }
        for member in members {
            guard let frame = frames[member.stableIdentity],
                  destinationVisibleFrame.insetBy(
                      dx: -frameTolerance,
                      dy: -frameTolerance
                  ).contains(frame),
                  satisfies(frame.width, minimum: member.limits.minWidth,
                            maximum: member.limits.maxWidth),
                  satisfies(frame.height, minimum: member.limits.minHeight,
                            maximum: member.limits.maxHeight) else {
                return false
            }
        }
        for (index, lhs) in members.enumerated() {
            guard let lhsFrame = frames[lhs.stableIdentity] else {
                return false
            }
            for rhs in members.dropFirst(index + 1) {
                guard let rhsFrame = frames[rhs.stableIdentity] else {
                    return false
                }
                let overlap = lhsFrame.intersection(rhsFrame)
                if !overlap.isNull,
                   overlap.width > frameTolerance,
                   overlap.height > frameTolerance {
                    return false
                }
            }
        }
        let placements = members.compactMap { member
            -> SplitPlacementGeometry? in
            frames[member.stableIdentity].map {
                SplitPlacementGeometry(
                    stableIdentity: member.stableIdentity,
                    zone: member.zone,
                    frame: $0
                )
            }
        }
        guard placements.count == members.count,
              let preferred = members.first else { return false }
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements,
            detachedConnections: []
        )
        return SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: preferred.stableIdentity,
            handles: handles
        ) == Set(members.map(\.stableIdentity))
    }

    private static func satisfies(
        _ value: CGFloat,
        minimum: CGFloat?,
        maximum: CGFloat?
    ) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        if let minimum, value + frameTolerance < minimum { return false }
        if let maximum, value - frameTolerance > maximum { return false }
        return true
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
