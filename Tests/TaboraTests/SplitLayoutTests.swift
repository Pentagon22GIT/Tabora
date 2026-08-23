import AppKit
import XCTest
@testable import Tabora

final class SplitLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testContentDragIsNotClassifiedAsAPlainClick() {
        XCTAssertFalse(PointerInteractionPolicy.isDrag(maximumDistance: 4))
        XCTAssertTrue(PointerInteractionPolicy.isDrag(maximumDistance: 4.01))
        XCTAssertFalse(
            PointerInteractionPolicy.isDrag(maximumDistance: CGFloat.nan)
        )
    }

    func testOppositeVerticalSnapUsesRemainingFortyPercent() {
        let bottom = SplitPlacementGeometry(
            stableIdentity: "bottom",
            zone: .bottomHalf,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 540)
        )
        let result = SplitLayoutGeometry.resolvedFrame(
            for: .topHalf,
            in: screen,
            placements: [bottom]
        )
        XCTAssertEqual(result, CGRect(x: 0, y: 540, width: 1_440, height: 360))
    }

    func testDistinctFocusedSurfaceVetoesAutomaticGroupRaise() {
        XCTAssertTrue(ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "popup",
            mainIdentity: "finder-window"
        ).hasDistinctFocusedSurface)
        XCTAssertFalse(ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "finder-window",
            mainIdentity: "finder-window"
        ).hasDistinctFocusedSurface)
    }

    func testOppositeSnapUsesRemainingFortyPercent() {
        let left = SplitPlacementGeometry(
            stableIdentity: "left",
            zone: .leftHalf,
            frame: CGRect(x: 0, y: 0, width: 864, height: 900)
        )
        let result = SplitLayoutGeometry.resolvedFrame(
            for: .rightHalf,
            in: screen,
            placements: [left]
        )
        XCTAssertEqual(result, CGRect(x: 864, y: 0, width: 576, height: 900))
    }

    func testFullHeightSnapUsesSafeBoundaryAcrossDiscontinuousRows() {
        let topLeft = SplitPlacementGeometry(
            stableIdentity: "top-left",
            zone: .topLeft,
            frame: CGRect(x: 0, y: 450, width: 864, height: 450)
        )
        let bottomLeft = SplitPlacementGeometry(
            stableIdentity: "bottom-left",
            zone: .bottomLeft,
            frame: CGRect(x: 0, y: 0, width: 720, height: 450)
        )
        let result = SplitLayoutGeometry.resolvedFrame(
            for: .rightHalf,
            in: screen,
            placements: [topLeft, bottomLeft]
        )
        XCTAssertEqual(result.minX, 864)
        XCTAssertEqual(result.maxX, screen.maxX)
    }

    func testQuarterGuidesShareBothDividersFromExistingQuarter() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let topLeft = SplitPlacementGeometry(
            stableIdentity: "top-left",
            zone: .topLeft,
            frame: CGRect(x: 0, y: 400, width: 600, height: 600)
        )
        XCTAssertEqual(
            SplitLayoutGeometry.resolvedFrame(
                for: .topRight,
                in: frame,
                placements: [topLeft]
            ),
            CGRect(x: 600, y: 400, width: 400, height: 600)
        )
        XCTAssertEqual(
            SplitLayoutGeometry.resolvedFrame(
                for: .bottomLeft,
                in: frame,
                placements: [topLeft]
            ),
            CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        XCTAssertEqual(
            SplitLayoutGeometry.resolvedFrame(
                for: .bottomRight,
                in: frame,
                placements: [topLeft]
            ),
            CGRect(x: 600, y: 0, width: 400, height: 400)
        )
    }

    func testQuarterRelationsOnlyLinkTheSharedFace() {
        XCTAssertEqual(
            SplitLayoutGeometry.relationDirection(
                driverZone: .topLeft,
                followerZone: .topRight,
                in: screen
            ),
            .right
        )
        XCTAssertNil(
            SplitLayoutGeometry.relationDirection(
                driverZone: .topLeft,
                followerZone: .bottomRight,
                in: screen
            )
        )
    }

    func testQuarterSnapDeclaresBothBoundaryAxes() {
        XCTAssertEqual(
            SplitLayoutGeometry.splitAxes(for: .topLeft),
            Set([.horizontal, .vertical])
        )
        XCTAssertEqual(
            SplitLayoutGeometry.splitAxes(for: .rightHalf),
            Set([.horizontal])
        )
    }

    func testQuarterZonesJoinTheSameVerticalBoundaryFromOppositeSides() {
        XCTAssertEqual(
            SplitLayoutGeometry.boundarySide(for: .topLeft, axis: .horizontal),
            .nearOrigin
        )
        XCTAssertEqual(
            SplitLayoutGeometry.boundarySide(for: .bottomRight, axis: .horizontal),
            .farOrigin
        )
        XCTAssertEqual(
            SplitLayoutGeometry.perpendicularBands(for: .topLeft, axis: .horizontal),
            Set([.first])
        )
        XCTAssertEqual(
            SplitLayoutGeometry.perpendicularBands(for: .bottomLeft, axis: .horizontal),
            Set([.second])
        )
    }

    func testUnevenRowJoinsOnlyAfterDriverCatchesItsBoundary() {
        XCTAssertFalse(
            SplitLayoutGeometry.hasReachedBoundary(
                initialCoordinate: 600,
                currentCoordinate: 740,
                participantCoordinates: [800, 800]
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.hasReachedBoundary(
                initialCoordinate: 600,
                currentCoordinate: 792,
                participantCoordinates: [800, 800]
            )
        )
    }

    func testJoinedVerticalBoundaryResizesBothSidesToOneCoordinate() {
        let left = SplitLayoutGeometry.frame(
            CGRect(x: 0, y: 0, width: 720, height: 450),
            meetingBoundary: 840,
            side: .nearOrigin,
            axis: .horizontal
        )
        let right = SplitLayoutGeometry.frame(
            CGRect(x: 720, y: 0, width: 720, height: 450),
            meetingBoundary: 840,
            side: .farOrigin,
            axis: .horizontal
        )
        XCTAssertEqual(left.maxX, 840)
        XCTAssertEqual(right.minX, 840)
        XCTAssertEqual(right.maxX, 1_440)
    }

    func testExistingOverlapWaitsUntilActualContact() {
        XCTAssertFalse(
            SplitLayoutGeometry.hasReachedContact(
                initialMismatch: 60,
                currentMismatch: 30
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.hasReachedContact(
                initialMismatch: 60,
                currentMismatch: 8
            )
        )
    }

    func testBoundaryAnchorKeepsTheOppositeOuterEdgeStable() {
        XCTAssertEqual(
            SplitLayoutGeometry.boundaryAnchor(
                sides: [.horizontal: .nearOrigin],
                activeAxes: [.horizontal]
            ),
            CGPoint(x: 0, y: 0.5)
        )
        XCTAssertEqual(
            SplitLayoutGeometry.boundaryAnchor(
                sides: [.horizontal: .farOrigin],
                activeAxes: [.horizontal]
            ),
            CGPoint(x: 1, y: 0.5)
        )
        XCTAssertEqual(
            SplitLayoutGeometry.boundaryAnchor(
                sides: [
                    .horizontal: .nearOrigin,
                    .vertical: .farOrigin
                ],
                activeAxes: [.horizontal, .vertical]
            ),
            CGPoint(x: 0, y: 1)
        )
    }

    func testFollowerKeepsItsFarEdge() {
        let follower = CGRect(x: 720, y: 0, width: 720, height: 900)
        let driver = CGRect(x: 0, y: 0, width: 900, height: 900)
        let target = SplitLayoutGeometry.followerTarget(
            direction: .right,
            driverFrame: driver,
            followerFrame: follower
        )
        XCTAssertEqual(target.minX, 900)
        XCTAssertEqual(target.maxX, 1_440)
    }

    func testNewSplitInvasionUsesTheCandidateConstraintReference() {
        XCTAssertEqual(
            SplitLayoutGeometry.invasionRatio(
                requestedLength: 300,
                acceptedLength: 600,
                referenceLength: 600
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            SplitLayoutGeometry.invasionRatio(
                requestedLength: 144,
                acceptedLength: 144,
                referenceLength: 720
            ),
            0.5
        )
    }

    func testRatioHysteresisPreventsVirtualBoxFlicker() {
        let reference = CGSize(width: 600, height: 400)
        XCTAssertTrue(
            SplitLayoutGeometry.isBeyondTolerance(
                targetFrame: CGRect(x: 0, y: 0, width: 290, height: 400),
                direction: .right,
                referenceSize: reference,
                tolerance: 0.5
            )
        )
        XCTAssertFalse(
            SplitLayoutGeometry.canResume(
                targetFrame: CGRect(x: 0, y: 0, width: 320, height: 400),
                direction: .right,
                referenceSize: reference,
                tolerance: 0.5
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.canResume(
                targetFrame: CGRect(x: 0, y: 0, width: 340, height: 400),
                direction: .right,
                referenceSize: reference,
                tolerance: 0.5
            )
        )
    }

    func testStraightBoundaryAllowsThreeMemberPartitionReplacement() {
        let displaced = [
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 450)
            )
        ]
        let retained = [
            SplitPlacementGeometry(
                stableIdentity: "left",
                zone: .leftHalf,
                frame: CGRect(x: 0, y: 0, width: 720, height: 900)
            )
        ]

        XCTAssertTrue(
            SplitLayoutGeometry.hasStraightSharedBoundaryBetweenPartitions(
                displacedPlacements: displaced,
                retainedPlacements: retained
            )
        )
    }

    func testStraightBoundaryAllowsFourToThreeReplacement() {
        let displaced = [
            SplitPlacementGeometry(
                stableIdentity: "top-left",
                zone: .topLeft,
                frame: CGRect(x: 0, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-left",
                zone: .bottomLeft,
                frame: CGRect(x: 0, y: 0, width: 720, height: 450)
            )
        ]
        let retained = [
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 450)
            )
        ]

        XCTAssertTrue(
            SplitLayoutGeometry.hasStraightSharedBoundaryBetweenPartitions(
                displacedPlacements: displaced,
                retainedPlacements: retained
            )
        )
    }

    func testMisalignedCrossPartitionBoundaryBlocksMultiMemberReplacement() {
        let displaced = [
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 724, y: 0, width: 716, height: 450)
            )
        ]
        let retained = [
            SplitPlacementGeometry(
                stableIdentity: "left",
                zone: .leftHalf,
                frame: CGRect(x: 0, y: 0, width: 720, height: 900)
            )
        ]

        XCTAssertFalse(
            SplitLayoutGeometry.hasStraightSharedBoundaryBetweenPartitions(
                displacedPlacements: displaced,
                retainedPlacements: retained
            )
        )
    }

    func testCrossPartitionBoundariesOnTwoAxesAreNotStraight() {
        let displaced = [
            SplitPlacementGeometry(
                stableIdentity: "top-left",
                zone: .topLeft,
                frame: CGRect(x: 0, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 450)
            )
        ]
        let retained = [
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-left",
                zone: .bottomLeft,
                frame: CGRect(x: 0, y: 0, width: 720, height: 450)
            )
        ]

        XCTAssertFalse(
            SplitLayoutGeometry.hasStraightSharedBoundaryBetweenPartitions(
                displacedPlacements: displaced,
                retainedPlacements: retained
            )
        )
    }

    func testResizeHandleJoinsAFullHeightWindowToTwoQuarterWindows() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "left",
                zone: .leftHalf,
                frame: CGRect(x: 0, y: 0, width: 720, height: 900)
            ),
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 450)
            )
        ]
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements
        )
        XCTAssertEqual(handles.count, 2)
        let verticalBoundary = handles.first { $0.axis == .horizontal }
        XCTAssertEqual(verticalBoundary?.coordinate, 720)
        XCTAssertEqual(verticalBoundary?.span, 0...900)
        XCTAssertEqual(
            verticalBoundary?.participantIDs,
            Set(["left", "top-right", "bottom-right"])
        )
        let rightHorizontalBoundary = handles.first { $0.axis == .vertical }
        XCTAssertEqual(rightHorizontalBoundary?.coordinate, 450)
        XCTAssertEqual(rightHorizontalBoundary?.span, 720...1_440)
        XCTAssertEqual(
            rightHorizontalBoundary?.participantIDs,
            Set(["top-right", "bottom-right"])
        )
    }

    func testProposedTopologyConnectsAFullHeightWindowToTwoQuarterWindows() {
        let handles = SplitLayoutGeometry.proposedResizeHandleGeometries(
            zonesByIdentity: [
                "left": .leftHalf,
                "top-right": .topRight,
                "bottom-right": .bottomRight
            ],
            in: screen
        )
        let connected = SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: "left",
            handles: handles
        )
        XCTAssertEqual(connected, Set(["left", "top-right", "bottom-right"]))
        XCTAssertEqual(
            handles.first(where: { $0.axis == .horizontal })?.participantIDs,
            Set(["left", "top-right", "bottom-right"])
        )
    }

    func testProposedTopologyIsAxisSymmetricForAFullWidthWindowAndTwoQuarters() {
        let handles = SplitLayoutGeometry.proposedResizeHandleGeometries(
            zonesByIdentity: [
                "top": .topHalf,
                "bottom-left": .bottomLeft,
                "bottom-right": .bottomRight
            ],
            in: screen
        )
        let connected = SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: "top",
            handles: handles
        )
        XCTAssertEqual(connected, Set(["top", "bottom-left", "bottom-right"]))
        XCTAssertEqual(
            handles.first(where: { $0.axis == .vertical })?.participantIDs,
            Set(["top", "bottom-left", "bottom-right"])
        )
    }


    func testProposedFourQuarterTopologyKeepsIndependentRowAndColumnBoundaries() {
        let handles = SplitLayoutGeometry.proposedResizeHandleGeometries(
            zonesByIdentity: [
                "top-left": .topLeft,
                "top-right": .topRight,
                "bottom-left": .bottomLeft,
                "bottom-right": .bottomRight
            ],
            in: screen
        )

        let verticalDividers = handles.filter { $0.axis == .horizontal }
        let horizontalDividers = handles.filter { $0.axis == .vertical }
        XCTAssertEqual(verticalDividers.count, 2)
        XCTAssertEqual(horizontalDividers.count, 2)
        XCTAssertEqual(
            Set(verticalDividers.map(\.participantIDs)),
            Set([
                Set(["top-left", "top-right"]),
                Set(["bottom-left", "bottom-right"])
            ])
        )
        XCTAssertEqual(
            Set(horizontalDividers.map(\.participantIDs)),
            Set([
                Set(["top-left", "bottom-left"]),
                Set(["top-right", "bottom-right"])
            ])
        )
    }


    func testCanonicalConstraintPartitionUsesEmptySiblingAsLayoutSlack() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var topRightLimits = AppConstraintLimits.unknown
        topRightLimits.minHeight = 600
        let result = SplitLayoutGeometry.canonicalConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "left", zone: .leftHalf,
                    referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right", zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 500, width: 500, height: 500),
                    limits: topRightLimits
                )
            ],
            incomingIdentity: "top-right",
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected the empty bottom-right cell to provide layout slack")
        }
        XCTAssertEqual(frames["top-right"]?.height ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["top-right"]?.minY ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(frames["left"]?.height ?? -1, 1000, accuracy: 0.001)
    }

    func testCanonicalConstraintPartitionPreservesExistingDividerWhenAddingSibling() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let result = SplitLayoutGeometry.canonicalConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right", zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 400, width: 500, height: 600),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-right", zone: .bottomRight,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
                    limits: .unknown
                )
            ],
            incomingIdentity: "bottom-right",
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected a connected right-column partition")
        }
        XCTAssertEqual(frames["top-right"]?.minY ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-right"]?.height ?? -1, 400, accuracy: 0.001)
    }

    func testCanonicalFourQuarterPartitionPropagatesBothDividers() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var strong = AppConstraintLimits.unknown
        strong.minWidth = 600
        strong.minHeight = 600
        let result = SplitLayoutGeometry.canonicalConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-left", zone: .topLeft,
                    referenceFrame: CGRect(x: 0, y: 500, width: 500, height: 500),
                    limits: strong
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right", zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 500, width: 500, height: 500),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-left", zone: .bottomLeft,
                    referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-right", zone: .bottomRight,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
                    limits: .unknown
                )
            ],
            incomingIdentity: "top-left",
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected a canonical four-cell partition")
        }
        XCTAssertEqual(frames["top-left"]?.width ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-left"]?.width ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["top-right"]?.minX ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-right"]?.minX ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["top-left"]?.height ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["top-right"]?.height ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-left"]?.height ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-right"]?.height ?? -1, 400, accuracy: 0.001)
    }

    func testCanonicalPartitionRejectsOnlyConfirmedConstraintConflict() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var leftLimits = AppConstraintLimits.unknown
        leftLimits.minWidth = 600
        var rightLimits = AppConstraintLimits.unknown
        rightLimits.minWidth = 500
        let result = SplitLayoutGeometry.canonicalConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "left", zone: .leftHalf,
                    referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                    limits: leftLimits
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "right", zone: .rightHalf,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 1000),
                    limits: rightLimits
                )
            ],
            incomingIdentity: "right",
            in: frame
        )
        guard case .confirmedInfeasible = result else {
            return XCTFail("600 + 500 cannot fit in a 1000-point partition")
        }
    }

    func testCanonicalPartitionRejectsDisconnectedDiagonalPartialGroup() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let result = SplitLayoutGeometry.canonicalConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-left", zone: .topLeft,
                    referenceFrame: CGRect(x: 0, y: 500, width: 500, height: 500),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-right", zone: .bottomRight,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
                    limits: .unknown
                )
            ],
            incomingIdentity: "bottom-right",
            in: frame
        )
        guard case .confirmedInfeasible = result else {
            return XCTFail("Diagonal-only cells do not form one split group")
        }
    }

    func testAdaptiveConstraintPartitionUsesIncomingConstraintWithoutResizingNonAdjacentHalf() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var incomingLimits = AppConstraintLimits.unknown
        incomingLimits.minHeight = 600
        let result = SplitLayoutGeometry.adaptiveConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "left",
                    zone: .leftHalf,
                    referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right",
                    zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 500, width: 500, height: 500),
                    limits: incomingLimits
                )
            ],
            incomingIdentity: "top-right",
            preferredIncomingFrame: CGRect(
                x: 500, y: 500, width: 500, height: 500
            ),
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected empty bottom-right slack to absorb the incoming minimum")
        }
        XCTAssertEqual(frames["top-right"]?.height ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["top-right"]?.minY ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(frames["left"], CGRect(x: 0, y: 0, width: 500, height: 1000))
    }

    func testAdaptiveConstraintPartitionTwoMemberPrefersIncomingBoundaryWhenItIsLegal() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let result = SplitLayoutGeometry.adaptiveConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "left",
                    zone: .leftHalf,
                    referenceFrame: CGRect(x: 0, y: 0, width: 600, height: 1000),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "right",
                    zone: .rightHalf,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 1000),
                    limits: .unknown
                )
            ],
            incomingIdentity: "right",
            preferredIncomingFrame: CGRect(x: 500, y: 0, width: 500, height: 1000),
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected a feasible two-member partition")
        }
        XCTAssertEqual(frames["left"]?.width ?? -1, 500, accuracy: 0.001)
        XCTAssertEqual(frames["right"]?.width ?? -1, 500, accuracy: 0.001)
    }

    func testAdaptiveConstraintPartitionPrefersIncomingBoundaryWhenItIsLegal() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var incomingLimits = AppConstraintLimits.unknown
        incomingLimits.minHeight = 250
        let result = SplitLayoutGeometry.adaptiveConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right",
                    zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 400, width: 500, height: 600),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-right",
                    zone: .bottomRight,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
                    limits: incomingLimits
                )
            ],
            incomingIdentity: "bottom-right",
            preferredIncomingFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected connected right-column partition")
        }
        // Existing 60/40 geometry is not authority. The user selected the
        // bottom-right quarter, so the legal 50% boundary is restored.
        XCTAssertEqual(frames["top-right"]?.minY ?? -1, 500, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-right"]?.height ?? -1, 500, accuracy: 0.001)
    }

    func testAdaptiveConstraintPartitionClampsIncomingBoundaryOnlyWhenKnownMinimumRequiresIt() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var incomingLimits = AppConstraintLimits.unknown
        incomingLimits.minHeight = 600
        var siblingLimits = AppConstraintLimits.unknown
        siblingLimits.minHeight = 300
        let result = SplitLayoutGeometry.adaptiveConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right",
                    zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 500, width: 500, height: 500),
                    limits: siblingLimits
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-right",
                    zone: .bottomRight,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
                    limits: incomingLimits
                )
            ],
            incomingIdentity: "bottom-right",
            preferredIncomingFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected incoming minimum to shift the shared boundary")
        }
        XCTAssertEqual(frames["bottom-right"]?.height ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["top-right"]?.height ?? -1, 400, accuracy: 0.001)
    }

    func testAdaptiveConstraintPartitionRejectsOnlyWhenCombinedMinimumsAreTrulyInfeasible() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var leftLimits = AppConstraintLimits.unknown
        leftLimits.minWidth = 600
        var rightLimits = AppConstraintLimits.unknown
        rightLimits.minWidth = 500
        let result = SplitLayoutGeometry.adaptiveConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "left", zone: .leftHalf,
                    referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                    limits: leftLimits
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "right", zone: .rightHalf,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 1000),
                    limits: rightLimits
                )
            ],
            incomingIdentity: "right",
            preferredIncomingFrame: CGRect(x: 500, y: 0, width: 500, height: 1000),
            in: frame
        )
        guard case .confirmedInfeasible = result else {
            return XCTFail("600 + 500 cannot fit in a 1000-point shared boundary")
        }
    }

    func testAdaptiveConstraintPartitionThreeMemberRightColumnReflowsAroundKnownMinimum() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var topLimits = AppConstraintLimits.unknown
        topLimits.minHeight = 600
        var bottomLimits = AppConstraintLimits.unknown
        bottomLimits.minHeight = 300
        let result = SplitLayoutGeometry.adaptiveConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "left", zone: .leftHalf,
                    referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right", zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 500, width: 500, height: 500),
                    limits: topLimits
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-right", zone: .bottomRight,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
                    limits: bottomLimits
                )
            ],
            incomingIdentity: "bottom-right",
            preferredIncomingFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected the right-column shared boundary to reflow")
        }
        XCTAssertEqual(frames["left"], CGRect(x: 0, y: 0, width: 500, height: 1000))
        XCTAssertEqual(frames["top-right"]?.height ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-right"]?.height ?? -1, 400, accuracy: 0.001)
    }

    func testAdaptiveConstraintPartitionFourQuarterTopologyUnifiesBothAxes() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var topRightLimits = AppConstraintLimits.unknown
        topRightLimits.minHeight = 600
        var bottomRightLimits = AppConstraintLimits.unknown
        bottomRightLimits.minHeight = 300
        let result = SplitLayoutGeometry.adaptiveConstraintPartition(
            members: [
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-left", zone: .topLeft,
                    referenceFrame: CGRect(x: 0, y: 500, width: 500, height: 500),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-left", zone: .bottomLeft,
                    referenceFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
                    limits: .unknown
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "top-right", zone: .topRight,
                    referenceFrame: CGRect(x: 500, y: 500, width: 500, height: 500),
                    limits: topRightLimits
                ),
                CanonicalSplitPartitionMember(
                    stableIdentity: "bottom-right", zone: .bottomRight,
                    referenceFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
                    limits: bottomRightLimits
                )
            ],
            incomingIdentity: "bottom-right",
            preferredIncomingFrame: CGRect(x: 500, y: 0, width: 500, height: 500),
            in: frame
        )
        guard case .ready(let frames) = result else {
            return XCTFail("Expected a feasible four-quarter adaptive topology")
        }
        XCTAssertEqual(frames["top-left"]?.minY ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-left"]?.height ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(frames["top-right"]?.height ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(frames["bottom-right"]?.height ?? -1, 400, accuracy: 0.001)
    }

    func testFourQuartersMergeBothBoundariesAcrossTheFullSharedSpan() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "top-left",
                zone: .topLeft,
                frame: CGRect(x: 0, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-left",
                zone: .bottomLeft,
                frame: CGRect(x: 0, y: 0, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 450)
            )
        ]
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements
        )
        XCTAssertEqual(handles.count, 2)
        let verticalBoundary = handles.first { $0.axis == .horizontal }
        XCTAssertEqual(verticalBoundary?.coordinate, 720)
        XCTAssertEqual(verticalBoundary?.span, 0...900)
        XCTAssertEqual(verticalBoundary?.participantIDs.count, 4)
        let horizontalBoundary = handles.first { $0.axis == .vertical }
        XCTAssertEqual(horizontalBoundary?.coordinate, 450)
        XCTAssertEqual(horizontalBoundary?.span, 0...1_440)
        XCTAssertEqual(horizontalBoundary?.participantIDs.count, 4)
    }

    func testNearlyAlignedRowsRemainIndependentUntilFramesActuallyMatch() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "top-left",
                zone: .topLeft,
                frame: CGRect(x: 0, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-left",
                zone: .bottomLeft,
                frame: CGRect(x: 0, y: 0, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 456, width: 720, height: 444)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 456)
            )
        ]
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements
        )
        let rowHandles = handles.filter { $0.axis == .vertical }
        XCTAssertEqual(rowHandles.count, 2)
        XCTAssertEqual(Set(rowHandles.map(\.coordinate)), Set([450, 456]))
        XCTAssertEqual(
            rowHandles.map(\.span).sorted {
                $0.lowerBound < $1.lowerBound
            },
            [0...720, 720...1_440]
        )
    }

    func testOnlyWindowsAboveAHandleParticipantCanOccludeIt() {
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 100,
                pid: 20,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 2,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 1,
                pid: 11,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 5,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 101,
                pid: 21,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 7,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 2,
                pid: 12,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 10,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 102,
                pid: 22,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 12,
                layer: 0
            )
        ]
        let occluders = AXWindowService().occludingWindows(
            above: [
                WindowOcclusionParticipant(
                    pid: 11,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    windowID: 1
                ),
                WindowOcclusionParticipant(
                    pid: 12,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    windowID: 2
                )
            ],
            in: snapshot
        )
        XCTAssertEqual(Set(occluders?.map(\.windowID) ?? []), Set([100, 101]))
    }

    func testOcclusionMatchingRecoversFromAStaleParticipantWindowID() {
        let leftFrame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let rightFrame = CGRect(x: 720, y: 0, width: 720, height: 900)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 90,
                pid: 30,
                frame: CGRect(x: 680, y: 200, width: 300, height: 300),
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: leftFrame,
                zIndex: 3,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 20,
                pid: 12,
                frame: rightFrame,
                zIndex: 4,
                layer: 0
            )
        ]
        let occluders = AXWindowService().occludingWindows(
            above: [
                WindowOcclusionParticipant(
                    pid: 11,
                    frame: leftFrame,
                    windowID: 999
                ),
                WindowOcclusionParticipant(
                    pid: 12,
                    frame: rightFrame,
                    windowID: 20
                )
            ],
            in: snapshot
        )
        XCTAssertEqual(occluders?.map(\.windowID), [90])
    }

    func testAmbiguousParticipantMatchFailsClosed() {
        let frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 11,
                frame: frame,
                zIndex: 2,
                layer: 0
            )
        ]
        XCTAssertNil(
            AXWindowService().occludingWindows(
                above: [
                    WindowOcclusionParticipant(
                        pid: 11,
                        frame: frame,
                        windowID: nil
                    )
                ],
                in: snapshot
            )
        )
    }

    func testKnownWindowIDWinsOverAmbiguousGeometry() {
        let frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 11,
                frame: frame,
                zIndex: 2,
                layer: 0
            )
        ]
        XCTAssertEqual(
            AXWindowService().occludingWindows(
                above: [
                    WindowOcclusionParticipant(
                        pid: 11,
                        frame: frame,
                        windowID: 11
                    )
                ],
                in: snapshot
            )?.map(\.windowID),
            [10]
        )
    }

    func testReusedWindowIDWithWrongGeometryFallsBackToCurrentWindow() {
        let currentFrame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let reusedIDFrame = CGRect(x: 900, y: 100, width: 300, height: 400)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 90,
                pid: 30,
                frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: reusedIDFrame,
                zIndex: 2,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 11,
                frame: currentFrame,
                zIndex: 3,
                layer: 0
            )
        ]
        XCTAssertEqual(
            AXWindowService().occludingWindows(
                above: [
                    WindowOcclusionParticipant(
                        pid: 11,
                        frame: currentFrame,
                        windowID: 10
                    )
                ],
                in: snapshot
            )?.map(\.windowID),
            [90, 10]
        )
    }

    func testJunctionWaitsForIntentAndLocksToTheDominantDragAxis() {
        XCTAssertNil(
            SplitLayoutGeometry.resizeAxis(
                forDragDelta: CGPoint(x: 2, y: 1)
            )
        )
        XCTAssertEqual(
            SplitLayoutGeometry.resizeAxis(
                forDragDelta: CGPoint(x: 8, y: 3)
            ),
            .horizontal
        )
        XCTAssertEqual(
            SplitLayoutGeometry.resizeAxis(
                forDragDelta: CGPoint(x: 3, y: -8)
            ),
            .vertical
        )
    }

    func testMacStandaloneBoundaryKeepsTheVisibleCenterControlAsInput() {
        let verticalDivider = ResizeHandleDescriptor(
            id: "vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"],
            presentationStyle: .mac
        )
        XCTAssertEqual(
            verticalDivider.interactionFrame(),
            CGRect(x: 716, y: 428, width: 8, height: 44)
        )

        let horizontalDivider = ResizeHandleDescriptor(
            id: "horizontal-divider",
            displayID: 1,
            axis: .vertical,
            coordinate: 450,
            span: 0...1_440,
            screenFrame: screen,
            participantIDs: ["top", "bottom"],
            presentationStyle: .mac
        )
        XCTAssertEqual(
            horizontalDivider.interactionFrame(),
            CGRect(x: 698, y: 446, width: 44, height: 8)
        )
    }

    func testCombinedBoundaryStaysThinnerThanWindowsBoundary() {
        XCTAssertLessThan(
            ResizeHandleDescriptor.combinedBoundaryIdleThickness,
            ResizeHandleDescriptor.windowsBoundaryIdleThickness
        )
        XCTAssertLessThan(
            ResizeHandleDescriptor.combinedBoundaryActiveThickness,
            ResizeHandleDescriptor.windowsBoundaryActiveThickness
        )
    }

    func testBoundaryPresentationsUseTheSharedBoundaryInputFrame() {
        for style in [
            LinkedResizePresentationStyle.windows,
            LinkedResizePresentationStyle.combined
        ] {
            let descriptor = ResizeHandleDescriptor(
                id: "vertical-divider",
                displayID: 1,
                axis: .horizontal,
                coordinate: 720,
                span: 0...900,
                screenFrame: screen,
                participantIDs: ["left", "right"],
                presentationStyle: style
            )
            XCTAssertEqual(
                descriptor.interactionFrame(),
                CGRect(x: 714, y: 0, width: 12, height: 900)
            )
        }
    }

    func testActiveJunctionFollowsBeyondItsOriginalTShapeEndpoint() {
        let point = CGPoint(x: 760, y: 500)
        XCTAssertNil(
            ResizeHandleJunctionTrackingGeometry.frame(
                at: point,
                horizontalSpan: 0...450,
                verticalSpan: 0...720,
                screenFrame: screen,
                radius: 6,
                isActive: false
            )
        )
        XCTAssertEqual(
            ResizeHandleJunctionTrackingGeometry.frame(
                at: point,
                horizontalSpan: 0...450,
                verticalSpan: 0...720,
                screenFrame: screen,
                radius: 6,
                isActive: true
            ),
            CGRect(x: 754, y: 494, width: 12, height: 12)
        )
    }

    func testPartialExplicitGroupNeverPresentsAnInputOwningHandle() {
        let partialHandle = SplitResizeHandleGeometry(
            axis: .horizontal,
            coordinate: 720,
            span: 0...450,
            participantIDs: ["left", "top-right"]
        )

        XCTAssertFalse(
            ResizeHandleGroupPresentationPolicy.presentsCompleteGroup(
                memberIDs: ["left", "top-right", "bottom-right"],
                preferredMemberID: "left",
                geometries: [partialHandle]
            )
        )
        XCTAssertTrue(
            ResizeHandleGroupPresentationPolicy.presentsCompleteGroup(
                memberIDs: ["left", "top-right"],
                preferredMemberID: "left",
                geometries: [partialHandle]
            )
        )
    }

    func testCompleteThreeMemberGroupStillPresentsItsHandles() {
        let handles = [
            SplitResizeHandleGeometry(
                axis: .horizontal,
                coordinate: 720,
                span: 0...900,
                participantIDs: ["left", "top-right", "bottom-right"]
            ),
            SplitResizeHandleGeometry(
                axis: .vertical,
                coordinate: 450,
                span: 720...1_440,
                participantIDs: ["top-right", "bottom-right"]
            )
        ]

        XCTAssertTrue(
            ResizeHandleGroupPresentationPolicy.presentsCompleteGroup(
                memberIDs: ["left", "top-right", "bottom-right"],
                preferredMemberID: "left",
                geometries: handles
            )
        )
    }

    func testCompleteTwoAndFourMemberGroupsAlsoPresentTheirHandles() {
        let twoMemberHandles = [
            SplitResizeHandleGeometry(
                axis: .horizontal,
                coordinate: 720,
                span: 0...900,
                participantIDs: ["left", "right"]
            )
        ]
        XCTAssertTrue(
            ResizeHandleGroupPresentationPolicy.presentsCompleteGroup(
                memberIDs: ["left", "right"],
                preferredMemberID: "left",
                geometries: twoMemberHandles
            )
        )

        let fourMemberHandles = [
            SplitResizeHandleGeometry(
                axis: .horizontal,
                coordinate: 720,
                span: 0...900,
                participantIDs: [
                    "top-left", "top-right", "bottom-left", "bottom-right"
                ]
            ),
            SplitResizeHandleGeometry(
                axis: .vertical,
                coordinate: 450,
                span: 0...1_440,
                participantIDs: [
                    "top-left", "top-right", "bottom-left", "bottom-right"
                ]
            )
        ]
        XCTAssertTrue(
            ResizeHandleGroupPresentationPolicy.presentsCompleteGroup(
                memberIDs: [
                    "top-left", "top-right", "bottom-left", "bottom-right"
                ],
                preferredMemberID: "top-left",
                geometries: fourMemberHandles
            )
        )
    }

    func testNativeWindowResizeDetectsOnlyARealSizeDelta() {
        let original = CGRect(x: 0, y: 0, width: 720, height: 900)
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: original,
            to: CGRect(x: 40, y: 20, width: 720, height: 900),
            tolerance: 0.5
        ))
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: original,
            to: CGRect(x: 0, y: 0, width: 720.4, height: 900),
            tolerance: 0.5
        ))
        XCTAssertTrue(NativeWindowResizePolicy.didResize(
            from: original,
            to: CGRect(x: 0, y: 0, width: 721, height: 900),
            tolerance: 0.5
        ))
    }

    func testNativeWindowResizeRejectsInvalidMeasurements() {
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: CGRect(
                x: CGFloat.infinity,
                y: 0,
                width: 720,
                height: 900
            ),
            to: CGRect(x: 0, y: 0, width: 721, height: 900),
            tolerance: 0.5
        ))
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: CGRect(x: 0, y: 0, width: 720, height: 900),
            to: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 900),
            tolerance: 0.5
        ))
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: CGRect(x: 0, y: 0, width: 720, height: 900),
            to: CGRect(x: CGFloat.nan, y: 0, width: 721, height: 900),
            tolerance: 0.5
        ))
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: CGRect(x: 0, y: 0, width: 720, height: 900),
            to: CGRect(x: 0, y: 0, width: 0, height: 900),
            tolerance: 0.5
        ))
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: CGRect(x: 0, y: 0, width: 720, height: 900),
            to: CGRect(x: 0, y: 0, width: 721, height: 900),
            tolerance: CGFloat.nan
        ))
        XCTAssertFalse(NativeWindowResizePolicy.didResize(
            from: CGRect(x: 0, y: 0, width: 720, height: 900),
            to: CGRect(x: 0, y: 0, width: 721, height: 900),
            tolerance: -1
        ))
    }

    func testNativeResizeFallbackSelectsOnlyTheActuallyResizedOverlap() {
        let shared = CGRect(x: 0, y: 0, width: 720, height: 900)
        let resized = NativeWindowResizePolicy.resizedIdentities(
            in: [
                .init(
                    stableIdentity: "same-app-front",
                    original: shared,
                    current: CGRect(
                        x: 0,
                        y: 0,
                        width: 760,
                        height: 900
                    )
                ),
                .init(
                    stableIdentity: "same-app-behind",
                    original: shared,
                    current: shared
                )
            ],
            tolerance: 0.5
        )

        XCTAssertEqual(resized, ["same-app-front"])
    }

    func testNativeResizeFallbackRequiresARealWindowEdge() {
        let frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        XCTAssertTrue(NativeWindowResizePolicy.isNearResizeEdge(
            CGPoint(x: 719, y: 450),
            frame: frame
        ))
        XCTAssertFalse(NativeWindowResizePolicy.isNearResizeEdge(
            CGPoint(x: 360, y: 450),
            frame: frame
        ))
        XCTAssertFalse(NativeWindowResizePolicy.isNearResizeEdge(
            CGPoint(x: CGFloat.nan, y: 450),
            frame: frame
        ))
    }

    func testPresentationStyleChangesThePresentationSignature() {
        let mac = ResizeHandleDescriptor(
            id: "divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"],
            presentationStyle: .mac
        )
        let windows = ResizeHandleDescriptor(
            id: "divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"],
            presentationStyle: .windows
        )
        let combined = ResizeHandleDescriptor(
            id: "divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"],
            presentationStyle: .combined
        )
        XCTAssertNotEqual(
            ResizeHandlePresentationSignature(mac),
            ResizeHandlePresentationSignature(windows)
        )
        XCTAssertNotEqual(
            ResizeHandlePresentationSignature(windows),
            ResizeHandlePresentationSignature(combined)
        )
    }

    func testUnoccludedHandleRemainsAvailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertFalse(descriptor.isOccluded(by: []))
    }

    func testPartiallyOccludedHandleIsEntirelyUnavailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertTrue(descriptor.isOccluded(by: [
            CGRect(x: 700, y: 400, width: 40, height: 100)
        ]))
    }

    func testFullyOccludedHandleIsEntirelyUnavailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertTrue(descriptor.isOccluded(by: [
            CGRect(x: 700, y: -20, width: 40, height: 940)
        ]))
    }

    func testPartiallyOccludedHorizontalDividerIsEntirelyUnavailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:horizontal-divider",
            displayID: 1,
            axis: .vertical,
            coordinate: 450,
            span: 0...1_440,
            screenFrame: screen,
            participantIDs: ["top", "bottom"]
        )
        XCTAssertTrue(descriptor.isOccluded(by: [
            CGRect(x: 600, y: 430, width: 240, height: 40)
        ]))
    }

    func testWindowTouchingOnlyTheInteractionFrameEdgeDoesNotHideHandle() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertFalse(descriptor.isOccluded(by: [
            CGRect(x: 728, y: 400, width: 100, height: 100)
        ]))
    }

    func testWindowAwayFromHandleDoesNotHideIt() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertFalse(descriptor.isOccluded(by: [
            CGRect(x: 900, y: 400, width: 40, height: 100)
        ]))
    }

    func testConnectedParticipantIDsIncludeTheWholeSplitGroupOnly() {
        let handles = [
            SplitResizeHandleGeometry(
                axis: .horizontal,
                coordinate: 720,
                span: 0...900,
                participantIDs: ["main", "right-top", "right-bottom"]
            ),
            SplitResizeHandleGeometry(
                axis: .vertical,
                coordinate: 450,
                span: 720...1_440,
                participantIDs: ["right-top", "right-bottom"]
            ),
            SplitResizeHandleGeometry(
                axis: .horizontal,
                coordinate: 200,
                span: 0...300,
                participantIDs: ["unrelated-a", "unrelated-b"]
            )
        ]
        XCTAssertEqual(
            SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: "main",
                handles: handles
            ),
            Set(["main", "right-top", "right-bottom"])
        )
    }

    func testRecoverableResizeUsesHysteresisBeforeReconnecting() {
        XCTAssertTrue(
            SplitLayoutGeometry.remainsSuspended(
                wasSuspended: false,
                compressionRatios: [0.51],
                tolerance: 0.5
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.remainsSuspended(
                wasSuspended: true,
                compressionRatios: [0.47],
                tolerance: 0.5
            )
        )
        XCTAssertFalse(
            SplitLayoutGeometry.remainsSuspended(
                wasSuspended: true,
                compressionRatios: [0.44],
                tolerance: 0.5
            )
        )
    }

    func testResizeHandleDoesNotJoinDetachedWindows() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "left",
                zone: .leftHalf,
                frame: CGRect(x: 0, y: 0, width: 720, height: 900)
            ),
            SplitPlacementGeometry(
                stableIdentity: "right",
                zone: .rightHalf,
                frame: CGRect(x: 720, y: 0, width: 720, height: 900)
            )
        ]
        XCTAssertTrue(
            SplitLayoutGeometry.resizeHandleGeometries(
                placements: placements,
                detachedConnections: [SplitConnectionKey("left", "right")]
            ).isEmpty
        )
    }

    func testAllowedBoundaryRangeUsesTheSameConstraintMathOnBothAxes() {
        let square = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let horizontal = [
            SplitResizeParticipantGeometry(
                stableIdentity: "near",
                frame: CGRect(x: 0, y: 0, width: 500, height: 1_000),
                side: .nearOrigin,
                minimumLength: 320,
                maximumLength: 620
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "far",
                frame: CGRect(x: 500, y: 0, width: 500, height: 1_000),
                side: .farOrigin,
                minimumLength: 350,
                maximumLength: 680
            )
        ]
        let vertical = [
            SplitResizeParticipantGeometry(
                stableIdentity: "near",
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 500),
                side: .nearOrigin,
                minimumLength: 320,
                maximumLength: 620
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "far",
                frame: CGRect(x: 0, y: 500, width: 1_000, height: 500),
                side: .farOrigin,
                minimumLength: 350,
                maximumLength: 680
            )
        ]
        XCTAssertEqual(
            SplitLayoutGeometry.allowedBoundaryRange(
                axis: .horizontal,
                participants: horizontal,
                screenFrame: square
            ),
            SplitLayoutGeometry.allowedBoundaryRange(
                axis: .vertical,
                participants: vertical,
                screenFrame: square
            )
        )
    }

    func testStackedPeerConstraintsShrinkTheIncomingHalfOnEitherAxis() {
        let square = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let horizontal = [
            SplitResizeParticipantGeometry(
                stableIdentity: "incoming-left",
                frame: CGRect(x: 0, y: 0, width: 500, height: 1_000),
                side: .nearOrigin,
                minimumLength: 300
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "right-top",
                frame: CGRect(x: 400, y: 500, width: 600, height: 500),
                side: .farOrigin,
                minimumLength: 600
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "right-bottom",
                frame: CGRect(x: 400, y: 0, width: 600, height: 500),
                side: .farOrigin,
                minimumLength: 600
            )
        ]
        let vertical = [
            SplitResizeParticipantGeometry(
                stableIdentity: "incoming-bottom",
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 500),
                side: .nearOrigin,
                minimumLength: 300
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "top-left",
                frame: CGRect(x: 0, y: 400, width: 500, height: 600),
                side: .farOrigin,
                minimumLength: 600
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "top-right",
                frame: CGRect(x: 500, y: 400, width: 500, height: 600),
                side: .farOrigin,
                minimumLength: 600
            )
        ]

        XCTAssertEqual(
            SplitLayoutGeometry.allowedBoundaryRange(
                axis: .horizontal,
                participants: horizontal,
                screenFrame: square
            ),
            300...400
        )
        XCTAssertEqual(
            SplitLayoutGeometry.allowedBoundaryRange(
                axis: .vertical,
                participants: vertical,
                screenFrame: square
            ),
            300...400
        )
    }

    func testAllowedBoundaryRangeProtectsBothSides() {
        let participants = [
            SplitResizeParticipantGeometry(
                stableIdentity: "left",
                frame: CGRect(x: 0, y: 0, width: 720, height: 900),
                side: .nearOrigin,
                minimumLength: 300
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "right",
                frame: CGRect(x: 720, y: 0, width: 720, height: 900),
                side: .farOrigin,
                minimumLength: 400
            )
        ]
        XCTAssertEqual(
            SplitLayoutGeometry.allowedBoundaryRange(
                axis: .horizontal,
                participants: participants,
                screenFrame: screen
            ),
            300...1_040
        )
    }

    func testHandleResizeUsesOneBoundaryForEveryParticipant() {
        let participants = [
            SplitResizeParticipantGeometry(
                stableIdentity: "left",
                frame: CGRect(x: 0, y: 0, width: 720, height: 900),
                side: .nearOrigin,
                minimumLength: 1
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "right",
                frame: CGRect(x: 720, y: 0, width: 720, height: 900),
                side: .farOrigin,
                minimumLength: 1
            )
        ]
        let frames = SplitLayoutGeometry.resizedFrames(
            meetingBoundary: 840,
            axis: .horizontal,
            participants: participants
        )
        XCTAssertEqual(frames["left"]?.maxX, 840)
        XCTAssertEqual(frames["right"]?.minX, 840)
        XCTAssertEqual(frames["left"]?.minX, screen.minX)
        XCTAssertEqual(frames["right"]?.maxX, screen.maxX)
    }

    func testConnectedGroupNeedsRaiseWhenExternalWindowSeparatesMembers() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "external",
                frame: CGRect(x: 100, y: 100, width: 200, height: 200)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertFalse(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testConnectedGroupIsFrontmostWhenAllMembersLeadRelevantWindows() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "external",
                frame: CGRect(x: 100, y: 100, width: 800, height: 200)
            )
        ]
        XCTAssertTrue(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testSingleProvisionalPlacementMustActuallyBeFrontmost() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "external",
                frame: CGRect(x: 100, y: 100, width: 200, height: 200)
            ),
            SplitZOrderWindow(
                stableIdentity: "provisional",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertFalse(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["provisional"],
            orderedWindows: windows
        ))
    }

    func testConnectedGroupIgnoresWindowsOutsideItsCombinedBounds() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "external-display",
                frame: CGRect(x: 2_000, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertTrue(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testIncompleteActionableGroupSnapshotDoesNotAuthorizeRaise() {
        XCTAssertTrue(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "missing-group"],
            orderedWindows: [
                SplitZOrderWindow(
                    stableIdentity: "front-group",
                    frame: CGRect(x: 0, y: 0, width: 500, height: 900)
                )
            ]
        ))
    }

    func testConnectedGroupNeedsRaiseWhenExternalWindowOccludesRearMember() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "external",
                frame: CGRect(x: 600, y: 100, width: 200, height: 200)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertFalse(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testNonActionableFrontmostSurfaceBlocksClickThrough() {
        let point = CGPoint(x: 250, y: 250)
        let surfaces = [
            SplitHitTestSurface(
                windowID: 10,
                frame: CGRect(x: 200, y: 200, width: 300, height: 200)
            ),
            SplitHitTestSurface(
                windowID: 20,
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertEqual(
            SplitLayoutGeometry.frontmostHitWindowID(
                at: point,
                orderedSurfaces: surfaces
            ),
            10
        )
    }

    func testFrontmostHitTestUsesWindowServerOrder() {
        let point = CGPoint(x: 250, y: 250)
        let surfaces = [
            SplitHitTestSurface(
                windowID: 20,
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitHitTestSurface(
                windowID: 30,
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertEqual(
            SplitLayoutGeometry.frontmostHitWindowID(
                at: point,
                orderedSurfaces: surfaces
            ),
            20
        )
    }

    func testResizeHandlePresentationPolicyIgnoresNoisyFocusSignals() {
        XCTAssertFalse(ResizeHandlePresentationPolicy.shouldSuspend(
            for: .accessibilityFocusChanged
        ))
        XCTAssertFalse(ResizeHandlePresentationPolicy.shouldSuspend(
            for: .windowServerSelectionChanged
        ))
        XCTAssertTrue(ResizeHandlePresentationPolicy.shouldSuspend(
            for: .applicationDeactivated
        ))
        XCTAssertTrue(ResizeHandlePresentationPolicy.shouldSuspend(
            for: .applicationActivated
        ))
    }

    func testEveryStyleHidesOldGeometryWhileDragStarts() {
        for style in LinkedResizePresentationStyle.allCases {
            XCTAssertTrue(
                ResizeHandleDragPresentationPolicy
                    .hidesOriginalGeometryUntilFirstUpdate(for: style)
            )
        }
    }

    func testMixedVirtualResizePlacesOverlayBelowLiveWindow() {
        let layering = VirtualResizePresentationPolicy.layering(
            liveWindowCount: 1,
            virtualWindowCount: 1
        )
        XCTAssertEqual(layering, .belowLiveWindows)
        XCTAssertFalse(VirtualResizePresentationPolicy.shouldMaskLiveFrames(
            for: layering
        ))
        XCTAssertEqual(
            VirtualResizePresentationPolicy.orderingStrategy(
                for: layering,
                liveWindowID: 42
            ),
            .belowLiveWindow(42)
        )
    }

    func testMixedVirtualResizeUsesRaiseFallbackWithoutAWindowServerID() {
        XCTAssertEqual(
            VirtualResizePresentationPolicy.orderingStrategy(
                for: .belowLiveWindows,
                liveWindowID: nil
            ),
            .belowLiveWindowFallback
        )
    }

    func testFullyVirtualResizeKeepsOverlayAboveAllWindows() {
        let layering = VirtualResizePresentationPolicy.layering(
            liveWindowCount: 0,
            virtualWindowCount: 2
        )
        XCTAssertEqual(layering, .aboveAllWindows)
        XCTAssertTrue(VirtualResizePresentationPolicy.shouldMaskLiveFrames(
            for: layering
        ))
        XCTAssertEqual(
            VirtualResizePresentationPolicy.orderingStrategy(
                for: layering,
                liveWindowID: 42
            ),
            .aboveAllWindows
        )
    }

    func testVirtualConcealmentUsesSharedBackingPixelEdges() {
        let left = VirtualResizePresentationPolicy.pixelAlignedCoverageFrame(
            CGRect(x: 0, y: 0, width: 500.24, height: 400.24),
            backingScaleFactor: 2
        )
        let right = VirtualResizePresentationPolicy.pixelAlignedCoverageFrame(
            CGRect(x: 500.24, y: 0, width: 499.76, height: 400.24),
            backingScaleFactor: 2
        )

        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.maxX, 500)
        XCTAssertEqual(left.maxY, 400)
        XCTAssertEqual(right.maxX, 1_000)
    }

    func testSettingsScrollGeometryStartsAtTopForFlippedDocument() {
        XCTAssertEqual(
            SettingsScrollGeometry.topOrigin(
                documentBounds: CGRect(x: 0, y: 0, width: 580, height: 1_600),
                viewportBounds: CGRect(x: 0, y: 420, width: 580, height: 820),
                isFlipped: true
            ),
            CGPoint(x: 0, y: 0)
        )
    }

    func testSettingsScrollGeometryStartsAtTopForUnflippedDocument() {
        XCTAssertEqual(
            SettingsScrollGeometry.topOrigin(
                documentBounds: CGRect(x: 20, y: 40, width: 580, height: 1_600),
                viewportBounds: CGRect(x: 0, y: 0, width: 580, height: 820),
                isFlipped: false
            ),
            CGPoint(x: 20, y: 820)
        )
    }

    func testRecoverySceneSignatureIgnoresNonWindowLayers() {
        let windows = [
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 100,
                frame: CGRect(x: 0, y: 0, width: 500, height: 900),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 101,
                frame: CGRect(x: 500, y: 0, width: 500, height: 900),
                zIndex: 1,
                layer: 0
            )
        ]
        let withMenu = [
            WindowOcclusionSnapshot(
                windowID: 99,
                pid: 200,
                frame: CGRect(x: 20, y: 20, width: 100, height: 40),
                zIndex: 0,
                layer: 24
            )
        ] + windows

        XCTAssertEqual(
            SplitLayoutGeometry.recoverySceneSignature(for: windows),
            SplitLayoutGeometry.recoverySceneSignature(for: withMenu)
        )
    }

    func testRecoverySceneSignatureIgnoresDistantExternalChurnWhenScoped() {
        let managed = WindowOcclusionSnapshot(
            windowID: 10, pid: 100,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900),
            zIndex: 0, layer: 0
        )
        let distant = WindowOcclusionSnapshot(
            windowID: 99, pid: 200,
            frame: CGRect(x: 1200, y: 100, width: 300, height: 300),
            zIndex: 1, layer: 0
        )
        let movedDistant = WindowOcclusionSnapshot(
            windowID: 99, pid: 200,
            frame: CGRect(x: 1300, y: 100, width: 300, height: 300),
            zIndex: 1, layer: 0
        )
        let region = CGRect(x: 495, y: 200, width: 10, height: 500)
        XCTAssertEqual(
            SplitLayoutGeometry.recoverySceneSignature(
                for: [managed, distant],
                managedWindowIDs: [10],
                interactionRegions: [region]
            ),
            SplitLayoutGeometry.recoverySceneSignature(
                for: [managed, movedDistant],
                managedWindowIDs: [10],
                interactionRegions: [region]
            )
        )
    }

    func testRecoverySceneSignatureTracksRelevantOccluderArrivalAndRemoval() {
        let managed = WindowOcclusionSnapshot(
            windowID: 10, pid: 100,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900),
            zIndex: 1, layer: 0
        )
        let occluder = WindowOcclusionSnapshot(
            windowID: 99, pid: 200,
            frame: CGRect(x: 490, y: 250, width: 40, height: 200),
            zIndex: 0, layer: 0
        )
        let region = CGRect(x: 495, y: 200, width: 10, height: 500)
        let without = SplitLayoutGeometry.recoverySceneSignature(
            for: [managed],
            managedWindowIDs: [10],
            interactionRegions: [region]
        )
        let with = SplitLayoutGeometry.recoverySceneSignature(
            for: [occluder, managed],
            managedWindowIDs: [10],
            interactionRegions: [region]
        )
        XCTAssertNotEqual(without, with)
        XCTAssertEqual(
            without,
            SplitLayoutGeometry.recoverySceneSignature(
                for: [managed],
                managedWindowIDs: [10],
                interactionRegions: [region]
            )
        )
    }

    func testRecoverySceneSignatureChangesForWindowOrderOrGeometry() {
        let first = WindowOcclusionSnapshot(
            windowID: 10,
            pid: 100,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900),
            zIndex: 0,
            layer: 0
        )
        let second = WindowOcclusionSnapshot(
            windowID: 11,
            pid: 101,
            frame: CGRect(x: 500, y: 0, width: 500, height: 900),
            zIndex: 1,
            layer: 0
        )
        let movedSecond = WindowOcclusionSnapshot(
            windowID: 11,
            pid: 101,
            frame: CGRect(x: 520, y: 0, width: 480, height: 900),
            zIndex: 1,
            layer: 0
        )
        let originalSignature = SplitLayoutGeometry.recoverySceneSignature(
            for: [first, second]
        )

        XCTAssertNotEqual(
            originalSignature,
            SplitLayoutGeometry.recoverySceneSignature(for: [second, first])
        )
        XCTAssertNotEqual(
            originalSignature,
            SplitLayoutGeometry.recoverySceneSignature(
                for: [first, movedSecond]
            )
        )
    }

    func testFocusedWindowPollEstablishesBaselineWithoutTriggering() {
        var state = FocusedWindowPollState()
        let first = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:first",
            mainIdentity: "ax:100:first"
        )

        XCTAssertNil(state.observe(first))
        XCTAssertTrue(state.hasBaseline)
        XCTAssertEqual(state.lastSnapshot, first)
        XCTAssertNil(state.observe(first))
    }

    func testFocusedWindowPollPrefersAChangedMainWindow() {
        var state = FocusedWindowPollState()
        let first = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:focused",
            mainIdentity: "ax:100:first-main"
        )
        let second = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:focused",
            mainIdentity: "ax:100:second-main"
        )
        let expected = FocusedWindowIdentity(
            pid: 100,
            stableIdentity: "ax:100:second-main"
        )

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(state.observe(second), expected)
        XCTAssertNil(state.observe(second))
    }

    func testFocusedWindowPollUsesFocusedChangeWhenMainIsStable() {
        var state = FocusedWindowPollState()
        let first = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:first-focused",
            mainIdentity: "ax:100:main"
        )
        let second = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:second-focused",
            mainIdentity: "ax:100:main"
        )

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(
            state.observe(second),
            FocusedWindowIdentity(
                pid: 100,
                stableIdentity: "ax:100:second-focused"
            )
        )
    }

    func testFocusedWindowPollRecoversAfterTemporaryNil() {
        var state = FocusedWindowPollState()
        let window = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:focused",
            mainIdentity: "ax:100:main"
        )
        let expected = FocusedWindowIdentity(
            pid: 100,
            stableIdentity: "ax:100:main"
        )

        XCTAssertNil(state.observe(window))
        XCTAssertNil(state.observe(nil))
        XCTAssertEqual(state.observe(window), expected)
        state.reset()
        XCTAssertFalse(state.hasBaseline)
        XCTAssertNil(state.lastSnapshot)
        XCTAssertNil(state.observe(window))
    }

    func testFocusedWindowSettlementRequiresConsecutiveIdentitySamples() {
        let first = FocusedWindowSettlementState.nextObservationCount(
            previousIdentity: nil,
            currentIdentity: "window-a",
            previousCount: 0
        )
        let second = FocusedWindowSettlementState.nextObservationCount(
            previousIdentity: "window-a",
            currentIdentity: "window-a",
            previousCount: first
        )
        let third = FocusedWindowSettlementState.nextObservationCount(
            previousIdentity: "window-a",
            currentIdentity: "window-a",
            previousCount: second
        )

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 3)
    }

    func testFocusedWindowSettlementResetsWhenCandidateChangesOrDisappears() {
        XCTAssertEqual(
            FocusedWindowSettlementState.nextObservationCount(
                previousIdentity: "window-a",
                currentIdentity: "window-b",
                previousCount: 2
            ),
            1
        )
        XCTAssertEqual(
            FocusedWindowSettlementState.nextObservationCount(
                previousIdentity: "window-a",
                currentIdentity: nil,
                previousCount: 2
            ),
            0
        )
    }

    func testWindowServerSelectionPollEstablishesBaselineWithoutTriggering() {
        var state = WindowServerSelectionPollState()
        let selection = WindowServerSelectionSnapshot(
            pid: 100,
            windowID: 42
        )

        XCTAssertNil(state.observe(selection))
        XCTAssertEqual(state.lastSnapshot, selection)
        XCTAssertNil(state.observe(selection))
    }

    func testWindowServerSelectionPollReportsExactWindowChange() {
        var state = WindowServerSelectionPollState()
        let first = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        let second = WindowServerSelectionSnapshot(pid: 100, windowID: 43)

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(state.observe(second), second)
        XCTAssertNil(state.observe(second))
    }

    func testWindowServerSelectionPollReportsApplicationChange() {
        var state = WindowServerSelectionPollState()
        let first = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        let second = WindowServerSelectionSnapshot(pid: 200, windowID: 84)

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(state.observe(second), second)
    }

    func testWindowServerSelectionPollRecoversAfterMissionControlGap() {
        var state = WindowServerSelectionPollState()
        let selection = WindowServerSelectionSnapshot(pid: 100, windowID: 42)

        XCTAssertNil(state.observe(selection))
        XCTAssertNil(state.observe(nil))
        XCTAssertEqual(state.observe(selection), selection)
    }

    func testJunctionResizeAppliesBothAxesAtomicallyToFourQuadrants() {
        let frames = [
            "bottomLeft": CGRect(x: 0, y: 0, width: 50, height: 50),
            "bottomRight": CGRect(x: 50, y: 0, width: 50, height: 50),
            "topLeft": CGRect(x: 0, y: 50, width: 50, height: 50),
            "topRight": CGRect(x: 50, y: 50, width: 50, height: 50)
        ]
        let resized = HandleResizeGeometry.resizedFrames(
            originalFrames: frames,
            boundaries: [
                HandleResizeBoundaryGeometry(
                    axis: .horizontal,
                    coordinate: 60,
                    sides: [
                        "bottomLeft": .nearOrigin,
                        "topLeft": .nearOrigin,
                        "bottomRight": .farOrigin,
                        "topRight": .farOrigin
                    ]
                ),
                HandleResizeBoundaryGeometry(
                    axis: .vertical,
                    coordinate: 40,
                    sides: [
                        "bottomLeft": .nearOrigin,
                        "bottomRight": .nearOrigin,
                        "topLeft": .farOrigin,
                        "topRight": .farOrigin
                    ]
                )
            ]
        )

        XCTAssertEqual(resized["bottomLeft"], CGRect(x: 0, y: 0, width: 60, height: 40))
        XCTAssertEqual(resized["bottomRight"], CGRect(x: 60, y: 0, width: 40, height: 40))
        XCTAssertEqual(resized["topLeft"], CGRect(x: 0, y: 40, width: 60, height: 60))
        XCTAssertEqual(resized["topRight"], CGRect(x: 60, y: 40, width: 40, height: 60))
    }
}
