import AppKit

extension SnapController {
    /// Keeps native edge-resize departure observable even when the initial
    /// AX-to-CG hit test cannot choose between overlapping same-application
    /// windows. Candidates are limited to registered windows whose own AX
    /// edge was under the pointer; the first real size delta identifies the
    /// actual target without guessing from title or geometry ties.
    func prepareUnresolvedNativeResizeCandidates(at point: CGPoint) {
        unresolvedNativeResizeWasActivated = false
        pendingNativeResizeCandidates = lockedPlacements.compactMap {
            identity, placement in
            // The recorded frame is a cheap prefilter. AX is consulted only
            // for locks whose edge can actually own this pointer-down.
            guard isNearWindowResizeEdge(
                point,
                frame: placement.appliedFrame
            ), let frame = windowService.currentFrame(
                of: placement.element,
                pid: placement.pid
            ), isNearWindowResizeEdge(point, frame: frame) else {
                return nil
            }
            let physicalFrame = placement.cgWindowID.flatMap { windowID in
                windowService.windowServerFrame(
                    pid: placement.pid,
                    windowID: windowID
                )
            }
            return PendingNativeResizeCandidate(
                element: placement.element,
                pid: placement.pid,
                stableIdentity: identity,
                initialFrame: frame,
                cgWindowID: placement.cgWindowID,
                initialWindowServerFrame: physicalFrame,
                departure: explicitGroupDepartureSnapshot(
                    containing: identity
                )
            )
        }
    }

    func trackUnresolvedNativeResizeIfNeeded() -> Bool {
        guard !pendingNativeResizeCandidates.isEmpty,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              !isSnapPlacementInProgress else {
            return unresolvedNativeResizeWasActivated
        }
        if unresolvedNativeResizeWasActivated {
            return true
        }

        let observations = pendingNativeResizeCandidates.compactMap {
            candidate -> NativeWindowResizePolicy.FrameObservation? in
            // A physical size delta may justify an AX-vs-AX verification, but
            // never authorizes native departure by itself. When the exact
            // Window Server surface has not changed size, skip the expensive
            // AX read entirely.
            if let windowID = candidate.cgWindowID,
               let physicalBaseline = candidate.initialWindowServerFrame,
               let currentPhysicalFrame = windowService.windowServerFrame(
                   pid: candidate.pid,
                   windowID: windowID
               ), !NativeWindowResizePolicy.didResize(
                   from: physicalBaseline,
                   to: currentPhysicalFrame,
                   tolerance: manualResizeDetectionTolerance
               ) {
                return nil
            }
            guard let currentFrame = windowService.currentFrame(
                of: candidate.element,
                pid: candidate.pid
            ) else { return nil }
            return NativeWindowResizePolicy.FrameObservation(
                stableIdentity: candidate.stableIdentity,
                original: candidate.initialFrame,
                current: currentFrame
            )
        }
        let resizedIDs = NativeWindowResizePolicy.resizedIdentities(
            in: observations,
            tolerance: manualResizeDetectionTolerance
        )
        let resizedCandidates = pendingNativeResizeCandidates.filter {
            resizedIDs.contains($0.stableIdentity)
        }
        guard !resizedCandidates.isEmpty else {
            return unresolvedNativeResizeWasActivated
        }

        if !unresolvedNativeResizeWasActivated {
            invalidatePendingOperations(rollbackPendingPlacements: false)
        }
        unresolvedNativeResizeWasActivated = true
        var retiredGroupIDs = Set<SnapGroupID>()
        for candidate in resizedCandidates {
            if let departure = candidate.departure {
                guard retiredGroupIDs.insert(departure.groupID).inserted else {
                    continue
                }
                if retireExplicitGroup(departure, reason: .nativeResizeDeparture) {
                    continue
                }
            }
            retirePlacementForNativeResize(
                identity: candidate.stableIdentity
            )
        }
        virtualResizeOverlay.hideAll()
        overlay.hide()
        activeTarget = nil
        return true
    }

    func finishUnresolvedNativeResizeIfNeeded() -> Bool {
        if !unresolvedNativeResizeWasActivated {
            _ = trackUnresolvedNativeResizeIfNeeded()
        }
        guard unresolvedNativeResizeWasActivated else {
            pendingNativeResizeCandidates.removeAll()
            return false
        }
        virtualResizeOverlay.hideAll()
        overlay.hide()
        resetDragState()
        refreshResizeHandles()
        return true
    }

    /// Observes a resize performed through an application's own window edge.
    ///
    /// Native edges never own Tabora's shared-resize transaction. Once a
    /// real size delta is observed, the complete explicit group is retired
    /// from the mouse-down snapshot. This keeps Command-Tab/Mission Control
    /// single-window selection isolated and prevents a late geometry refresh
    /// from manufacturing a partial successor group.
    func trackManualResizeIfNeeded() -> Bool {
        guard !isWindowMoveConfirmed,
              !hasWindowActuallyMoved,
              !didStartDragRestore,
              handleResizeSession == nil,
              let originalWindow = pendingDragWindow,
              let originalFrame = pendingDragWindowFrame,
              manualResizeWindow != nil
                || pendingNativeResizeDeparture != nil
                || lockedPlacements[originalWindow.stableIdentity] != nil else {
            return false
        }

        // Once native resize departure has been confirmed, the structural work
        // is already complete. Continue owning the gesture without polling AX
        // for every subsequent mouseDragged sample.
        if manualResizeWindow != nil {
            return true
        }

        // Window Server geometry is only a cheap prefilter here. Structural
        // native-resize departure remains AX-vs-AX below. During an ordinary
        // title-bar drag, a streamed app must not be synchronously AX-polled at
        // 60 Hz merely to prove that its size did not change.
        if manualResizeWindow == nil,
           let physicalBaseline = pendingDragWindowServerFrame,
           let currentPhysicalFrame = windowService.windowServerFrame(originalWindow) {
            pendingDragCurrentWindowServerFrame = currentPhysicalFrame
            if !NativeWindowResizePolicy.didResize(
                from: physicalBaseline,
                to: currentPhysicalFrame,
                tolerance: manualResizeDetectionTolerance
            ) {
                return false
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastManualResizeRefreshAt < manualResizeRefreshInterval {
            return manualResizeWindow != nil
        }
        lastManualResizeRefreshAt = now

        guard let currentFrame = windowService.refreshedFrame(
            originalWindow,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        ) else {
            return manualResizeWindow != nil
        }
        let currentWindow = originalWindow.replacingFrame(currentFrame)
        guard manualResizeWindow != nil
                || NativeWindowResizePolicy.didResize(
                    from: originalFrame,
                    to: currentFrame,
                    tolerance: manualResizeDetectionTolerance
                ) else {
            return false
        }

        if manualResizeWindow == nil {
            // A native edge resize is a new source of truth. Invalidate every
            // older frame transaction before retiring the group; otherwise a
            // delayed snap/reflow callback can recreate the locks that this
            // interaction just removed. Do not restore pending snapshots here
            // because that would overwrite the size chosen by the user.
            invalidatePendingOperations(rollbackPendingPlacements: false)
        }
        manualResizeWindow = currentWindow
        retirePlacementForNativeResize(
            identity: currentWindow.stableIdentity
        )
        virtualResizeOverlay.hideAll()
        dragWindow = nil
        isWindowMoveConfirmed = false
        overlay.hide()
        activeTarget = nil
        return true
    }

    /// Completes the same transaction for an ordinary mouse-up or for the
    /// one-second lost-mouse-up recovery path. Cleanup is idempotent because
    /// the authoritative departure snapshot is consumed on first use.
    func finishManualResizeIfNeeded() -> Bool {
        guard !isWindowMoveConfirmed,
              !hasWindowActuallyMoved,
              !didStartDragRestore,
              let originalWindow = pendingDragWindow,
              let originalFrame = pendingDragWindowFrame else {
            return false
        }

        if manualResizeWindow == nil,
           let currentFrame = windowService.refreshedFrame(
               originalWindow,
               messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
           ),
           NativeWindowResizePolicy.didResize(
               from: originalFrame,
               to: currentFrame,
               tolerance: manualResizeDetectionTolerance
           ) {
            invalidatePendingOperations(rollbackPendingPlacements: false)
            manualResizeWindow = originalWindow.replacingFrame(currentFrame)
            retirePlacementForNativeResize(
                identity: originalWindow.stableIdentity
            )
        }

        guard manualResizeWindow != nil else { return false }
        retirePlacementForNativeResize(identity: originalWindow.stableIdentity)
        virtualResizeOverlay.hideAll()
        overlay.hide()
        resetDragState()
        refreshResizeHandles()
        return true
    }

    /// Removes every piece of controller-owned state for the old group in one
    /// operation. If the window was only a provisional single placement, only
    /// that placement is retired. Native resize never writes a peer frame.
    private func retirePlacementForNativeResize(identity: String) {
        if let departure = pendingNativeResizeDeparture {
            pendingNativeResizeDeparture = nil
            if retireExplicitGroup(departure, reason: .nativeResizeDeparture) {
                return
            }
        }
        if dissolveExplicitGroupForUserDeparture(containing: identity) {
            return
        }
        // A provisional placement can still own a maximized-layer entry even
        // though it has no split group. Retire through the store API so that
        // stale layer occupancy cannot block a later snap.
        explicitGroupStore.removeWindow(identity)
        lockedPlacements.removeValue(forKey: identity)
        removeConnections(for: identity)
        restoreFrames.removeValue(forKey: identity)
        inFlightPlacementIDs.remove(identity)
        pendingPlacementSnapshots.removeValue(forKey: identity)
        lastGroupWindowServerEvidenceByIdentity.removeValue(forKey: identity)
    }
}
