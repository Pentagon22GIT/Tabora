import AppKit

extension SnapController {
    func mergedConstraintPermissionRequest(
        existing: ConstraintRecordingPermissionRequest?,
        identity: AppConstraintIdentity,
        displayName: String,
        windowStableIdentity: String?
    ) -> ConstraintRecordingPermissionRequest {
        guard let existing else {
            return ConstraintRecordingPermissionRequest(
                identity: identity,
                displayName: displayName,
                windowStableIdentity: windowStableIdentity
            )
        }
        guard existing.windowStableIdentity == nil,
              windowStableIdentity != nil else { return existing }
        return ConstraintRecordingPermissionRequest(
            identity: identity,
            displayName: existing.displayName,
            windowStableIdentity: windowStableIdentity
        )
    }

    func presentConstraintRecordingPermissionRequests(
        _ requests: [AppConstraintIdentity: ConstraintRecordingPermissionRequest]
    ) {
        guard settings.constraintRecordingPromptsEnabled,
              !requests.isEmpty,
              beginConstraintPermissionPrompt() else { return }
        var measurementRequests: [ConstraintRecordingPermissionRequest] = []
        for (identity, request) in requests.sorted(by: {
            $0.value.displayName.localizedStandardCompare($1.value.displayName)
                == .orderedAscending
        }) {
            let currentPermission = appConstraintRegistry.record(for: identity)?
                .recordingPermission ?? .undecided
            guard currentPermission == .undecided else { continue }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.format(
                "constraints.permission.title",
                request.displayName
            )
            alert.informativeText =
                L10n.text("constraints.permission.detail")
            alert.addButton(withTitle: L10n.text("common.measure"))
            let denyButton = alert.addButton(withTitle: L10n.text("common.deny"))
            denyButton.keyEquivalent = "\u{1b}"
            let response = alert.runModal()
            _ = appConstraintRegistry.ensureRecord(
                identity: identity,
                displayName: request.displayName
            )
            if response == .alertFirstButtonReturn {
                appConstraintRegistry.setPermission(.allowed, for: identity)
                if request.windowStableIdentity != nil {
                    measurementRequests.append(request)
                }
            } else {
                appConstraintRegistry.setPermission(.denied, for: identity)
            }
        }
        guard !measurementRequests.isEmpty else {
            endConstraintPermissionPrompt()
            return
        }
        // Keep the permission state—and therefore input/presentation
        // suppression—owned across the modal-to-measurement handoff. The
        // originating snap/resize callback unwinds before this continuation;
        // ending the prompt and beginning measurement then happen in one main
        // turn with no interactive gap and no fixed delay.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.endConstraintPermissionPrompt(refreshPresentation: false)
            self.measureAuthorizedConstraintRequests(measurementRequests)
        }
    }

    private func measureAuthorizedConstraintRequests(
        _ requests: [ConstraintRecordingPermissionRequest]
    ) {
        guard !requests.isEmpty,
              canRefreshPresentationAfterAsyncTransaction else {
            if isConstraintPermissionPromptActive {
                endConstraintPermissionPrompt()
            }
            return
        }
        guard beginConstraintMeasurement() else {
            if canRefreshPresentationAfterAsyncTransaction {
                refreshResizeHandles()
            }
            return
        }
        permissionConstraintMeasurementIsActive = true
        let displayName = requests.count == 1
            ? requests[0].displayName
            : L10n.format("constraints.multiple_apps", requests.count)
        permissionConstraintMeasurementProgressPanel.begin(
            displayName: displayName,
            screen: NSScreen.main
        )
        measureAuthorizedConstraintRequest(
            requests,
            at: 0,
            confirmedValueCount: 0
        )
    }

    private func measureAuthorizedConstraintRequest(
        _ requests: [ConstraintRecordingPermissionRequest],
        at index: Int,
        confirmedValueCount: Int
    ) {
        guard isConstraintMeasurementActive else { return }
        guard requests.indices.contains(index) else {
            permissionConstraintMeasurementIsActive = false
            endConstraintMeasurement()
            permissionConstraintMeasurementProgressPanel.finish(
                confirmedValueCount: confirmedValueCount,
                restoredOriginalFrame: true
            )
            return
        }
        let request = requests[index]
        guard let stableIdentity = request.windowStableIdentity,
              let window = managedVisibleWindows().first(where: {
                  $0.stableIdentity == stableIdentity
                      && windowService.isEligibleForConstraintLearning($0)
                      && appConstraintIdentityResolver.resolve($0)?.identity
                        == request.identity
              }),
              let screen = screen(containing: CGPoint(
                  x: window.frame.midX,
                  y: window.frame.midY
              ))
                ?? NSScreen.main else {
            measureAuthorizedConstraintRequest(
                requests,
                at: index + 1,
                confirmedValueCount: confirmedValueCount
            )
            return
        }

        permissionConstraintMeasurementEngine.measure(
            window: window,
            screenFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor,
            progress: { [weak self] progress in
                guard let self else { return }
                let aggregate = ConstraintMeasurementProgressPolicy
                    .aggregateFraction(
                        itemIndex: index,
                        itemCount: requests.count,
                        itemFraction: progress.fractionCompleted
                    )
                self.permissionConstraintMeasurementProgressPanel.update(
                    fractionCompleted: aggregate,
                    progress: progress,
                    displayName: request.displayName
                )
            }
        ) { [weak self] result in
            guard let self, self.isConstraintMeasurementActive else { return }
            self.appConstraintRegistry.applyExplicitMeasurement(
                result.confirmedValues,
                identity: request.identity,
                displayName: request.displayName
            )
            guard result.restoredOriginalFrame else {
                self.permissionConstraintMeasurementIsActive = false
                self.endConstraintMeasurement()
                self.permissionConstraintMeasurementProgressPanel.finish(
                    confirmedValueCount: confirmedValueCount
                        + result.confirmedValues.count,
                    restoredOriginalFrame: false
                )
                return
            }
            self.measureAuthorizedConstraintRequest(
                requests,
                at: index + 1,
                confirmedValueCount: confirmedValueCount
                    + result.confirmedValues.count
            )
        }
    }
}
