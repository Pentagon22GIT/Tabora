import CoreGraphics
import XCTest
@testable import Tabora

final class GroupSpaceMigrationTests: XCTestCase {
    func testFrameBatchExpiryRetiresWritesBeforeRestoreHandoff() {
        var events: [String] = []
        var results: [Bool] = []
        let successor = GroupMigrationFrameBatch(
            memberIDs: ["a"],
            cancelFrame: { events.append("cancel-restore-\($0)") },
            completion: { _ in }
        )
        let batch = GroupMigrationFrameBatch(
            memberIDs: ["a", "b", "c", "other-app"],
            cancelFrame: { events.append("cancel-\($0)") },
            completion: {
                results.append($0)
                events.append("restore")
                XCTAssertTrue(successor.begin(memberID: "a"))
            }
        )
        XCTAssertTrue(batch.begin(memberID: "a"))
        XCTAssertTrue(batch.begin(memberID: "other-app"))
        XCTAssertTrue(batch.resolve(memberID: "a", succeeded: true))
        XCTAssertTrue(batch.begin(memberID: "b"))

        batch.expire()
        XCTAssertEqual(events, ["cancel-b", "cancel-other-app", "restore"])
        XCTAssertEqual(results, [false])
        // The old same-PID lane cannot write c after restoration has begun.
        XCTAssertFalse(batch.resolve(memberID: "b", succeeded: true))
        XCTAssertFalse(batch.begin(memberID: "c"))
        batch.expire()
        batch.cancel()
        XCTAssertEqual(events, ["cancel-b", "cancel-other-app", "restore"])
        XCTAssertTrue(successor.resolve(memberID: "a", succeeded: true))
    }

    func testFrameBatchCancellationDoesNotStartFailureRestore() {
        var cancelled: [String] = []
        var completed = false
        let batch = GroupMigrationFrameBatch(
            memberIDs: ["a", "b"],
            cancelFrame: { cancelled.append($0) },
            completion: { _ in completed = true }
        )
        XCTAssertTrue(batch.begin(memberID: "a"))
        batch.cancel()
        batch.expire()
        XCTAssertEqual(cancelled, ["a"])
        XCTAssertFalse(completed)
        XCTAssertFalse(batch.resolve(memberID: "a", succeeded: false))
        XCTAssertFalse(batch.begin(memberID: "b"))
    }

    func testFrameBatchCompletionIsOneShotAndKeepsFailedResult() {
        for firstSucceeded in [false, true] {
            var results: [Bool] = []
            let batch = GroupMigrationFrameBatch(
                memberIDs: ["a", "b"],
                cancelFrame: { _ in XCTFail("Completed writes need no cancellation") },
                completion: { results.append($0) }
            )
            XCTAssertFalse(batch.begin(memberID: "foreign"))
            XCTAssertFalse(batch.resolve(memberID: "b", succeeded: true))
            XCTAssertTrue(batch.begin(memberID: "a"))
            XCTAssertFalse(batch.begin(memberID: "a"))
            XCTAssertTrue(batch.resolve(memberID: "a", succeeded: firstSucceeded))
            XCTAssertFalse(batch.resolve(memberID: "a", succeeded: true))
            XCTAssertTrue(results.isEmpty)
            XCTAssertTrue(batch.begin(memberID: "b"))
            XCTAssertTrue(batch.resolve(memberID: "b", succeeded: true))
            batch.expire()
            XCTAssertEqual(results, [firstSucceeded])
        }
    }

    func testForegroundFlushWaitsForNormalProxySelectionOwnership() {
        XCTAssertTrue(
            GroupSpaceMigrationForegroundFlushOwnershipPolicy.allowsFlush(
                proxyActivationIsActive: false,
                proxyConfirmationIsPending: false
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationForegroundFlushOwnershipPolicy.allowsFlush(
                proxyActivationIsActive: true,
                proxyConfirmationIsPending: false
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationForegroundFlushOwnershipPolicy.allowsFlush(
                proxyActivationIsActive: false,
                proxyConfirmationIsPending: true
            )
        )
    }

    func testNewProxyBaselineRetryIsFinite() {
        XCTAssertTrue(
            GroupSpaceProxyBaselineRetryPolicy.shouldRetry(
                completedRetryCount: 0
            )
        )
        XCTAssertFalse(
            GroupSpaceProxyBaselineRetryPolicy.shouldRetry(
                completedRetryCount:
                    GroupSpaceProxyBaselineRetryPolicy.maximumRetryCount
            )
        )
    }

    func testDestinationObservationWinsOverProxySelection() {
        let source = TaboraSpaceID(10)!
        let destination = TaboraSpaceID(20)!
        XCTAssertFalse(
            GroupSpaceProxySelectionArbitrationPolicy.shouldPreferMigration(
                sourceSpace: source,
                observedSpace: source,
                existingCandidateSpace: nil
            )
        )
        XCTAssertTrue(
            GroupSpaceProxySelectionArbitrationPolicy.shouldPreferMigration(
                sourceSpace: source,
                observedSpace: destination,
                existingCandidateSpace: nil
            )
        )
        XCTAssertTrue(
            GroupSpaceProxySelectionArbitrationPolicy.shouldPreferMigration(
                sourceSpace: source,
                observedSpace: nil,
                existingCandidateSpace: destination
            )
        )
    }

    func testMigrationFrameWritesSerializeOnlyWithinOneApplication() {
        let lanes = GroupMigrationFrameSchedulingPolicy.lanes(subjects: [
            GroupMigrationFrameWriteSubject(
                stableIdentity: "finder-b",
                pid: 100
            ),
            GroupMigrationFrameWriteSubject(
                stableIdentity: "chrome",
                pid: 200
            ),
            GroupMigrationFrameWriteSubject(
                stableIdentity: "finder-a",
                pid: 100
            )
        ])
        XCTAssertEqual(lanes, [["finder-a", "finder-b"], ["chrome"]])
        XCTAssertGreaterThan(
            GroupMigrationFrameSchedulingPolicy.completionTimeout(
                maximumLaneLength: 2
            ),
            GroupMigrationFrameSchedulingPolicy.completionTimeout(
                maximumLaneLength: 1
            )
        )
    }
    func testMigrationRequiresUniquePhysicalSurfaceForEveryMember() {
        let first = WindowSpaceMemberObservation(
            stableIdentity: "first",
            windowID: 10,
            membership: .unknown
        )
        let second = WindowSpaceMemberObservation(
            stableIdentity: "second",
            windowID: 11,
            membership: .unknown
        )
        XCTAssertTrue(WindowSpaceSubjectIdentityPolicy.hasUniquePhysicalSurfaces(
            memberIDs: ["first", "second"],
            observation: WindowSpaceObservation(membersByStableIdentity: [
                "first": first,
                "second": second
            ])
        ))

        XCTAssertFalse(WindowSpaceSubjectIdentityPolicy.hasUniquePhysicalSurfaces(
            memberIDs: ["first", "second"],
            observation: WindowSpaceObservation(membersByStableIdentity: [
                "first": first,
                "second": WindowSpaceMemberObservation(
                    stableIdentity: "second",
                    windowID: 10,
                    membership: .unknown
                )
            ])
        ))
        XCTAssertFalse(WindowSpaceSubjectIdentityPolicy.hasUniquePhysicalSurfaces(
            memberIDs: ["first", "second"],
            observation: WindowSpaceObservation(membersByStableIdentity: [
                "first": first
            ])
        ))
        XCTAssertFalse(WindowSpaceSubjectIdentityPolicy.hasUniquePhysicalSurfaces(
            memberIDs: ["first", "second"],
            observation: WindowSpaceObservation(membersByStableIdentity: [
                "first": first,
                "second": WindowSpaceMemberObservation(
                    stableIdentity: "another-member",
                    windowID: 11,
                    membership: .unknown
                )
            ])
        ))
    }

    func testAPIFailureAlertPolicyOnlyReportsFailedInvocationBoundaries() {
        XCTAssertNil(
            GroupSpaceMigrationAPIFailurePolicy.kind(for: .dispatched)
        )
        XCTAssertEqual(
            GroupSpaceMigrationAPIFailurePolicy.kind(for: .unavailable),
            .runtimeUnavailable
        )
        XCTAssertEqual(
            GroupSpaceMigrationAPIFailurePolicy.kind(for: .rejected),
            .dispatchRejected
        )
    }

    func testAPIFailureAlertDeduplicationIncludesKindAndRuntimeDetail() {
        let unavailable = GroupSpaceMigrationAPIUnavailableNotice(
            kind: .runtimeUnavailable,
            detail: "exact local symbol missing"
        )
        let same = GroupSpaceMigrationAPIUnavailableNotice(
            kind: .runtimeUnavailable,
            detail: "exact local symbol missing"
        )
        let rejected = GroupSpaceMigrationAPIUnavailableNotice(
            kind: .dispatchRejected,
            detail: "exact local symbol missing"
        )
        XCTAssertEqual(
            unavailable.sessionDeduplicationKey,
            same.sessionDeduplicationKey
        )
        XCTAssertNotEqual(
            unavailable.sessionDeduplicationKey,
            rejected.sessionDeduplicationKey
        )
    }

    func testVerifiedMigrationEnvironmentRemainsExplicit() {
        XCTAssertEqual(
            GroupSpaceMigrationRuntimeStatus.verifiedEnvironmentDescription,
            L10n.text("migration.verified_environment")
        )
    }

    func testRuntimeCapabilityDescriptionNamesMissingBoundary() {
        let capabilities: SpaceRuntimeCapabilities = [
            .resolveWindowID,
            .readWindowSpaces,
            .readSpaceType
        ]
        XCTAssertEqual(
            capabilities.missingMigrationComponentDescription,
            L10n.format(
                "migration.component.missing",
                [
                    L10n.text("migration.component.read_space_display"),
                    L10n.text("migration.component.dispatch_move")
                ].joined(separator: ", ")
            )
        )
    }

    func testAPIFailureAlertWaitsForItsExactGroupToReturnNormally() {
        let pending = SnapGroupID()
        XCTAssertFalse(
            GroupSpaceMigrationAPIFailurePolicy
                .shouldDeliverAfterNormalDesktop(
                    pendingGroupID: pending,
                    observedNormalGroupIDs: [SnapGroupID()]
                )
        )
        XCTAssertTrue(
            GroupSpaceMigrationAPIFailurePolicy
                .shouldDeliverAfterNormalDesktop(
                    pendingGroupID: pending,
                    observedNormalGroupIDs: [pending]
                )
        )
    }

    func testProxyObservationDoesNotDependOnMoveCapability() {
        let observationOnly: SpaceRuntimeCapabilities = [
            .readWindowSpaces,
            .readSpaceType
        ]
        XCTAssertTrue(
            observationOnly.contains(.proxyObservationMinimum)
        )
        XCTAssertFalse(observationOnly.contains(.migrationMinimum))
    }

    func testProxyDestinationRequiresSettledDropWithoutSpaceSignal() {
        XCTAssertFalse(
            GroupSpaceProxyMonitoringPolicy.destinationIsSettled(
                observationCount: 1,
                firstObservedAt: 10,
                now: 10.2,
                buttonIsDown: false,
                activeSpaceSettlementWasObserved: false
            )
        )
        XCTAssertTrue(
            GroupSpaceProxyMonitoringPolicy.destinationIsSettled(
                observationCount: 2,
                firstObservedAt: 10,
                now: 10.2,
                buttonIsDown: false,
                activeSpaceSettlementWasObserved: false
            )
        )
    }

    func testActiveSpaceSignalCanSettleExactChangedMembership() {
        XCTAssertTrue(
            GroupSpaceProxyMonitoringPolicy.destinationIsSettled(
                observationCount: 1,
                firstObservedAt: 10,
                now: 10,
                buttonIsDown: true,
                activeSpaceSettlementWasObserved: true
            )
        )
    }

    func testSpaceRelationshipRequiresExactKnownSingletons() {
        let space1 = TaboraSpaceID(1)!
        let space2 = TaboraSpaceID(2)!
        let same = WindowSpaceObservation(membersByStableIdentity: [
            "left": .init(
                stableIdentity: "left",
                windowID: 10,
                membership: .known([space1])
            ),
            "right": .init(
                stableIdentity: "right",
                windowID: 11,
                membership: .known([space1])
            )
        ])
        XCTAssertEqual(
            GroupSpaceMembershipPolicy.relationship(
                memberIDs: ["left", "right"],
                observation: same
            ),
            .knownSame(space1)
        )

        let different = WindowSpaceObservation(membersByStableIdentity: [
            "left": same.member("left")!,
            "right": .init(
                stableIdentity: "right",
                windowID: 11,
                membership: .known([space2])
            )
        ])
        XCTAssertEqual(
            GroupSpaceMembershipPolicy.relationship(
                memberIDs: ["left", "right"],
                observation: different
            ),
            .knownDifferent(["left": space1, "right": space2])
        )

        let unknown = WindowSpaceObservation(membersByStableIdentity: [
            "left": same.member("left")!,
            "right": .init(
                stableIdentity: "right",
                windowID: nil,
                membership: .unknown
            )
        ])
        XCTAssertEqual(
            GroupSpaceMembershipPolicy.relationship(
                memberIDs: ["left", "right"],
                observation: unknown
            ),
            .unknown
        )
    }

    func testMigrationPreflightRetriesOnlyUnknownPublication() {
        let source = TaboraSpaceID(1)!
        let other = TaboraSpaceID(2)!
        XCTAssertEqual(
            GroupSpaceMigrationPreflightPolicy.disposition(
                relationship: .knownSame(source),
                expectedSourceSpace: source
            ),
            .proceed
        )
        XCTAssertEqual(
            GroupSpaceMigrationPreflightPolicy.disposition(
                relationship: .unknown,
                expectedSourceSpace: source
            ),
            .retry
        )
        XCTAssertEqual(
            GroupSpaceMigrationPreflightPolicy.disposition(
                relationship: .knownSame(other),
                expectedSourceSpace: source
            ),
            .reject
        )
        XCTAssertEqual(
            GroupSpaceMigrationPreflightPolicy.disposition(
                relationship: .knownDifferent([
                    "left": source,
                    "right": other
                ]),
                expectedSourceSpace: source
            ),
            .reject
        )
    }

    func testMigrationPreflightRetryBudgetIsFinite() {
        XCTAssertTrue(
            GroupSpaceMigrationPreflightPolicy.shouldRetry(
                completedRetryCount: 0
            )
        )
        XCTAssertTrue(
            GroupSpaceMigrationPreflightPolicy.shouldRetry(
                completedRetryCount:
                    GroupSpaceMigrationPreflightPolicy
                        .maximumObservationRetryCount - 1
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationPreflightPolicy.shouldRetry(
                completedRetryCount:
                    GroupSpaceMigrationPreflightPolicy
                        .maximumObservationRetryCount
            )
        )
    }

    func testCompletedMigrationAndPreDispatchCancellationWaitForDesktopRearm() {
        XCTAssertTrue(
            GroupSpaceMigrationTerminalPolicy
                .requiresNormalDesktopRearm(.completed)
        )
        XCTAssertFalse(
            GroupSpaceMigrationTerminalPolicy
                .requiresNormalDesktopRearm(.rolledBack)
        )
        XCTAssertTrue(
            GroupSpaceMigrationTerminalPolicy
                .requiresNormalDesktopRearm(.cancelledBeforeStart)
        )
        XCTAssertFalse(
            GroupSpaceMigrationTerminalPolicy
                .requiresNormalDesktopRearm(.cancelledAtSource)
        )
        XCTAssertFalse(
            GroupSpaceMigrationTerminalPolicy
                .requiresNormalDesktopRearm(.dissolvedAtDestination)
        )
        XCTAssertFalse(
            GroupSpaceMigrationTerminalPolicy
                .requiresNormalDesktopRearm(.dissolvedAfterOriginRestore)
        )
        XCTAssertFalse(
            GroupSpaceMigrationTerminalPolicy
                .requiresNormalDesktopRearm(
                    .dissolvedAfterIncompleteRollback
                )
        )
    }

    func testOnlySourceReturnCancellationPreservesQueuedProxy() {
        XCTAssertTrue(
            GroupSpaceMigrationTerminalPolicy
                .preservesQueuedProxy(.cancelledAtSource)
        )
        XCTAssertFalse(
            GroupSpaceMigrationTerminalPolicy
                .preservesQueuedProxy(.cancelledBeforeStart)
        )
        XCTAssertFalse(
            GroupSpaceMigrationTerminalPolicy
                .preservesQueuedProxy(.completed)
        )
    }

    func testQueuedPresentationPreservesOnlyUndispatchedProxy() {
        XCTAssertTrue(
            GroupSpaceMigrationQueuedPresentationPolicy.preservesMovedProxy(
                for: .awaitingNormalDesktopDispatch
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationQueuedPresentationPolicy.preservesMovedProxy(
                for: .dispatchingMove
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationQueuedPresentationPolicy.preservesMovedProxy(
                for: .verifyingMove
            )
        )
    }

    func testMigrationQueueAcceptsDifferentGroupsButRejectsDuplicateCapture() {
        let first = SnapGroupID()
        let second = SnapGroupID()
        XCTAssertFalse(
            GroupSpaceMigrationQueuePolicy.acceptsCapture(
                groupID: first,
                capturedGroupIDs: [first]
            )
        )
        XCTAssertTrue(
            GroupSpaceMigrationQueuePolicy.acceptsCapture(
                groupID: second,
                capturedGroupIDs: [first]
            )
        )
        XCTAssertTrue(
            GroupSpaceMigrationQueuePolicy.acceptsPhysicalMembers(
                memberIDs: ["third", "fourth"],
                windowIDs: [30, 40],
                capturedMemberIDs: ["first", "second"],
                capturedWindowIDs: [10, 20]
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationQueuePolicy.acceptsPhysicalMembers(
                memberIDs: ["second", "third"],
                windowIDs: [20, 30],
                capturedMemberIDs: ["first", "second"],
                capturedWindowIDs: [10, 20]
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationQueuePolicy.acceptsPhysicalMembers(
                memberIDs: ["third", "fourth"],
                windowIDs: [20, 40],
                capturedMemberIDs: ["first", "second"],
                capturedWindowIDs: [10, 20]
            )
        )
    }

    func testActiveSpaceChangeCannotCancelMigrationFrameOwnership() {
        XCTAssertFalse(
            GroupSpaceMigrationFrameOperationOwnershipPolicy
                .ownsFrameOperations(for: .awaitingNormalDesktopDispatch)
        )
        XCTAssertTrue(
            GroupSpaceMigrationFrameOperationOwnershipPolicy
                .ownsFrameOperations(for: .verifyingMove)
        )
        XCTAssertTrue(
            GroupSpaceMigrationFrameOperationOwnershipPolicy
                .ownsFrameOperations(for: .applyingLayout)
        )
        XCTAssertTrue(
            GroupSpaceMigrationFrameOperationOwnershipPolicy
                .ownsFrameOperations(for: .rollingBack)
        )
    }

    func testDispatchPreflightGathersExactMembersFromDifferentUserSpaces() {
        let source = TaboraSpaceID(1)!
        let destination = TaboraSpaceID(2)!
        let observation = WindowSpaceObservation(
            membersByStableIdentity: [
                "left": WindowSpaceMemberObservation(
                    stableIdentity: "left",
                    windowID: 10,
                    membership: .known([source])
                ),
                "right": WindowSpaceMemberObservation(
                    stableIdentity: "right",
                    windowID: 11,
                    membership: .known([destination])
                )
            ]
        )
        XCTAssertEqual(
            GroupSpaceMigrationDispatchMembershipPolicy.disposition(
                expectedWindowIDsByMemberID: ["left": 10, "right": 11],
                observation: observation,
                destinationSpace: destination,
                isUserSpace: { _ in true }
            ),
            .dispatchRequired
        )
    }

    func testDispatchPreflightAvoidsDuplicateMoveAtDestination() {
        let source = TaboraSpaceID(1)!
        let destination = TaboraSpaceID(2)!
        let sourceObservation = WindowSpaceObservation(
            membersByStableIdentity: [
                "left": .init(
                    stableIdentity: "left",
                    windowID: 10,
                    membership: .known([source])
                ),
                "right": .init(
                    stableIdentity: "right",
                    windowID: 11,
                    membership: .known([source])
                )
            ]
        )
        let destinationObservation = WindowSpaceObservation(
            membersByStableIdentity: [
                "left": .init(
                    stableIdentity: "left",
                    windowID: 10,
                    membership: .known([destination])
                ),
                "right": .init(
                    stableIdentity: "right",
                    windowID: 11,
                    membership: .known([destination])
                )
            ]
        )
        XCTAssertEqual(
            GroupSpaceMigrationDispatchMembershipPolicy.disposition(
                expectedWindowIDsByMemberID: ["left": 10, "right": 11],
                observation: sourceObservation,
                destinationSpace: destination,
                isUserSpace: { _ in true }
            ),
            .dispatchRequired
        )
        XCTAssertEqual(
            GroupSpaceMigrationDispatchMembershipPolicy.disposition(
                expectedWindowIDsByMemberID: ["left": 10, "right": 11],
                observation: destinationObservation,
                destinationSpace: destination,
                isUserSpace: { _ in true }
            ),
            .alreadyAtDestination
        )
    }

    func testDispatchPreflightRejectsChangedPhysicalWindowIdentity() {
        let destination = TaboraSpaceID(2)!
        let observation = WindowSpaceObservation(
            membersByStableIdentity: [
                "left": .init(
                    stableIdentity: "left",
                    windowID: 99,
                    membership: .known([TaboraSpaceID(1)!])
                ),
                "right": .init(
                    stableIdentity: "right",
                    windowID: 11,
                    membership: .known([TaboraSpaceID(1)!])
                )
            ]
        )
        XCTAssertEqual(
            GroupSpaceMigrationDispatchMembershipPolicy.disposition(
                expectedWindowIDsByMemberID: ["left": 10, "right": 11],
                observation: observation,
                destinationSpace: destination,
                isUserSpace: { _ in true }
            ),
            .cancelForIdentityMutation
        )
    }

    func testRollbackRestoresEachDispatchedMemberToItsExactOrigin() {
        let source = TaboraSpaceID(1)!
        let alternate = TaboraSpaceID(3)!
        let destination = TaboraSpaceID(4)!
        let batches = GroupSpaceMigrationRollbackPolicy.batches(
            originsByMemberID: [
                "left": source,
                "right": alternate,
                "already-there": destination
            ],
            dispatchedDestination: destination
        )
        XCTAssertEqual(
            batches,
            [
                GroupSpaceMigrationRollbackBatch(
                    destinationSpace: source,
                    memberIDs: ["left"]
                ),
                GroupSpaceMigrationRollbackBatch(
                    destinationSpace: alternate,
                    memberIDs: ["right"]
                )
            ]
        )
        XCTAssertFalse(
            GroupSpaceMigrationRollbackPolicy.canPreserveStructuralGroup(
                originsByMemberID: [
                    "left": source,
                    "right": alternate,
                    "already-there": destination
                ],
                capturedSource: source,
                expectedMemberCount: 3
            )
        )
        XCTAssertTrue(
            GroupSpaceMigrationRollbackPolicy.canPreserveStructuralGroup(
                originsByMemberID: ["left": source, "right": source],
                capturedSource: source,
                expectedMemberCount: 2
            )
        )
    }

    func testDispatchPreflightUnknownRetryBudgetIsFinite() {
        XCTAssertTrue(
            GroupSpaceMigrationDispatchMembershipPolicy.shouldRetryUnknown(
                completedRetryCount: 0
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationDispatchMembershipPolicy.shouldRetryUnknown(
                completedRetryCount:
                    GroupSpaceMigrationDispatchMembershipPolicy
                        .maximumUnknownRetryCount
            )
        )
    }

    func testMoveDispatchWaitsForSettledRepeatedNormalDesktopEvidence() {
        let first = GroupSpaceMigrationDispatchReadinessPolicy.observe(
            previous: nil,
            now: 10
        )
        let tooEarly = GroupSpaceMigrationDispatchReadinessPolicy.observe(
            previous: first.evidence,
            now: 10.08
        )
        let settled = GroupSpaceMigrationDispatchReadinessPolicy.observe(
            previous: tooEarly.evidence,
            now: 10
                + GroupSpaceMigrationDispatchReadinessPolicy
                    .minimumSettleInterval
        )
        XCTAssertFalse(first.isConfirmed)
        XCTAssertFalse(tooEarly.isConfirmed)
        XCTAssertTrue(settled.isConfirmed)
    }

    func testMoveDispatchRequiresMeasuredNormalGeometryOrSpaceSignal() {
        XCTAssertFalse(
            GroupSpaceMigrationDispatchReadinessPolicy
                .acceptsNormalDesktopObservation(
                    migratingGroupIsNormal: false,
                    migratingGroupHasNormalMember: false,
                    activeSpaceChangeWasObserved: false
                )
        )
        XCTAssertTrue(
            GroupSpaceMigrationDispatchReadinessPolicy
                .acceptsNormalDesktopObservation(
                    migratingGroupIsNormal: true,
                    migratingGroupHasNormalMember: true,
                    activeSpaceChangeWasObserved: false
                )
        )
        XCTAssertTrue(
            GroupSpaceMigrationDispatchReadinessPolicy
                .acceptsNormalDesktopObservation(
                    migratingGroupIsNormal: false,
                    migratingGroupHasNormalMember: false,
                    activeSpaceChangeWasObserved: true
            )
        )
        XCTAssertTrue(
            GroupSpaceMigrationDispatchReadinessPolicy
                .acceptsNormalDesktopObservation(
                    migratingGroupIsNormal: false,
                    migratingGroupHasNormalMember: true,
                    activeSpaceChangeWasObserved: false
                )
        )
    }

    func testMigrationInterruptionNeverConfusesDispatchAndCommitBoundaries() {
        XCTAssertEqual(
            GroupSpaceMigrationInterruptionPolicy.disposition(
                for: .awaitingNormalDesktopDispatch
            ),
            .cancelBeforeDispatch
        )
        XCTAssertEqual(
            GroupSpaceMigrationInterruptionPolicy.disposition(
                for: .verifyingMove
            ),
            .rollbackDispatchedMove
        )
        XCTAssertEqual(
            GroupSpaceMigrationInterruptionPolicy.disposition(
                for: .rollingBack
            ),
            .continueRollback
        )
        XCTAssertEqual(
            GroupSpaceMigrationInterruptionPolicy.disposition(
                for: .applyingLayout
            ),
            .dissolveAtDestination
        )
    }

    func testPresentationRearmNeedsSettledRepeatedNormalEvidence() {
        let first = GroupSpacePresentationRearmPolicy.observe(
            previous: nil,
            now: 10
        )
        let tooEarly = GroupSpacePresentationRearmPolicy.observe(
            previous: first.evidence,
            now: 10.08
        )
        let settled = GroupSpacePresentationRearmPolicy.observe(
            previous: tooEarly.evidence,
            now: 10 + GroupSpacePresentationRearmPolicy.minimumSettleInterval
        )
        XCTAssertFalse(first.isConfirmed)
        XCTAssertFalse(tooEarly.isConfirmed)
        XCTAssertTrue(settled.isConfirmed)
    }

    func testDirectSeparationNeedsStableRepeatedEvidence() {
        let spaces = [
            "left": TaboraSpaceID(1)!,
            "right": TaboraSpaceID(2)!
        ]
        let first = DirectGroupSpaceSeparationPolicy.observe(
            previous: nil,
            spacesByMemberID: spaces,
            now: 10
        )
        let confirmed = DirectGroupSpaceSeparationPolicy.observe(
            previous: first.evidence,
            spacesByMemberID: spaces,
            now: 10 + DirectGroupSpaceSeparationPolicy.minimumSettleInterval
        )
        XCTAssertFalse(first.isConfirmed)
        XCTAssertTrue(confirmed.isConfirmed)
    }

    func testLayoutProjectionPreservesConnectedHalfPartition() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let destination = CGRect(x: 100, y: 50, width: 600, height: 400)
        let result = GroupMigrationLayoutPlanner.plan(
            members: [
                .init(
                    stableIdentity: "left",
                    zone: .leftHalf,
                    sourceFrame: CGRect(x: 0, y: 0, width: 500, height: 800),
                    limits: .unknown
                ),
                .init(
                    stableIdentity: "right",
                    zone: .rightHalf,
                    sourceFrame: CGRect(x: 500, y: 0, width: 500, height: 800),
                    limits: .unknown
                )
            ],
            sourceVisibleFrame: source,
            destinationVisibleFrame: destination
        )
        guard case .exact(let frames) = result else {
            XCTFail("Expected exact projected partition")
            return
        }
        XCTAssertEqual(frames["left"], CGRect(x: 100, y: 50, width: 300, height: 400))
        XCTAssertEqual(frames["right"], CGRect(x: 400, y: 50, width: 300, height: 400))
    }

    func testLayoutRejectsConfirmedInfeasibleConstraints() {
        let limits = AppConstraintLimits(
            minWidth: 400,
            minHeight: nil,
            maxWidth: nil,
            maxHeight: nil
        )
        let result = GroupMigrationLayoutPlanner.plan(
            members: [
                .init(
                    stableIdentity: "left",
                    zone: .leftHalf,
                    sourceFrame: CGRect(x: 0, y: 0, width: 500, height: 800),
                    limits: limits
                ),
                .init(
                    stableIdentity: "right",
                    zone: .rightHalf,
                    sourceFrame: CGRect(x: 500, y: 0, width: 500, height: 800),
                    limits: limits
                )
            ],
            sourceVisibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            destinationVisibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        XCTAssertEqual(result, .impossible)
    }

    func testQueuedProxyUsesLatestSettledDestinationOrCancelsAtSource() {
        let source = TaboraSpaceID(10)!
        let firstDestination = TaboraSpaceID(20)!
        let laterDestination = TaboraSpaceID(30)!

        XCTAssertEqual(
            GroupSpaceMigrationQueuedDestinationPolicy.disposition(
                observedSpace: firstDestination,
                sourceSpace: source,
                currentDestinationSpace: firstDestination
            ),
            .unchanged
        )
        XCTAssertEqual(
            GroupSpaceMigrationQueuedDestinationPolicy.disposition(
                observedSpace: source,
                sourceSpace: source,
                currentDestinationSpace: firstDestination
            ),
            .cancelAtSource
        )
        XCTAssertEqual(
            GroupSpaceMigrationQueuedDestinationPolicy.disposition(
                observedSpace: laterDestination,
                sourceSpace: source,
                currentDestinationSpace: firstDestination
            ),
            .retarget
        )
    }

    func testReservationShadowMatchesExactSameApplicationWindowOnly() {
        let groupID = SnapGroupID()
        let reserved = GroupSpaceMigrationReservationShadowIdentity(
            pid: 100,
            windowID: 10
        )
        let sibling = GroupSpaceMigrationReservationShadowIdentity(
            pid: 100,
            windowID: 11
        )
        let items = GroupSpaceMigrationReservationShadowPolicy.visibleItems(
            reservations: [
                GroupSpaceMigrationReservationShadowReservation(
                    groupID: groupID,
                    memberIdentities: [reserved],
                    groupLabel: "グループ 1",
                    queuePosition: 1,
                    queueTotal: 2
                )
            ],
            surfaces: [
                GroupSpaceMigrationReservationShadowSurface(
                    identity: sibling,
                    displayID: 1,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100)
                ),
                GroupSpaceMigrationReservationShadowSurface(
                    identity: reserved,
                    displayID: 1,
                    frame: CGRect(x: 120, y: 0, width: 100, height: 100)
                )
            ]
        )
        XCTAssertEqual(items.map(\.identity), [reserved])
        XCTAssertEqual(items.first?.queuePosition, 1)
        XCTAssertEqual(items.first?.queueTotal, 2)
    }

    func testReservationShadowRejectsDuplicateReservationOwnership() {
        let identity = GroupSpaceMigrationReservationShadowIdentity(
            pid: 100,
            windowID: 10
        )
        let reservations = ["グループ 1", "グループ 2"].map { label in
            GroupSpaceMigrationReservationShadowReservation(
                groupID: SnapGroupID(),
                memberIdentities: [identity],
                groupLabel: label,
                queuePosition: nil,
                queueTotal: nil
            )
        }
        let items = GroupSpaceMigrationReservationShadowPolicy.visibleItems(
            reservations: reservations,
            surfaces: [
                GroupSpaceMigrationReservationShadowSurface(
                    identity: identity,
                    displayID: 1,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100)
                )
            ]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testReservationShadowRejectsDuplicateWindowServerSurface() {
        let identity = GroupSpaceMigrationReservationShadowIdentity(
            pid: 100,
            windowID: 10
        )
        let reservation = GroupSpaceMigrationReservationShadowReservation(
            groupID: SnapGroupID(),
            memberIdentities: [identity],
            groupLabel: "グループ 1",
            queuePosition: nil,
            queueTotal: nil
        )
        let surface = GroupSpaceMigrationReservationShadowSurface(
            identity: identity,
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertTrue(
            GroupSpaceMigrationReservationShadowPolicy.visibleItems(
                reservations: [reservation],
                surfaces: [surface, surface]
            ).isEmpty
        )
    }

    func testReservationShadowUsesCurrentSurfaceWithoutHoldingOldGeometry() {
        let identity = GroupSpaceMigrationReservationShadowIdentity(
            pid: 100,
            windowID: 10
        )
        let reservation = GroupSpaceMigrationReservationShadowReservation(
            groupID: SnapGroupID(),
            memberIdentities: [identity],
            groupLabel: "グループ 1",
            queuePosition: 1,
            queueTotal: 1
        )
        let movedFrame = CGRect(x: 80, y: 40, width: 120, height: 90)
        let moved = GroupSpaceMigrationReservationShadowPolicy.visibleItems(
            reservations: [reservation],
            surfaces: [
                GroupSpaceMigrationReservationShadowSurface(
                    identity: identity,
                    displayID: 1,
                    frame: movedFrame
                )
            ]
        )
        XCTAssertEqual(moved.map(\.frame), [movedFrame])
        XCTAssertTrue(
            GroupSpaceMigrationReservationShadowPolicy.visibleItems(
                reservations: [reservation],
                surfaces: []
            ).isEmpty
        )
    }

    func testReservationShadowUsesDisplayWithLargestIntersection() {
        let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 100, height: 100)),
            (2, CGRect(x: 100, y: 0, width: 100, height: 100))
        ]
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowPolicy.owningDisplayID(
                for: CGRect(x: 80, y: 10, width: 80, height: 80),
                displays: displays
            ),
            2
        )
        XCTAssertNil(
            GroupSpaceMigrationReservationShadowPolicy.owningDisplayID(
                for: CGRect(x: 250, y: 0, width: 40, height: 40),
                displays: displays
            )
        )
    }

    func testReservationShadowPresenterPointerGateOnlySuppressesWhilePointerIsDown() {
        var gate = GroupSpaceMigrationReservationShadowInteractionGate()
        XCTAssertFalse(gate.presentationIsSuppressed)

        gate.pointerBegan()
        XCTAssertTrue(gate.presentationIsSuppressed)
        XCTAssertFalse(gate.observe(buttonIsDown: true))

        gate.pointerEnded()
        XCTAssertFalse(gate.presentationIsSuppressed)
        XCTAssertTrue(gate.observe(buttonIsDown: false))
    }

    func testReservationShadowPointerGateRecoversFromMissedMouseUpWithoutNewMonitor() {
        var gate = GroupSpaceMigrationReservationShadowInteractionGate()
        gate.pointerBegan()

        XCTAssertTrue(gate.observe(buttonIsDown: false))
        XCTAssertFalse(gate.pointerIsDown)
        XCTAssertFalse(gate.presentationIsSuppressed)
    }

    func testReservationShadowGeometrySettleRejectsMovingAnimationFrames() {
        let identity = GroupSpaceMigrationReservationShadowIdentity(
            pid: 120,
            windowID: 44
        )
        var gate = GroupSpaceMigrationReservationShadowGeometrySettleGate()
        XCTAssertFalse(gate.observe(
            frames: [identity: CGRect(x: 10, y: 10, width: 300, height: 200)],
            now: 1.00,
            reason: .pointer
        ))
        XCTAssertFalse(gate.observe(
            frames: [identity: CGRect(x: 25, y: 20, width: 300, height: 200)],
            now: 1.10,
            reason: .pointer
        ))
        XCTAssertFalse(gate.observe(
            frames: [identity: CGRect(x: 40, y: 30, width: 300, height: 200)],
            now: 1.20,
            reason: .pointer
        ))
        XCTAssertFalse(gate.isSettled)
    }

    func testReservationShadowGeometrySettleRequiresThreeStablePointerSamplesAndTime() {
        let identity = GroupSpaceMigrationReservationShadowIdentity(
            pid: 120,
            windowID: 44
        )
        let frame = CGRect(x: 40, y: 30, width: 300, height: 200)
        var gate = GroupSpaceMigrationReservationShadowGeometrySettleGate()
        XCTAssertFalse(gate.observe(
            frames: [identity: frame],
            now: 2.00,
            reason: .pointer
        ))
        XCTAssertFalse(gate.observe(
            frames: [identity: frame],
            now: 2.10,
            reason: .pointer
        ))
        XCTAssertTrue(gate.observe(
            frames: [identity: frame],
            now: 2.20,
            reason: .pointer
        ))
        XCTAssertTrue(gate.isSettled)
    }

    func testReservationShadowInitialReservationSettlesFasterThanPointerRecovery() {
        let identity = GroupSpaceMigrationReservationShadowIdentity(
            pid: 120,
            windowID: 44
        )
        let frame = CGRect(x: 40, y: 30, width: 300, height: 200)
        var gate = GroupSpaceMigrationReservationShadowGeometrySettleGate()
        XCTAssertFalse(gate.observe(
            frames: [identity: frame],
            now: 3.00,
            reason: .reservation
        ))
        XCTAssertTrue(gate.observe(
            frames: [identity: frame],
            now: 3.10,
            reason: .reservation
        ))
    }

    func testReservationShadowSettledProbeDetectsUnexpectedMovement() {
        let identity = GroupSpaceMigrationReservationShadowIdentity(
            pid: 120,
            windowID: 44
        )
        let settled = [identity: CGRect(x: 40, y: 30, width: 300, height: 200)]
        XCTAssertTrue(
            GroupSpaceMigrationReservationShadowGeometrySettleGate
                .probeMatchesSettledGeometry(
                    [identity: CGRect(x: 40.5, y: 30, width: 300, height: 200)],
                    settledFrames: settled
                )
        )
        XCTAssertFalse(
            GroupSpaceMigrationReservationShadowGeometrySettleGate
                .probeMatchesSettledGeometry(
                    [identity: CGRect(x: 45, y: 30, width: 300, height: 200)],
                    settledFrames: settled
                )
        )
    }

    func testReservationShadowProbeClassifiesNormalTransformedAndAmbiguousGeometry() {
        let expected = CGRect(x: 100, y: 100, width: 1000, height: 700)
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowProbePolicy.classify(
                expectedFrame: expected,
                currentFrame: expected
            ),
            .normal
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowProbePolicy.classify(
                expectedFrame: expected,
                currentFrame: CGRect(x: 200, y: 150, width: 600, height: 420)
            ),
            .transformed
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowProbePolicy.classify(
                expectedFrame: expected,
                currentFrame: CGRect(x: 200, y: 150, width: 600, height: 620)
            ),
            .unresolved
        )
    }

    func testReservationShadowTypographyKeepsRealWindowStatusSecondary() {
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowTypographyPolicy
                .statusMaximumPointSize,
            26
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowTypographyPolicy
                .statusHeightScale,
            0.17
        )
    }

    func testReservationShadowObserverUsesSessionScopedTenHertzCadence() {
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObserver.observationInterval,
            0.10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObserver
                .normalSamplesRequiredToEndScene,
            2
        )
    }

    func testReservationShadowObserverSkipsSnapshotProcessingDuringPointerInteraction() {
        XCTAssertTrue(
            GroupSpaceMigrationReservationShadowObserver.shouldProcessSnapshot(
                pointerInteractionIsActive: false
            )
        )
        XCTAssertFalse(
            GroupSpaceMigrationReservationShadowObserver.shouldProcessSnapshot(
                pointerInteractionIsActive: true
            )
        )
    }

    func testReservationShadowObservationGateFailsClosedAndEndsAfterTwoNormalSamples() {
        var gate = GroupSpaceMigrationReservationShadowObservationGate()
        XCTAssertFalse(gate.sceneIsActive)
        XCTAssertEqual(gate.consume(.transformed), .ignore)

        gate.beginScene()
        XCTAssertTrue(gate.sceneIsActive)
        XCTAssertEqual(gate.consume(.transformed), .showCandidate)

        XCTAssertEqual(gate.consume(.unresolved), .hide)
        XCTAssertTrue(gate.sceneIsActive)

        XCTAssertEqual(gate.consume(.normal), .hide)
        XCTAssertTrue(gate.sceneIsActive)
        XCTAssertEqual(gate.consecutiveNormalSamples, 1)

        // A renewed transform cancels normal-desktop exit debt.
        XCTAssertEqual(gate.consume(.transformed), .showCandidate)
        XCTAssertEqual(gate.consecutiveNormalSamples, 0)

        XCTAssertEqual(gate.consume(.normal), .hide)
        XCTAssertEqual(gate.consume(.normal), .hideAndEndScene)
        XCTAssertFalse(gate.sceneIsActive)
        XCTAssertEqual(gate.consecutiveNormalSamples, 0)
    }


    func testReservationShadowObservationUsesFrozenReservationBaseline() {
        let groupID = SnapGroupID()
        let first = GroupSpaceMigrationReservationShadowBaselineMember(
            stableIdentity: "first",
            identity: GroupSpaceMigrationReservationShadowIdentity(
                pid: 120,
                windowID: 44
            ),
            expectedFrame: CGRect(x: 100, y: 100, width: 1000, height: 700)
        )
        let second = GroupSpaceMigrationReservationShadowBaselineMember(
            stableIdentity: "second",
            identity: GroupSpaceMigrationReservationShadowIdentity(
                pid: 121,
                windowID: 45
            ),
            expectedFrame: CGRect(x: 1200, y: 100, width: 800, height: 600)
        )
        let baseline = GroupSpaceMigrationReservationShadowBaseline(
            groupID: groupID,
            members: [second, first]
        )
        XCTAssertEqual(
            baseline.members.map(\.stableIdentity),
            ["first", "second"]
        )
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 44,
                pid: 120,
                frame: CGRect(x: 180, y: 140, width: 600, height: 420),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 45,
                pid: 121,
                frame: CGRect(x: 800, y: 150, width: 480, height: 360),
                zIndex: 1,
                layer: 0
            )
        ]
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObservationPolicy.observe(
                baseline: baseline,
                snapshot: snapshot
            ),
            .transformed
        )
    }

    func testReservationShadowObservationPolicyAggregatesOnlyPresentationTruth() {
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObservationPolicy.aggregate([]),
            .normal
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObservationPolicy.aggregate([
                .normal, .normal
            ]),
            .normal
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObservationPolicy.aggregate([
                .normal, .unavailable
            ]),
            .unresolved
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObservationPolicy.aggregate([
                .unresolvedLive, .normal
            ]),
            .unresolved
        )
        XCTAssertEqual(
            GroupSpaceMigrationReservationShadowObservationPolicy.aggregate([
                .unavailable, .transformed
            ]),
            .transformed
        )
    }


    func testMigrationForegroundIntentSurvivesOnlySuccessfulCompletion() {
        XCTAssertTrue(
            GroupSpaceMigrationForegroundIntentPolicy
                .survivesTerminalState(.completed)
        )
        XCTAssertFalse(
            GroupSpaceMigrationForegroundIntentPolicy
                .survivesTerminalState(.rolledBack)
        )
        XCTAssertFalse(
            GroupSpaceMigrationForegroundIntentPolicy
                .survivesTerminalState(.dissolvedAtDestination)
        )
        XCTAssertFalse(
            GroupSpaceMigrationForegroundIntentPolicy
                .survivesTerminalState(.cancelledAtSource)
        )
    }

    func testMigrationForegroundIntentsRaiseLastExplicitSelectionLast() {
        let firstGroup = SnapGroupID()
        let secondGroup = SnapGroupID()
        let ignoredGroup = SnapGroupID()
        let ordered = GroupSpaceMigrationForegroundIntentPolicy
            .orderedCompletedIntents([
                GroupSpaceMigrationForegroundIntent(
                    groupID: secondGroup,
                    memberIDs: ["b-main", "b-side"],
                    preferredMemberID: "b-main",
                    sequence: 20,
                    migrationCompleted: true
                ),
                GroupSpaceMigrationForegroundIntent(
                    groupID: ignoredGroup,
                    memberIDs: ["c-main", "c-side"],
                    preferredMemberID: "c-main",
                    sequence: 30,
                    migrationCompleted: false
                ),
                GroupSpaceMigrationForegroundIntent(
                    groupID: firstGroup,
                    memberIDs: ["a-main", "a-side"],
                    preferredMemberID: "a-main",
                    sequence: 10,
                    migrationCompleted: true
                )
            ])

        XCTAssertEqual(ordered.map(\.groupID), [firstGroup, secondGroup])
        XCTAssertEqual(ordered.last?.preferredMemberID, "b-main")
    }

    func testReservationShadowLifecycleHintBlocksRetargetOneShotUntilRearmed() {
        XCTAssertFalse(
            GroupSpaceMigrationReservationShadowRearmPolicy
                .allowsRefreshOneShot(lifecycleRearmIsRequired: true)
        )
        XCTAssertTrue(
            GroupSpaceMigrationReservationShadowRearmPolicy
                .allowsRefreshOneShot(lifecycleRearmIsRequired: false)
        )
    }

    func testMigrationForegroundFollowerRaiseOrderPreservesExistingZOrder() {
        XCTAssertEqual(
            GroupSpaceMigrationForegroundIntentPolicy.followerRaiseOrder(
                frontToBackMemberIDs: ["main", "front-follower", "back-follower"],
                preferredMemberID: "main"
            ),
            ["back-follower", "front-follower"]
        )
        XCTAssertEqual(
            GroupSpaceMigrationForegroundIntentPolicy.followerRaiseOrder(
                frontToBackMemberIDs: ["front-follower", "main", "back-follower"],
                preferredMemberID: "main"
            ),
            ["back-follower", "front-follower"]
        )
    }

    func testManagedDisplayTopologyReturnsEveryDisplayForSharedSpace() {
        let shared = TaboraSpaceID(900)!
        let privateSpace = TaboraSpaceID(901)!
        let topology = ManagedDisplaySpaceTopology(displays: [
            .init(
                managedDisplayIdentifier: "DISPLAY-A",
                currentSpaceID: shared,
                spaceIDs: [shared]
            ),
            .init(
                managedDisplayIdentifier: "DISPLAY-B",
                currentSpaceID: shared,
                spaceIDs: [shared, privateSpace]
            )
        ])

        XCTAssertEqual(
            topology.managedDisplayIdentifiers(for: shared),
            Set(["DISPLAY-A", "DISPLAY-B"])
        )
        XCTAssertEqual(
            topology.managedDisplayIdentifiers(for: privateSpace),
            Set(["DISPLAY-B"])
        )
    }

}
