import AppKit
import XCTest
@testable import Tabora

final class SnapZoneTests: XCTestCase {
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
