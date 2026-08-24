enum MonitoringLifecyclePolicy {
    static func connectedPlacementCount(in zones: [SnapZone]) -> Int {
        zones.lazy.filter(
            SnapPlacementLayerPolicy.countsTowardConnectedLayout
        ).count
    }

    static func shouldRunSelectionPolling(
        controllerIsRunning: Bool,
        taboraIsEnabled: Bool,
        linkedResizeIsEnabled: Bool,
        connectedWindowRaiseIsEnabled: Bool,
        lockedPlacementCount: Int,
        userSessionIsActive: Bool = true
    ) -> Bool {
        controllerIsRunning
            && taboraIsEnabled
            && userSessionIsActive
            && linkedResizeIsEnabled
            && connectedWindowRaiseIsEnabled
            && lockedPlacementCount >= 2
    }
}
