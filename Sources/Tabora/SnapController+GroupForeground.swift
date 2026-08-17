import AppKit

extension SnapController {
    func scheduleConnectedGroupRaiseForPlainClick(at point: CGPoint) {
        guard isEnabled,
              settings.linkedResizeEnabled,
              settings.raiseConnectedWindowsOnClick,
              !isApplicationUIVisible,
              !isSnapPlacementInProgress,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              activeSession == nil,
              !isAssistPlacementPending else { return }

        // A Window Server selection cycle is authoritative for Mission Control
        // and app switching. Do not start the pointer fallback while that
        // existing cycle is still settling.
        if pendingGroupRaiseWorkItem != nil
            || pendingSelectionRaiseWorkItem != nil {
            deferredPlainClickPoint = point
            return
        }

        invalidatePendingGroupRaise()
        groupRaiseGeneration &+= 1
        scheduleConnectedGroupRaiseEvaluation(
            at: point,
            clickedIdentity: nil,
            origin: .pointer,
            refreshHandlesWhenSettled: false,
            resolutionAttempts: 0,
            completedAttempts: 0,
            generation: groupRaiseGeneration,
            delay: groupRaiseSettleDelay
        )
    }

    func scheduleConnectedGroupRaiseEvaluation(
        at point: CGPoint?,
        clickedIdentity: String?,
        origin: ConnectedGroupRaiseOrigin,
        refreshHandlesWhenSettled: Bool,
        resolutionAttempts: Int,
        completedAttempts: Int,
        generation: Int,
        delay: TimeInterval
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.groupRaiseGeneration == generation else { return }
            self.pendingGroupRaiseWorkItem = nil
            self.evaluateConnectedGroupRaise(
                at: point,
                clickedIdentity: clickedIdentity,
                origin: origin,
                refreshHandlesWhenSettled: refreshHandlesWhenSettled,
                resolutionAttempts: resolutionAttempts,
                completedAttempts: completedAttempts,
                generation: generation
            )
        }
        pendingGroupRaiseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    func evaluateConnectedGroupRaise(
        at point: CGPoint?,
        clickedIdentity: String?,
        origin: ConnectedGroupRaiseOrigin,
        refreshHandlesWhenSettled: Bool,
        resolutionAttempts: Int,
        completedAttempts: Int,
        generation: Int
    ) {
        guard groupRaiseGeneration == generation else { return }
        guard isEnabled,
              settings.linkedResizeEnabled,
              !isApplicationUIVisible,
              !isSnapPlacementInProgress,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              activeSession == nil,
              !isAssistPlacementPending else {
            finishConnectedGroupRaiseCycle(
                visibleWindows: nil,
                selectedIdentity: nil,
                origin: origin,
                refreshHandles: false
            )
            return
        }

        let visibleWindows = managedVisibleWindows()
        guard settings.raiseConnectedWindowsOnClick else {
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: nil,
                origin: origin,
                refreshHandles: refreshHandlesWhenSettled
            )
            return
        }
        let clickedWindow: ManagedWindow?
        if let clickedIdentity {
            clickedWindow = visibleWindows.first {
                $0.stableIdentity == clickedIdentity
            }
        } else if let point {
            clickedWindow = resolvedUserWindowAtMouseUp(
                at: point,
                visibleWindows: visibleWindows
            )
        } else {
            clickedWindow = nil
        }
        guard let clickedWindow,
              let groupWindows = connectedSnapGroupWindows(
                  for: clickedWindow,
                  visibleWindows: visibleWindows
              ) else {
            if origin == .pointer,
               point != nil,
               resolutionAttempts < maximumPlainClickResolutionAttempts {
                scheduleConnectedGroupRaiseEvaluation(
                    at: point,
                    clickedIdentity: nil,
                    origin: .pointer,
                    refreshHandlesWhenSettled: false,
                    resolutionAttempts: resolutionAttempts + 1,
                    completedAttempts: completedAttempts,
                    generation: generation,
                    delay: groupRaiseVerificationDelay
                )
                return
            }
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: nil,
                origin: origin,
                refreshHandles: refreshHandlesWhenSettled
            )
            return
        }

        if let clickedGroup = explicitGroupStore.group(
            containing: clickedWindow.stableIdentity
        ), GroupForegroundAuthorizationPolicy.directClickDisposition(
            for: foregroundMode(for: clickedGroup.id)
        ) == .preserveSystemIsolation {
            // A system-level single-window selection is a persistent per-group
            // lock. Even if every member later becomes visible, an ordinary
            // member click must not silently turn back into group intent.
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: clickedWindow.stableIdentity,
                origin: origin,
                refreshHandles: true
            )
            return
        }

        switch connectedGroupFrontmostEvaluation(groupWindows) {
        case .verifiedFrontmost:
            // The complete-frontmost postcondition is proven by Window Server,
            // so the direct desktop click can safely restore automatic mode.
            setAutomaticForegroundMode(
                forMemberID: clickedWindow.stableIdentity
            )
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: clickedWindow.stableIdentity,
                origin: origin,
                refreshHandles: refreshHandlesWhenSettled
                    || completedAttempts > 0
            )
            return
        case .indeterminate:
            // An incomplete Window Server scene is not authorization to rearm
            // group foregrounding and is not authorization to AXRaise peers.
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: clickedWindow.stableIdentity,
                origin: origin,
                refreshHandles: refreshHandlesWhenSettled
            )
            return
        case .occluded:
            break
        }

        guard completedAttempts < maximumGroupRaiseAttempts else {
            // Intent alone is insufficient: if the complete group never
            // becomes frontmost, keep controls and linked native resize
            // suppressed until a later explicit, successful interaction.
            setSoloForegroundMode(
                memberID: clickedWindow.stableIdentity
            )
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: clickedWindow.stableIdentity,
                origin: origin,
                refreshHandles: true
            )
            return
        }
        guard automaticGroupRaiseIsSafe(
            for: clickedWindow
        ) else {
            setSoloForegroundMode(
                memberID: clickedWindow.stableIdentity
            )
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: nil,
                origin: origin,
                refreshHandles: refreshHandlesWhenSettled
            )
            return
        }
        guard raiseWindowsForAutomaticSelection(
            groupWindows,
            withMainWindow: clickedWindow,
            isRequestCurrent: { [weak self] in
                self?.groupRaiseGeneration == generation
            }
        ) else {
            setSoloForegroundMode(
                memberID: clickedWindow.stableIdentity
            )
            finishConnectedGroupRaiseCycle(
                visibleWindows: nil,
                selectedIdentity: nil,
                origin: origin,
                refreshHandles: true
            )
            return
        }
        setAutomaticForegroundMode(
            forMemberID: clickedWindow.stableIdentity
        )
        scheduleConnectedGroupRaiseEvaluation(
            at: point,
            clickedIdentity: clickedWindow.stableIdentity,
            origin: origin,
            refreshHandlesWhenSettled: refreshHandlesWhenSettled,
            resolutionAttempts: resolutionAttempts,
            completedAttempts: completedAttempts + 1,
            generation: generation,
            delay: groupRaiseVerificationDelay
        )
    }

    func finishConnectedGroupRaiseCycle(
        visibleWindows: [ManagedWindow]?,
        selectedIdentity: String?,
        origin: ConnectedGroupRaiseOrigin,
        refreshHandles: Bool
    ) {
        if let selectedIdentity {
            explicitGroupStore.setPreferredMember(selectedIdentity)
        }
        if refreshHandles {
            refreshResizeHandles(using: visibleWindows)
        }
        endOwnedForegroundMutation()
        replayDeferredForegroundSignalIfNeeded()
        _ = origin
    }

    func foregroundMode(for groupID: SnapGroupID) -> GroupForegroundMode {
        groupForegroundModes[groupID] ?? .defaultMode
    }

    func setSoloForegroundMode(memberID: String) {
        guard let group = explicitGroupStore.group(containing: memberID)
        else { return }
        groupForegroundModes[group.id] = .soloPresented(memberID: memberID)
    }

    func setAutomaticForegroundMode(forMemberID memberID: String) {
        guard let group = explicitGroupStore.group(containing: memberID)
        else { return }
        setAutomaticForegroundMode(forGroupID: group.id)
    }

    func setAutomaticForegroundMode(forGroupID groupID: SnapGroupID) {
        groupForegroundModes[groupID] = .automatic
    }

    func pruneForegroundStateForActiveGroups() {
        let activeGroupIDs = Set(explicitGroupStore.groups.map(\.id))
        groupForegroundModes = groupForegroundModes.filter {
            activeGroupIDs.contains($0.key)
        }
    }

    func connectedSnapGroupWindows(
        for clickedWindow: ManagedWindow,
        visibleWindows: [ManagedWindow]
    ) -> [ManagedWindow]? {
        guard windowService.canMoveAndResize(clickedWindow),
              let explicitGroup = explicitGroupStore.group(
                  containing: clickedWindow.stableIdentity
              ),
              let placement = lockedPlacements[clickedWindow.stableIdentity],
              let screen = screen(withDisplayID: placement.displayID),
              let currentDisplayID = displayID(for: screen),
              explicitGroup.displayID == currentDisplayID else { return nil }

        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let placements = lockedPlacements.compactMap { identity, placement
            -> SplitPlacementGeometry? in
            guard explicitGroup.memberIDs.contains(identity),
                  placement.displayID == currentDisplayID,
                  let currentWindow = windowsByIdentity[identity],
                  windowService.canMoveAndResize(currentWindow) else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: currentWindow.frame
            )
        }
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements,
            detachedConnections: detachedConnections
        )
        let groupIDs = SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: clickedWindow.stableIdentity,
            handles: handles
        )
        guard groupIDs == explicitGroup.memberIDs,
              groupIDs.count >= 2 else { return nil }
        return visibleWindows.filter {
            explicitGroup.memberIDs.contains($0.stableIdentity)
        }
    }

    func replayDeferredForegroundSignalIfNeeded() {
        guard pendingGroupRaiseWorkItem == nil,
              pendingSelectionRaiseWorkItem == nil,
              activeMissionControlProxyActivationGeneration == nil else {
            return
        }
        if hasDeferredSelectionSignal {
            let expectedPID = deferredSelectionExpectedPID
            hasDeferredSelectionSignal = false
            deferredSelectionExpectedPID = nil
            scheduleSelectionDrivenGroupRaise(expectedPID: expectedPID)
            return
        }
        guard let point = deferredPlainClickPoint else { return }
        deferredPlainClickPoint = nil
        scheduleConnectedGroupRaiseForPlainClick(at: point)
    }

    func connectedGroupFrontmostEvaluation(
        _ groupWindows: [ManagedWindow]
    ) -> GroupFrontmostEvaluation {
        let resolved = groupWindows.map {
            windowService.resolvingWindowServerIdentity($0)
        }
        let selections = Set(resolved.compactMap { window in
            window.cgWindowID.map {
                WindowServerSelectionSnapshot(pid: window.pid, windowID: $0)
            }
        })
        guard selections.count == Set(groupWindows.map(\.stableIdentity)).count
        else { return .indeterminate }
        return GroupFrontmostEvaluationPolicy.evaluate(
            memberSelections: selections,
            snapshot: windowService.windowOcclusionSnapshot()
        )
    }

    func invalidatePendingGroupRaise() {
        if activeMissionControlProxyActivationGeneration != nil,
           let groupID = ownedForegroundMutation?.groupID {
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
        }
        groupRaiseGeneration &+= 1
        pendingGroupRaiseWorkItem?.cancel()
        pendingGroupRaiseWorkItem = nil
        activeMissionControlProxyActivationGeneration = nil
        missionControlProxyFocusRequestedGeneration = nil
        endOwnedForegroundMutation()
    }

    func beginOwnedForegroundMutation(
        groupID: SnapGroupID,
        windows: [ManagedWindow],
        generation: Int
    ) -> Bool {
        let resolved = windows.map {
            windowService.resolvingWindowServerIdentity($0)
        }
        let selections = Set(resolved.compactMap { window in
            window.cgWindowID.map {
                WindowServerSelectionSnapshot(
                    pid: window.pid,
                    windowID: $0
                )
            }
        })
        guard selections.count == Set(
            windows.map(\.stableIdentity)
        ).count else {
            return false
        }
        let memberIdentities = Set(windows.map(\.stableIdentity))
        if let current = ownedForegroundMutation,
           current.generation == generation,
           current.groupID == groupID,
           current.memberIdentities == memberIdentities,
           current.memberSelections == selections {
            return true
        }
        endOwnedForegroundMutation()
        ownedForegroundMutation = OwnedForegroundMutation(
            generation: generation,
            groupID: groupID,
            memberIdentities: memberIdentities,
            memberSelections: selections
        )
        // A new explicit foreground request supersedes notifications queued
        // before it. Notifications generated during this transaction are
        // filtered by exact Window Server identity instead of replayed.
        hasDeferredSelectionSignal = false
        deferredSelectionExpectedPID = nil
        return true
    }

    func endOwnedForegroundMutation(generation: Int? = nil) {
        guard let mutation = ownedForegroundMutation,
              generation == nil || mutation.generation == generation else {
            return
        }
        ownedForegroundMutation = nil
        // Establish a fresh baseline after our AXRaise sequence. Otherwise
        // the poller reports the final member as a new external selection.
        windowServerSelectionPollState.reset()
    }

    func automaticGroupRaiseIsSafe(
        for selectedWindow: ManagedWindow,
        allowedWindowServerIDs: Set<CGWindowID>? = nil
    ) -> Bool {
        let resolved = windowService.resolvingWindowServerIdentity(
            selectedWindow
        )
        guard let selectedWindowID = resolved.cgWindowID else { return false }
        return ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: resolved.pid,
                selectedIdentity: resolved.stableIdentity,
                selectedWindowID: selectedWindowID,
                allowedWindowServerIDs: allowedWindowServerIDs
                    ?? [selectedWindowID],
                windowServerSelection: windowService
                    .windowServerSelectionSnapshot(),
                focusedWindowServerSelection: windowService
                    .focusedWindowServerSelectionSnapshot(),
                accessibilitySelection: windowService
                    .activeWindowIdentitySnapshot()
            )
        )
    }

    /// Revalidates the selected surface immediately before every AXRaise.
    /// The first failed validation permanently aborts this request; a later
    /// notification must create a new generation before another attempt.
    @discardableResult
    func raiseWindowsForAutomaticSelection(
        _ windows: [ManagedWindow],
        withMainWindow mainWindow: ManagedWindow,
        isRequestCurrent: () -> Bool
    ) -> Bool {
        var seen = Set<String>()
        let uniqueWindows = windows.filter {
            seen.insert($0.stableIdentity).inserted
        }
        let followers = uniqueWindows.filter {
            $0.stableIdentity != mainWindow.stableIdentity
        }
        let resolvedMain = windowService.resolvingWindowServerIdentity(
            mainWindow
        )
        guard let mainWindowID = resolvedMain.cgWindowID else { return false }
        let resolvedFollowers = followers.map {
            windowService.resolvingWindowServerIdentity($0)
        }
        guard resolvedFollowers.allSatisfy({ $0.cgWindowID != nil }) else {
            return false
        }
        guard let group = explicitGroupStore.group(
            containing: resolvedMain.stableIdentity
        ), beginOwnedForegroundMutation(
            groupID: group.id,
            windows: uniqueWindows,
            generation: groupRaiseGeneration
        ) else {
            return false
        }
        guard isRequestCurrent(),
              windowService.isWindowAlive(
                  element: resolvedMain.element,
                  pid: resolvedMain.pid
              ),
              resolvedFollowers.allSatisfy({
                  windowService.isWindowAlive(element: $0.element, pid: $0.pid)
              }),
              automaticGroupRaiseIsSafe(
                  for: resolvedMain,
                  allowedWindowServerIDs: [mainWindowID]
              ) else {
            return false
        }
        var allowedWindowServerIDs: Set<CGWindowID> = [mainWindowID]

        for follower in resolvedFollowers.reversed() {
            guard isRequestCurrent(),
                  automaticGroupRaiseIsSafe(
                      for: resolvedMain,
                      allowedWindowServerIDs: allowedWindowServerIDs
                  ),
                  windowService.isWindowAlive(
                      element: follower.element,
                      pid: follower.pid
                  ),
                  windowService.raise(follower) else {
                return false
            }
            if let followerWindowID = follower.cgWindowID {
                allowedWindowServerIDs.insert(followerWindowID)
            }
        }
        guard isRequestCurrent(),
              automaticGroupRaiseIsSafe(
                  for: resolvedMain,
                  allowedWindowServerIDs: allowedWindowServerIDs
              ),
              windowService.isWindowAlive(
                  element: resolvedMain.element,
                  pid: resolvedMain.pid
              ) else {
            return false
        }
        return windowService.raise(resolvedMain)
    }

    @discardableResult
    func raiseWindows(
        _ windows: [ManagedWindow],
        withMainWindow mainWindow: ManagedWindow
    ) -> Bool {
        var seen = Set<String>()
        let uniqueWindows = windows.filter {
            seen.insert($0.stableIdentity).inserted
        }
        let followers = uniqueWindows.filter {
            $0.stableIdentity != mainWindow.stableIdentity
        }
        var didRaiseAnyWindow = false
        for follower in followers.reversed() {
            didRaiseAnyWindow = windowService.raise(follower) || didRaiseAnyWindow
        }
        didRaiseAnyWindow = windowService.raise(mainWindow) || didRaiseAnyWindow
        return didRaiseAnyWindow
    }

    func restoreResizeGroupForeground(
        _ windows: [ManagedWindow],
        mainWindow: ManagedWindow
    ) {
        guard connectedGroupFrontmostEvaluation(windows) == .occluded else {
            return
        }
        for follower in windows where
            follower.stableIdentity != mainWindow.stableIdentity {
            _ = windowService.raise(follower)
        }
        windowService.focus(mainWindow)
    }

    func raiseSnapGroup(
        withMainWindow mainWindow: ManagedWindow,
        on screen: NSScreen,
        requiresConnectedPeer: Bool = false
    ) {
        let visibleWindows = managedVisibleWindows()
        guard let groupWindows = connectedSnapGroupWindows(
            for: mainWindow,
            visibleWindows: visibleWindows
        ) else { return }
        if requiresConnectedPeer, groupWindows.count < 2 { return }
        guard connectedGroupFrontmostEvaluation(groupWindows) == .occluded else {
            return
        }
        raiseWindows(groupWindows, withMainWindow: mainWindow)
    }

}
