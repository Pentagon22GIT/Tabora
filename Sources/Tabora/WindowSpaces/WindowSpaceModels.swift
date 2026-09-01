import ApplicationServices
import CoreGraphics
import Foundation

struct TaboraSpaceID: Hashable, Equatable {
    let rawValue: UInt64

    init?(_ rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

enum WindowSpaceMembership: Equatable {
    case known(Set<TaboraSpaceID>)
    case unknown

    var singleUserCandidate: TaboraSpaceID? {
        guard case .known(let spaces) = self,
              spaces.count == 1 else { return nil }
        return spaces.first
    }
}

struct WindowSpaceSubject {
    let stableIdentity: String
    let element: AXUIElement
    let pid: pid_t
    let cachedWindowID: CGWindowID?
}

struct WindowSpaceMemberObservation: Equatable {
    let stableIdentity: String
    let windowID: CGWindowID?
    let membership: WindowSpaceMembership
}

struct WindowSpaceObservation: Equatable {
    let membersByStableIdentity: [String: WindowSpaceMemberObservation]

    func member(_ stableIdentity: String) -> WindowSpaceMemberObservation? {
        membersByStableIdentity[stableIdentity]
    }
}

enum WindowSpaceSubjectIdentityPolicy {
    static func hasUniquePhysicalSurfaces(
        memberIDs: Set<String>,
        observation: WindowSpaceObservation
    ) -> Bool {
        var windowIDs: [CGWindowID] = []
        for memberID in memberIDs {
            guard let member = observation.member(memberID),
                  member.stableIdentity == memberID,
                  let windowID = member.windowID else { return false }
            windowIDs.append(windowID)
        }
        return Set(windowIDs).count == memberIDs.count
    }
}

enum GroupSpaceRelationship: Equatable {
    case knownSame(TaboraSpaceID)
    case knownDifferent([String: TaboraSpaceID])
    case unknown
}

enum GroupSpaceMembershipPolicy {
    static func relationship(
        memberIDs: Set<String>,
        observation: WindowSpaceObservation
    ) -> GroupSpaceRelationship {
        guard memberIDs.count >= 2 else { return .unknown }
        var spacesByMemberID: [String: TaboraSpaceID] = [:]
        for memberID in memberIDs {
            guard let member = observation.member(memberID),
                  let space = member.membership.singleUserCandidate else {
                return .unknown
            }
            spacesByMemberID[memberID] = space
        }
        let spaces = Set(spacesByMemberID.values)
        guard let first = spaces.first else { return .unknown }
        return spaces.count == 1
            ? .knownSame(first)
            : .knownDifferent(spacesByMemberID)
    }
}

struct DirectGroupSpaceSeparationEvidence: Equatable {
    let spacesByMemberID: [String: TaboraSpaceID]
    let firstObservedAt: TimeInterval
    let observationCount: Int
}

struct DirectGroupSpaceSeparationObservation: Equatable {
    let evidence: DirectGroupSpaceSeparationEvidence
    let isConfirmed: Bool
}

enum DirectGroupSpaceSeparationPolicy {
    static let minimumSettleInterval: TimeInterval = 0.15
    static let requiredObservationCount = 2

    static func observe(
        previous: DirectGroupSpaceSeparationEvidence?,
        spacesByMemberID: [String: TaboraSpaceID],
        now: TimeInterval
    ) -> DirectGroupSpaceSeparationObservation {
        guard let previous,
              previous.spacesByMemberID == spacesByMemberID else {
            return DirectGroupSpaceSeparationObservation(
                evidence: DirectGroupSpaceSeparationEvidence(
                    spacesByMemberID: spacesByMemberID,
                    firstObservedAt: now,
                    observationCount: 1
                ),
                isConfirmed: false
            )
        }
        let evidence = DirectGroupSpaceSeparationEvidence(
            spacesByMemberID: spacesByMemberID,
            firstObservedAt: previous.firstObservedAt,
            observationCount: previous.observationCount + 1
        )
        return DirectGroupSpaceSeparationObservation(
            evidence: evidence,
            isConfirmed: evidence.observationCount
                >= requiredObservationCount
                && now - evidence.firstObservedAt >= minimumSettleInterval
        )
    }
}

struct GroupSpaceStructuralSnapshot: Equatable {
    let groupID: SnapGroupID
    let memberIDs: Set<String>
    let zonesByMemberID: [String: SnapZone]
    let displayID: CGDirectDisplayID
}

struct SpaceRuntimeCapabilities: OptionSet, Equatable {
    let rawValue: Int

    static let resolveWindowID = Self(rawValue: 1 << 0)
    static let readWindowSpaces = Self(rawValue: 1 << 1)
    static let readSpaceType = Self(rawValue: 1 << 2)
    static let readSpaceDisplay = Self(rawValue: 1 << 3)
    static let dispatchBridgedMove = Self(rawValue: 1 << 4)

    // Detecting where Tabora's own proxy was dropped does not require the
    // member-window or move capabilities. Keep observation alive so a missing
    // macOS 26 transport symbol is reported at the transport boundary instead
    // of looking like a missing Mission Control trigger.
    static let proxyObservationMinimum: Self = [
        .readWindowSpaces,
        .readSpaceType
    ]

    static let migrationMinimum: Self = [
        .resolveWindowID,
        .readWindowSpaces,
        .readSpaceType,
        .readSpaceDisplay,
        .dispatchBridgedMove
    ]

    var missingMigrationComponentDescription: String {
        let components: [(Self, String)] = [
            (.resolveWindowID, L10n.text("migration.component.resolve_window_id")),
            (.readWindowSpaces, L10n.text("migration.component.read_window_spaces")),
            (.readSpaceType, L10n.text("migration.component.read_space_type")),
            (.readSpaceDisplay, L10n.text("migration.component.read_space_display")),
            (.dispatchBridgedMove, L10n.text("migration.component.dispatch_move"))
        ]
        let missing = components.compactMap { capability, name in
            contains(capability) ? nil : name
        }
        return missing.isEmpty
            ? L10n.text("migration.component.none_missing")
            : L10n.format("migration.component.missing", missing.joined(separator: ", "))
    }
}

enum SpaceTransportDispatchResult: Equatable {
    case dispatched
    case unavailable
    case rejected
}

enum GroupSpaceProxyMonitoringPolicy {
    static let maximumDuration: TimeInterval = 120

    static func isWithinLifetime(
        startedAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        now >= startedAt && now - startedAt <= maximumDuration
    }

    static func destinationIsSettled(
        observationCount: Int,
        firstObservedAt: TimeInterval?,
        now: TimeInterval,
        buttonIsDown: Bool,
        activeSpaceSettlementWasObserved: Bool
    ) -> Bool {
        guard observationCount > 0,
              let firstObservedAt else { return false }
        if activeSpaceSettlementWasObserved {
            return true
        }
        guard !buttonIsDown,
              observationCount >= 2 else { return false }
        return now - firstObservedAt >= 0.10
    }
}

protocol WindowSpaceObservationPort: AnyObject {
    var capabilities: SpaceRuntimeCapabilities { get }

    func observe(subjects: [WindowSpaceSubject]) -> WindowSpaceObservation
    func membership(forWindowID windowID: CGWindowID) -> WindowSpaceMembership
    func isUserSpace(_ spaceID: TaboraSpaceID) -> Bool?
    func managedDisplayIdentifier(for spaceID: TaboraSpaceID) -> String?
}

protocol WindowSpaceTransportPort: AnyObject {
    var moveRuntimeDiagnosticDescription: String { get }
    var lastMoveDispatchDiagnosticDescription: String { get }

    func move(
        windowIDs: [CGWindowID],
        to destination: TaboraSpaceID
    ) -> SpaceTransportDispatchResult
}

extension WindowSpaceTransportPort {
    var moveRuntimeDiagnosticDescription: String {
        L10n.text("migration.diagnostic.transport_unavailable")
    }

    var lastMoveDispatchDiagnosticDescription: String {
        L10n.text("migration.diagnostic.dispatch_unavailable")
    }
}
