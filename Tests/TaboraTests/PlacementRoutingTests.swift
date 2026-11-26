import AppKit
import XCTest
@testable import Tabora

final class PlacementRoutingTests: XCTestCase {
    func testReplacementDefaultAndLayerDecisions() throws {
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.occupiedReplacementEnabled)
        for occupied in SnapZone.allCases {
            for incoming in SnapZone.allCases {
                XCTAssertTrue(OccupiedSplitPolicy.permits(existing: occupied, incoming: incoming,
                    replacementEnabled: true))
                let allowed = occupied == .maximize || incoming == .maximize
                    || !SnapPlacementLayerPolicy.conflicts(existing: occupied, incoming: incoming)
                XCTAssertEqual(OccupiedSplitPolicy.permits(existing: occupied, incoming: incoming,
                    replacementEnabled: false), allowed)
            }
        }
        settings.occupiedReplacementEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).occupiedReplacementEnabled)
    }

    func testLockedGestureTable() {
        let directions: [SnapZone] = [.topHalf, .topRight, .rightHalf, .bottomRight, .bottomHalf, .bottomLeft, .leftHalf, .topLeft]
        let ignored = LockedGestureRoute.ignored, sub = LockedGestureRoute.subdivision
        let ex = LockedGestureRoute.exchange
        let rows: [(SnapZone, [LockedGestureRoute])] = [
            (.leftHalf, [ignored, ex(.topRight), ex(.rightHalf), ex(.bottomRight), ignored, sub, ignored, sub]),
            (.rightHalf, [ignored, sub, ignored, sub, ignored, ex(.bottomLeft), ex(.leftHalf), ex(.topLeft)]),
            (.topHalf, [ignored, sub, ignored, ex(.bottomRight), ex(.bottomHalf), ex(.bottomLeft), ignored, sub]),
            (.bottomHalf, [ex(.topHalf), ex(.topRight), ignored, sub, ignored, sub, ignored, ex(.topLeft)]),
            (.topLeft, [ignored, ex(.topRight), ex(.topRight), ignored, ex(.bottomLeft), ex(.bottomLeft), ignored, ignored]),
            (.topRight, [ignored, ignored, ignored, ex(.bottomRight), ex(.bottomRight), ignored, ex(.topLeft), ex(.topLeft)]),
            (.bottomLeft, [ex(.topLeft), ignored, ex(.bottomRight), ex(.bottomRight), ignored, ignored, ignored, ex(.topLeft)]),
            (.bottomRight, [ex(.topRight), ex(.topRight), ignored, ignored, ignored, ex(.bottomLeft), ex(.bottomLeft), ignored])
        ]
        for (source, expected) in rows {
            let quarters = AssistCompletionLayoutPolicy.fourWindowZones.filter { !source.occupiedQuarters.contains($0) }
            let layout = Dictionary(uniqueKeysWithValues: ([source] + quarters).map { ($0.rawValue, $0) })
            for (direction, route) in zip(directions, expected) {
                XCTAssertEqual(LockedGestureRoute.resolve(source: source, direction: direction, layout: layout,
                    subdivisionEnabled: true), route, "\(source) → \(direction)")
                XCTAssertEqual(LockedGestureRoute.resolve(source: source, direction: direction, layout: layout,
                    subdivisionEnabled: false), route == sub ? ignored : route)
            }
        }
    }

    func testLockedGestureTargetsTheWindowCoveringTheAdjacentCorner() {
        let sides: [SnapZone] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
        for source in sides {
            let opposite = sides.first { $0.occupiedQuarters.isDisjoint(with: source.occupiedQuarters) }!
            let halves = ["source": source, "peer": opposite]
            for direction in opposite.occupiedQuarters.union([opposite]) {
                XCTAssertEqual(LockedGestureRoute.resolve(source: source, direction: direction, layout: halves,
                    subdivisionEnabled: true), .exchange(opposite))
            }
            let corners = source.occupiedQuarters
            var mixed = Dictionary(uniqueKeysWithValues: corners.map { ($0.rawValue, $0) })
            mixed["peer"] = opposite
            for corner in corners {
                XCTAssertEqual(LockedGestureRoute.resolve(source: corner, direction: opposite, layout: mixed,
                    subdivisionEnabled: true), .exchange(opposite))
            }
        }
    }

    func testMaximizePlanUsesExactVisibleFrame() {
        let reference = CGRect(x: 90, y: 100, width: 400, height: 300)
        let member = CanonicalSplitPartitionMember(stableIdentity: "cover", zone: .maximize,
            referenceFrame: reference, limits: .unknown)
        for visible in [CGRect(x: 0, y: 63, width: 1024, height: 674),
                        CGRect(x: 0, y: 62, width: 1024, height: 675)] {
            guard case .ready(let frames) = SplitLayoutGeometry.adaptiveConstraintPartition(
                members: [member], incomingIdentity: member.stableIdentity,
                preferredIncomingFrame: reference, in: visible
            ) else { return XCTFail("Expected a maximize plan for \(visible)") }
            XCTAssertEqual(frames[member.stableIdentity], visible)
        }
    }
    func testConstraintMeasurementRetiresOnlyTheMeasuredWindowsGroup() throws {
        let controller = SnapController()
        defer { controller.stop() }
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        func makeGroup(_ prefix: String) throws -> SnapGroup {
            let placements = [SnapZone.leftHalf, .rightHalf].enumerated().map { index, zone in
                SplitPlacementGeometry(stableIdentity: "\(prefix)-\(index)", zone: zone,
                                       frame: zone.frame(in: bounds))
            }
            return try XCTUnwrap(controller.explicitGroupStore.reconcileAfterLayoutMutation(
                preferredMemberID: placements[0].stableIdentity, displayID: CGMainDisplayID(),
                placements: placements, detachedConnections: []))
        }
        let measured = try makeGroup("measured")
        let other = try makeGroup("other")
        XCTAssertTrue(controller.beginConstraintMeasurement(windowIdentity: "measured-0"))
        XCTAssertNotNil(controller.explicitGroupStore.group(id: measured.id))
        controller.endConstraintMeasurement()
        XCTAssertNil(controller.explicitGroupStore.group(id: measured.id))
        XCTAssertNotNil(controller.explicitGroupStore.group(id: other.id))
        XCTAssertNil(controller.measuredGroup)
    }

}
