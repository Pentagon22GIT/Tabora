import XCTest
@testable import Tabora

final class ForegroundSelectionMonitorTests: XCTestCase {
    func testEnableDoesNotCreateObservationUntilBaselineIsRequested() {
        var reads = 0
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: {
                reads += 1
                return WindowServerSelectionSnapshot(pid: 10, windowID: 20)
            },
            changeHandler: { changes.append($0) }
        )

        XCTAssertTrue(monitor.setEnabled(true))
        XCTAssertEqual(reads, 0)
        monitor.establishBaseline()
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(changes.isEmpty)
    }

    func testFallbackReportsOnlyAnExactSelectionChange() {
        var current: WindowServerSelectionSnapshot? =
            WindowServerSelectionSnapshot(pid: 10, windowID: 20)
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: { current },
            changeHandler: { changes.append($0) }
        )

        monitor.setEnabled(true)
        monitor.establishBaseline()
        monitor.sampleFallback()
        XCTAssertTrue(changes.isEmpty)

        current = WindowServerSelectionSnapshot(pid: 10, windowID: 21)
        monitor.sampleFallback()
        XCTAssertEqual(changes, [current].compactMap { $0 })

        monitor.sampleFallback()
        XCTAssertEqual(changes.count, 1)
    }

    func testRepeatedEligibilityUpdateDoesNotEraseBaseline() {
        var current: WindowServerSelectionSnapshot? =
            WindowServerSelectionSnapshot(pid: 10, windowID: 20)
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: { current },
            changeHandler: { changes.append($0) }
        )

        XCTAssertTrue(monitor.setEnabled(true))
        monitor.establishBaseline()
        XCTAssertFalse(monitor.setEnabled(true))
        current = WindowServerSelectionSnapshot(pid: 10, windowID: 21)
        monitor.sampleFallback()

        XCTAssertEqual(changes, [current].compactMap { $0 })
    }

    func testInvalidationMakesNextFallbackABaselineOnly() {
        var current: WindowServerSelectionSnapshot? =
            WindowServerSelectionSnapshot(pid: 10, windowID: 20)
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: { current },
            changeHandler: { changes.append($0) }
        )

        monitor.setEnabled(true)
        monitor.establishBaseline()
        monitor.invalidateBaseline()
        current = WindowServerSelectionSnapshot(pid: 10, windowID: 21)
        monitor.sampleFallback()
        XCTAssertTrue(changes.isEmpty)

        current = WindowServerSelectionSnapshot(pid: 11, windowID: 30)
        monitor.sampleFallback()
        XCTAssertEqual(changes, [current].compactMap { $0 })
    }

    func testSynchronizePreventsEventReplayByFallback() {
        var current: WindowServerSelectionSnapshot? =
            WindowServerSelectionSnapshot(pid: 10, windowID: 20)
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: { current },
            changeHandler: { changes.append($0) }
        )

        monitor.setEnabled(true)
        monitor.establishBaseline()
        current = WindowServerSelectionSnapshot(pid: 10, windowID: 21)
        monitor.synchronize(to: current)
        monitor.sampleFallback()

        XCTAssertTrue(changes.isEmpty)
    }

    func testUnconsumedSamePIDChangeRemainsVisibleToFallback() {
        var current: WindowServerSelectionSnapshot? =
            WindowServerSelectionSnapshot(pid: 10, windowID: 20)
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: { current },
            changeHandler: { changes.append($0) }
        )

        monitor.setEnabled(true)
        monitor.establishBaseline()
        current = WindowServerSelectionSnapshot(pid: 10, windowID: 99)
        // An early AX callback whose ownership is still indeterminate must not
        // call synchronize(to:). Recovery can then classify the exact surface.
        monitor.sampleFallback()

        XCTAssertEqual(changes, [current].compactMap { $0 })
    }

    func testDisabledMonitorDoesNotReadOrDeliver() {
        var reads = 0
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: {
                reads += 1
                return WindowServerSelectionSnapshot(pid: 10, windowID: 20)
            },
            changeHandler: { changes.append($0) }
        )

        monitor.sampleFallback()
        monitor.establishBaseline()
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(changes.isEmpty)
    }

    func testNilGapRequiresARealSelectionBeforeDelivery() {
        var current: WindowServerSelectionSnapshot?
        var changes: [WindowServerSelectionSnapshot] = []
        let monitor = ForegroundSelectionMonitor(
            snapshotProvider: { current },
            changeHandler: { changes.append($0) }
        )

        monitor.setEnabled(true)
        monitor.establishBaseline()
        monitor.sampleFallback()
        XCTAssertTrue(changes.isEmpty)

        current = WindowServerSelectionSnapshot(pid: 10, windowID: 20)
        monitor.sampleFallback()
        XCTAssertEqual(changes, [current].compactMap { $0 })
    }
}
