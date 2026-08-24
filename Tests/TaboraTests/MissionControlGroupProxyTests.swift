import CoreGraphics
import XCTest
@testable import Tabora

final class MissionControlGroupProxyTests: XCTestCase {
    func testPeriodicPreviewRefreshHasAConstantWorkBudget() {
        XCTAssertEqual(
            MissionControlPreviewWorkPolicy.periodicRequestCount(
                staleCount: 100,
                outstandingCount: 0
            ),
            2
        )
        XCTAssertEqual(
            MissionControlPreviewWorkPolicy.periodicRequestCount(
                staleCount: 100,
                outstandingCount: 3
            ),
            1
        )
        XCTAssertEqual(
            MissionControlPreviewWorkPolicy.periodicRequestCount(
                staleCount: 100,
                outstandingCount: 4
            ),
            0
        )
        XCTAssertGreaterThan(
            MissionControlPreviewWorkPolicy.coolingFinalCaptureDelay,
            0
        )
        XCTAssertLessThanOrEqual(
            MissionControlPreviewWorkPolicy.coolingFinalCaptureDelay,
            5
        )
    }

    func testPeriodicPreviewRefreshRotatesFairlyAcrossStaleKeys() {
        XCTAssertEqual(
            MissionControlPreviewWorkPolicy.periodicRequestIndices(
                staleCount: 5,
                cursor: 0,
                requestCount: 2
            ),
            [0, 1]
        )
        XCTAssertEqual(
            MissionControlPreviewWorkPolicy.periodicRequestIndices(
                staleCount: 5,
                cursor: 2,
                requestCount: 2
            ),
            [2, 3]
        )
        XCTAssertEqual(
            MissionControlPreviewWorkPolicy.periodicRequestIndices(
                staleCount: 5,
                cursor: 4,
                requestCount: 2
            ),
            [4, 0]
        )
    }

    func testPreviewActivityPreservesPriorStateOnlyWhenEvidenceIsUnknown() {
        let groups = ["group": Set(["left", "right"])]
        XCTAssertEqual(
            MissionControlPreviewActivityPolicy.desiredHotMemberIDs(
                previousHotMemberIDs: ["left"],
                currentMemberIDsByGroupID: groups,
                observedExposedMemberIDsByGroupID: [:]
            ),
            ["left"]
        )
        XCTAssertEqual(
            MissionControlPreviewActivityPolicy.desiredHotMemberIDs(
                previousHotMemberIDs: ["left"],
                currentMemberIDsByGroupID: groups,
                observedExposedMemberIDsByGroupID: ["group": ["right"]]
            ),
            ["right"]
        )
        XCTAssertEqual(
            MissionControlPreviewActivityPolicy.desiredHotMemberIDs(
                previousHotMemberIDs: ["left"],
                currentMemberIDsByGroupID: groups,
                observedExposedMemberIDsByGroupID: ["group": []]
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

    func testPreviewFreshnessKeepsRecentImageAndRefreshesExpiredImage() {
        XCTAssertTrue(
            MissionControlPreviewFreshnessPolicy.needsRefresh(
                capturedAt: nil,
                now: 100
            )
        )
        XCTAssertFalse(
            MissionControlPreviewFreshnessPolicy.needsRefresh(
                capturedAt: 90,
                now: 100
            )
        )
        XCTAssertTrue(
            MissionControlPreviewFreshnessPolicy.needsRefresh(
                capturedAt: 85,
                now: 100
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

}
