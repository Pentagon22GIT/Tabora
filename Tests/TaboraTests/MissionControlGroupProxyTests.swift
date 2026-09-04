import CoreGraphics
import XCTest
@testable import Tabora

final class MissionControlGroupProxyTests: XCTestCase {
    func testMigrationPresentationRemainsQueuedUntilProxyRetirement() {
        let queued = MissionControlGroupProxyMigrationPresentationPolicy
            .presentation(
                queuePosition: 1,
                queueTotal: 2
            )
        XCTAssertEqual(queued.title, L10n.text("migration.proxy.ready"))
        XCTAssertEqual(
            queued.subtitle,
            L10n.format("migration.proxy.subtitle.queued", 1, 2)
        )

        let waiting = MissionControlGroupProxyMigrationPresentationPolicy
            .presentation(queuePosition: 2, queueTotal: 2)
        XCTAssertEqual(waiting.title, L10n.text("migration.proxy.waiting"))
        XCTAssertEqual(
            waiting.subtitle,
            L10n.format("migration.proxy.subtitle.queued", 2, 2)
        )
    }

    func testNormalPreviewProviderAuthorizationCanCrossEscapingCaptureGate() {
        var forwardedAuthorization: (() -> Bool)?
        let provider: MissionControlGroupProxyController.PreviewProvider = {
            _, captureIsAuthorized in
            forwardedAuthorization = captureIsAuthorized
            return nil
        }

        XCTAssertNil(provider(nil, { true }))
        XCTAssertTrue(forwardedAuthorization?() == true)
    }

    func testTransientPreviewProviderAuthorizationCanCrossEscapingCaptureGate() {
        var forwardedAuthorization: (() -> Bool)?
        let provider: MissionControlTransientPreviewCapturer.PreviewProvider = {
            _, _, captureIsAuthorized in
            // This assignment is intentionally part of the regression test.
            // `PreviewProvider` must declare the authorization parameter as
            // escaping because the real provider forwards it into the optional
            // `shouldCapture` gate used after shared capture admission.
            forwardedAuthorization = captureIsAuthorized
            return nil
        }

        XCTAssertNil(provider(nil, .nominal, { true }))
        XCTAssertTrue(forwardedAuthorization?() == true)
    }

    func testPreviewAuthorizationIsRecheckedAfterCaptureAdmission() {
        var authorizationChecks = 0
        let image = AXWindowService().previewCGImage(
            for: 1,
            capacityWait: 0.1,
            shouldCapture: {
                authorizationChecks += 1
                return false
            }
        )
        XCTAssertNil(image)
        XCTAssertEqual(authorizationChecks, 1)
    }

    func testSettledGeometryRefreshUsesBoundedWork() {
        XCTAssertEqual(
            MissionControlPreviewGeometryRefreshPolicy.requestCount(
                dueCount: 100,
                outstandingCount: 0
            ),
            2
        )
        XCTAssertEqual(
            MissionControlPreviewGeometryRefreshPolicy.requestCount(
                dueCount: 100,
                outstandingCount: 3
            ),
            1
        )
        XCTAssertEqual(
            MissionControlPreviewGeometryRefreshPolicy.requestCount(
                dueCount: 100,
                outstandingCount: 4
            ),
            0
        )
    }

    func testTriggerConfirmationRequiresTwoMatchingObservations() {
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.nextStableObservationCount(
                previousCount: nil,
                representsSameCandidate: false
            ), 1
        )
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.nextStableObservationCount(
                previousCount: 1,
                representsSameCandidate: true
            ), 2
        )
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy.isConfirmed(observationCount: 1)
        )
        XCTAssertTrue(
            MissionControlPreviewTriggerPolicy.isConfirmed(observationCount: 2)
        )
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy.isConfirmed(
                observationCount: 4,
                firstObservedAt: 10.0,
                now: 10.05,
                minimumStableInterval: 0.15
            )
        )
        XCTAssertTrue(
            MissionControlPreviewTriggerPolicy.isConfirmed(
                observationCount: 2,
                firstObservedAt: 10.0,
                now: 10.15,
                minimumStableInterval: 0.15
            )
        )
        XCTAssertTrue(
            MissionControlPreviewTriggerPolicy.captureMatchesCurrentGeometry(
                admittedRevision: 7,
                currentRevision: 7
            )
        )
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy.captureMatchesCurrentGeometry(
                admittedRevision: 7,
                currentRevision: 8
            )
        )
        XCTAssertTrue(
            MissionControlPreviewTriggerPolicy.canReuseCapturedPixels(
                representsSamePhysicalWindow: true,
                displayMatches: true,
                pixelSizeMatches: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy.canReuseCapturedPixels(
                representsSamePhysicalWindow: true,
                displayMatches: false,
                pixelSizeMatches: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy.canReuseCapturedPixels(
                representsSamePhysicalWindow: true,
                displayMatches: true,
                pixelSizeMatches: false
            )
        )
    }

    func testGeometryObservationFallbackIgnoresPositionAndExplicitDebt() {
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy.shouldObserveGeometryFallback(
                sizeChanged: false,
                displayChanged: false,
                hasOutstandingCurrentGeometryWork: false
            )
        )
        XCTAssertTrue(
            MissionControlPreviewTriggerPolicy.shouldObserveGeometryFallback(
                sizeChanged: true,
                displayChanged: false,
                hasOutstandingCurrentGeometryWork: false
            )
        )
        XCTAssertTrue(
            MissionControlPreviewTriggerPolicy.shouldObserveGeometryFallback(
                sizeChanged: false,
                displayChanged: true,
                hasOutstandingCurrentGeometryWork: false
            )
        )
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy.shouldObserveGeometryFallback(
                sizeChanged: true,
                displayChanged: false,
                hasOutstandingCurrentGeometryWork: true
            )
        )
    }

    func testCaptureFailureDebtIsRetainedOnlyAcrossPresentabilityLoss() {
        XCTAssertFalse(
            MissionControlPreviewTriggerPolicy
                .shouldRetainDebtAfterCaptureFailure(
                    hasReusableActiveKey: true
                )
        )
        XCTAssertTrue(
            MissionControlPreviewTriggerPolicy
                .shouldRetainDebtAfterCaptureFailure(
                    hasReusableActiveKey: false
                )
        )
    }

    func testPreviewHasOnlyInitialColdAndGeometryTriggers() {
        XCTAssertEqual(
            Set(MissionControlPreviewTriggerReason.allCases),
            Set([.initial, .coldConfirmed, .geometryConfirmed])
        )
    }

    func testResizeSupersedesColdWithoutDuplicatingCaptureReason() {
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.merged(
                .coldConfirmed,
                with: .geometryConfirmed
            ),
            .geometryConfirmed
        )
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.merged(
                .geometryConfirmed,
                with: .coldConfirmed
            ),
            .geometryConfirmed
        )
    }

    func testTriggerCooldownDelaysColdAndGeometryButNotInitialCapture() {
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.cooldownRemaining(
                reason: .coldConfirmed,
                lastCaptureAt: 10,
                now: 10.25
            ),
            0.75,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.cooldownRemaining(
                reason: .initial,
                lastCaptureAt: 10,
                now: 10.25
            ), 0
        )
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.cooldownRemaining(
                reason: .geometryConfirmed,
                lastCaptureAt: 10,
                now: 10.25
            ),
            0.75,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MissionControlPreviewTriggerPolicy.cooldownRemaining(
                reason: .coldConfirmed,
                lastCaptureAt: 10,
                now: 11
            ), 0
        )
    }

    func testPreviewQueueInterleavesDisplaysDeterministically() {
        XCTAssertEqual(
            MissionControlPreviewDisplayFairnessPolicy.interleavedIndices(
                displayIDs: [1, 1, 1, 2, 2, 3]
            ),
            [0, 3, 5, 1, 4, 2]
        )
        XCTAssertEqual(
            MissionControlPreviewDisplayFairnessPolicy.fairFIFOIndices(
                displayIDs: [1, 1, 1, 2, 2, 3],
                enqueueOrders: [60, 10, 50, 20, 40, 30]
            ),
            [1, 3, 5, 2, 4, 0]
        )
    }

    func testPreviewQueueKeepsFIFOOrderWhenManyGroupsShareOneDisplay() {
        XCTAssertEqual(
            MissionControlPreviewDisplayFairnessPolicy.fairFIFOIndices(
                displayIDs: [1, 1, 1, 1, 1, 1],
                enqueueOrders: [6, 1, 5, 2, 4, 3]
            ),
            [1, 3, 5, 4, 2, 0]
        )
        XCTAssertEqual(
            MissionControlPreviewDisplayFairnessPolicy.fairFIFOIndices(
                displayIDs: [1, 2],
                enqueueOrders: [1]
            ),
            []
        )
    }

    func testPreviewAdmissionClosesOneSharedGateDuringDesktopTransform() {
        XCTAssertTrue(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: true,
                captureSuspended: false,
                desktopPresentationIsStable: true,
                byteBudget: 1024,
                outstandingCount: 3,
                queuedOperationCount: 3,
                keyIsActive: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: true,
                captureSuspended: false,
                desktopPresentationIsStable: false,
                byteBudget: 1024,
                outstandingCount: 0,
                queuedOperationCount: 0,
                keyIsActive: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: true,
                captureSuspended: false,
                desktopPresentationIsStable: true,
                byteBudget: 1024,
                outstandingCount: 4,
                queuedOperationCount: 4,
                keyIsActive: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: true,
                captureSuspended: false,
                desktopPresentationIsStable: true,
                byteBudget: 1024,
                outstandingCount: 0,
                queuedOperationCount: 8,
                keyIsActive: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: false,
                captureSuspended: false,
                desktopPresentationIsStable: true,
                byteBudget: 1024,
                outstandingCount: 0,
                queuedOperationCount: 0,
                keyIsActive: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: true,
                captureSuspended: true,
                desktopPresentationIsStable: true,
                byteBudget: 1024,
                outstandingCount: 0,
                queuedOperationCount: 0,
                keyIsActive: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: true,
                captureSuspended: false,
                desktopPresentationIsStable: true,
                byteBudget: 0,
                outstandingCount: 0,
                queuedOperationCount: 0,
                keyIsActive: true
            )
        )
        XCTAssertFalse(
            MissionControlPreviewAdmissionPolicy.allowsCapture(
                previewsEnabled: true,
                captureSuspended: false,
                desktopPresentationIsStable: true,
                byteBudget: 1024,
                outstandingCount: 0,
                queuedOperationCount: 0,
                keyIsActive: false
            )
        )
    }

    func testTransientCaptureAuthorizationIsGroupAtomicAndCurrentOnly() {
        let current: Set<String> = ["primary", "secondary", "third"]
        let evaluations: [String: GroupFrontmostEvaluation] = [
            "primary": .verifiedFrontmost,
            "secondary": .indeterminate,
            "third": .occluded,
            // A retired group must not survive merely because old evidence was HOT.
            "retired": .verifiedFrontmost
        ]
        XCTAssertEqual(
            MissionControlTransientPreviewEligibilityPolicy
                .authorizedHotGroupIDs(
                    currentGroupIDs: current,
                    currentEvaluationByGroupID: evaluations
                ),
            ["primary"]
        )
        XCTAssertEqual(
            MissionControlTransientPreviewEligibilityPolicy
                .authorizedHotGroupIDs(
                    currentGroupIDs: current,
                    currentEvaluationByGroupID: [
                        "primary": .indeterminate,
                        "secondary": .occluded,
                        "third": .indeterminate
                    ]
                ),
            []
        )
    }

    func testSelectedProxyRequiresTheExactPresentedMemberSet() {
        XCTAssertTrue(
            MissionControlProxySelectionStructuralPolicy.matchesPresentedMembers(
                presentedMemberIDs: ["left", "right"],
                currentMemberIDs: ["right", "left"]
            )
        )
        XCTAssertFalse(
            MissionControlProxySelectionStructuralPolicy.matchesPresentedMembers(
                presentedMemberIDs: ["left", "right"],
                currentMemberIDs: ["left", "new-right"]
            )
        )
        XCTAssertFalse(
            MissionControlProxySelectionStructuralPolicy.matchesPresentedMembers(
                presentedMemberIDs: ["left"],
                currentMemberIDs: ["left"]
            )
        )
    }

    func testPendingSelectionFreezesProxyPresentationMutation() {
        XCTAssertTrue(
            MissionControlProxySelectionDeliveryPolicy
                .allowsPresentationMutation(
                    selectionWasDelivered: false,
                    confirmationIsPending: false
                )
        )
        XCTAssertFalse(
            MissionControlProxySelectionDeliveryPolicy
                .allowsPresentationMutation(
                    selectionWasDelivered: false,
                    confirmationIsPending: true
                )
        )
        XCTAssertFalse(
            MissionControlProxySelectionDeliveryPolicy
                .cancelsOnWindowResign(
                    selectionWasDelivered: false,
                    confirmationIsPending: true
                )
        )
        XCTAssertTrue(
            MissionControlProxySelectionDeliveryPolicy
                .cancelsOnWindowResign(
                    selectionWasDelivered: false,
                    confirmationIsPending: false
                )
        )
        XCTAssertFalse(
            MissionControlProxySelectionDeliveryPolicy
                .cancelsOnWindowResign(
                    selectionWasDelivered: true,
                    confirmationIsPending: false
                )
        )
        XCTAssertFalse(
            MissionControlProxySelectionDeliveryPolicy
                .allowsPresentationMutation(
                    selectionWasDelivered: true,
                    confirmationIsPending: false
                )
        )
    }

    func testProxyConfirmationSettlementIsBoundedAndKeepsInitialLatency() {
        XCTAssertEqual(
            MissionControlProxySelectionConfirmationSettlementPolicy
                .delay(forAttempt: 0),
            0.14
        )
        let delays = MissionControlProxySelectionConfirmationSettlementPolicy
            .observationDelays
        XCTAssertFalse(delays.isEmpty)
        XCTAssertNil(
            MissionControlProxySelectionConfirmationSettlementPolicy
                .delay(forAttempt: delays.count)
        )
        XCTAssertLessThan(
            delays.reduce(0, +),
            MissionControlTransitionTokenPolicy.lifetime
        )
    }

    func testActiveSpaceCleanupPreservesOnlyNarrowSelectionOwnership() {
        let confirmationGroup = SnapGroupID()
        let activationGroup = SnapGroupID()

        let migrationOnly = MissionControlActiveSpaceCleanupPolicy.decision(
            confirmationOwnerGroupID: nil,
            activationOwnerGroupID: nil,
            migrationPresentationIsOwned: true
        )
        XCTAssertTrue(migrationOnly.preservedProxyGroupIDs.isEmpty)
        XCTAssertFalse(migrationOnly.preservesProxyActivation)

        let confirmation = MissionControlActiveSpaceCleanupPolicy.decision(
            confirmationOwnerGroupID: confirmationGroup,
            activationOwnerGroupID: nil,
            migrationPresentationIsOwned: true
        )
        XCTAssertEqual(
            confirmation.preservedProxyGroupIDs,
            [confirmationGroup]
        )
        XCTAssertFalse(confirmation.preservesProxyActivation)

        let activation = MissionControlActiveSpaceCleanupPolicy.decision(
            confirmationOwnerGroupID: nil,
            activationOwnerGroupID: activationGroup,
            migrationPresentationIsOwned: false
        )
        XCTAssertEqual(activation.preservedProxyGroupIDs, [activationGroup])
        XCTAssertTrue(activation.preservesProxyActivation)
    }

    func testMissionControlWholeGroupRetryIsBounded() {
        XCTAssertTrue(
            MissionControlProxyActivationRetryPolicy.allowsAnotherPass(
                completedAttempts: 0
            )
        )
        XCTAssertTrue(
            MissionControlProxyActivationRetryPolicy.allowsAnotherPass(
                completedAttempts:
                    MissionControlProxyActivationRetryPolicy.maximumAttempts - 1
            )
        )
        XCTAssertFalse(
            MissionControlProxyActivationRetryPolicy.allowsAnotherPass(
                completedAttempts:
                    MissionControlProxyActivationRetryPolicy.maximumAttempts
            )
        )
    }

    func testVisualHandoffNeverDelaysTheInitialOrderingPass() {
        XCTAssertFalse(
            MissionControlVisualHandoffPolicy.shouldSuppressRepeatedOrdering(
                transformIsObserved: true,
                successfulOrderingPassExists: false,
                completedPassiveObservations: 0
            )
        )
    }

    func testSelectedProxyVisualCoverHasShorterFailSafeThanTokenLifetime() {
        XCTAssertGreaterThan(
            MissionControlSelectedProxyPresentationPolicy
                .maximumVisibleHandoffLifetime,
            0
        )
        XCTAssertLessThan(
            MissionControlSelectedProxyPresentationPolicy
                .maximumVisibleHandoffLifetime,
            MissionControlTransitionTokenPolicy.lifetime
        )
        XCTAssertLessThanOrEqual(
            MissionControlSelectedProxyPresentationPolicy
                .maximumVisibleHandoffLifetime,
            0.50
        )
    }

    func testVisualHandoffSuppressesOnlyBoundedRepeatOrdering() {
        XCTAssertTrue(
            MissionControlVisualHandoffPolicy.shouldSuppressRepeatedOrdering(
                transformIsObserved: true,
                successfulOrderingPassExists: true,
                completedPassiveObservations: 0
            )
        )
        XCTAssertFalse(
            MissionControlVisualHandoffPolicy.shouldSuppressRepeatedOrdering(
                transformIsObserved: false,
                successfulOrderingPassExists: true,
                completedPassiveObservations: 0
            )
        )
        XCTAssertFalse(
            MissionControlVisualHandoffPolicy.shouldSuppressRepeatedOrdering(
                transformIsObserved: true,
                successfulOrderingPassExists: true,
                completedPassiveObservations:
                    MissionControlVisualHandoffPolicy
                        .maximumSuppressedRepeatOrderingObservations
            )
        )
    }

    func testVisualHandoffDefersOnlyFirstUnsettledDesktopVerification() {
        XCTAssertTrue(
            MissionControlVisualHandoffPolicy
                .shouldDeferUnsettledDesktopVerification(
                    transformIsObserved: false,
                    successfulOrderingPassExists: true,
                    orderingIsVerified: false,
                    completedDeferrals: 0
                )
        )
        XCTAssertFalse(
            MissionControlVisualHandoffPolicy
                .shouldDeferUnsettledDesktopVerification(
                    transformIsObserved: true,
                    successfulOrderingPassExists: true,
                    orderingIsVerified: false,
                    completedDeferrals: 0
                )
        )
        XCTAssertFalse(
            MissionControlVisualHandoffPolicy
                .shouldDeferUnsettledDesktopVerification(
                    transformIsObserved: false,
                    successfulOrderingPassExists: false,
                    orderingIsVerified: false,
                    completedDeferrals: 0
                )
        )
        XCTAssertFalse(
            MissionControlVisualHandoffPolicy
                .shouldDeferUnsettledDesktopVerification(
                    transformIsObserved: false,
                    successfulOrderingPassExists: true,
                    orderingIsVerified: false,
                    completedDeferrals:
                        MissionControlVisualHandoffPolicy
                            .maximumUnsettledDesktopVerificationDeferrals
                )
        )
        XCTAssertFalse(
            MissionControlVisualHandoffPolicy
                .shouldDeferUnsettledDesktopVerification(
                    transformIsObserved: false,
                    successfulOrderingPassExists: true,
                    orderingIsVerified: true,
                    completedDeferrals: 0
                )
        )
    }

    func testOnlyLatestExactProxySelectionCandidateCanBeConsumed() {
        let groupA = SnapGroupID()
        let groupB = SnapGroupID()
        let latest = MissionControlProxySelectionCandidate(
            generation: 12,
            groupID: groupB,
            memberIDs: ["b-left", "b-right"]
        )

        XCTAssertFalse(
            MissionControlProxySelectionCandidatePolicy.matches(
                latest,
                generation: 11,
                groupID: groupA,
                memberIDs: ["a-left", "a-right"]
            )
        )
        XCTAssertFalse(
            MissionControlProxySelectionCandidatePolicy.matches(
                latest,
                generation: 12,
                groupID: groupB,
                memberIDs: ["b-left", "stale-right"]
            )
        )
        XCTAssertTrue(
            MissionControlProxySelectionCandidatePolicy.matches(
                latest,
                generation: 12,
                groupID: groupB,
                memberIDs: ["b-right", "b-left"]
            )
        )
    }

    func testSelectedProxyCoverIsNotGenericOrderingRecoveryDebt() {
        XCTAssertTrue(
            MissionControlSelectedProxyPresentationPolicy
                .allowsGenericOrderingRevalidation(
                    selectionWasDelivered: false
                )
        )
        XCTAssertFalse(
            MissionControlSelectedProxyPresentationPolicy
                .allowsGenericOrderingRevalidation(
                    selectionWasDelivered: true
                )
        )
    }

    func testFailedAXRaiseDoesNotAdvanceAutomaticDesktopMemberBarrier() {
        let attempted: Set<String> = ["left"]
        XCTAssertEqual(
            AutomaticGroupRaiseAttemptPolicy.acceptedMemberIDs(
                current: attempted,
                memberID: "right",
                actionAccepted: false
            ),
            attempted
        )
        XCTAssertEqual(
            AutomaticGroupRaiseAttemptPolicy.acceptedMemberIDs(
                current: attempted,
                memberID: "right",
                actionAccepted: true
            ),
            Set(["left", "right"])
        )
    }

    func testTransitionTokenIsGroupScopedGenerationScopedAndExpires() {
        let groupA = SnapGroupID()
        let groupB = SnapGroupID()
        let token = MissionControlTransitionTokenPolicy.make(
            groupID: groupA, presentationGeneration: 7, now: 10
        )
        XCTAssertTrue(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupA, presentationGeneration: 7, now: 11
        ))
        XCTAssertFalse(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupB, presentationGeneration: 7, now: 11
        ))
        XCTAssertFalse(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupA, presentationGeneration: 8, now: 11
        ))
        XCTAssertFalse(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupA, presentationGeneration: 7, now: 13
        ))
    }

    func testProxyMustBeBehindEveryRequiredWindow() {
        let allMemberIDs: Set<CGWindowID> = [10, 11, 20, 21]

        XCTAssertTrue(
            MissionControlProxyOrderingPolicy.isBehindAllRequiredWindows(
                proxyWindowID: 99,
                requiredWindowIDs: allMemberIDs,
                orderedWindowIDs: [10, 11, 20, 21, 99]
            )
        )
        XCTAssertFalse(
            MissionControlProxyOrderingPolicy.isBehindAllRequiredWindows(
                proxyWindowID: 99,
                requiredWindowIDs: allMemberIDs,
                orderedWindowIDs: [10, 11, 99, 20, 21]
            )
        )
    }

    func testOrderingScopeRequiresOwnMembersAndOnlyOverlappingForeignWindows() throws {
        let proxyFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let required = try XCTUnwrap(
            MissionControlProxyOrderingScopePolicy.requiredWindowIDs(
                proxyFrame: proxyFrame,
                surfaces: [
                    MissionControlProxyOrderingSurface(
                        windowID: 10,
                        frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: 11,
                        frame: CGRect(x: 500, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: 20,
                        frame: CGRect(x: 2000, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: false
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: 21,
                        frame: CGRect(x: 900, y: 100, width: 500, height: 500),
                        belongsToTargetGroup: false
                    )
                ]
            )
        )
        XCTAssertEqual(required, Set([10, 11, 21]))
    }

    func testOrderingScopeUsesTheSameOwnMemberRuleForTwoThreeAndFourWayGroups() throws {
        let proxyFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        for memberCount in 2...4 {
            let surfaces = (0..<memberCount).map { index in
                MissionControlProxyOrderingSurface(
                    windowID: CGWindowID(100 + index),
                    frame: CGRect(
                        x: CGFloat(index) * 200,
                        y: 0,
                        width: 200,
                        height: 900
                    ),
                    belongsToTargetGroup: true
                )
            }
            let required = try XCTUnwrap(
                MissionControlProxyOrderingScopePolicy.requiredWindowIDs(
                    proxyFrame: proxyFrame,
                    surfaces: surfaces
                )
            )
            XCTAssertEqual(
                required,
                Set((0..<memberCount).map { CGWindowID(100 + $0) })
            )
        }
    }

    func testOrderingScopeFailsClosedWhenOwnMemberIdentityIsMissing() {
        XCTAssertNil(
            MissionControlProxyOrderingScopePolicy.requiredWindowIDs(
                proxyFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                surfaces: [
                    MissionControlProxyOrderingSurface(
                        windowID: 10,
                        frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: nil,
                        frame: CGRect(x: 500, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    )
                ]
            )
        )
    }

    func testOrderingScopeFailsClosedForUnidentifiedOverlappingForeignWindow() {
        XCTAssertNil(
            MissionControlProxyOrderingScopePolicy.requiredWindowIDs(
                proxyFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                surfaces: [
                    MissionControlProxyOrderingSurface(
                        windowID: 10,
                        frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: 11,
                        frame: CGRect(x: 500, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: nil,
                        frame: CGRect(x: 900, y: 100, width: 300, height: 300),
                        belongsToTargetGroup: false
                    )
                ]
            )
        )
    }

    func testOrderingScopeIgnoresUnidentifiedNonOverlappingForeignWindow() throws {
        let required = try XCTUnwrap(
            MissionControlProxyOrderingScopePolicy.requiredWindowIDs(
                proxyFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                surfaces: [
                    MissionControlProxyOrderingSurface(
                        windowID: 10,
                        frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: 11,
                        frame: CGRect(x: 500, y: 0, width: 500, height: 800),
                        belongsToTargetGroup: true
                    ),
                    MissionControlProxyOrderingSurface(
                        windowID: nil,
                        frame: CGRect(x: 1600, y: 100, width: 300, height: 300),
                        belongsToTargetGroup: false
                    )
                ]
            )
        )
        XCTAssertEqual(required, Set([10, 11]))
    }

    func testMissingWindowServerEvidenceFailsClosed() {
        XCTAssertFalse(
            MissionControlProxyOrderingPolicy.isBehindAllRequiredWindows(
                proxyWindowID: 99,
                requiredWindowIDs: [10, 11, 20, 21],
                orderedWindowIDs: [10, 11, 20, 99]
            )
        )
    }

    func testOrderingRecoveryIsBoundedAndBacksOff() {
        XCTAssertEqual(
            MissionControlProxyOrderingRecoveryPolicy.verificationDelays,
            [0, 0.04, 0.12, 0.28]
        )
        XCTAssertEqual(
            MissionControlProxyOrderingRecoveryPolicy
                .delayAfterFailedAttempt(0),
            0.04
        )
        XCTAssertEqual(
            MissionControlProxyOrderingRecoveryPolicy
                .delayAfterFailedAttempt(2),
            0.28
        )
        XCTAssertNil(
            MissionControlProxyOrderingRecoveryPolicy
                .delayAfterFailedAttempt(3)
        )
    }

    func testGroupPresentationFastRecoveryIsBounded() {
        XCTAssertEqual(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 1
            ),
            0.06
        )
        XCTAssertEqual(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 4
            ),
            0.15
        )
        XCTAssertEqual(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 6
            ),
            0.35
        )
        XCTAssertNil(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 7
            )
        )
    }

    func testPreviewSizingPreservesUsefulResolutionWithinBudget() {
        let eightMiB = 8 * 1024 * 1024
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.targetPixelSize(
                sourceWidth: 1440,
                sourceHeight: 900,
                byteBudget: eightMiB
            ),
            MissionControlPreviewPixelSize(width: 1440, height: 900)
        )
    }

    func testPreviewSizingBoundsLargeWindowsWithoutFixedPixelCap() throws {
        let eightMiB = 8 * 1024 * 1024
        let target = MissionControlPreviewSizingPolicy.targetPixelSize(
            sourceWidth: 3840,
            sourceHeight: 2160,
            byteBudget: eightMiB
        )
        let resolved = try XCTUnwrap(target)
        XCTAssertLessThan(resolved.width, 3840)
        XCTAssertLessThan(resolved.height, 2160)
        XCTAssertLessThanOrEqual(
            resolved.width * resolved.height
                * MissionControlPreviewSizingPolicy.bytesPerPixel,
            eightMiB
        )
        XCTAssertEqual(
            Double(resolved.width) / Double(resolved.height),
            16.0 / 9.0,
            accuracy: 0.01
        )
    }

    func testPreviewBudgetUsesTheSameRuleForTwoThreeFourAndMultipleGroups() {
        let total = 32 * 1024 * 1024
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 2
            ),
            total / 2
        )
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 3
            ),
            total / 3
        )
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 4
            ),
            total / 4
        )
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 8
            ),
            total / 8
        )
        let memberCount = 11
        let divided = MissionControlPreviewSizingPolicy.perImageByteBudget(
            totalByteBudget: total,
            presentableMemberCount: memberCount
        )
        XCTAssertLessThanOrEqual(divided * memberCount, total)
    }

    func testPreviewPaddingOverrunReducesPixelDimensions() throws {
        let reduced = try XCTUnwrap(
            MissionControlPreviewSizingPolicy.reducedPixelSize(
                width: 1000,
                height: 700,
                actualByteCost: 3_000_000,
                byteBudget: 2_000_000
            )
        )
        XCTAssertLessThan(reduced.width, 1000)
        XCTAssertLessThan(reduced.height, 700)
        XCTAssertGreaterThan(reduced.width, 0)
        XCTAssertGreaterThan(reduced.height, 0)
    }

    func testPreviewOnlyUpdateDoesNotRestartOrderingValidation() {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertFalse(
            MissionControlProxyStructuralUpdatePolicy
                .requiresOrderingRestart(
                    lastFrame: frame,
                    newFrame: frame,
                    lastMemberWindowIDs: [10, 11],
                    requiredMemberWindowIDs: [11, 10],
                    presentationIsStableOrValidating: true
                )
        )
        XCTAssertTrue(
            MissionControlProxyStructuralUpdatePolicy
                .requiresOrderingRestart(
                    lastFrame: frame,
                    newFrame: frame.offsetBy(dx: 20, dy: 0),
                    lastMemberWindowIDs: [10, 11],
                    requiredMemberWindowIDs: [10, 11],
                    presentationIsStableOrValidating: true
                )
        )
        XCTAssertTrue(
            MissionControlProxyStructuralUpdatePolicy
                .requiresOrderingRestart(
                    lastFrame: frame,
                    newFrame: frame,
                    lastMemberWindowIDs: [10, 11],
                    requiredMemberWindowIDs: [10, 12],
                    presentationIsStableOrValidating: true
                )
        )
        XCTAssertTrue(
            MissionControlProxyStructuralUpdatePolicy
                .requiresOrderingRestart(
                    lastFrame: frame,
                    newFrame: frame,
                    lastMemberWindowIDs: [10, 11],
                    requiredMemberWindowIDs: nil,
                    presentationIsStableOrValidating: true
                )
        )
        XCTAssertTrue(
            MissionControlProxyStructuralUpdatePolicy
                .requiresOrderingRestart(
                    lastFrame: frame,
                    newFrame: frame,
                    lastMemberWindowIDs: [10, 11],
                    requiredMemberWindowIDs: [10, 11],
                    presentationIsStableOrValidating: false
                )
        )
    }

    func testOrderingObservationDistinguishesUnknownFromConfirmedUnsafeForAllGroupCounts() {
        let requiredSets: [Set<CGWindowID>] = [
            [10, 11],
            [10, 11, 12],
            [10, 11, 12, 13]
        ]
        for required in requiredSets {
            let orderedRequired = required.sorted()
            XCTAssertEqual(
                MissionControlProxyOrderingPolicy.observation(
                    proxyWindowID: 99,
                    requiredWindowIDs: required,
                    orderedWindowIDs: orderedRequired + [99]
                ),
                .verifiedBehind
            )
            var unsafe = orderedRequired
            unsafe.insert(99, at: max(1, unsafe.count - 1))
            XCTAssertEqual(
                MissionControlProxyOrderingPolicy.observation(
                    proxyWindowID: 99,
                    requiredWindowIDs: required,
                    orderedWindowIDs: unsafe
                ),
                .confirmedUnsafe
            )
            XCTAssertEqual(
                MissionControlProxyOrderingPolicy.observation(
                    proxyWindowID: 99,
                    requiredWindowIDs: required,
                    orderedWindowIDs: Array(orderedRequired.dropLast()) + [99]
                ),
                .unresolved
            )
            XCTAssertEqual(
                MissionControlProxyOrderingPolicy.observation(
                    proxyWindowID: 99,
                    requiredWindowIDs: required,
                    orderedWindowIDs: orderedRequired
                ),
                .unresolved
            )
        }
    }

    func testMigrationProxyPreparationTitleUsesStrongerHierarchy() {
        XCTAssertEqual(
            MissionControlGroupProxyMigrationTypographyPolicy
                .titleMaximumPointSize,
            48
        )
        XCTAssertEqual(
            MissionControlGroupProxyMigrationTypographyPolicy
                .titleHeightScale,
            0.25
        )
    }

    func testTransientTransformRequiresStableGeometryNotJustRepeatedObservation() {
        let first = MissionControlTransientTransformFingerprint(
            framesByWindowID: [
                10: CGRect(x: 10, y: 20, width: 300, height: 200),
                11: CGRect(x: 320, y: 20, width: 300, height: 200)
            ]
        )
        let stable = MissionControlTransientTransformFingerprint(
            framesByWindowID: [
                10: CGRect(x: 10.5, y: 20, width: 300, height: 200),
                11: CGRect(x: 320, y: 20.5, width: 300, height: 200)
            ]
        )
        let moving = MissionControlTransientTransformFingerprint(
            framesByWindowID: [
                10: CGRect(x: 18, y: 20, width: 295, height: 198),
                11: CGRect(x: 326, y: 20, width: 295, height: 198)
            ]
        )
        XCTAssertTrue(
            MissionControlTransientTransformStabilityPolicy
                .representsSameSettledGeometry(first, stable)
        )
        XCTAssertFalse(
            MissionControlTransientTransformStabilityPolicy
                .representsSameSettledGeometry(first, moving)
        )
    }

    func testTransientPreviewAcceptsArbitraryMatchingWindowSizes() {
        XCTAssertTrue(
            MissionControlTransientPreviewValidationPolicy
                .aspectRatioIsCompatible(
                    capturedSize: CGSize(width: 1_600, height: 900),
                    expectedSize: CGSize(width: 800, height: 450)
                )
        )
        XCTAssertTrue(
            MissionControlTransientPreviewValidationPolicy
                .aspectRatioIsCompatible(
                    capturedSize: CGSize(width: 354, height: 1_024),
                    expectedSize: CGSize(width: 177, height: 512)
                )
        )
        XCTAssertFalse(
            MissionControlTransientPreviewValidationPolicy
                .aspectRatioIsCompatible(
                    capturedSize: CGSize(width: 1_000, height: 600),
                    expectedSize: CGSize(width: 300, height: 700)
                )
        )
    }

    func testTransientDirectWindowPixelsKeepQualityAndNeverUpscale() throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 100,
                height: 60,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        )
        context.setFillColor(
            red: 0.2,
            green: 0.4,
            blue: 0.8,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        let source = try XCTUnwrap(context.makeImage())
        let member = MissionControlTransientPreviewMemberPlan(
            stableIdentity: "member",
            pid: 100,
            windowID: 10,
            relativeFrame: CGRect(x: 0, y: 0, width: 500, height: 300),
            targetPixelSize: MissionControlPreviewPixelSize(
                width: 200,
                height: 120
            ),
            byteBudget: 1 * 1024 * 1024
        )
        let rendered = try XCTUnwrap(
            MissionControlTransientPreviewCapturer.makePreviewImage(
                from: source,
                member: member
            )
        )
        XCTAssertEqual(rendered.width, 100)
        XCTAssertEqual(rendered.height, 60)
    }

    func testTransientPreviewResizeRejectsCanceledSessionBeforeDerivedWork() throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 200,
                height: 120,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        )
        let source = try XCTUnwrap(context.makeImage())
        let member = MissionControlTransientPreviewMemberPlan(
            stableIdentity: "member",
            pid: 100,
            windowID: 10,
            relativeFrame: CGRect(x: 0, y: 0, width: 500, height: 300),
            targetPixelSize: MissionControlPreviewPixelSize(
                width: 100,
                height: 60
            ),
            byteBudget: 1 * 1024 * 1024
        )
        XCTAssertNil(
            MissionControlTransientPreviewCapturer.makePreviewImage(
                from: source,
                member: member,
                shouldContinue: { false }
            )
        )
    }

    func testTransientPreviewBudgetIsSeparateAndWorkBounded() {
        let normal = 32 * 1024 * 1024
        let transient = MissionControlTransientPreviewPolicy.byteLimit(
            normalPreviewByteLimit: normal
        )
        XCTAssertEqual(transient, normal)
        XCTAssertEqual(
            MissionControlTransientPreviewPolicy.maximumAdmittedMemberCount(
                totalByteBudget: transient
            ),
            24
        )
        XCTAssertEqual(
            MissionControlTransientPreviewPolicy.maximumAdmittedMemberCount(
                totalByteBudget: 1 * 1024 * 1024
            ),
            1
        )
    }

    func testTransientUsesBestResolutionOnlyWhenBudgetedTargetExceedsNominal() {
        func member(targetWidth: Int, targetHeight: Int)
            -> MissionControlTransientPreviewMemberPlan {
            MissionControlTransientPreviewMemberPlan(
                stableIdentity: "member",
                pid: 100,
                windowID: 10,
                relativeFrame: CGRect(
                    x: 0,
                    y: 0,
                    width: 800,
                    height: 500
                ),
                targetPixelSize: MissionControlPreviewPixelSize(
                    width: targetWidth,
                    height: targetHeight
                ),
                byteBudget: 16 * 1024 * 1024
            )
        }
        XCTAssertEqual(
            MissionControlTransientPreviewPolicy.captureResolution(
                for: member(targetWidth: 800, targetHeight: 500)
            ),
            .nominal
        )
        XCTAssertEqual(
            MissionControlTransientPreviewPolicy.captureResolution(
                for: member(targetWidth: 1_600, targetHeight: 1_000)
            ),
            .best
        )
    }

    func testTransientAdmissionNeverSplitsAGroupAndKeepsDisplayFairness() {
        func group(displayID: CGDirectDisplayID, members: Int)
            -> MissionControlTransientPreviewGroupPlan {
            MissionControlTransientPreviewGroupPlan(
                groupID: SnapGroupID(),
                groupRevision: 1,
                displayID: displayID,
                proxyFrame: CGRect(x: 0, y: 0, width: 600, height: 400),
                members: (0..<members).map { index in
                    MissionControlTransientPreviewMemberPlan(
                        stableIdentity: "\(displayID)-\(index)",
                        pid: 100,
                        windowID: CGWindowID(displayID * 100 + UInt32(index)),
                        relativeFrame: CGRect(
                            x: CGFloat(index * 100),
                            y: 0,
                            width: 100,
                            height: 100
                        ),
                        targetPixelSize: MissionControlPreviewPixelSize(
                            width: 100,
                            height: 100
                        ),
                        byteBudget: 1 * 1024 * 1024
                    )
                }
            )
        }
        let plans = [
            group(displayID: 1, members: 2),
            group(displayID: 1, members: 2),
            group(displayID: 2, members: 2)
        ]
        let admitted = MissionControlTransientPreviewPolicy.admittedPlans(
            plans,
            totalByteBudget: 4 * 1024 * 1024
        )
        XCTAssertEqual(admitted.reduce(0) { $0 + $1.members.count }, 4)
        XCTAssertEqual(Set(admitted.map(\.displayID)), Set([1, 2]))
        XCTAssertTrue(admitted.allSatisfy { $0.members.count == 2 })
    }

}
