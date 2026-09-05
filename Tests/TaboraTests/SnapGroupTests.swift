import CoreGraphics
import XCTest
@testable import Tabora

final class SnapGroupTests: XCTestCase {
    func testProvisionalPlacementCannotUseIncomingWindowAsItsOwnPeer() {
        XCTAssertFalse(
            SnapGroupPlacementEligibilityPolicy.canUseProvisionalPeer(
                existingIdentity: "same-window",
                incomingIdentity: "same-window"
            )
        )
        XCTAssertTrue(
            SnapGroupPlacementEligibilityPolicy.canUseProvisionalPeer(
                existingIdentity: "existing-window",
                incomingIdentity: "incoming-window"
            )
        )
    }

    func testReplacementRevalidationUsesExactStructuralSignature() {
        let members: Set<String> = ["left", "right"]
        let zones: [String: SnapZone] = [
            "left": .leftHalf,
            "right": .rightHalf
        ]
        XCTAssertTrue(
            MultiMemberReplacementStructuralPolicy.matchesCapturedStructure(
                expectedMemberIDs: members,
                expectedZonesByMemberID: zones,
                currentMemberIDs: members,
                currentZonesByMemberID: zones
            )
        )
        XCTAssertFalse(
            MultiMemberReplacementStructuralPolicy.matchesCapturedStructure(
                expectedMemberIDs: members,
                expectedZonesByMemberID: zones,
                currentMemberIDs: members,
                currentZonesByMemberID: [
                    "left": .topLeft,
                    "right": .rightHalf
                ]
            )
        )
        XCTAssertFalse(
            MultiMemberReplacementStructuralPolicy.matchesCapturedStructure(
                expectedMemberIDs: members,
                expectedZonesByMemberID: zones,
                currentMemberIDs: ["left"],
                currentZonesByMemberID: ["left": .leftHalf]
            )
        )
    }

    func testDegradationDoesNotConfirmTwiceInSameEpoch() {
        let fingerprint = GroupDegradationFingerprint(
            missingMemberIDs: ["middle"],
            geometryDisconnected: true
        )
        let first = GroupDegradationConfirmationPolicy.observe(
            previous: nil, fingerprint: fingerprint, epoch: 10, now: 1.0
        )
        let repeated = GroupDegradationConfirmationPolicy.observe(
            previous: first.evidence,
            fingerprint: fingerprint,
            epoch: 10,
            now: 2.0
        )
        XCTAssertFalse(first.isConfirmed)
        XCTAssertFalse(repeated.isConfirmed)
    }

    func testDegradationRequiresFreshEpochAfterSettleInterval() {
        let fingerprint = GroupDegradationFingerprint(
            missingMemberIDs: ["middle"],
            geometryDisconnected: true
        )
        let first = GroupDegradationConfirmationPolicy.observe(
            previous: nil, fingerprint: fingerprint, epoch: 10, now: 1.0
        )
        let tooSoon = GroupDegradationConfirmationPolicy.observe(
            previous: first.evidence,
            fingerprint: fingerprint,
            epoch: 11, now: 1.01
        )
        let confirmed = GroupDegradationConfirmationPolicy.observe(
            previous: tooSoon.evidence,
            fingerprint: fingerprint,
            epoch: 12, now: 1.08
        )
        XCTAssertFalse(tooSoon.isConfirmed)
        XCTAssertTrue(confirmed.isConfirmed)
    }

    func testDegradationFingerprintChangeResetsEvidence() {
        let firstFingerprint = GroupDegradationFingerprint(
            missingMemberIDs: ["middle"],
            geometryDisconnected: true
        )
        let secondFingerprint = GroupDegradationFingerprint(
            missingMemberIDs: ["right"],
            geometryDisconnected: true
        )
        let first = GroupDegradationConfirmationPolicy.observe(
            previous: nil, fingerprint: firstFingerprint, epoch: 1, now: 1
        )
        let changed = GroupDegradationConfirmationPolicy.observe(
            previous: first.evidence,
            fingerprint: secondFingerprint, epoch: 2, now: 2
        )
        XCTAssertFalse(changed.isConfirmed)
        XCTAssertEqual(changed.evidence.firstObservationEpoch, 2)
    }

    func testSpaceSeparationRequiresProperExactMemberSplit() {
        let members: Set<String> = ["left", "right"]
        XCTAssertEqual(
            GroupSpaceSeparationPolicy.fingerprint(
                memberIDs: members,
                onScreenMemberIDs: ["left"],
                confirmedExistingMemberIDs: members,
                eligibleOffscreenMemberIDs: ["right"]
            ),
            GroupDegradationFingerprint(
                missingMemberIDs: ["right"],
                geometryDisconnected: false
            )
        )
    }

    func testSpaceSeparationPreservesAllVisibleAndAllOffscreenGroups() {
        let members: Set<String> = ["left", "right"]
        XCTAssertNil(GroupSpaceSeparationPolicy.fingerprint(
            memberIDs: members,
            onScreenMemberIDs: members,
            confirmedExistingMemberIDs: members,
            eligibleOffscreenMemberIDs: []
        ))
        XCTAssertNil(GroupSpaceSeparationPolicy.fingerprint(
            memberIDs: members,
            onScreenMemberIDs: [],
            confirmedExistingMemberIDs: members,
            eligibleOffscreenMemberIDs: members
        ))
    }

    func testSpaceSeparationRejectsIncompletePhysicalOrAXEvidence() {
        let members: Set<String> = ["left", "right"]
        XCTAssertNil(GroupSpaceSeparationPolicy.fingerprint(
            memberIDs: members,
            onScreenMemberIDs: ["left"],
            confirmedExistingMemberIDs: ["left"],
            eligibleOffscreenMemberIDs: ["right"]
        ))
        XCTAssertNil(GroupSpaceSeparationPolicy.fingerprint(
            memberIDs: members,
            onScreenMemberIDs: ["left"],
            confirmedExistingMemberIDs: members,
            eligibleOffscreenMemberIDs: []
        ))
    }

    func testSpaceSeparationConfirmationUsesLongerSettleWindow() {
        let fingerprint = GroupDegradationFingerprint(
            missingMemberIDs: ["right"],
            geometryDisconnected: false
        )
        let first = GroupDegradationConfirmationPolicy.observe(
            previous: nil,
            fingerprint: fingerprint,
            epoch: 1,
            now: 1,
            minimumSettleInterval:
                GroupSpaceSeparationPolicy.minimumSettleInterval
        )
        let tooSoon = GroupDegradationConfirmationPolicy.observe(
            previous: first.evidence,
            fingerprint: fingerprint,
            epoch: 2,
            now: 1.49,
            minimumSettleInterval:
                GroupSpaceSeparationPolicy.minimumSettleInterval
        )
        let confirmed = GroupDegradationConfirmationPolicy.observe(
            previous: tooSoon.evidence,
            fingerprint: fingerprint,
            epoch: 3,
            now: 1.50,
            minimumSettleInterval:
                GroupSpaceSeparationPolicy.minimumSettleInterval
        )
        XCTAssertFalse(tooSoon.isConfirmed)
        XCTAssertTrue(confirmed.isConfirmed)
    }

    func testFrontmostEvaluationUsesWindowServerOccluders() {
        let members: Set<WindowServerSelectionSnapshot> = [
            WindowServerSelectionSnapshot(pid: 100, windowID: 10),
            WindowServerSelectionSnapshot(pid: 200, windowID: 20)
        ]
        let memberA = WindowOcclusionSnapshot(
            windowID: 10, pid: 100,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900),
            zIndex: 1, layer: 0
        )
        let memberB = WindowOcclusionSnapshot(
            windowID: 20, pid: 200,
            frame: CGRect(x: 500, y: 0, width: 500, height: 900),
            zIndex: 2, layer: 0
        )
        let popup = WindowOcclusionSnapshot(
            windowID: 99, pid: 300,
            frame: CGRect(x: 400, y: 200, width: 250, height: 250),
            zIndex: 0, layer: 0
        )
        XCTAssertEqual(
            GroupFrontmostEvaluationPolicy.evaluate(
                memberSelections: members, snapshot: [memberA, memberB]
            ),
            .verifiedFrontmost
        )
        XCTAssertEqual(
            GroupFrontmostEvaluationPolicy.evaluate(
                memberSelections: members,
                snapshot: [popup, memberA, memberB]
            ),
            .occluded
        )
    }

    func testFrontmostEvaluationSupportsSingleProvisionalPlacement() {
        let member = WindowServerSelectionSnapshot(pid: 100, windowID: 10)
        let window = WindowOcclusionSnapshot(
            windowID: 10, pid: 100,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900),
            zIndex: 0, layer: 0
        )
        XCTAssertEqual(
            GroupFrontmostEvaluationPolicy.evaluate(
                memberSelections: [member], snapshot: [window]
            ),
            .verifiedFrontmost
        )
    }

    func testFrontmostEvaluationFailsIndeterminateOnMissingMemberEvidence() {
        let members: Set<WindowServerSelectionSnapshot> = [
            WindowServerSelectionSnapshot(pid: 100, windowID: 10),
            WindowServerSelectionSnapshot(pid: 200, windowID: 20)
        ]
        let onlyOne = WindowOcclusionSnapshot(
            windowID: 10, pid: 100,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900),
            zIndex: 0, layer: 0
        )
        XCTAssertEqual(
            GroupFrontmostEvaluationPolicy.evaluate(
                memberSelections: members, snapshot: [onlyOne]
            ),
            .indeterminate
        )
    }

    func testFrontmostEvaluationIgnoresIntraGroupMemberOrdering() {
        let members: Set<WindowServerSelectionSnapshot> = [
            WindowServerSelectionSnapshot(pid: 100, windowID: 10),
            WindowServerSelectionSnapshot(pid: 200, windowID: 20)
        ]
        let frontMember = WindowOcclusionSnapshot(
            windowID: 10, pid: 100,
            frame: CGRect(x: 0, y: 0, width: 600, height: 900),
            zIndex: 0, layer: 0
        )
        let rearMember = WindowOcclusionSnapshot(
            windowID: 20, pid: 200,
            frame: CGRect(x: 400, y: 0, width: 600, height: 900),
            zIndex: 1, layer: 0
        )
        XCTAssertEqual(
            GroupFrontmostEvaluationPolicy.evaluate(
                memberSelections: members,
                snapshot: [frontMember, rearMember]
            ),
            .verifiedFrontmost
        )
    }

    private let displayID: CGDirectDisplayID = 1
    private let left = SplitPlacementGeometry(
        stableIdentity: "left",
        zone: .leftHalf,
        frame: CGRect(x: 0, y: 0, width: 720, height: 900)
    )
    private let right = SplitPlacementGeometry(
        stableIdentity: "right",
        zone: .rightHalf,
        frame: CGRect(x: 720, y: 0, width: 720, height: 900)
    )

    func testSystemWindowSelectionAuthorizesOnlyAnAlreadyFrontmostGroup() {
        XCTAssertEqual(GroupForegroundMode.defaultMode, .disabled)
        XCTAssertEqual(
            GroupForegroundSelectionPolicy.disposition(
                frontmostEvaluation: .occluded
            ),
            .presentSelectedMemberOnly
        )
        XCTAssertEqual(
            GroupForegroundSelectionPolicy.disposition(
                frontmostEvaluation: .indeterminate
            ),
            .presentSelectedMemberOnly
        )
        XCTAssertEqual(
            GroupForegroundSelectionPolicy.disposition(
                frontmostEvaluation: .verifiedFrontmost
            ),
            .authorizeAutomaticForeground
        )
    }

    func testDirectClickDoesNotUnlockSystemIsolatedGroup() {
        XCTAssertEqual(
            GroupForegroundAuthorizationPolicy.directClickDisposition(
                for: .soloPresented(memberID: "selected")
            ),
            .preserveSystemIsolation
        )
        XCTAssertEqual(
            GroupForegroundAuthorizationPolicy.directClickDisposition(
                for: .disabled
            ),
            .evaluateExplicitGroupRaise
        )
        XCTAssertEqual(
            GroupForegroundAuthorizationPolicy.directClickDisposition(
                for: .automatic
            ),
            .evaluateExplicitGroupRaise
        )
    }

    func testNewSystemSelectionClosesOnlyAutomaticAuthorization() {
        XCTAssertEqual(
            GroupForegroundAuthorizationPolicy
                .modeAfterSystemSelectionSupersedesAutomatic(.automatic),
            .disabled
        )
        XCTAssertEqual(
            GroupForegroundAuthorizationPolicy
                .modeAfterSystemSelectionSupersedesAutomatic(.disabled),
            .disabled
        )
        XCTAssertEqual(
            GroupForegroundAuthorizationPolicy
                .modeAfterSystemSelectionSupersedesAutomatic(
                    .soloPresented(memberID: "isolated")
                ),
            .soloPresented(memberID: "isolated")
        )
    }

    func testOwnedForegroundMutationFiltersOnlyExactMemberSurfaces() {
        let groupID = SnapGroupID()
        let mutation = OwnedForegroundMutation(
            generation: 7,
            groupID: groupID,
            memberIdentities: ["first", "second"],
            memberSelections: [
                WindowServerSelectionSnapshot(pid: 100, windowID: 41),
                WindowServerSelectionSnapshot(pid: 100, windowID: 42)
            ]
        )

        XCTAssertTrue(ForegroundMutationSelectionPolicy.isOwnedSelection(
            WindowServerSelectionSnapshot(pid: 100, windowID: 42),
            mutation: mutation
        ))
        XCTAssertFalse(ForegroundMutationSelectionPolicy.isOwnedSelection(
            WindowServerSelectionSnapshot(pid: 100, windowID: 43),
            mutation: mutation
        ))
        XCTAssertFalse(ForegroundMutationSelectionPolicy.isOwnedSelection(
            WindowServerSelectionSnapshot(pid: 200, windowID: 42),
            mutation: mutation
        ))
        XCTAssertEqual(
            ForegroundMutationSelectionPolicy.processNotificationDisposition(
                expectedPID: 100,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "second",
                    mainIdentity: "first"
                ),
                mutation: mutation
            ),
            .ownedMutation
        )
        XCTAssertEqual(
            ForegroundMutationSelectionPolicy.processNotificationDisposition(
                expectedPID: 100,
                accessibilitySelection: ActiveWindowIdentitySnapshot(
                    pid: 100,
                    focusedIdentity: "other",
                    mainIdentity: "other"
                ),
                mutation: mutation
            ),
            .externalSelection
        )
        XCTAssertEqual(
            ForegroundMutationSelectionPolicy.processNotificationDisposition(
                expectedPID: 100,
                accessibilitySelection: nil,
                mutation: mutation
            ),
            .awaitExactWindowIdentity
        )
    }

    func testPlacementCannotAbsorbAGroupThatWasCoveredAtPointerDown() {
        XCTAssertFalse(
            SnapGroupPlacementEligibilityPolicy.canAbsorbPlacement(
                wasFrontmostAtPointerDown: false,
                isFrontmostNow: true,
                isComplete: true
            )
        )
        XCTAssertTrue(
            SnapGroupPlacementEligibilityPolicy.canAbsorbPlacement(
                wasFrontmostAtPointerDown: true,
                isFrontmostNow: true,
                isComplete: true
            )
        )
        XCTAssertEqual(
            SnapGroupPlacementEligibilityPolicy.relationshipRank(
                conflictingMemberCount: 1,
                multiMemberReplacementHasStraightBoundary: false,
                canExtend: true
            ),
            0
        )
        XCTAssertEqual(
            SnapGroupPlacementEligibilityPolicy.relationshipRank(
                conflictingMemberCount: 0,
                multiMemberReplacementHasStraightBoundary: false,
                canExtend: true
            ),
            1
        )
        XCTAssertNil(
            SnapGroupPlacementEligibilityPolicy.relationshipRank(
                conflictingMemberCount: 0,
                multiMemberReplacementHasStraightBoundary: false,
                canExtend: false
            )
        )
        XCTAssertEqual(
            SnapGroupPlacementEligibilityPolicy.relationshipRank(
                conflictingMemberCount: 2,
                multiMemberReplacementHasStraightBoundary: true,
                canExtend: false
            ),
            0
        )
        XCTAssertNil(
            SnapGroupPlacementEligibilityPolicy.relationshipRank(
                conflictingMemberCount: 2,
                multiMemberReplacementHasStraightBoundary: false,
                canExtend: true
            )
        )
        XCTAssertEqual(
            SnapGroupPlacementEligibilityPolicy.relationshipRank(
                conflictingMemberCount: 2,
                multiMemberReplacementHasStraightBoundary: false,
                fullGroupReplacementIsExactCover: true,
                canExtend: false
            ),
            0
        )
    }

    func testAssistExclusionsReleaseDisplacedMembersAfterCommittedReplacement() {
        XCTAssertEqual(
            AssistCandidateExclusionPolicy.currentExclusions(
                capturedIDs: ["retained", "displaced", "foreign"],
                lockedIDs: ["retained", "foreign"],
                groupedIDs: ["retained", "foreign"]
            ),
            Set(["retained", "foreign"])
        )
    }

    func testAssistReservationDoesNotTreatMaximizeAsSplitMembership() {
        XCTAssertFalse(
            AssistCandidateReservationPolicy.isReserved(
                placementZone: nil
            )
        )
        XCTAssertFalse(
            AssistCandidateReservationPolicy.isReserved(
                placementZone: .maximize
            )
        )
        XCTAssertTrue(
            AssistCandidateReservationPolicy.isReserved(
                placementZone: .leftHalf
            )
        )
        XCTAssertTrue(
            AssistCandidateReservationPolicy.isReserved(
                placementZone: .topRight
            )
        )
    }

    func testDraggedSurfaceAloneDoesNotBlockReplacementSnap() {
        let bindings = [
            PersistedWindowBinding(
                stableIdentity: "left",
                pid: 100,
                windowID: 10
            ),
            PersistedWindowBinding(
                stableIdentity: "right",
                pid: 200,
                windowID: 20
            )
        ]
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 30,
                pid: 300,
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 100,
                frame: left.frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 20,
                pid: 200,
                frame: right.frame,
                zIndex: 2,
                layer: 0
            )
        ]

        XCTAssertTrue(
            SnapGroupPlacementEligibilityPolicy
                .wasFrontmostAtPointerDown(
                    groupIDs: ["left", "right"],
                    draggedSurface: WindowServerSelectionSnapshot(
                        pid: 300,
                        windowID: 30
                    ),
                    bindings: bindings,
                    windowServerSnapshot: snapshot
                )
        )
    }

    func testFrontmostGroupStillAcceptsAnExplicitSpatialInvasion() {
        let bindings = [
            PersistedWindowBinding(
                stableIdentity: "left",
                pid: 100,
                windowID: 10
            ),
            PersistedWindowBinding(
                stableIdentity: "right",
                pid: 200,
                windowID: 20
            )
        ]
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 30,
                pid: 300,
                frame: CGRect(x: 1_600, y: 0, width: 300, height: 300),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 100,
                frame: left.frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 20,
                pid: 200,
                frame: right.frame,
                zIndex: 2,
                layer: 0
            )
        ]

        XCTAssertTrue(
            SnapGroupPlacementEligibilityPolicy
                .wasFrontmostAtPointerDown(
                    groupIDs: ["left", "right"],
                    draggedSurface: WindowServerSelectionSnapshot(
                        pid: 300,
                        windowID: 30
                    ),
                    bindings: bindings,
                    windowServerSnapshot: snapshot
                )
        )
    }

    func testUnregisteredSameApplicationCoverCreatesIndependentGroup() {
        let bindings = [
            PersistedWindowBinding(
                stableIdentity: "left",
                pid: 100,
                windowID: 10
            ),
            PersistedWindowBinding(
                stableIdentity: "right",
                pid: 100,
                windowID: 20
            )
        ]
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 30,
                pid: 100,
                frame: left.frame,
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 31,
                pid: 100,
                frame: right.frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 100,
                frame: left.frame,
                zIndex: 2,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 20,
                pid: 100,
                frame: right.frame,
                zIndex: 3,
                layer: 0
            )
        ]

        XCTAssertFalse(
            SnapGroupPlacementEligibilityPolicy
                .wasFrontmostAtPointerDown(
                    groupIDs: ["left", "right"],
                    draggedSurface: WindowServerSelectionSnapshot(
                        pid: 100,
                        windowID: 30
                    ),
                    bindings: bindings,
                    windowServerSnapshot: snapshot
                )
        )
    }

    func testReplacementTargetsOnlyTheTopmostOverlappingGroup() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "first-right",
            displayID: displayID,
            placements: [
                SplitPlacementGeometry(
                    stableIdentity: "first-left",
                    zone: .leftHalf,
                    frame: left.frame
                ),
                SplitPlacementGeometry(
                    stableIdentity: "first-right",
                    zone: .rightHalf,
                    frame: right.frame
                )
            ],
            detachedConnections: []
        )
        let second = store.reconcileAfterLayoutMutation(
            preferredMemberID: "second-right",
            displayID: displayID,
            placements: [
                SplitPlacementGeometry(
                    stableIdentity: "second-left",
                    zone: .leftHalf,
                    frame: left.frame
                ),
                SplitPlacementGeometry(
                    stableIdentity: "second-right",
                    zone: .rightHalf,
                    frame: right.frame
                )
            ],
            detachedConnections: []
        )
        let bindings = [
            PersistedWindowBinding(
                stableIdentity: "first-left",
                pid: 100,
                windowID: 10
            ),
            PersistedWindowBinding(
                stableIdentity: "first-right",
                pid: 100,
                windowID: 11
            ),
            PersistedWindowBinding(
                stableIdentity: "second-left",
                pid: 100,
                windowID: 20
            ),
            PersistedWindowBinding(
                stableIdentity: "second-right",
                pid: 100,
                windowID: 21
            )
        ]
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 99,
                pid: 200,
                frame: left.frame.union(right.frame),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 20,
                pid: 100,
                frame: left.frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 21,
                pid: 100,
                frame: right.frame,
                zIndex: 2,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 100,
                frame: left.frame,
                zIndex: 3,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 100,
                frame: right.frame,
                zIndex: 4,
                layer: 0
            )
        ]

        let frontmost = SnapGroupPlacementEligibilityPolicy
            .frontmostGroupIDs(
                groups: store.groups,
                draggedSurface: WindowServerSelectionSnapshot(
                    pid: 200,
                    windowID: 99
                ),
                bindings: bindings,
                windowServerSnapshot: snapshot
            )

        XCTAssertEqual(frontmost, Set([try! XCTUnwrap(second?.id)]))
        XCTAssertFalse(frontmost.contains(try! XCTUnwrap(first?.id)))
    }

    func testSinglePlacementDoesNotCreateAGroup() {
        var store = SnapGroupStore()
        let result = store.reconcileAfterLayoutMutation(
            preferredMemberID: "left",
            displayID: displayID,
            placements: [left],
            detachedConnections: []
        )

        XCTAssertNil(result)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.connectedMemberCount, 0)
    }

    func testDisplayOrdinalUsesOnlyCurrentStableGroupOrder() {
        var store = SnapGroupStore()
        func createGroup(_ prefix: String) -> SnapGroup {
            let group = store.reconcileAfterLayoutMutation(
                preferredMemberID: "\(prefix)-right",
                displayID: displayID,
                placements: [
                    SplitPlacementGeometry(
                        stableIdentity: "\(prefix)-left",
                        zone: .leftHalf,
                        frame: left.frame
                    ),
                    SplitPlacementGeometry(
                        stableIdentity: "\(prefix)-right",
                        zone: .rightHalf,
                        frame: right.frame
                    )
                ],
                detachedConnections: []
            )
            return try! XCTUnwrap(group)
        }

        let first = createGroup("first")
        let second = createGroup("second")
        let third = createGroup("third")
        XCTAssertEqual(store.displayOrdinal(for: first.id), 1)
        XCTAssertEqual(store.displayOrdinal(for: second.id), 2)
        XCTAssertEqual(store.displayOrdinal(for: third.id), 3)

        _ = store.dissolveGroup(id: first.id)
        _ = store.dissolveGroup(id: second.id)

        XCTAssertEqual(third.creationOrder, 3)
        XCTAssertEqual(store.displayOrdinal(for: third.id), 1)
        XCTAssertEqual(store.displayOrdinalsByGroupID, [third.id: 1])
    }

    func testAdjacentPlacementsCreateOneExplicitGroup() {
        var store = SnapGroupStore()
        let result = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        XCTAssertEqual(result?.memberIDs, ["left", "right"])
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.connectedMemberCount, 2)
        XCTAssertEqual(store.group(containing: "left")?.id, result?.id)
        XCTAssertEqual(store.group(containing: "right")?.id, result?.id)
    }

    func testCompleteSpaceTransitionReactivatesExactGroup() {
        var store = SnapGroupStore()
        let group = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let groupID = try! XCTUnwrap(group?.id)

        store.suspendForSpaceTransition()
        XCTAssertEqual(
            store.group(id: groupID)?.state,
            .suspendedForSpaceTransition
        )

        store.markDegraded(groupID: groupID, missingMemberIDs: [])
        XCTAssertEqual(store.group(id: groupID)?.state, .active)
        XCTAssertEqual(store.group(id: groupID)?.memberIDs, ["left", "right"])
    }

    func testIndependentGroupsWithOverlappingGeometryCoexist() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let secondLeft = SplitPlacementGeometry(
            stableIdentity: "second-left",
            zone: .leftHalf,
            frame: left.frame
        )
        let secondRight = SplitPlacementGeometry(
            stableIdentity: "second-right",
            zone: .rightHalf,
            frame: right.frame
        )
        let second = store.reconcileAfterLayoutMutation(
            preferredMemberID: "second-right",
            displayID: displayID,
            placements: [secondLeft, secondRight],
            detachedConnections: []
        )

        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(store.groups.count, 2)
        XCTAssertEqual(store.group(containing: "left")?.id, first?.id)
        XCTAssertEqual(
            store.group(containing: "second-left")?.id,
            second?.id
        )
        XCTAssertEqual(store.groups.first?.id, first?.id)
        XCTAssertEqual(store.groups.last?.id, second?.id)
    }

    func testThirdIndependentGroupDoesNotEvictEarlierGroups() {
        var store = SnapGroupStore()
        var createdIDs: [SnapGroupID] = []

        for suffix in ["one", "two", "three"] {
            let group = store.reconcileAfterLayoutMutation(
                preferredMemberID: "right-\(suffix)",
                displayID: displayID,
                placements: [
                    SplitPlacementGeometry(
                        stableIdentity: "left-\(suffix)",
                        zone: .leftHalf,
                        frame: left.frame
                    ),
                    SplitPlacementGeometry(
                        stableIdentity: "right-\(suffix)",
                        zone: .rightHalf,
                        frame: right.frame
                    )
                ],
                detachedConnections: []
            )
            XCTAssertNotNil(group)
            if let group { createdIDs.append(group.id) }
        }

        XCTAssertEqual(store.groups.count, 3)
        XCTAssertEqual(store.groups.map(\.id), createdIDs)
        XCTAssertEqual(store.connectedMemberCount, 6)
    }

    func testTargetedReplacementPreservesGroupIDAndOtherGroups() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let otherLeft = SplitPlacementGeometry(
            stableIdentity: "other-left",
            zone: .leftHalf,
            frame: left.frame
        )
        let otherRight = SplitPlacementGeometry(
            stableIdentity: "other-right",
            zone: .rightHalf,
            frame: right.frame
        )
        let other = store.reconcileAfterLayoutMutation(
            preferredMemberID: "other-right",
            displayID: displayID,
            placements: [otherLeft, otherRight],
            detachedConnections: []
        )
        let replacement = SplitPlacementGeometry(
            stableIdentity: "replacement",
            zone: .rightHalf,
            frame: right.frame
        )

        let rebuilt = store.reconcileAfterLayoutMutation(
            preferredMemberID: "replacement",
            displayID: displayID,
            placements: [left, replacement],
            detachedConnections: [],
            targetGroupID: first?.id
        )

        XCTAssertEqual(rebuilt?.id, first?.id)
        XCTAssertNil(store.group(containing: "right"))
        XCTAssertEqual(
            store.group(containing: "replacement")?.id,
            first?.id
        )
        XCTAssertEqual(store.group(containing: "other-left")?.id, other?.id)
        XCTAssertEqual(store.groups.count, 2)
    }

    func testTargetedReconciliationCannotStealForeignMember() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let otherLeft = SplitPlacementGeometry(
            stableIdentity: "other-left",
            zone: .leftHalf,
            frame: left.frame
        )
        let otherRight = SplitPlacementGeometry(
            stableIdentity: "other-right",
            zone: .rightHalf,
            frame: right.frame
        )
        let other = store.reconcileAfterLayoutMutation(
            preferredMemberID: "other-right",
            displayID: displayID,
            placements: [otherLeft, otherRight],
            detachedConnections: []
        )

        let result = store.reconcileAfterLayoutMutation(
            preferredMemberID: "other-right",
            displayID: displayID,
            placements: [left, otherRight],
            detachedConnections: [],
            targetGroupID: first?.id
        )

        XCTAssertNil(result)
        XCTAssertEqual(store.group(containing: "left")?.id, first?.id)
        XCTAssertEqual(
            store.group(containing: "other-right")?.id,
            other?.id
        )
        XCTAssertEqual(store.groups.count, 2)
    }

    func testFailedTargetedReconciliationDoesNotMutateExistingGroup() {
        var store = SnapGroupStore()
        let group = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        let result = store.reconcileAfterLayoutMutation(
            preferredMemberID: "left",
            displayID: displayID,
            placements: [left],
            detachedConnections: [],
            targetGroupID: group?.id
        )

        XCTAssertNil(result)
        XCTAssertEqual(store.group(containing: "left")?.id, group?.id)
        XCTAssertEqual(store.group(containing: "right")?.id, group?.id)
        XCTAssertEqual(store.groups.count, 1)
    }

    func testTargetedReconciliationRejectsDisconnectedSuccessorMember() {
        var store = SnapGroupStore()
        let group = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let disconnected = SplitPlacementGeometry(
            stableIdentity: "disconnected",
            zone: .topLeft,
            frame: CGRect(x: 2000, y: 2000, width: 300, height: 300)
        )

        let result = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right, disconnected],
            detachedConnections: [],
            targetGroupID: group?.id
        )

        XCTAssertNil(result)
        XCTAssertEqual(store.group(containing: "left")?.id, group?.id)
        XCTAssertEqual(store.group(containing: "right")?.id, group?.id)
        XCTAssertNil(store.group(containing: "disconnected"))
    }

    func testStaleTargetGroupIDCannotManufactureAGroup() {
        var store = SnapGroupStore()
        let result = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: [],
            targetGroupID: SnapGroupID()
        )

        XCTAssertNil(result)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testPassiveEquivalentReconciliationPreservesIdentityAndRevision() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let second = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(second?.revision, first?.revision)
    }

    func testDetachDissolvesTwoMemberGroupWithoutChangingPlacementData() {
        var store = SnapGroupStore()
        _ = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        let peers = store.detachMember("left")

        XCTAssertEqual(peers, ["right"])
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.group(containing: "left"))
        XCTAssertNil(store.group(containing: "right"))
    }

    func testDetachedLegacyEdgeDoesNotRecreateGroup() {
        var store = SnapGroupStore()
        let result = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: [SplitConnectionKey("left", "right")]
        )

        XCTAssertNil(result)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testMaximizedLayerIsSeparateFromSplitMembership() {
        var store = SnapGroupStore()
        let group = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        store.registerMaximizedLayer(
            windowID: "cover",
            displayID: displayID
        )

        XCTAssertEqual(store.group(containing: "left")?.id, group?.id)
        XCTAssertEqual(
            store.group(containing: "left")?.state,
            .occludedByMaximizedLayer(windowID: "cover")
        )
        XCTAssertNil(store.group(containing: "cover"))
    }

    func testRemovingOneMemberFromThreeDissolvesTheWholeGroup() {
        let topRight = SplitPlacementGeometry(
            stableIdentity: "top-right",
            zone: .topRight,
            frame: CGRect(x: 720, y: 450, width: 720, height: 450)
        )
        let bottomRight = SplitPlacementGeometry(
            stableIdentity: "bottom-right",
            zone: .bottomRight,
            frame: CGRect(x: 720, y: 0, width: 720, height: 450)
        )
        var store = SnapGroupStore()
        _ = store.reconcileAfterLayoutMutation(
            preferredMemberID: "top-right",
            displayID: displayID,
            placements: [left, topRight, bottomRight],
            detachedConnections: []
        )

        let peers = store.detachMember("left")

        XCTAssertEqual(peers, ["top-right", "bottom-right"])
        XCTAssertNil(store.group(containing: "left"))
        XCTAssertNil(store.group(containing: "top-right"))
        XCTAssertNil(store.group(containing: "bottom-right"))
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testRemovingAPlacementLockDissolvesTheWholeGroup() {
        var store = SnapGroupStore()
        _ = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        store.removeWindow("left")

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.group(containing: "right"))
    }

    func testReplacingOneMemberBuildsANewGroupFromTheRetainedPeer() {
        var store = SnapGroupStore()
        _ = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        store.removeWindow("right")
        let replacement = SplitPlacementGeometry(
            stableIdentity: "replacement",
            zone: .rightHalf,
            frame: right.frame
        )
        let rebuilt = store.reconcileAfterLayoutMutation(
            preferredMemberID: "replacement",
            displayID: displayID,
            placements: [left, replacement],
            detachedConnections: []
        )

        XCTAssertEqual(rebuilt?.memberIDs, ["left", "replacement"])
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertNotNil(store.group(containing: "left"))
        XCTAssertNotNil(store.group(containing: "replacement"))
        XCTAssertNil(store.group(containing: "right"))
    }

    func testMaximizingAGroupMemberDissolvesItsSplitGroup() {
        var store = SnapGroupStore()
        _ = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        store.registerMaximizedLayer(
            windowID: "left",
            displayID: displayID
        )

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.group(containing: "right"))
    }

    func testRemovingAProvisionalMaximizedWindowReleasesItsLayer() {
        var store = SnapGroupStore()
        store.registerMaximizedLayer(
            windowID: "cover",
            displayID: displayID
        )
        XCTAssertEqual(store.maximizedLayerByDisplayID[displayID], "cover")

        store.removeWindow("cover")

        XCTAssertNil(store.maximizedLayerByDisplayID[displayID])
    }

    func testRejectedSubsetReconciliationPreservesOriginalGroupForRetirement() {
        let topRight = SplitPlacementGeometry(
            stableIdentity: "top-right",
            zone: .topRight,
            frame: CGRect(x: 720, y: 450, width: 720, height: 450)
        )
        let bottomRight = SplitPlacementGeometry(
            stableIdentity: "bottom-right",
            zone: .bottomRight,
            frame: CGRect(x: 720, y: 0, width: 720, height: 450)
        )
        var store = SnapGroupStore()
        let original = store.reconcileAfterLayoutMutation(
            preferredMemberID: "top-right",
            displayID: displayID,
            placements: [left, topRight, bottomRight],
            detachedConnections: []
        )

        let replacement = store.reconcileAfterLayoutMutation(
            preferredMemberID: "top-right",
            displayID: displayID,
            placements: [topRight, bottomRight],
            detachedConnections: []
        )

        XCTAssertNil(replacement)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(
            store.group(containing: "left")?.id,
            original?.id
        )
        XCTAssertEqual(
            store.group(containing: "top-right")?.id,
            original?.id
        )
        XCTAssertEqual(
            store.group(containing: "bottom-right")?.id,
            original?.id
        )
    }

    func testWholeGroupRetirementRemovesStaleConnectionMarkers() {
        let unrelated = SplitConnectionKey("other-left", "other-right")
        let connections = SnapGroupDeparturePolicy.connectionsAfterRetirement(
            existing: [
                SplitConnectionKey("left", "top-right"),
                SplitConnectionKey("left", "bottom-right"),
                SplitConnectionKey("top-right", "bottom-right"),
                SplitConnectionKey("left", "unrelated-window"),
                unrelated
            ],
            retiredMemberIDs: ["left", "top-right", "bottom-right"]
        )

        XCTAssertEqual(connections, [unrelated])
    }

    func testRetirementKeepsCapturedMembersAfterLateStoreLoss() {
        XCTAssertEqual(
            SnapGroupDeparturePolicy.retirementMemberIDs(
                captured: ["left", "right"],
                current: []
            ),
            ["left", "right"]
        )
        XCTAssertEqual(
            SnapGroupDeparturePolicy.retirementMemberIDs(
                captured: ["left", "right"],
                current: ["right", "bottom-right"]
            ),
            ["left", "right", "bottom-right"]
        )
    }

    func testGroupCanBeRetiredByCapturedIdentity() {
        var store = SnapGroupStore()
        let group = store.reconcileAfterLayoutMutation(
            preferredMemberID: "left",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let groupID = try! XCTUnwrap(group?.id)

        XCTAssertEqual(store.dissolveGroup(id: groupID), ["left", "right"])
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.group(containing: "left"))
        XCTAssertNil(store.group(containing: "right"))
    }

    func testRetiredMembersCanJoinANewGroupAgain() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "left",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let firstID = try! XCTUnwrap(first?.id)
        XCTAssertEqual(store.dissolveGroup(id: firstID), ["left", "right"])

        let replacement = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )

        XCTAssertNotNil(replacement)
        XCTAssertNotEqual(replacement?.id, firstID)
        XCTAssertEqual(store.group(containing: "left")?.id, replacement?.id)
        XCTAssertEqual(store.group(containing: "right")?.id, replacement?.id)
    }

    func testCapturedMembersDissolveAReplacementGroupIdentity() {
        var store = SnapGroupStore()
        let original = store.reconcileAfterLayoutMutation(
            preferredMemberID: "left",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let originalID = try! XCTUnwrap(original?.id)
        _ = store.dissolveGroup(id: originalID)
        let replacement = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let replacementID = try! XCTUnwrap(replacement?.id)

        let dissolution = store.dissolveGroups(
            intersecting: ["left", "right"]
        )

        XCTAssertEqual(dissolution.groupIDs, Set([replacementID]))
        XCTAssertEqual(dissolution.memberIDs, Set(["left", "right"]))
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.group(containing: "left"))
        XCTAssertNil(store.group(containing: "right"))
    }

    func testCapturedMembersDissolveEveryReachedSuccessorGroup() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let secondLeft = SplitPlacementGeometry(
            stableIdentity: "second-left",
            zone: .leftHalf,
            frame: left.frame
        )
        let secondRight = SplitPlacementGeometry(
            stableIdentity: "second-right",
            zone: .rightHalf,
            frame: right.frame
        )
        let second = store.reconcileAfterLayoutMutation(
            preferredMemberID: "second-right",
            displayID: displayID,
            placements: [secondLeft, secondRight],
            detachedConnections: []
        )
        let firstID = try! XCTUnwrap(first?.id)
        let secondID = try! XCTUnwrap(second?.id)

        let dissolution = store.dissolveGroups(
            intersecting: ["left", "second-left"]
        )

        XCTAssertEqual(dissolution.groupIDs, Set([firstID, secondID]))
        XCTAssertEqual(
            dissolution.memberIDs,
            Set(["left", "right", "second-left", "second-right"])
        )
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testDepartureFromOneOverlappingGroupPreservesTheOtherGroup() {
        var store = SnapGroupStore()
        let first = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let secondLeft = SplitPlacementGeometry(
            stableIdentity: "second-left",
            zone: .leftHalf,
            frame: left.frame
        )
        let secondRight = SplitPlacementGeometry(
            stableIdentity: "second-right",
            zone: .rightHalf,
            frame: right.frame
        )
        let second = store.reconcileAfterLayoutMutation(
            preferredMemberID: "second-right",
            displayID: displayID,
            placements: [secondLeft, secondRight],
            detachedConnections: []
        )
        let firstID = try! XCTUnwrap(first?.id)
        let secondID = try! XCTUnwrap(second?.id)

        let dissolution = store.dissolveGroups(intersecting: ["left"])

        XCTAssertEqual(dissolution.groupIDs, Set([firstID]))
        XCTAssertEqual(dissolution.memberIDs, Set(["left", "right"]))
        XCTAssertNil(store.group(containing: "left"))
        XCTAssertNil(store.group(containing: "right"))
        XCTAssertEqual(store.group(containing: "second-left")?.id, secondID)
        XCTAssertEqual(store.group(containing: "second-right")?.id, secondID)
    }

    func testMissionControlScalePreservesLastGroupPresentation() {
        let evidence = [
            GroupWindowServerEvidence(
                stableIdentity: "left",
                pid: 10,
                windowID: 101,
                expectedFrame: left.frame
            ),
            GroupWindowServerEvidence(
                stableIdentity: "right",
                pid: 20,
                windowID: 202,
                expectedFrame: right.frame
            )
        ]
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 101,
                pid: 10,
                frame: CGRect(x: 80, y: 80, width: 500, height: 625),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 202,
                pid: 20,
                frame: CGRect(x: 580, y: 80, width: 500, height: 625),
                zIndex: 1,
                layer: 0
            )
        ]

        XCTAssertTrue(
            GroupPresentationTransitionPolicy.shouldPreserveLastPresentation(
                evidence: evidence,
                visibleMemberIDs: [],
                snapshot: snapshot
            )
        )
    }

    func testMissionControlActivationUsesExactIdentityNotTransformedGeometry() throws {
        let bindings = [
            PersistedWindowBinding(
                stableIdentity: "left",
                pid: 10,
                windowID: 101
            ),
            PersistedWindowBinding(
                stableIdentity: "right",
                pid: 20,
                windowID: 202
            )
        ]
        let transformedSnapshot = [
            WindowOcclusionSnapshot(
                windowID: 101,
                pid: 10,
                frame: CGRect(x: 70, y: 80, width: 420, height: 620),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 202,
                pid: 20,
                frame: CGRect(x: 510, y: 80, width: 420, height: 620),
                zIndex: 1,
                layer: 0
            )
        ]
        let selections = try XCTUnwrap(
            MissionControlActivationIdentityPolicy.exactSelections(
                memberIDs: ["left", "right"],
                bindings: bindings,
                snapshot: transformedSnapshot
            )
        )
        XCTAssertEqual(
            selections,
            Set([
                WindowServerSelectionSnapshot(pid: 10, windowID: 101),
                WindowServerSelectionSnapshot(pid: 20, windowID: 202)
            ])
        )
    }

    func testMissionControlActivationExactIdentityFailsClosedWhenMemberSurfaceIsMissing() {
        let bindings = [
            PersistedWindowBinding(
                stableIdentity: "left",
                pid: 10,
                windowID: 101
            ),
            PersistedWindowBinding(
                stableIdentity: "right",
                pid: 20,
                windowID: 202
            )
        ]
        XCTAssertNil(
            MissionControlActivationIdentityPolicy.exactSelections(
                memberIDs: ["left", "right"],
                bindings: bindings,
                snapshot: [
                    WindowOcclusionSnapshot(
                        windowID: 101,
                        pid: 10,
                        frame: left.frame,
                        zIndex: 0,
                        layer: 0
                    )
                ]
            )
        )
    }

    func testMissionControlObservationIsGroupLocalWhenAnotherGroupEvidenceIsUnavailable() {
        let transformedEvidence = [
            GroupWindowServerEvidence(
                stableIdentity: "left",
                pid: 10,
                windowID: 101,
                expectedFrame: left.frame
            ),
            GroupWindowServerEvidence(
                stableIdentity: "right",
                pid: 20,
                windowID: 202,
                expectedFrame: right.frame
            )
        ]
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 101,
                pid: 10,
                frame: CGRect(x: 80, y: 80, width: 500, height: 625),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 202,
                pid: 20,
                frame: CGRect(x: 580, y: 80, width: 500, height: 625),
                zIndex: 1,
                layer: 0
            )
        ]

        XCTAssertEqual(
            GroupPresentationTransitionPolicy.observe(
                evidence: transformedEvidence,
                expectedMemberCount: 2,
                visibleMemberIDs: [],
                snapshot: snapshot
            ),
            .transformed
        )
        XCTAssertEqual(
            GroupPresentationTransitionPolicy.observe(
                evidence: Array(transformedEvidence.prefix(1)),
                expectedMemberCount: 2,
                visibleMemberIDs: [],
                snapshot: snapshot
            ),
            .unavailable
        )
    }

    func testMissionControlBaselineUsesSettledAXAndWindowServerGeometry() {
        let settled = CGRect(x: 0, y: 0, width: 800, height: 900)
        XCTAssertTrue(
            GroupWindowServerEvidenceBaselinePolicy
                .framesRepresentTheSameDesktopGeometry(
                    accessibilityFrame: settled,
                    windowServerFrame: settled.offsetBy(dx: 1, dy: -1)
                )
        )

        XCTAssertFalse(
            GroupWindowServerEvidenceBaselinePolicy
                .framesRepresentTheSameDesktopGeometry(
                    accessibilityFrame: settled,
                    windowServerFrame: CGRect(
                        x: 80,
                        y: 90,
                        width: 640,
                        height: 720
                    )
                )
        )
    }

    func testMissionControlTransformObservationUsesTheSameRuleForTwoThreeAndFourMembers() {
        for memberCount in 2...4 {
            var evidence: [GroupWindowServerEvidence] = []
            evidence.reserveCapacity(memberCount)
            for index in 0..<memberCount {
                let stableIdentity = "member-\(index)"
                let pid = pid_t(100 + index)
                let windowID = CGWindowID(1000 + index)
                let expectedFrame = CGRect(
                    x: CGFloat(index) * 400,
                    y: 0,
                    width: 400,
                    height: 800
                )
                evidence.append(
                    GroupWindowServerEvidence(
                        stableIdentity: stableIdentity,
                        pid: pid,
                        windowID: windowID,
                        expectedFrame: expectedFrame
                    )
                )
            }

            var snapshot: [WindowOcclusionSnapshot] = []
            snapshot.reserveCapacity(evidence.count)
            for (index, member) in evidence.enumerated() {
                guard let windowID = member.windowID else {
                    XCTFail("Expected exact Window Server identity for member \(index)")
                    continue
                }
                let frame = CGRect(
                    x: CGFloat(index) * 320 + 60,
                    y: 60,
                    width: 320,
                    height: 640
                )
                snapshot.append(
                    WindowOcclusionSnapshot(
                        windowID: windowID,
                        pid: member.pid,
                        frame: frame,
                        zIndex: index,
                        layer: 0
                    )
                )
            }

            XCTAssertEqual(
                GroupPresentationTransitionPolicy.observe(
                    evidence: evidence,
                    expectedMemberCount: memberCount,
                    visibleMemberIDs: [],
                    snapshot: snapshot
                ),
                .transformed
            )
        }
    }

    func testRetiringOneGroupPreservesUnrelatedPresentationLease() {
        let groupA = SnapGroupID()
        let groupB = SnapGroupID()
        let leaseA = GroupPresentationTransitionLeasePolicy.make(
            groupID: groupA, memberIDs: ["a1", "a2"], now: 10
        )
        let leaseB = GroupPresentationTransitionLeasePolicy.make(
            groupID: groupB, memberIDs: ["b1", "b2"], now: 10
        )
        let retained = GroupPresentationTransitionLeasePolicy.retainingUnretired(
            [groupA: leaseA, groupB: leaseB],
            retiring: [groupA]
        )
        XCTAssertNil(retained[groupA])
        XCTAssertEqual(retained[groupB], leaseB)
    }

    func testMissionControlTransformLeaseIsGroupMemberScopedAndBounded() {
        let groupID = SnapGroupID()
        let lease = GroupPresentationTransitionLeasePolicy.make(
            groupID: groupID,
            memberIDs: ["left", "right"],
            now: 10
        )

        XCTAssertTrue(
            GroupPresentationTransitionLeasePolicy.isValid(
                lease,
                groupID: groupID,
                memberIDs: ["left", "right"],
                now: 10.5
            )
        )
        XCTAssertFalse(
            GroupPresentationTransitionLeasePolicy.isValid(
                lease,
                groupID: SnapGroupID(),
                memberIDs: ["left", "right"],
                now: 10.5
            )
        )
        XCTAssertFalse(
            GroupPresentationTransitionLeasePolicy.isValid(
                lease,
                groupID: groupID,
                memberIDs: ["left", "replacement"],
                now: 10.5
            )
        )
        XCTAssertFalse(
            GroupPresentationTransitionLeasePolicy.isValid(
                lease,
                groupID: groupID,
                memberIDs: ["left", "right"],
                now: 11.26
            )
        )
    }

    func testMissionControlObservationReturnsNormalOnlyForCompleteVisibleGroup() {
        let evidence = [
            GroupWindowServerEvidence(
                stableIdentity: "left",
                pid: 10,
                windowID: 101,
                expectedFrame: left.frame
            ),
            GroupWindowServerEvidence(
                stableIdentity: "right",
                pid: 20,
                windowID: 202,
                expectedFrame: right.frame
            )
        ]
        XCTAssertEqual(
            GroupPresentationTransitionPolicy.observe(
                evidence: evidence,
                expectedMemberCount: 2,
                visibleMemberIDs: ["left", "right"],
                snapshot: []
            ),
            .normal
        )
        XCTAssertEqual(
            GroupPresentationTransitionPolicy.observe(
                evidence: Array(evidence.prefix(1)),
                expectedMemberCount: 2,
                visibleMemberIDs: ["left"],
                snapshot: []
            ),
            .unavailable
        )
    }

    func testMovedOrClosedWindowDoesNotMasqueradeAsMissionControl() {
        let evidence = [
            GroupWindowServerEvidence(
                stableIdentity: "left",
                pid: 10,
                windowID: 101,
                expectedFrame: left.frame
            )
        ]
        let movedWithoutScaling = WindowOcclusionSnapshot(
            windowID: 101,
            pid: 10,
            frame: left.frame.offsetBy(dx: 100, dy: 100),
            zIndex: 0,
            layer: 0
        )

        XCTAssertFalse(
            GroupPresentationTransitionPolicy.shouldPreserveLastPresentation(
                evidence: evidence,
                visibleMemberIDs: ["left"],
                snapshot: [movedWithoutScaling]
            )
        )
        XCTAssertTrue(
            GroupPresentationTransitionPolicy.unresolvedMembersRemainLive(
                evidence: evidence,
                visibleMemberIDs: [],
                snapshot: [movedWithoutScaling]
            )
        )
        XCTAssertFalse(
            GroupPresentationTransitionPolicy.shouldPreserveLastPresentation(
                evidence: evidence,
                visibleMemberIDs: [],
                snapshot: [movedWithoutScaling]
            )
        )
        XCTAssertFalse(
            GroupPresentationTransitionPolicy.shouldPreserveLastPresentation(
                evidence: evidence,
                visibleMemberIDs: [],
                snapshot: []
            )
        )
        XCTAssertFalse(
            GroupPresentationTransitionPolicy.unresolvedMembersRemainLive(
                evidence: evidence,
                visibleMemberIDs: [],
                snapshot: []
            )
        )
    }

    func testSingleAxisResizeDoesNotMasqueradeAsMissionControl() {
        let evidence = [
            GroupWindowServerEvidence(
                stableIdentity: "left",
                pid: 10,
                windowID: 101,
                expectedFrame: left.frame
            )
        ]
        let horizontallyResized = WindowOcclusionSnapshot(
            windowID: 101,
            pid: 10,
            frame: CGRect(
                x: left.frame.minX,
                y: left.frame.minY,
                width: left.frame.width * 0.8,
                height: left.frame.height
            ),
            zIndex: 0,
            layer: 0
        )

        XCTAssertFalse(
            GroupPresentationTransitionPolicy.shouldPreserveLastPresentation(
                evidence: evidence,
                visibleMemberIDs: [],
                snapshot: [horizontallyResized]
            )
        )
    }
    func testDisplayEnvironmentRebindPreservesSpaceTransitionSuspension() {
        var store = SnapGroupStore()
        let group = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let groupID = try! XCTUnwrap(group?.id)
        store.suspendForSpaceTransition()
        let rebound = store.rebindDisplayAfterValidatedEnvironmentTransition(
            groupID: groupID,
            displayID: displayID + 1
        )
        XCTAssertEqual(rebound?.displayID, displayID + 1)
        XCTAssertEqual(rebound?.state, .suspendedForSpaceTransition)
    }

    func testValidatedDisplayEnvironmentRebindClearsStaleDegradedState() {
        var store = SnapGroupStore()
        let group = store.reconcileAfterLayoutMutation(
            preferredMemberID: "right",
            displayID: displayID,
            placements: [left, right],
            detachedConnections: []
        )
        let groupID = try! XCTUnwrap(group?.id)
        store.markDegraded(groupID: groupID, missingMemberIDs: ["left"])
        let rebound = store.rebindDisplayAfterValidatedEnvironmentTransition(
            groupID: groupID,
            displayID: displayID + 1
        )
        XCTAssertEqual(rebound?.displayID, displayID + 1)
        XCTAssertEqual(rebound?.state, .active)
    }

}
