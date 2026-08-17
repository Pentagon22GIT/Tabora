import CoreGraphics
import XCTest
@testable import Tabora

final class WindowSafetyPolicyTests: XCTestCase {
    func testOnlyConfirmedMissingAuthorizesStructuralDestruction() {
        XCTAssertTrue(WindowStructuralPolicy.isConfirmedMissing(.missing))
        XCTAssertFalse(WindowStructuralPolicy.isConfirmedMissing(.unknown))
        XCTAssertFalse(WindowStructuralPolicy.isConfirmedMissing(.alive))
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
            canMoveAndResize: true,
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
            canMoveAndResize: true,
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
            canMoveAndResize: true,
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
            canMoveAndResize: true,
            followsPointer: true
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

    func testForegroundSafetyRequiresAllSelectionsToAgree() {
        let selection = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        XCTAssertTrue(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "selected",
                selectedWindowID: 42,
                allowedWindowServerIDs: [42],
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
                allowedWindowServerIDs: [42],
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

    func testForegroundSafetyAllowsAPreviouslyRaisedParticipantOnTop() {
        XCTAssertTrue(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "selected",
                selectedWindowID: 42,
                allowedWindowServerIDs: [42, 84],
                windowServerSelection: WindowServerSelectionSnapshot(
                    pid: 100,
                    windowID: 84
                ),
                focusedWindowServerSelection: WindowServerSelectionSnapshot(
                    pid: 100,
                    windowID: 42
                ),
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "selected",
                    mainIdentity: "selected"
                )
            )
        ))
    }

    func testForegroundSafetyRejectsDifferentFocusedSurface() {
        let selection = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        XCTAssertFalse(ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: 100,
                selectedIdentity: "selected",
                selectedWindowID: 42,
                allowedWindowServerIDs: [42],
                windowServerSelection: selection,
                focusedWindowServerSelection: selection,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "dialog",
                    mainIdentity: "selected"
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
}
