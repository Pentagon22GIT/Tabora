import CoreGraphics
import XCTest
@testable import Tabora

final class WindowSafetyPolicyTests: XCTestCase {
    func testFrameOperationOwnershipIncludesProcessIdentity() {
        let first = FrameOperationOwnershipPolicy.key(pid: 100, elementHash: "7")
        let same = FrameOperationOwnershipPolicy.key(pid: 100, elementHash: "7")
        let otherProcess = FrameOperationOwnershipPolicy.key(
            pid: 101,
            elementHash: "7"
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherProcess)
    }

    func testPickerPreviewBudgetScalesResolutionInsteadOfDroppingCandidates() {
        let total = PickerPreviewWorkPolicy.totalPreviewByteBudget
        XCTAssertEqual(
            PickerPreviewWorkPolicy.perImageByteBudget(candidateCount: 1),
            total
        )
        XCTAssertEqual(
            PickerPreviewWorkPolicy.perImageByteBudget(candidateCount: 64),
            total / 64
        )
        XCTAssertLessThanOrEqual(
            PickerPreviewWorkPolicy.perImageByteBudget(candidateCount: 64)
                * 64,
            total
        )
        XCTAssertEqual(
            PickerPreviewWorkPolicy.perImageByteBudget(candidateCount: 0),
            0
        )
        XCTAssertEqual(
            PickerPreviewWorkPolicy.maximumCaptureAttempts,
            3
        )
        XCTAssertNotNil(
            PickerPreviewWorkPolicy.retryDelay(afterFailedAttempt: 0)
        )
        XCTAssertNotNil(
            PickerPreviewWorkPolicy.retryDelay(afterFailedAttempt: 1)
        )
        XCTAssertNil(
            PickerPreviewWorkPolicy.retryDelay(afterFailedAttempt: 2)
        )
    }

    func testPreviewCaptureCapacityWaitIsBoundedAndNeverBlocksMainThread() {
        XCTAssertGreaterThan(
            PreviewCaptureAdmissionPolicy.assistCapacityWait,
            0
        )
        XCTAssertLessThanOrEqual(
            PreviewCaptureAdmissionPolicy.assistCapacityWait,
            0.45
        )
        XCTAssertEqual(
            PreviewCaptureAdmissionPolicy.missionControlCapacityWait,
            PreviewCaptureAdmissionPolicy.assistCapacityWait
        )
        XCTAssertEqual(
            PreviewCaptureAdmissionPolicy.effectiveWait(
                requested: PreviewCaptureAdmissionPolicy.assistCapacityWait,
                isMainThread: true
            ),
            0
        )
        XCTAssertEqual(
            PreviewCaptureAdmissionPolicy.effectiveWait(
                requested: .infinity,
                isMainThread: false
            ),
            0
        )
        XCTAssertEqual(
            PreviewCaptureAdmissionPolicy.effectiveWait(
                requested: 5,
                isMainThread: false
            ),
            PreviewCaptureAdmissionPolicy.maximumCapacityWait
        )
    }

    func testRecoveryCannotCancelAssistWhileSnapOwnsPlacementTransaction() {
        XCTAssertFalse(
            PointerInteractionOwnershipPolicy.recoveryMayCancelAssist(
                assistSessionActive: true,
                pickerVisible: false,
                assistPlacementPending: false,
                snapPlacementInProgress: true
            )
        )
        XCTAssertTrue(
            PointerInteractionOwnershipPolicy.recoveryMayCancelAssist(
                assistSessionActive: true,
                pickerVisible: false,
                assistPlacementPending: false,
                snapPlacementInProgress: false
            )
        )
        XCTAssertFalse(
            PointerInteractionOwnershipPolicy.recoveryMayCancelAssist(
                assistSessionActive: true,
                pickerVisible: true,
                assistPlacementPending: false,
                snapPlacementInProgress: false
            )
        )
    }

    func testGroupForegroundPassiveRetryIsPointerOnlyAndBounded() {
        XCTAssertTrue(
            GroupForegroundPointerObservationPolicy.shouldRetry(
                isPointerOrigin: true,
                completedObservationAttempts: 0,
                maximumObservationAttempts: 2
            )
        )
        XCTAssertTrue(
            GroupForegroundPointerObservationPolicy.shouldRetry(
                isPointerOrigin: true,
                completedObservationAttempts: 1,
                maximumObservationAttempts: 2
            )
        )
        XCTAssertFalse(
            GroupForegroundPointerObservationPolicy.shouldRetry(
                isPointerOrigin: true,
                completedObservationAttempts: 2,
                maximumObservationAttempts: 2
            )
        )
        XCTAssertFalse(
            GroupForegroundPointerObservationPolicy.shouldRetry(
                isPointerOrigin: false,
                completedObservationAttempts: 0,
                maximumObservationAttempts: 2
            )
        )
    }

    func testMoveResizeCapabilityPreservesUnknownSeparatelyFromUnavailable() {
        XCTAssertEqual(
            WindowInteractionCapabilityObservation.combining(
                .available, .available
            ),
            .available
        )
        XCTAssertEqual(
            WindowInteractionCapabilityObservation.combining(
                .available, .unknown
            ),
            .unknown
        )
        XCTAssertEqual(
            WindowInteractionCapabilityObservation.combining(
                .unknown, .unavailable
            ),
            .unavailable
        )
    }

    func testSnapOrAssistOwnsMissionControlPresentationWithoutBackgroundRefresh() {
        XCTAssertTrue(PresentationTransactionOwnershipPolicy
            .preservesMissionControlPresentation(
                snapPlacementInProgress: true,
                assistSessionActive: false,
                assistPlacementPending: false
            ))
        XCTAssertTrue(PresentationTransactionOwnershipPolicy
            .preservesMissionControlPresentation(
                snapPlacementInProgress: false,
                assistSessionActive: true,
                assistPlacementPending: false
            ))
        XCTAssertTrue(PresentationTransactionOwnershipPolicy
            .preservesMissionControlPresentation(
                snapPlacementInProgress: false,
                assistSessionActive: false,
                assistPlacementPending: true
            ))
        XCTAssertFalse(PresentationTransactionOwnershipPolicy
            .preservesMissionControlPresentation(
                snapPlacementInProgress: false,
                assistSessionActive: false,
                assistPlacementPending: false
            ))
    }

    func testMissionControlSelectionOwnsResizeHandlePresentationUntilCompletion() {
        XCTAssertTrue(
            ResizeHandlePresentationOwnershipPolicy
                .missionControlSelectionOwnsPresentation(
                    activationIsActive: true
                )
        )
        XCTAssertFalse(
            ResizeHandlePresentationOwnershipPolicy
                .missionControlSelectionOwnsPresentation(
                    activationIsActive: false
                )
        )
    }

    func testPreviewOnlyRecoveryDoesNotRequestFullPresentationRefresh() {
        XCTAssertEqual(
            RecoveryPresentationRefreshPolicy.action(
                hasPresentationRecoveryDebt: false,
                hasPreviewCacheDebt: true
            ),
            .missionControlPreviewOnly
        )
        XCTAssertEqual(
            RecoveryPresentationRefreshPolicy.action(
                hasPresentationRecoveryDebt: true,
                hasPreviewCacheDebt: true
            ),
            .fullPresentationRefresh
        )
        XCTAssertEqual(
            RecoveryPresentationRefreshPolicy.action(
                hasPresentationRecoveryDebt: false,
                hasPreviewCacheDebt: false
            ),
            .none
        )
    }

    func testExclusiveApplicationTransactionsSuppressInteractionIndependently() {
        XCTAssertTrue(ApplicationInteractionSuppressionPolicy.isSuppressed(
            applicationUIVisible: false,
            constraintMeasurementActive: true,
            constraintPermissionPromptActive: false,
            restoreTransactionActive: false
        ))
        XCTAssertTrue(ApplicationInteractionSuppressionPolicy.isSuppressed(
            applicationUIVisible: false,
            constraintMeasurementActive: false,
            constraintPermissionPromptActive: true,
            restoreTransactionActive: false
        ))
        XCTAssertTrue(ApplicationInteractionSuppressionPolicy.isSuppressed(
            applicationUIVisible: false,
            constraintMeasurementActive: false,
            constraintPermissionPromptActive: false,
            restoreTransactionActive: true
        ))
        XCTAssertTrue(ApplicationInteractionSuppressionPolicy.isSuppressed(
            applicationUIVisible: true,
            constraintMeasurementActive: false,
            constraintPermissionPromptActive: false,
            restoreTransactionActive: false
        ))
        XCTAssertFalse(ApplicationInteractionSuppressionPolicy.isSuppressed(
            applicationUIVisible: false,
            constraintMeasurementActive: false,
            constraintPermissionPromptActive: false,
            restoreTransactionActive: false
        ))
    }

    func testOnlyConfirmedMissingAuthorizesStructuralDestruction() {
        XCTAssertTrue(WindowStructuralPolicy.isConfirmedMissing(.missing))
        XCTAssertFalse(WindowStructuralPolicy.isConfirmedMissing(.unknown))
        XCTAssertFalse(WindowStructuralPolicy.isConfirmedMissing(.alive))
    }

    func testSettledAcceptedFrameCanCommitAfterProceduralTimeout() {
        let observation = AXFrameMutationObservation(
            requestedFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            acceptedFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            mutationWasSent: true,
            sizeMutationSucceeded: false,
            acceptedFrameIsSettled: true,
            liveness: .unknown,
            completedSuccessfully: false,
            settlementEvidence: .exactTarget
        )
        XCTAssertTrue(AXFrameMutationCommitPolicy.accepts(
            observation,
            requiredOuterEdgesMatch: true
        ))
    }

    func testUnsettledOrMissingFrameNeverCommits() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let unsettled = AXFrameMutationObservation(
            requestedFrame: frame, acceptedFrame: frame,
            mutationWasSent: true, sizeMutationSucceeded: false,
            acceptedFrameIsSettled: false, liveness: .unknown,
            completedSuccessfully: false, settlementEvidence: .unresolved
        )
        let missing = AXFrameMutationObservation(
            requestedFrame: frame, acceptedFrame: frame,
            mutationWasSent: true, sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true, liveness: .missing,
            completedSuccessfully: true, settlementEvidence: .exactTarget
        )
        XCTAssertFalse(AXFrameMutationCommitPolicy.accepts(
            unsettled, requiredOuterEdgesMatch: true
        ))
        XCTAssertFalse(AXFrameMutationCommitPolicy.accepts(
            missing, requiredOuterEdgesMatch: true
        ))
        XCTAssertFalse(AXFrameMutationCommitPolicy.accepts(
            unsettled, requiredOuterEdgesMatch: false
        ))
        let settledButAliveFailure = AXFrameMutationObservation(
            requestedFrame: frame, acceptedFrame: frame,
            mutationWasSent: true, sizeMutationSucceeded: false,
            acceptedFrameIsSettled: true, liveness: .alive,
            completedSuccessfully: false, settlementEvidence: .boundedAlternative
        )
        XCTAssertFalse(AXFrameMutationCommitPolicy.accepts(
            settledButAliveFailure, requiredOuterEdgesMatch: true
        ))
    }

    func testIdentityCensusPreservesCompletenessSeparatelyFromContents() {
        XCTAssertEqual(
            WindowIdentityCensus(identities: [], completeness: .complete),
            WindowIdentityCensus(identities: [], completeness: .complete)
        )
        XCTAssertNotEqual(
            WindowIdentityCensus(identities: [], completeness: .complete),
            .unknown
        )
    }

    func testPointerEvidenceCapturesOnlyTheFrontmostLayerZeroSurface() {
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 20, pid: 200,
                frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                zIndex: 0, layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10, pid: 100,
                frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                zIndex: 1, layer: 0
            )
        ]
        let evidence = PointerDragSurfaceEvidencePolicy.capture(
            at: CGPoint(x: 100, y: 100), snapshot: snapshot, now: 10
        )
        XCTAssertEqual(evidence?.selection.windowID, 20)
        XCTAssertEqual(evidence?.selection.pid, 200)
    }

    func testPointerEvidenceUsesQuartzEventHandlerBehindNonInteractiveSurface() {
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 99, pid: 999,
                frame: CGRect(x: 90, y: 90, width: 28, height: 40),
                zIndex: 0, layer: 2_147_483_630
            ),
            WindowOcclusionSnapshot(
                windowID: 20, pid: 200,
                frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                zIndex: 1, layer: 0
            )
        ]
        let evidence = PointerDragSurfaceEvidencePolicy.capture(
            at: CGPoint(x: 100, y: 100),
            snapshot: snapshot,
            eventHandlerWindowID: 20,
            now: 10
        )
        XCTAssertEqual(evidence?.selection.windowID, 20)
        XCTAssertEqual(evidence?.selection.pid, 200)
    }

    func testPointerEvidenceRejectsStaleOrNonPhysicalQuartzHandler() {
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 99, pid: 999,
                frame: CGRect(x: 90, y: 90, width: 28, height: 40),
                zIndex: 0, layer: 2_147_483_630
            ),
            WindowOcclusionSnapshot(
                windowID: 20, pid: 200,
                frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                zIndex: 1, layer: 0
            )
        ]
        XCTAssertNil(PointerDragSurfaceEvidencePolicy.capture(
            at: CGPoint(x: 100, y: 100),
            snapshot: snapshot,
            eventHandlerWindowID: 777,
            now: 10
        ))
        XCTAssertNil(PointerDragSurfaceEvidencePolicy.capture(
            at: CGPoint(x: 100, y: 100),
            snapshot: snapshot,
            eventHandlerWindowID: 99,
            now: 10
        ))
    }

    func testPointerEvidenceDoesNotSkipPopupToReachWindowBehindIt() {
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 99, pid: 200,
                frame: CGRect(x: 50, y: 50, width: 200, height: 200),
                zIndex: 0, layer: 8
            ),
            WindowOcclusionSnapshot(
                windowID: 10, pid: 100,
                frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                zIndex: 1, layer: 0
            )
        ]
        XCTAssertNil(PointerDragSurfaceEvidencePolicy.capture(
            at: CGPoint(x: 100, y: 100), snapshot: snapshot, now: 10
        ))
    }

    func testPersistedWindowBindingResolvesOverlappingSameApplicationWindows() {
        let bindings = [
            PersistedWindowBinding(
                stableIdentity: "finder-group-a",
                pid: 100,
                windowID: 10
            ),
            PersistedWindowBinding(
                stableIdentity: "finder-group-b",
                pid: 100,
                windowID: 20
            )
        ]

        XCTAssertEqual(
            PersistedWindowBindingPolicy.resolve(
                pid: 100,
                windowID: 20,
                bindings: bindings
            ),
            .matched(stableIdentity: "finder-group-b")
        )
    }

    func testPersistedWindowBindingRejectsConflictingClaims() {
        XCTAssertEqual(
            PersistedWindowBindingPolicy.resolve(
                pid: 100,
                windowID: 20,
                bindings: [
                    PersistedWindowBinding(
                        stableIdentity: "chrome-group-a",
                        pid: 100,
                        windowID: 20
                    ),
                    PersistedWindowBinding(
                        stableIdentity: "chrome-group-b",
                        pid: 100,
                        windowID: 20
                    )
                ]
            ),
            .conflicting
        )
    }

    func testPersistedWindowBindingIsScopedByProcess() {
        XCTAssertEqual(
            PersistedWindowBindingPolicy.resolve(
                pid: 200,
                windowID: 20,
                bindings: [
                    PersistedWindowBinding(
                        stableIdentity: "other-application",
                        pid: 100,
                        windowID: 20
                    )
                ]
            ),
            .unavailable
        )
    }

    func testSystemSettingsIsAlwaysExcludedFromSnapping() {
        XCTAssertFalse(WindowSnapEligibilityPolicy.isEligible(
            bundleIdentifier: "com.apple.systempreferences"
        ))
        XCTAssertFalse(WindowSnapEligibilityPolicy.isEligible(
            bundleIdentifier: "com.apple.SystemSettings"
        ))
        XCTAssertTrue(WindowSnapEligibilityPolicy.isEligible(
            bundleIdentifier: "com.google.Chrome"
        ))
        XCTAssertTrue(WindowSnapEligibilityPolicy.isEligible(
            bundleIdentifier: nil
        ))
    }

    func testPointerDragUsesTheFrontmostDraggableSurfaceNotStaleFocus() {
        let surfaces = [
            SplitHitTestSurface(
                windowID: 20,
                frame: CGRect(x: 0, y: 0, width: 500, height: 500)
            ),
            SplitHitTestSurface(
                windowID: 10,
                frame: CGRect(x: 0, y: 0, width: 500, height: 500)
            )
        ]
        XCTAssertEqual(
            PointerDragAcquisitionPolicy.draggableWindowID(
                at: CGPoint(x: 100, y: 100),
                orderedSurfaces: surfaces,
                draggableWindowIDs: [10, 20]
            ),
            20
        )
    }

    func testPointerDragDoesNotSkipAPopupToReachAWindowBehindIt() {
        let surfaces = [
            SplitHitTestSurface(
                windowID: 99,
                frame: CGRect(x: 50, y: 50, width: 200, height: 200)
            ),
            SplitHitTestSurface(
                windowID: 10,
                frame: CGRect(x: 0, y: 0, width: 500, height: 500)
            )
        ]
        XCTAssertNil(
            PointerDragAcquisitionPolicy.draggableWindowID(
                at: CGPoint(x: 100, y: 100),
                orderedSurfaces: surfaces,
                draggableWindowIDs: [10]
            )
        )
    }

    func testDetachedWindowSurfaceCanMigrateFromStaleRoutedContainerToNewVisualSurface() {
        let point = CGPoint(x: 100, y: 100)
        let routed = PointerDragSurfaceEvidence(
            selection: WindowServerSelectionSnapshot(pid: 100, windowID: 10),
            frame: CGRect(x: 0, y: 0, width: 500, height: 500),
            mouseDownPoint: point,
            acquiredAt: 1
        )
        let detached = PointerDragSurfaceEvidence(
            selection: WindowServerSelectionSnapshot(pid: 100, windowID: 30),
            frame: CGRect(x: 50, y: 50, width: 400, height: 400),
            mouseDownPoint: point,
            acquiredAt: 2
        )
        XCTAssertEqual(
            DetachedWindowSurfaceSelectionPolicy.candidateEvidence(
                routed: routed,
                visualFallback: detached,
                sourcePID: 100,
                windowServerIDsAtDragStart: [10, 20],
                eventHandlerWasReported: true
            )?.selection.windowID,
            30
        )
    }

    func testDetachedWindowSurfaceDoesNotUseVisualFallbackWithoutRoutedMismatch() {
        let point = CGPoint(x: 100, y: 100)
        let visual = PointerDragSurfaceEvidence(
            selection: WindowServerSelectionSnapshot(pid: 100, windowID: 30),
            frame: CGRect(x: 50, y: 50, width: 400, height: 400),
            mouseDownPoint: point,
            acquiredAt: 2
        )
        XCTAssertNil(DetachedWindowSurfaceSelectionPolicy.candidateEvidence(
            routed: nil,
            visualFallback: visual,
            sourcePID: 100,
            windowServerIDsAtDragStart: [10, 20],
            eventHandlerWasReported: false
        ))
    }

    func testDetachedWindowCanReplaceTheOriginalDragIdentity() {
        XCTAssertTrue(DetachedWindowAdoptionPolicy.canAdopt(
            candidatePID: 100,
            sourcePID: 100,
            candidateIdentity: "detached-tab",
            sourceIdentity: "chrome-container",
            currentDragIdentity: nil,
            candidateWindowID: 30,
            windowServerIDsAtDragStart: [10, 20],
            dragStartCensusCompleteness: .complete,
            moveAndResizeCapability: .available,
            followsPointer: true
        ))
    }

    func testDetachedWindowRejectsPreexistingOrUnrelatedSurfaces() {
        XCTAssertFalse(DetachedWindowAdoptionPolicy.canAdopt(
            candidatePID: 100,
            sourcePID: 100,
            candidateIdentity: "older-window",
            sourceIdentity: "chrome-container",
            currentDragIdentity: nil,
            candidateWindowID: 20,
            windowServerIDsAtDragStart: [10, 20],
            dragStartCensusCompleteness: .complete,
            moveAndResizeCapability: .available,
            followsPointer: true
        ))
        XCTAssertFalse(DetachedWindowAdoptionPolicy.canAdopt(
            candidatePID: 200,
            sourcePID: 100,
            candidateIdentity: "foreign-popup",
            sourceIdentity: "chrome-container",
            currentDragIdentity: nil,
            candidateWindowID: 30,
            windowServerIDsAtDragStart: [10],
            dragStartCensusCompleteness: .complete,
            moveAndResizeCapability: .available,
            followsPointer: true
        ))
    }

    func testDetachedWindowRejectsIncompleteDragStartCensus() {
        XCTAssertFalse(DetachedWindowAdoptionPolicy.canAdopt(
            candidatePID: 100,
            sourcePID: 100,
            candidateIdentity: "detached-tab",
            sourceIdentity: "chrome-container",
            currentDragIdentity: nil,
            candidateWindowID: 30,
            windowServerIDsAtDragStart: [],
            dragStartCensusCompleteness: .unknown,
            moveAndResizeCapability: .available,
            followsPointer: true
        ))
    }

    func testDetachedWindowDoesNotCollapseUnknownCapabilityIntoUnavailable() {
        XCTAssertTrue(DetachedWindowAdoptionPolicy.canAdopt(
            candidatePID: 100,
            sourcePID: 100,
            candidateIdentity: "detached-tab",
            sourceIdentity: "chrome-container",
            currentDragIdentity: nil,
            candidateWindowID: 30,
            windowServerIDsAtDragStart: [10, 20],
            dragStartCensusCompleteness: .complete,
            moveAndResizeCapability: .unknown,
            followsPointer: true
        ))
    }

    func testDetachedWindowRejectsConfirmedUnavailableCapability() {
        XCTAssertFalse(DetachedWindowAdoptionPolicy.canAdopt(
            candidatePID: 100,
            sourcePID: 100,
            candidateIdentity: "detached-tab",
            sourceIdentity: "chrome-container",
            currentDragIdentity: nil,
            candidateWindowID: 30,
            windowServerIDsAtDragStart: [10, 20],
            dragStartCensusCompleteness: .complete,
            moveAndResizeCapability: .unavailable,
            followsPointer: true
        ))
    }

    func testStagedGroupContinuesWhenDraggedHalfBecomesAdjacentQuarter() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertTrue(StagedGroupContinuationPolicy.canContinue(
            draggedIdentity: "left",
            memberIDs: ["left", "right"],
            zonesByMemberID: [
                "left": .leftHalf,
                "right": .rightHalf
            ],
            incomingZone: .topLeft,
            visibleFrame: screen
        ))
        XCTAssertTrue(StagedGroupContinuationPolicy.canContinue(
            draggedIdentity: "right",
            memberIDs: ["left", "right"],
            zonesByMemberID: [
                "left": .leftHalf,
                "right": .rightHalf
            ],
            incomingZone: .topRight,
            visibleFrame: screen
        ))
    }

    func testStagedGroupDoesNotForceContinuationForDisconnectedDrop() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertFalse(StagedGroupContinuationPolicy.canContinue(
            draggedIdentity: "left",
            memberIDs: ["left", "right"],
            zonesByMemberID: [
                "left": .leftHalf,
                "right": .rightHalf
            ],
            incomingZone: .topRight,
            visibleFrame: screen
        ))
    }

    func testWindowMatchRejectsEqualBestCandidates() {
        XCTAssertNil(WindowMatchingPolicy.uniqueBestCandidate(in: [
            WindowMatchScore(candidateIndex: 0, score: 100),
            WindowMatchScore(candidateIndex: 1, score: 100)
        ]))
    }

    func testWindowMatchRequiresASeparatedWinner() {
        XCTAssertNil(WindowMatchingPolicy.uniqueBestCandidate(in: [
            WindowMatchScore(candidateIndex: 0, score: 100),
            WindowMatchScore(candidateIndex: 1, score: 99)
        ]))
        XCTAssertEqual(WindowMatchingPolicy.uniqueBestCandidate(in: [
            WindowMatchScore(candidateIndex: 0, score: 100),
            WindowMatchScore(candidateIndex: 1, score: 98)
        ]), 0)
    }

    func testWindowMatchesMustBeUniqueInBothDirections() {
        let matches = WindowMatchingPolicy.mutualUniqueMatches(scores: [
            [100, 10],
            [20, 90]
        ])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].axIndex, 0)
        XCTAssertEqual(matches[0].cgIndex, 0)
        XCTAssertEqual(matches[1].axIndex, 1)
        XCTAssertEqual(matches[1].cgIndex, 1)
    }

    func testAmbiguousReverseWindowMatchIsRejected() {
        let matches = WindowMatchingPolicy.mutualUniqueMatches(scores: [
            [100],
            [100]
        ])
        XCTAssertTrue(matches.isEmpty)
    }

    func testForegroundSafetyRequiresExactInitialSelection() {
        let selection = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        XCTAssertTrue(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "selected",
                selectedWindowID: 42,
                allowedWindowServerSelections: [selection],
                allowedAccessibilitySelections: [
                    FocusedWindowIdentity(pid: 100, stableIdentity: "selected")
                ],
                windowServerSelection: selection,
                focusedWindowServerSelection: selection,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "selected",
                    mainIdentity: "selected"
                )
            )
        ))
    }

    func testForegroundSafetyRejectsModalOrSheetSurface() {
        let selection = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        XCTAssertFalse(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "selected",
                selectedWindowID: 42,
                allowedWindowServerSelections: [selection],
                allowedAccessibilitySelections: [
                    FocusedWindowIdentity(pid: 100, stableIdentity: "selected")
                ],
                windowServerSelection: selection,
                focusedWindowServerSelection: selection,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "selected",
                    mainIdentity: "selected",
                    hasBlockingModalSurface: true
                )
            )
        ))
    }

    func testForegroundSafetyAllowsExactPreviouslyRaisedParticipantAcrossApps() {
        let main = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        let follower = WindowServerSelectionSnapshot(pid: 200, windowID: 84)
        XCTAssertTrue(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "main",
                selectedWindowID: 42,
                allowedWindowServerSelections: [main, follower],
                allowedAccessibilitySelections: [
                    FocusedWindowIdentity(pid: 100, stableIdentity: "main"),
                    FocusedWindowIdentity(pid: 200, stableIdentity: "follower")
                ],
                windowServerSelection: follower,
                focusedWindowServerSelection: follower,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 200,
                    focusedIdentity: "follower",
                    mainIdentity: "follower"
                )
            )
        ))
    }

    func testForegroundSafetyAllowsDistinctAXSurfacesOnlyWhenBothAreGroupMembers() {
        let main = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        let follower = WindowServerSelectionSnapshot(pid: 100, windowID: 84)
        XCTAssertTrue(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "main",
                selectedWindowID: 42,
                allowedWindowServerSelections: [main, follower],
                allowedAccessibilitySelections: [
                    FocusedWindowIdentity(pid: 100, stableIdentity: "main"),
                    FocusedWindowIdentity(pid: 100, stableIdentity: "follower")
                ],
                windowServerSelection: follower,
                focusedWindowServerSelection: follower,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "follower",
                    mainIdentity: "main"
                )
            )
        ))
    }

    func testForegroundSafetyRejectsUnownedFocusedSurface() {
        let main = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        let dialog = WindowServerSelectionSnapshot(pid: 100, windowID: 99)
        XCTAssertFalse(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "main",
                selectedWindowID: 42,
                allowedWindowServerSelections: [main],
                allowedAccessibilitySelections: [
                    FocusedWindowIdentity(pid: 100, stableIdentity: "main")
                ],
                windowServerSelection: main,
                focusedWindowServerSelection: dialog,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "dialog",
                    mainIdentity: "main"
                )
            )
        ))
    }

    func testForegroundSafetyRejectsForeignWindowFromSameApplication() {
        let selectedMain = WindowServerSelectionSnapshot(
            pid: 100,
            windowID: 42
        )
        let foreignGroupWindow = WindowServerSelectionSnapshot(
            pid: 100,
            windowID: 84
        )
        XCTAssertFalse(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "selected-group-main",
                selectedWindowID: 42,
                allowedWindowServerSelections: [selectedMain],
                allowedAccessibilitySelections: [
                    FocusedWindowIdentity(
                        pid: 100,
                        stableIdentity: "selected-group-main"
                    )
                ],
                windowServerSelection: foreignGroupWindow,
                focusedWindowServerSelection: foreignGroupWindow,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "foreign-group-window",
                    mainIdentity: "foreign-group-window"
                )
            )
        ))
    }

    func testCursorAdornmentDirectionFollowsBoundaryAxis() {
        XCTAssertEqual(
            ResizeCursorAdornmentKind.kind(for: .horizontal),
            .horizontal
        )
        XCTAssertEqual(
            ResizeCursorAdornmentKind.kind(for: .vertical),
            .vertical
        )
    }
    func testExplicitOperationCommitAxesDoNotChangeHistoricalCorrectionAxes() {
        let cornerOuterEdges = SnapZone.bottomLeft.requiredOuterEdges
        XCTAssertEqual(
            AXFrameSizePolicy.historicalCorrectionAxes(
                requiredOuterEdges: cornerOuterEdges
            ),
            []
        )
        XCTAssertEqual(
            AXFrameSizePolicy.commitAxes(
                requiredOuterEdges: cornerOuterEdges,
                explicitCommitAxes: [.height]
            ),
            [.height]
        )
        XCTAssertEqual(
            AXFrameSizePolicy.historicalCorrectionAxes(
                requiredOuterEdges: cornerOuterEdges
            ),
            []
        )

        let halfOuterEdges = SnapZone.leftHalf.requiredOuterEdges
        XCTAssertEqual(
            AXFrameSizePolicy.historicalCorrectionAxes(
                requiredOuterEdges: halfOuterEdges
            ),
            [.height]
        )
        XCTAssertEqual(
            AXFrameSizePolicy.commitAxes(
                requiredOuterEdges: halfOuterEdges,
                explicitCommitAxes: [.width]
            ),
            [.width]
        )
        XCTAssertEqual(
            AXFrameSizePolicy.historicalCorrectionAxes(
                requiredOuterEdges: halfOuterEdges
            ),
            [.height]
        )
    }

    func testExplicitHeightCommitCannotSettleAtOldLargerSize() {
        let oldLargerSize = CGSize(width: 500, height: 600)
        let requestedSize = CGSize(width: 500, height: 500)

        // Historical callers remain flexible when no explicit commit axis
        // owns a size requirement.
        XCTAssertTrue(
            AXFrameSizePolicy.requiredSizeIsCorrect(
                actual: oldLargerSize,
                target: requestedSize,
                exactAxes: []
            )
        )
        // A snap/resize transaction that owns height exactly cannot accept
        // the old larger size as successful settlement. Initial snap may then
        // replan from settled evidence; shared resize may classify a genuine
        // rejection only after the existing observation window completes.
        XCTAssertFalse(
            AXFrameSizePolicy.requiredSizeIsCorrect(
                actual: oldLargerSize,
                target: requestedSize,
                exactAxes: [.height]
            )
        )
        XCTAssertTrue(
            AXFrameSizePolicy.requiredSizeIsCorrect(
                actual: requestedSize,
                target: requestedSize,
                exactAxes: [.height]
            )
        )
    }


    func testCommitSizeProgressIgnoresPositionOnlyMovement() {
        let target = CGSize(width: 500, height: 500)
        let stale = CGSize(width: 500, height: 600)
        XCTAssertEqual(
            AXFrameSizePolicy.targetDistance(
                actual: stale,
                target: target,
                exactAxes: [.height]
            ),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AXFrameSizePolicy.targetDistance(
                actual: CGSize(width: 500, height: 550),
                target: target,
                exactAxes: [.height]
            ),
            50,
            accuracy: 0.001
        )
    }

}
