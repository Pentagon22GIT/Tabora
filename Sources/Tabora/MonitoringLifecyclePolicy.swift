enum MonitoringLifecyclePolicy {
    static func connectedPlacementCount(in zones: [SnapZone]) -> Int {
        zones.lazy.filter(
            SnapPlacementLayerPolicy.countsTowardConnectedLayout
        ).count
    }

    static func shouldMonitorForegroundSelection(
        controllerIsRunning: Bool,
        taboraIsEnabled: Bool,
        linkedResizeIsEnabled: Bool,
        connectedWindowRaiseIsEnabled: Bool,
        lockedPlacementCount: Int,
        userSessionIsActive: Bool = true
    ) -> Bool {
        foregroundSelectionLifecycleIsActive(
            controllerIsRunning: controllerIsRunning,
            taboraIsEnabled: taboraIsEnabled,
            linkedResizeIsEnabled: linkedResizeIsEnabled,
            connectedWindowRaiseIsEnabled: connectedWindowRaiseIsEnabled,
            lockedPlacementCount: lockedPlacementCount,
            userSessionIsActive: userSessionIsActive
        )
    }

    static func foregroundSelectionLifecycleIsActive(
        controllerIsRunning: Bool,
        taboraIsEnabled: Bool,
        linkedResizeIsEnabled: Bool,
        connectedWindowRaiseIsEnabled: Bool,
        lockedPlacementCount: Int,
        userSessionIsActive: Bool
    ) -> Bool {
        controllerIsRunning
            && taboraIsEnabled
            && userSessionIsActive
            && linkedResizeIsEnabled
            && connectedWindowRaiseIsEnabled
            && lockedPlacementCount >= 2
    }
}
