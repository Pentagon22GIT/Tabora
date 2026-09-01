import AppKit
import XCTest
@testable import Tabora

final class SnapZoneTests: XCTestCase {
    func testDisplayTransitionDetectsBottomAlignedSidecarSeam() {
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let sidecar = CGRect(x: -1180, y: 0, width: 1180, height: 820)

        XCTAssertEqual(
            DisplayTransitionPolicy.sharedEntryEdge(
                from: main,
                to: sidecar,
                at: CGPoint(x: -1, y: 40)
            ),
            .right
        )
    }

    func testDisplayTransitionDoesNotTreatCornerTouchAsSharedEdge() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let cornerOnly = CGRect(x: -600, y: -500, width: 600, height: 500)

        XCTAssertNil(
            DisplayTransitionPolicy.sharedEntryEdge(
                from: main,
                to: cornerOnly,
                at: CGPoint(x: -1, y: -1)
            )
        )
    }

    func testDropUsesTheAuthoritativeMouseUpZone() {
        XCTAssertEqual(
            SnapDropTargetPolicy.preferredZone(
                detectedZone: .maximize,
                activeZone: .leftHalf,
                activeZoneIsStillValid: true
            ),
            .maximize
        )
    }

    func testDropOnlyFallsBackToAStillValidPreview() {
        XCTAssertEqual(
            SnapDropTargetPolicy.preferredZone(
                detectedZone: nil,
                activeZone: .rightHalf,
                activeZoneIsStillValid: true
            ),
            .rightHalf
        )
        XCTAssertNil(
            SnapDropTargetPolicy.preferredZone(
                detectedZone: nil,
                activeZone: .rightHalf,
                activeZoneIsStillValid: false
            )
        )
    }

    func testMaximizedLayerPreservesTheUnderlyingSplitLayout() {
        XCTAssertFalse(SnapPlacementLayerPolicy.conflicts(
            existing: .leftHalf,
            incoming: .maximize
        ))
        XCTAssertFalse(SnapPlacementLayerPolicy.conflicts(
            existing: .bottomRight,
            incoming: .maximize
        ))
        XCTAssertTrue(SnapPlacementLayerPolicy.conflicts(
            existing: .maximize,
            incoming: .maximize
        ))
    }

    func testReturningToSplitRemovesMaximizedLayerAndKeepsNormalConflicts() {
        XCTAssertTrue(SnapPlacementLayerPolicy.conflicts(
            existing: .maximize,
            incoming: .leftHalf
        ))
        XCTAssertTrue(SnapPlacementLayerPolicy.conflicts(
            existing: .topLeft,
            incoming: .leftHalf
        ))
        XCTAssertFalse(SnapPlacementLayerPolicy.conflicts(
            existing: .rightHalf,
            incoming: .leftHalf
        ))
    }

    func testMaximizedLayerDoesNotCountAsConnectedLayoutMembership() {
        XCTAssertFalse(SnapPlacementLayerPolicy.countsTowardConnectedLayout(.maximize))
        XCTAssertTrue(SnapPlacementLayerPolicy.countsTowardConnectedLayout(.topLeft))
    }

    func testFullHalfExactlyCoversItsTwoQuarterMembers() {
        XCTAssertTrue(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.topRight, .bottomRight],
            incoming: .rightHalf
        ))
        XCTAssertTrue(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.topLeft, .bottomLeft],
            incoming: .leftHalf
        ))
        XCTAssertTrue(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.topLeft, .topRight],
            incoming: .topHalf
        ))
        XCTAssertTrue(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.bottomLeft, .bottomRight],
            incoming: .bottomHalf
        ))
    }

    func testFullGroupCoverRejectsPartialOrUnrelatedOverlap() {
        XCTAssertFalse(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.topRight],
            incoming: .rightHalf
        ))
        XCTAssertFalse(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.topLeft, .bottomLeft],
            incoming: .rightHalf
        ))
        XCTAssertFalse(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.rightHalf, .topRight],
            incoming: .rightHalf
        ))
        XCTAssertFalse(SnapPlacementLayerPolicy.incomingExactlyCovers(
            existingZones: [.topRight, .bottomRight],
            incoming: .maximize
        ))
    }

    func testAssistKeepsOppositeHalfAndOffersOnlyItsMissingQuarter() {
        let zones = AssistLayoutPolicy.layoutZones(
            startingWith: .topRight,
            occupiedZones: [.leftHalf, .topRight]
        )
        var session = LayoutSession(
            excludedCandidateIDs: ["previously-snapped"],
            layoutZones: zones,
            occupiedZones: [
                .leftHalf: "left",
                .topRight: "top-right"
            ]
        )

        XCTAssertEqual(zones, [.leftHalf, .topRight, .bottomRight])
        XCTAssertEqual(session.remainingZones, [.bottomRight])
        session.occupy(.bottomRight, stableIdentity: "bottom-right")
        XCTAssertTrue(session.remainingZones.isEmpty)
        XCTAssertEqual(session.occupiedStableIDs.count, 3)
        XCTAssertEqual(session.excludedCandidateIDs, ["previously-snapped"])
    }

    func testAssistFourWayLayoutOffersOnlyUnoccupiedCornersInOrder() {
        let zones = AssistLayoutPolicy.layoutZones(
            startingWith: .topLeft,
            occupiedZones: [.topLeft]
        )
        var session = LayoutSession(
            layoutZones: zones,
            occupiedZones: [.topLeft: "top-left"]
        )

        XCTAssertEqual(
            session.remainingZones,
            [.topRight, .bottomLeft, .bottomRight]
        )
        session.occupy(.bottomRight, stableIdentity: "bottom-right")
        XCTAssertEqual(session.remainingZones, [.topRight, .bottomLeft])
        session.occupy(.topRight, stableIdentity: "top-right")
        XCTAssertEqual(session.remainingZones, [.bottomLeft])
    }

    func testAssistCompletionLayoutSwitchesOnlyForAdjacentQuarterPairs() {
        let cases: [(Set<SnapZone>, [SnapZone])] = [
            ([.topLeft, .topRight], [.topLeft, .topRight, .bottomHalf]),
            ([.bottomLeft, .bottomRight], [.topHalf, .bottomLeft, .bottomRight]),
            ([.topLeft, .bottomLeft], [.topLeft, .bottomLeft, .rightHalf]),
            ([.topRight, .bottomRight], [.leftHalf, .topRight, .bottomRight])
        ]
        for (occupied, threeWindow) in cases {
            XCTAssertEqual(
                AssistCompletionLayoutPolicy.layoutForModifierState(
                    occupiedZones: occupied,
                    currentLayout:
                        AssistCompletionLayoutPolicy.fourWindowZones,
                    modifierIsPressed: true
                ),
                threeWindow
            )
            XCTAssertEqual(
                AssistCompletionLayoutPolicy.layoutForModifierState(
                    occupiedZones: occupied,
                    currentLayout: threeWindow,
                    modifierIsPressed: false
                ),
                AssistCompletionLayoutPolicy.fourWindowZones
            )
        }
        XCTAssertNil(
            AssistCompletionLayoutPolicy.layoutForModifierState(
                occupiedZones: [.topLeft, .bottomRight],
                currentLayout: AssistCompletionLayoutPolicy.fourWindowZones,
                modifierIsPressed: true
            )
        )
    }

    func testAssistCompletionLayoutSplitsOppositeHalfForEveryAxis() {
        let cases: [(Set<SnapZone>, [SnapZone], [SnapZone])] = [
            ([.leftHalf], [.leftHalf, .rightHalf],
             [.leftHalf, .topRight, .bottomRight]),
            ([.rightHalf], [.leftHalf, .rightHalf],
             [.topLeft, .bottomLeft, .rightHalf]),
            ([.topHalf], [.topHalf, .bottomHalf],
             [.topHalf, .bottomLeft, .bottomRight]),
            ([.bottomHalf], [.topHalf, .bottomHalf],
             [.topLeft, .topRight, .bottomHalf])
        ]
        for (occupied, twoWindow, threeWindow) in cases {
            XCTAssertEqual(
                AssistCompletionLayoutPolicy.layoutForModifierState(
                    occupiedZones: occupied,
                    currentLayout: twoWindow,
                    modifierIsPressed: true
                ),
                threeWindow
            )
            XCTAssertEqual(
                AssistCompletionLayoutPolicy.layoutForModifierState(
                    occupiedZones: occupied,
                    currentLayout: threeWindow,
                    modifierIsPressed: false
                ),
                twoWindow
            )
        }
        XCTAssertNil(
            AssistCompletionLayoutPolicy.threeWindowZonesStartingFromHalf(
                occupiedZones: [.leftHalf, .topRight]
            )
        )
    }

    func testAssistHalfSplitRequiresTwoDistinctQuarterCandidates() {
        let occupied: Set<SnapZone> = [.leftHalf]
        XCTAssertEqual(
            AssistCompletionLayoutPolicy.completionLayoutStartingFromHalf(
                occupiedZones: occupied,
                modifierIsPressed: true,
                oppositeHalfCandidateCount: 2,
                maximumDistinctSplitAssignments: 2
            ),
            [.leftHalf, .topRight, .bottomRight]
        )
        XCTAssertEqual(
            AssistCompletionLayoutPolicy.completionLayoutStartingFromHalf(
                occupiedZones: occupied,
                modifierIsPressed: true,
                oppositeHalfCandidateCount: 1,
                maximumDistinctSplitAssignments: 1
            ),
            [.leftHalf, .rightHalf]
        )
        XCTAssertEqual(
            AssistCompletionLayoutPolicy.completionLayoutStartingFromHalf(
                occupiedZones: occupied,
                modifierIsPressed: false,
                oppositeHalfCandidateCount: 1,
                maximumDistinctSplitAssignments: 2
            ),
            [.leftHalf, .rightHalf]
        )
        XCTAssertNil(
            AssistCompletionLayoutPolicy.completionLayoutStartingFromHalf(
                occupiedZones: occupied,
                modifierIsPressed: false,
                oppositeHalfCandidateCount: 0,
                maximumDistinctSplitAssignments: 2
            )
        )
    }

    func testAssistCompletionLayoutUsesTwoWindowOrMergedOneWindowRules() {
        let occupied: Set<SnapZone> = [.topLeft, .topRight]
        XCTAssertEqual(
            AssistCompletionLayoutPolicy.completionLayout(
                occupiedZones: occupied,
                modifierIsPressed: false,
                maximumDistinctFourWindowAssignments: 2,
                mergedHalfCandidateCount: 1
            ),
            AssistCompletionLayoutPolicy.fourWindowZones
        )
        XCTAssertEqual(
            AssistCompletionLayoutPolicy.completionLayout(
                occupiedZones: occupied,
                modifierIsPressed: false,
                maximumDistinctFourWindowAssignments: 1,
                mergedHalfCandidateCount: 1
            ),
            [.topLeft, .topRight, .bottomHalf]
        )
        XCTAssertEqual(
            AssistCompletionLayoutPolicy.completionLayout(
                occupiedZones: occupied,
                modifierIsPressed: true,
                maximumDistinctFourWindowAssignments: 2,
                mergedHalfCandidateCount: 1
            ),
            [.topLeft, .topRight, .bottomHalf]
        )
        XCTAssertNil(
            AssistCompletionLayoutPolicy.completionLayout(
                occupiedZones: occupied,
                modifierIsPressed: false,
                maximumDistinctFourWindowAssignments: 0,
                mergedHalfCandidateCount: 0
            )
        )
        XCTAssertNil(
            AssistCompletionLayoutPolicy.completionLayout(
                occupiedZones: occupied,
                modifierIsPressed: true,
                maximumDistinctFourWindowAssignments: 2,
                mergedHalfCandidateCount: 0
            )
        )
    }

    func testAssistLayoutModifierAcceptsOnlyOption() {
        XCTAssertTrue(
            AssistLayoutModifierPolicy.isPressed(in: .maskAlternate)
        )
        XCTAssertFalse(
            AssistLayoutModifierPolicy.isPressed(in: .maskShift)
        )
        XCTAssertFalse(
            AssistLayoutModifierPolicy.isPressed(in: .maskCommand)
        )
    }

    func testAssistCandidateCompletionRequiresDistinctWindows() {
        let zones: [SnapZone] = [.bottomLeft, .bottomRight]
        XCTAssertEqual(
            AssistCandidateAssignmentPolicy.maximumDistinctAssignmentCount(
                zones: zones,
                candidateIDsByZone: [
                    .bottomLeft: ["only"],
                    .bottomRight: ["only"]
                ]
            ),
            1
        )
        XCTAssertEqual(
            AssistCandidateAssignmentPolicy.maximumDistinctAssignmentCount(
                zones: zones,
                candidateIDsByZone: [
                    .bottomLeft: ["first", "second"],
                    .bottomRight: ["second"]
                ]
            ),
            2
        )
    }

    func testAssistThreeWayPoliciesAreSymmetricForEveryHalf() {
        XCTAssertEqual(
            AssistLayoutPolicy.layoutZones(
                startingWith: .bottomLeft,
                occupiedZones: [.topHalf, .bottomLeft]
            ),
            [.topHalf, .bottomLeft, .bottomRight]
        )
        XCTAssertEqual(
            AssistLayoutPolicy.layoutZones(
                startingWith: .topLeft,
                occupiedZones: [.bottomHalf, .topLeft]
            ),
            [.topLeft, .topRight, .bottomHalf]
        )
        XCTAssertEqual(
            AssistLayoutPolicy.layoutZones(
                startingWith: .bottomLeft,
                occupiedZones: [.rightHalf, .bottomLeft]
            ),
            [.rightHalf, .bottomLeft, .topLeft]
        )
        XCTAssertEqual(
            AssistLayoutPolicy.layoutZones(
                startingWith: .topRight,
                occupiedZones: [.leftHalf, .topRight]
            ),
            [.leftHalf, .topRight, .bottomRight]
        )
    }
    func testExpandedSideSelectionUsesOnlyEqualTopAndBottomHalves() {
        XCTAssertEqual(
            ExpandedSideSelectionPolicy.zone(relativeY: 0.49, isLeftEdge: true),
            .bottomLeft
        )
        XCTAssertEqual(
            ExpandedSideSelectionPolicy.zone(relativeY: 0.5, isLeftEdge: true),
            .topLeft
        )
        XCTAssertEqual(
            ExpandedSideSelectionPolicy.zone(relativeY: 0.49, isLeftEdge: false),
            .bottomRight
        )
        XCTAssertEqual(
            ExpandedSideSelectionPolicy.zone(relativeY: 0.5, isLeftEdge: false),
            .topRight
        )
        XCTAssertEqual(
            ExpandedSideSelectionPolicy.candidateZones(isLeftEdge: true),
            [.topLeft, .bottomLeft]
        )
        XCTAssertEqual(
            ExpandedSideSelectionPolicy.candidateZones(isLeftEdge: false),
            [.topRight, .bottomRight]
        )
    }

    func testExpandedSideGuideKeepsOuterMarginWithoutMiddleGap() {
        let top = CGRect(x: 0, y: 450, width: 720, height: 450)
        let bottom = CGRect(x: 0, y: 0, width: 720, height: 450)
        let guides = ExpandedSideSelectionPolicy.guideFrames(
            candidateFrames: [top, bottom],
            outerInset: 6
        )

        XCTAssertEqual(guides.count, 2)
        XCTAssertEqual(guides[0], CGRect(
            x: 6, y: 450, width: 708, height: 444
        ))
        XCTAssertEqual(guides[1], CGRect(
            x: 6, y: 6, width: 708, height: 444
        ))
        XCTAssertEqual(guides[0].minY, guides[1].maxY)
    }
    private let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testDetectsEdgesAndCorners() {
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 0, y: 899), in: screenFrame), .topLeft)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 1_439, y: 899), in: screenFrame), .topRight)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 0, y: 1), in: screenFrame), .bottomLeft)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 1_439, y: 1), in: screenFrame), .bottomRight)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 0, y: 450), in: screenFrame), .leftHalf)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 1_439, y: 450), in: screenFrame), .rightHalf)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 720, y: 899), in: screenFrame), .maximize)
        XCTAssertNil(SnapZone.detect(at: CGPoint(x: 720, y: 0), in: screenFrame))
        XCTAssertNil(SnapZone.detect(at: CGPoint(x: 720, y: 450), in: screenFrame))
    }

    func testNegativeThresholdsAreClampedToZero() {
        XCTAssertEqual(
            SnapZone.detect(
                at: CGPoint(x: 0, y: 450),
                in: screenFrame,
                edgeThreshold: -20,
                cornerBand: -20
            ),
            .leftHalf
        )
    }

    func testRequiredOuterEdges() {
        XCTAssertEqual(SnapZone.leftHalf.requiredOuterEdges, [.left, .top, .bottom])
        XCTAssertEqual(SnapZone.topRight.requiredOuterEdges, [.right, .top])
        XCTAssertEqual(SnapZone.maximize.requiredOuterEdges, .all)
    }

    func testVerticalSiblingIsSymmetric() {
        for zone in [SnapZone.topLeft, .topRight, .bottomLeft, .bottomRight] {
            XCTAssertEqual(zone.verticalSibling.verticalSibling, zone)
        }
    }

    func testRawValuesRoundTrip() throws {
        let encoded = try JSONEncoder().encode(SnapZone.allCases)
        let decoded = try JSONDecoder().decode([SnapZone].self, from: encoded)
        XCTAssertEqual(decoded, SnapZone.allCases)
    }
}
