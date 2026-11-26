// Effective feature state is derived. Child preferences survive changes to their parents.
extension AppSettings {
    var canReassignByGesture: Bool { gestureSnapEnabled && splitLockEnabled }

    var groupPreviewAvailable: Bool {
        linkedResizeEnabled && windowPreviewsEnabled
    }

    var transientGroupPreviewEnabled: Bool {
        groupPreviewAvailable && missionControlLatestPreviewEnabled
    }

    var groupMigrationEnabled: Bool {
        linkedResizeEnabled && missionControlGroupMigrationEnabled
    }

    func shortcutAvailable(_ action: ShortcutAction) -> Bool {
        action != .toggleSplitLock || gestureSnapEnabled
    }
}
