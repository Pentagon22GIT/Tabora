import Foundation

extension SnapController {
    func updateSelectionMonitoringState() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateSelectionMonitoringState()
            }
            return
        }

        pruneForegroundStateForActiveGroups()

        let shouldRun = MonitoringLifecyclePolicy
            .shouldMonitorForegroundSelection(
                controllerIsRunning: isControllerRunning,
                taboraIsEnabled: isEnabled,
                linkedResizeIsEnabled: settings.linkedResizeEnabled,
                connectedWindowRaiseIsEnabled:
                    settings.raiseConnectedWindowsOnClick,
                lockedPlacementCount: connectedLayoutPlacementCount,
                userSessionIsActive: isUserSessionActive
            )
        let lifecycleChanged = foregroundSelectionMonitor.setEnabled(shouldRun)
        if shouldRun {
            if lifecycleChanged, foregroundSelectionObservationIsAllowed {
                foregroundSelectionMonitor.establishBaseline()
            }
        } else {
            // Disable, session lock, setting OFF, or loss of a connected layout
            // ends the authorization lifecycle. Never let an automatic grant
            // survive until a later fresh baseline; persistent solo isolation
            // remains group-local and is deliberately preserved.
            closeAutomaticForegroundModes()
            if lifecycleChanged || pendingSelectionRaiseWorkItem != nil {
                invalidatePendingSelectionRaise()
            }
        }
    }

    private var foregroundSelectionObservationIsAllowed: Bool {
        selectionDrivenRaiseIsAllowed
            && !isConstraintMeasurementActive
            && !isConstraintPermissionPromptActive
            && !isRestoreTransactionActive
    }

    func pollForegroundSelectionFallback() {
        guard foregroundSelectionObservationIsAllowed else {
            foregroundSelectionMonitor.invalidateBaseline()
            return
        }
        foregroundSelectionMonitor.sampleFallback()
    }

    func handleForegroundSelectionFallbackChange(
        _ changedSelection: WindowServerSelectionSnapshot
    ) {
        guard foregroundSelectionObservationIsAllowed else {
            foregroundSelectionMonitor.invalidateBaseline()
            return
        }
        if ForegroundMutationSelectionPolicy.isOwnedSelection(
            changedSelection,
            mutation: ownedForegroundMutation
        ) {
            return
        }
        handleResizeHandlePresentationSignal(.windowServerSelectionChanged)
        activeWindowObserver.observeFrontmostApplication()
        // Rebuild safe handles now; foreground settlement may intentionally
        // take longer and must not own handle creation timing.
        refreshResizeHandles()
        scheduleSelectionDrivenGroupRaise(
            expectedPID: changedSelection.pid,
            initialSelection: changedSelection
        )
    }
}
