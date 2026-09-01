import ApplicationServices
import CoreGraphics
import Foundation

enum GroupSpaceMigrationPhase: Equatable {
    case captured
    case awaitingNormalDesktopDispatch
    case dispatchingMove
    case verifyingMove
    case rollingBack
    case physicalCommitted
    case applyingLayout
    case rebuildingGroup
}

enum GroupSpaceMigrationInterruptionDisposition: Equatable {
    case cancelBeforeDispatch
    case rollbackDispatchedMove
    case continueRollback
    case dissolveAtDestination
}

enum GroupSpaceMigrationInterruptionPolicy {
    static func disposition(
        for phase: GroupSpaceMigrationPhase
    ) -> GroupSpaceMigrationInterruptionDisposition {
        switch phase {
        case .captured, .awaitingNormalDesktopDispatch, .dispatchingMove:
            return .cancelBeforeDispatch
        case .verifyingMove:
            return .rollbackDispatchedMove
        case .rollingBack:
            return .continueRollback
        case .physicalCommitted, .applyingLayout, .rebuildingGroup:
            return .dissolveAtDestination
        }
    }
}

enum GroupSpaceMigrationTerminalState: Equatable {
    case completed
    case rolledBack
    case dissolvedAfterOriginRestore
    case dissolvedAtDestination
    case dissolvedAfterIncompleteRollback
    case cancelledBeforeStart
    case cancelledAtSource
}

enum GroupSpaceMigrationTerminalPolicy {
    static func requiresNormalDesktopRearm(
        _ state: GroupSpaceMigrationTerminalState
    ) -> Bool {
        switch state {
        case .completed, .cancelledBeforeStart:
            // A consumed migration Proxy must not be recreated during the
            // compositor tail of the same Mission Control scene. Require the
            // existing bounded normal-desktop evidence before presentation can
            // be rebuilt. Source-return cancellation is different because it
            // deliberately preserves the original queued Proxy.
            return true
        case .rolledBack, .dissolvedAfterOriginRestore,
             .dissolvedAtDestination,
             .dissolvedAfterIncompleteRollback, .cancelledAtSource:
            return false
        }
    }

    static func preservesQueuedProxy(
        _ state: GroupSpaceMigrationTerminalState
    ) -> Bool {
        state == .cancelledAtSource
    }
}

enum GroupSpaceMigrationQueuedPresentationPolicy {
    static func preservesMovedProxy(for phase: GroupSpaceMigrationPhase) -> Bool {
        phase == .awaitingNormalDesktopDispatch
    }
}

enum GroupSpaceMigrationFrameOperationOwnershipPolicy {
    static func ownsFrameOperations(for phase: GroupSpaceMigrationPhase) -> Bool {
        switch phase {
        case .captured, .awaitingNormalDesktopDispatch:
            return false
        case .dispatchingMove, .verifyingMove, .rollingBack,
             .physicalCommitted, .applyingLayout, .rebuildingGroup:
            return true
        }
    }
}

enum GroupSpaceMigrationQueuePolicy {
    static func acceptsCapture(
        groupID: SnapGroupID,
        capturedGroupIDs: Set<SnapGroupID>
    ) -> Bool {
        !capturedGroupIDs.contains(groupID)
    }

    static func acceptsPhysicalMembers(
        memberIDs: Set<String>,
        windowIDs: Set<CGWindowID>,
        capturedMemberIDs: Set<String>,
        capturedWindowIDs: Set<CGWindowID>
    ) -> Bool {
        memberIDs.count >= 2
            && memberIDs.count == windowIDs.count
            && memberIDs.isDisjoint(with: capturedMemberIDs)
            && windowIDs.isDisjoint(with: capturedWindowIDs)
    }
}

enum GroupSpaceMigrationQueuedDestinationDisposition: Equatable {
    case unchanged
    case cancelAtSource
    case retarget
}

enum GroupSpaceMigrationQueuedDestinationPolicy {
    static func disposition(
        observedSpace: TaboraSpaceID,
        sourceSpace: TaboraSpaceID,
        currentDestinationSpace: TaboraSpaceID
    ) -> GroupSpaceMigrationQueuedDestinationDisposition {
        if observedSpace == currentDestinationSpace { return .unchanged }
        if observedSpace == sourceSpace { return .cancelAtSource }
        return .retarget
    }
}

enum GroupSpaceMigrationDispatchMembershipDisposition: Equatable {
    case dispatchRequired
    case alreadyAtDestination
    case retryUnknown
    case cancelForIdentityMutation
}

enum GroupSpaceMigrationDispatchMembershipPolicy {
    static let maximumUnknownRetryCount = 10

    static func disposition(
        expectedWindowIDsByMemberID: [String: CGWindowID],
        observation: WindowSpaceObservation,
        destinationSpace: TaboraSpaceID,
        isUserSpace: (TaboraSpaceID) -> Bool?
    ) -> GroupSpaceMigrationDispatchMembershipDisposition {
        guard expectedWindowIDsByMemberID.count >= 2 else {
            return .retryUnknown
        }
        var allAtDestination = true
        for (memberID, expectedWindowID) in expectedWindowIDsByMemberID {
            guard let member = observation.member(memberID),
                  let observedWindowID = member.windowID,
                  let observedSpace = member.membership.singleUserCandidate
            else { return .retryUnknown }
            guard observedWindowID == expectedWindowID else {
                return .cancelForIdentityMutation
            }
            guard let userSpace = isUserSpace(observedSpace) else {
                return .retryUnknown
            }
            guard userSpace else { return .cancelForIdentityMutation }
            if observedSpace != destinationSpace {
                allAtDestination = false
            }
        }
        return allAtDestination ? .alreadyAtDestination : .dispatchRequired
    }

    static func shouldRetryUnknown(completedRetryCount: Int) -> Bool {
        completedRetryCount < maximumUnknownRetryCount
    }
}

struct GroupSpaceMigrationRollbackBatch: Equatable {
    let destinationSpace: TaboraSpaceID
    let memberIDs: Set<String>
}

enum GroupSpaceMigrationRollbackPolicy {
    static func batches(
        originsByMemberID: [String: TaboraSpaceID],
        dispatchedDestination: TaboraSpaceID
    ) -> [GroupSpaceMigrationRollbackBatch] {
        var memberIDsByOrigin: [TaboraSpaceID: Set<String>] = [:]
        for (memberID, origin) in originsByMemberID where
            origin != dispatchedDestination {
            memberIDsByOrigin[origin, default: []].insert(memberID)
        }
        return memberIDsByOrigin.keys.sorted {
            $0.rawValue < $1.rawValue
        }.map {
            GroupSpaceMigrationRollbackBatch(
                destinationSpace: $0,
                memberIDs: memberIDsByOrigin[$0] ?? []
            )
        }
    }

    static func canPreserveStructuralGroup(
        originsByMemberID: [String: TaboraSpaceID],
        capturedSource: TaboraSpaceID,
        expectedMemberCount: Int
    ) -> Bool {
        originsByMemberID.count == expectedMemberCount
            && originsByMemberID.values.allSatisfy {
                $0 == capturedSource
            }
    }
}

struct GroupSpaceMigrationDispatchReadinessEvidence: Equatable {
    let firstObservedAt: TimeInterval
    let observationCount: Int
}

struct GroupSpaceMigrationDispatchReadinessObservation: Equatable {
    let evidence: GroupSpaceMigrationDispatchReadinessEvidence
    let isConfirmed: Bool
}

enum GroupSpaceMigrationDispatchReadinessPolicy {
    static let requiredObservationCount = 2
    static let minimumSettleInterval: TimeInterval = 0.15

    static func acceptsNormalDesktopObservation(
        migratingGroupIsNormal: Bool,
        migratingGroupHasNormalMember: Bool,
        activeSpaceChangeWasObserved: Bool
    ) -> Bool {
        migratingGroupIsNormal
            || migratingGroupHasNormalMember
            || activeSpaceChangeWasObserved
    }

    static func observe(
        previous: GroupSpaceMigrationDispatchReadinessEvidence?,
        now: TimeInterval
    ) -> GroupSpaceMigrationDispatchReadinessObservation {
        let evidence: GroupSpaceMigrationDispatchReadinessEvidence
        if let previous {
            evidence = GroupSpaceMigrationDispatchReadinessEvidence(
                firstObservedAt: previous.firstObservedAt,
                observationCount: previous.observationCount + 1
            )
        } else {
            evidence = GroupSpaceMigrationDispatchReadinessEvidence(
                firstObservedAt: now,
                observationCount: 1
            )
        }
        return GroupSpaceMigrationDispatchReadinessObservation(
            evidence: evidence,
            isConfirmed: evidence.observationCount >= requiredObservationCount
                && now - evidence.firstObservedAt >= minimumSettleInterval
        )
    }
}

enum GroupSpaceMigrationAPIFailureKind: String, Equatable {
    case runtimeUnavailable
    case dispatchRejected
}

struct GroupSpaceMigrationAPIUnavailableNotice: Equatable {
    let kind: GroupSpaceMigrationAPIFailureKind
    let detail: String

    var sessionDeduplicationKey: String {
        "\(kind.rawValue)|\(detail)"
    }
}

enum GroupSpaceMigrationAPIFailurePolicy {
    static func kind(
        for result: SpaceTransportDispatchResult
    ) -> GroupSpaceMigrationAPIFailureKind? {
        switch result {
        case .dispatched:
            return nil
        case .unavailable:
            return .runtimeUnavailable
        case .rejected:
            return .dispatchRejected
        }
    }

    static func shouldDeliverAfterNormalDesktop(
        pendingGroupID: SnapGroupID,
        observedNormalGroupIDs: Set<SnapGroupID>
    ) -> Bool {
        observedNormalGroupIDs.contains(pendingGroupID)
    }
}

struct GroupSpaceMigrationRuntimeStatus: Equatable {
    static let verifiedEnvironmentDescription =
        "動作確認済み: macOS 26.5.2 / 26.6.2（2026-08-30）"

    let isAvailable: Bool
    let detail: String
}

struct GroupSpaceMigrationMember {
    let stableIdentity: String
    let element: AXUIElement
    let pid: pid_t
    let windowID: CGWindowID
    let zone: SnapZone
    let sourceFrame: CGRect
    let limits: AppConstraintLimits
}

struct GroupSpaceMigrationCapture {
    let transactionID: UUID
    let structuralSnapshot: GroupSpaceStructuralSnapshot
    let preferredMemberID: String
    let members: [GroupSpaceMigrationMember]
    let sourceSpace: TaboraSpaceID
    let destinationSpace: TaboraSpaceID
    let sourceVisibleFrame: CGRect
    let destinationVisibleFrame: CGRect
    let destinationDisplayID: CGDirectDisplayID
    let proxyWindowID: CGWindowID
    let plannedLayout: GroupMigrationLayoutResolution
    let destinationRestoreFrames: [String: CGRect]
}

enum GroupSpaceMigrationCaptureResolution {
    case ready(GroupSpaceMigrationCapture)
    case retryableObservation
    case rejected
}

enum GroupSpaceMigrationPreflightDisposition: Equatable {
    case proceed
    case retry
    case reject
}

enum GroupSpaceMigrationPreflightPolicy {
    static let maximumObservationRetryCount = 10

    static func disposition(
        relationship: GroupSpaceRelationship,
        expectedSourceSpace: TaboraSpaceID
    ) -> GroupSpaceMigrationPreflightDisposition {
        switch relationship {
        case .knownSame(let space):
            return space == expectedSourceSpace ? .proceed : .reject
        case .knownDifferent:
            return .reject
        case .unknown:
            return .retry
        }
    }

    static func shouldRetry(completedRetryCount: Int) -> Bool {
        completedRetryCount < maximumObservationRetryCount
    }
}

enum GroupSpaceProxyBaselineRetryPolicy {
    /// WindowServer may publish a newly-created managed proxy before its Space
    /// membership becomes observable. Retry only this initialization edge;
    /// normal presentation refresh may start a new bounded attempt later.
    static let maximumRetryCount = 10

    static func shouldRetry(completedRetryCount: Int) -> Bool {
        completedRetryCount < maximumRetryCount
    }
}

enum GroupSpaceProxySelectionArbitrationPolicy {
    /// A confirmed destination observation belongs to the migration gesture,
    /// not to the older "select this group" Mission Control exit path.
    static func shouldPreferMigration(
        sourceSpace: TaboraSpaceID,
        observedSpace: TaboraSpaceID?,
        existingCandidateSpace: TaboraSpaceID?
    ) -> Bool {
        if let observedSpace, observedSpace != sourceSpace { return true }
        if let existingCandidateSpace,
           existingCandidateSpace != sourceSpace { return true }
        return false
    }
}

struct GroupMigrationFrameWriteSubject: Equatable {
    let stableIdentity: String
    let pid: pid_t
}

enum GroupMigrationFrameSchedulingPolicy {
    /// AX writes for separate windows of one application are not independent:
    /// position/size/position sequences can be reordered by that process.
    /// Keep one lane per PID while allowing unrelated applications to settle
    /// concurrently.
    static func lanes(
        subjects: [GroupMigrationFrameWriteSubject]
    ) -> [[String]] {
        Dictionary(grouping: subjects, by: \.pid)
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { _, lane in lane.map(\.stableIdentity).sorted() }
    }

    static func completionTimeout(maximumLaneLength: Int) -> TimeInterval {
        // Preserve the historical 1.8-second safety ceiling per concurrently
        // executable window. A serialized same-PID lane receives that same
        // budget for every member rather than expiring midway through a later
        // window's bounded correction sequence.
        1.8 * Double(max(maximumLaneLength, 1))
    }
}

struct GroupSpacePresentationRearmEvidence: Equatable {
    let firstObservedAt: TimeInterval
    let observationCount: Int
}

struct GroupSpacePresentationRearmObservation: Equatable {
    let evidence: GroupSpacePresentationRearmEvidence
    let isConfirmed: Bool
}

enum GroupSpacePresentationRearmPolicy {
    static let requiredObservationCount = 2
    static let minimumSettleInterval: TimeInterval = 0.15

    static func observe(
        previous: GroupSpacePresentationRearmEvidence?,
        now: TimeInterval
    ) -> GroupSpacePresentationRearmObservation {
        let evidence: GroupSpacePresentationRearmEvidence
        if let previous {
            evidence = GroupSpacePresentationRearmEvidence(
                firstObservedAt: previous.firstObservedAt,
                observationCount: previous.observationCount + 1
            )
        } else {
            evidence = GroupSpacePresentationRearmEvidence(
                firstObservedAt: now,
                observationCount: 1
            )
        }
        return GroupSpacePresentationRearmObservation(
            evidence: evidence,
            isConfirmed: evidence.observationCount >= requiredObservationCount
                && now - evidence.firstObservedAt >= minimumSettleInterval
        )
    }
}

final class GroupSpaceMigrationTransaction {
    var capture: GroupSpaceMigrationCapture
    var phase: GroupSpaceMigrationPhase = .captured
    var phaseDeadline: TimeInterval = 0
    var destinationEntryFrames: [String: CGRect] = [:]
    var dispatchReadinessEvidence:
        GroupSpaceMigrationDispatchReadinessEvidence?
    var normalDesktopDispatchIsReady = false
    var completedDispatchPreflightRetryCount = 0
    var activeSpaceChangeObservedAt: TimeInterval?
    var queuedProxyCandidateSpace: TaboraSpaceID?
    var queuedProxyCandidateFirstObservedAt: TimeInterval?
    var queuedProxyCandidateObservationCount = 0
    var completedRetargetRetryCount = 0
    var dispatchOriginsByMemberID: [String: TaboraSpaceID] = [:]
    var rollbackBatches: [GroupSpaceMigrationRollbackBatch] = []
    var rollbackBatchIndex = 0
    var rollbackBatchWasDispatched = false

    init(capture: GroupSpaceMigrationCapture) {
        self.capture = capture
    }
}

struct GroupSpaceProxyDescriptor {
    let groupID: SnapGroupID
    let memberIDs: Set<String>
    let windowID: CGWindowID
    let frame: CGRect
}

protocol GroupSpaceMigrationHost: AnyObject {
    var groupSpaceMigrationFeatureIsEnabled: Bool { get }
    var groupSpaceMigrationCanMonitor: Bool { get }
    var groupSpaceMigrationCanBegin: Bool { get }

    func groupSpaceProxyDescriptor(
        groupID: SnapGroupID
    ) -> GroupSpaceProxyDescriptor?

    func groupSpaceMigrationSubjects(
        groupID: SnapGroupID,
        presentedMemberIDs: Set<String>
    ) -> [WindowSpaceSubject]?

    func captureGroupSpaceMigration(
        groupID: SnapGroupID,
        presentedMemberIDs: Set<String>,
        proxyWindowID: CGWindowID,
        sourceSpace: TaboraSpaceID,
        destinationSpace: TaboraSpaceID,
        destinationManagedDisplayIdentifier: String,
        observedMembers: WindowSpaceObservation
    ) -> GroupSpaceMigrationCaptureResolution

    func groupSpaceMigrationStructureMatches(
        _ snapshot: GroupSpaceStructuralSnapshot
    ) -> Bool

    func groupSpaceMigrationDidBegin(_ capture: GroupSpaceMigrationCapture)
    func groupSpaceMigrationDidRefreshCapture(
        _ capture: GroupSpaceMigrationCapture
    )
    func updateGroupSpaceMigrationQueuePresentation(
        groupID: SnapGroupID,
        position: Int,
        total: Int
    )
    func groupSpaceMigrationDestinationEntryFrames(
        _ capture: GroupSpaceMigrationCapture
    ) -> [String: CGRect]?
    func applyGroupSpaceMigrationLayout(
        _ capture: GroupSpaceMigrationCapture,
        frames: [String: CGRect],
        completion: @escaping (Bool, [String: CGRect]) -> Void
    )
    func restoreGroupSpaceMigrationEntryFrames(
        _ capture: GroupSpaceMigrationCapture,
        frames: [String: CGRect],
        completion: @escaping () -> Void
    )
    func commitGroupSpaceMigration(
        _ capture: GroupSpaceMigrationCapture,
        acceptedFrames: [String: CGRect]
    ) -> Bool
    func dissolveGroupSpaceMigration(
        _ capture: GroupSpaceMigrationCapture
    )
    func retireGroupSpaceMigrationProxy(groupID: SnapGroupID)
    func restoreGroupSpaceMigrationProxyAfterSourceCancellation(
        groupID: SnapGroupID
    )
    func groupSpaceMigrationDidFinish(
        _ capture: GroupSpaceMigrationCapture,
        terminalState: GroupSpaceMigrationTerminalState
    )
    func groupSpaceMigrationDidDetectUnavailableAPI(
        _ notice: GroupSpaceMigrationAPIUnavailableNotice
    )
}
