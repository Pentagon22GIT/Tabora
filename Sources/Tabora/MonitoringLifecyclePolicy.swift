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
        lockedPlacementCount: Int
    ) -> Bool {
        controllerIsRunning
            && taboraIsEnabled
            && linkedResizeIsEnabled
            && connectedWindowRaiseIsEnabled
            && lockedPlacementCount >= 2
    }
}
