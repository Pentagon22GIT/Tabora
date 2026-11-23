import AppKit
import XCTest
@testable import Tabora

final class DefaultSplitAndGestureTests: XCTestCase {
    let screen = CGRect(x: -2000, y: -200, width: 2000, height: 1000)
    let ratio = DefaultSplitRatio(left: 70, top: 35)

    func testEveryEntryUsesSameInitialDividerAndExistingDividerWins() {
        for zone in SnapZone.allCases {
            let predicted = SplitLayoutGeometry.resolvedFrame(for: zone,
                in: screen, placements: [], ratio: ratio)
            XCTAssertEqual(predicted, zone.frame(in: screen, ratio: ratio))
        }
        XCTAssertEqual(SnapZone.topRight.frame(in: screen, ratio: ratio),
            CGRect(x: -600, y: 450, width: 600, height: 350))
        let left = SplitPlacementGeometry(stableIdentity: "left", zone: .leftHalf,
            frame: CGRect(x: -2000, y: -200, width: 1200, height: 1000))
        let right = SplitLayoutGeometry.resolvedFrame(for: .topRight, in: screen,
            placements: [left], ratio: ratio)
        XCTAssertEqual(right, CGRect(x: -800, y: 450, width: 800, height: 350))
    }

    func testCandidateCanMovePreferredDividerUntilBothMinimumsConflict() {
        let left = SnapZone.leftHalf.frame(in: screen, ratio: ratio)
        let right = SnapZone.rightHalf.frame(in: screen, ratio: ratio)
        var rightLimits = AppConstraintLimits.unknown
        rightLimits.minWidth = 760
        for minimum in [1200, 1300] {
            var leftLimits = AppConstraintLimits.unknown
            leftLimits.minWidth = CGFloat(minimum)
            let result = SplitLayoutGeometry.adaptiveConstraintPartition(members: [
                .init(stableIdentity: "left", zone: .leftHalf, referenceFrame: left, limits: leftLimits),
                .init(stableIdentity: "right", zone: .rightHalf, referenceFrame: right, limits: rightLimits)
            ], incomingIdentity: "right", preferredIncomingFrame: right, in: screen)
            switch result {
            case .ready(let frames):
                XCTAssertEqual(minimum, 1200)
                XCTAssertEqual(frames["left"]?.width, 1240)
                XCTAssertEqual(frames["right"]?.width, 760)
            case .confirmedInfeasible: XCTAssertEqual(minimum, 1300)
            case .indeterminate: XCTFail("Known bounds must yield a decision")
            }
        }
    }

    func testDisplayPreferencesSurviveReloadIndependently() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppSettings(defaults: defaults).setSplitRatio(ratio, for: "external")
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.splitRatio(for: "external"), ratio)
        XCTAssertEqual(reloaded.splitRatio(for: "internal"), .init())
    }

    func testGestureClaimsOnlyOptionAtStartAndConsumesMomentumWithoutSecondDispatch() {
        let monitor = TrackpadSnapMonitor()
        let target = WindowServerSelectionSnapshot(pid: 42, windowID: 12)
        monitor.target = { target }
        var fired: [SnapZone] = []
        monitor.snap = { zone, selected, _ in
            XCTAssertEqual(selected, target)
            fired.append(zone)
        }
        func send(_ phase: NSEvent.Phase, option: Bool = true,
                  momentum: NSEvent.Phase = [], precise: Bool = true) -> Bool {
            monitor.consume(precise: precise, phase: phase, momentum: momentum,
                modifiers: option ? .option : [], delta: CGPoint(x: -50, y: -50), inverted: true)
        }
        XCTAssertFalse(send(.began, option: false))
        XCTAssertFalse(send(.changed))
        XCTAssertFalse(send(.began, precise: false))
        XCTAssertTrue(send(.began))
        XCTAssertTrue(send(.changed))
        XCTAssertTrue(send(.ended))
        XCTAssertFalse(send(.ended))
        XCTAssertTrue(send([], momentum: .began))
        XCTAssertTrue(send([], momentum: .ended))
        XCTAssertTrue(send(.began))
        XCTAssertTrue(send(.changed, option: false))
        XCTAssertTrue(send(.ended))
        XCTAssertTrue(send(.began))
        XCTAssertTrue(send(.cancelled))
        XCTAssertTrue(send([], momentum: .began))
        XCTAssertTrue(send([], momentum: .cancelled))
        XCTAssertFalse(send([], momentum: .changed))
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(fired, [.topLeft])
    }

    func testUpwardMaximizeRequiresGesturesAndOnlyRemapsStraightUp() throws {
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.gestureSnapEnabled = true
        XCTAssertEqual(settings.gestureDestination(for: .topHalf), .topHalf)
        settings.maximizeOnUpwardGesture = true
        for direction in SnapZone.allCases where direction != .maximize {
            XCTAssertEqual(settings.gestureDestination(for: direction), direction == .topHalf ? .maximize : direction)
        }
        settings.gestureSnapEnabled = false
        XCTAssertNil(settings.gestureDestination(for: .topHalf))
        settings.gestureSnapEnabled = true
        XCTAssertEqual(AppSettings(defaults: defaults).gestureDestination(for: .topHalf), .maximize)
    }

    func testEightGestureDirectionsAndDeadZone() {
        let zones: [SnapZone] = [.rightHalf, .topRight, .topHalf, .topLeft,
            .leftHalf, .bottomLeft, .bottomHalf, .bottomRight]
        for (index, zone) in zones.enumerated() {
            let angle = CGFloat(index) * .pi / 4
            XCTAssertEqual(TrackpadSnapMonitor.direction(CGPoint(x: 80*cos(angle), y: 80*sin(angle))), zone)
        }
        XCTAssertNil(TrackpadSnapMonitor.direction(CGPoint(x: 15, y: -15)))
    }
}
