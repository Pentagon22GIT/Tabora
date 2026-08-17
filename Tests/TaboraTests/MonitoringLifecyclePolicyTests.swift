import XCTest
@testable import Tabora

final class MonitoringLifecyclePolicyTests: XCTestCase {
    func testMaximizedUpperLayerDoesNotStartOrStopSplitMonitoring() {
        XCTAssertEqual(MonitoringLifecyclePolicy.connectedPlacementCount(
            in: [.leftHalf, .rightHalf, .maximize]
        ), 2)
        XCTAssertEqual(MonitoringLifecyclePolicy.connectedPlacementCount(
            in: [.maximize]
        ), 0)
    }

    func testSelectionPollingRequiresEveryLongLivedCondition() {
        XCTAssertTrue(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))

        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: false,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            taboraIsEnabled: false,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: false,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: false,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 1
        ))
    }

    func testSelectionPollingAcceptsMoreThanTwoLockedPlacements() {
        XCTAssertTrue(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 4
        ))
    }
}
