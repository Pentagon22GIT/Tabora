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

    func testForegroundSelectionMonitoringRequiresEveryLongLivedCondition() {
        XCTAssertTrue(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))

        XCTAssertFalse(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: false,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: true,
            taboraIsEnabled: false,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: false,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: false,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 1
        ))
    }

    func testForegroundSelectionMonitoringAcceptsMoreThanTwoPlacements() {
        XCTAssertTrue(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 4
        ))
    }

    func testInactiveUserSessionStopsForegroundSelectionMonitoring() {
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldMonitorForegroundSelection(
            controllerIsRunning: true,
            taboraIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 4,
            userSessionIsActive: false
        ))
    }

    func testEventAuthorizationUsesTheSameLongLivedLifecycleBoundary() {
        XCTAssertTrue(MonitoringLifecyclePolicy
            .foregroundSelectionLifecycleIsActive(
                controllerIsRunning: true,
                taboraIsEnabled: true,
                linkedResizeIsEnabled: true,
                connectedWindowRaiseIsEnabled: true,
                lockedPlacementCount: 2,
                userSessionIsActive: true
            ))
        XCTAssertFalse(MonitoringLifecyclePolicy
            .foregroundSelectionLifecycleIsActive(
                controllerIsRunning: false,
                taboraIsEnabled: true,
                linkedResizeIsEnabled: true,
                connectedWindowRaiseIsEnabled: true,
                lockedPlacementCount: 2,
                userSessionIsActive: true
            ))
        XCTAssertFalse(MonitoringLifecyclePolicy
            .foregroundSelectionLifecycleIsActive(
                controllerIsRunning: true,
                taboraIsEnabled: true,
                linkedResizeIsEnabled: true,
                connectedWindowRaiseIsEnabled: true,
                lockedPlacementCount: 2,
                userSessionIsActive: false
            ))
    }
}
