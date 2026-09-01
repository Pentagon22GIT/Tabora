import AppKit

struct AutomaticGroupRaiseMutationOutcome: Equatable {
    let completed: Bool
    let attemptedMemberIDs: Set<String>

    static let notIssued = AutomaticGroupRaiseMutationOutcome(
        completed: false,
        attemptedMemberIDs: []
    )
}

enum AutomaticGroupRaiseAttemptPolicy {
    static func acceptedMemberIDs(
        current: Set<String>,
        memberID: String,
        actionAccepted: Bool
    ) -> Set<String> {
        guard actionAccepted else { return current }
        return current.union([memberID])
    }
}

enum ConnectedSnapGroupResolution {
    case connected([ManagedWindow])
    case confirmedDisconnected
    case indeterminate
}

extension SnapController {
    func scheduleConnectedGroupRaiseForPlainClick(at point: CGPoint) {
        guard isEnabled,
              settings.linkedResizeEnabled,
              settings.raiseConnectedWindowsOnClick,
              !isApplicationInteractionSuppressed,
              !isSnapPlacementInProgress,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              activeSession == nil,
              !isAssistPlacementPending,
              !missionControlSelectionTransactionIsActive else { return }

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
              !isApplicationInteractionSuppressed,
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

        let visibleWindows = clickedIdentity == nil
            ? managedVisibleWindows()
            : managedExplicitGroupWindows()
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
        guard let clickedWindow else {
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

        let groupWindows: [ManagedWindow]
        switch connectedSnapGroupResolution(
            for: clickedWindow,
            visibleWindows: visibleWindows
        ) {
        case .connected(let windows):
            groupWindows = windows
        case .indeterminate:
            // Retry observation only. No raise/focus mutation is reissued until
            // exact membership/geometry becomes usable.
            if origin == .pointer,
               point != nil,
               resolutionAttempts < maximumPlainClickResolutionAttempts {
                scheduleConnectedGroupRaiseEvaluation(
                    at: point,
                    clickedIdentity: clickedWindow.stableIdentity,
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
                selectedIdentity: clickedWindow.stableIdentity,
                origin: origin,
                refreshHandles: refreshHandlesWhenSettled
            )
            return
        case .confirmedDisconnected:
            finishConnectedGroupRaiseCycle(
                visibleWindows: visibleWindows,
                selectedIdentity: clickedWindow.stableIdentity,
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
            // A different group becoming selected can leave Window Server / AX
            // foreground evidence between states for the first observation.
            // Reuse the existing bounded pointer-resolution budget for passive
            // re-observation only; no AXRaise is authorized by uncertainty.
            if GroupForegroundPointerObservationPolicy.shouldRetry(
                isPointerOrigin: origin == .pointer,
                completedObservationAttempts: resolutionAttempts,
                maximumObservationAttempts: maximumPlainClickResolutionAttempts
            ), let point {
                scheduleConnectedGroupRaiseEvaluation(
                    at: point,
                    clickedIdentity: clickedWindow.stableIdentity,
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
            // Switching from another group requires Window Server selection,
            // focused-surface identity and AX focus to converge. A false result
            // here is not permission to weaken that safety gate; for a direct
            // pointer interaction, passively re-observe within the same bounded
            // budget and issue no mutation until the original gate succeeds.
            if GroupForegroundPointerObservationPolicy.shouldRetry(
                isPointerOrigin: origin == .pointer,
                completedObservationAttempts: resolutionAttempts,
                maximumObservationAttempts: maximumPlainClickResolutionAttempts
            ), let point {
                scheduleConnectedGroupRaiseEvaluation(
                    at: point,
                    clickedIdentity: clickedWindow.stableIdentity,
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
        let raiseOutcome = raiseWindowsForAutomaticSelection(
            groupWindows,
            withMainWindow: clickedWindow,
            isRequestCurrent: { [weak self] in
                self?.groupRaiseGeneration == generation
            }
        )
        guard raiseOutcome.completed else {
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

    /// A settled system selection supersedes every earlier automatic grant.
    /// Persistent solo isolation belongs to its own group and is intentionally
    /// retained. The selected group can be rearmed in the same observation,
    /// but only after its complete-frontmost postcondition is proven.
    func closeAutomaticForegroundModes() {
        guard groupForegroundModes.values.contains(.automatic) else { return }
        groupForegroundModes = groupForegroundModes.mapValues { mode in
            GroupForegroundAuthorizationPolicy
                .modeAfterSystemSelectionSupersedesAutomatic(mode)
        }
    }

    func pruneForegroundStateForActiveGroups() {
        let activeGroupIDs = Set(explicitGroupStore.groups.map(\.id))
        groupForegroundModes = groupForegroundModes.filter {
            activeGroupIDs.contains($0.key)
        }
    }

    func connectedSnapGroupResolution(
        for clickedWindow: ManagedWindow,
        visibleWindows: [ManagedWindow]
    ) -> ConnectedSnapGroupResolution {
        guard let explicitGroup = explicitGroupStore.group(
            containing: clickedWindow.stableIdentity
        ) else {
            return .confirmedDisconnected
        }
        guard let placement = lockedPlacements[clickedWindow.stableIdentity],
              let screen = screen(withDisplayID: placement.displayID),
              let currentDisplayID = displayID(for: screen),
              explicitGroup.displayID == currentDisplayID else {
            // Missing controller/display evidence is not proof that persistent
            // membership disappeared. The foreground operation can wait for a
            // bounded observation retry without changing structure.
            return .indeterminate
        }

        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var resolvedWindows: [String: ManagedWindow] = [:]
        for memberID in explicitGroup.memberIDs {
            guard let memberPlacement = lockedPlacements[memberID],
                  memberPlacement.displayID == currentDisplayID else {
                return .indeterminate
            }
            if let visible = windowsByIdentity[memberID] {
                resolvedWindows[memberID] = visible
                continue
            }
            switch windowService.refreshedPersistedWindow(
                element: memberPlacement.element,
                pid: memberPlacement.pid,
                expectedStableIdentity: memberPlacement.stableIdentity,
                cgWindowID: memberPlacement.cgWindowID,
                messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
            ) {
            case .available(let exactWindow):
                resolvedWindows[memberID] = exactWindow
            case .missing:
                // Confirmed absence makes a foreground operation impossible
                // now, but this function still does not own structural cleanup.
                return .confirmedDisconnected
            case .unknown:
                return .indeterminate
            }
        }

        let placements = explicitGroup.memberIDs.compactMap { identity
            -> SplitPlacementGeometry? in
            guard let memberPlacement = lockedPlacements[identity],
                  let currentWindow = resolvedWindows[identity] else {
                return nil
            }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: memberPlacement.zone,
                frame: currentWindow.frame
            )
        }
        guard placements.count == explicitGroup.memberIDs.count else {
            return .indeterminate
        }
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements,
            detachedConnections: detachedConnections
        )
        let groupIDs = SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: clickedWindow.stableIdentity,
            handles: handles
        )
        guard groupIDs == explicitGroup.memberIDs, groupIDs.count >= 2 else {
            // One exact geometry sample can be mid-settlement. Do not convert
            // it to structural disconnection; callers may perform bounded
            // observation retry without reissuing any mutation.
            return .indeterminate
        }
        return .connected(
            explicitGroup.memberIDs.compactMap { resolvedWindows[$0] }
        )
    }

    func replayDeferredForegroundSignalIfNeeded() {
        guard pendingGroupRaiseWorkItem == nil,
              pendingSelectionRaiseWorkItem == nil,
              !missionControlSelectionTransactionIsActive else {
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

    func discardDeferredForegroundSignals() {
        deferredPlainClickPoint = nil
        deferredSelectionExpectedPID = nil
        hasDeferredSelectionSignal = false
    }

    func connectedGroupFrontmostEvaluation(
        _ groupWindows: [ManagedWindow],
        allowsExactIdentityWithTransformedGeometry: Bool = false
    ) -> GroupFrontmostEvaluation {
        let resolved = groupWindows.map {
            windowService.resolvingWindowServerIdentity(
                $0,
                allowsExactIdentityWithTransformedGeometry:
                    allowsExactIdentityWithTransformedGeometry
            )
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

    func invalidatePendingGroupRaise(
        preservingMissionControlProxyActivation preserveActivation: Bool = false
    ) {
        // Once the exact selected Proxy has delivered its callback, every
        // queued group-raise item belongs to that immutable activation
        // generation: activation setup first invalidates all older desktop
        // raises, then creates its own retry. Active Space publication may
        // clear unrelated operations without cancelling this owner.
        if preserveActivation,
           activeMissionControlProxyActivation != nil {
            return
        }
        let invalidatedMissionControlSelection =
            activeMissionControlProxyActivation != nil
        if let activation = activeMissionControlProxyActivation {
            // The selected proxy owns its group identity from the first callback
            // onward. Cancellation must never depend on a later AX mutation
            // having been established. A bounded visual handoff cover may
            // still be registered, so cancellation must withdraw that exact
            // selected proxy as part of invalidation.
            missionControlGroupProxyController.cancelSelectionTransition(
                for: activation.groupID
            )
        }
        groupRaiseGeneration &+= 1
        pendingGroupRaiseWorkItem?.cancel()
        pendingGroupRaiseWorkItem = nil
        activeMissionControlProxyActivation = nil
        endOwnedForegroundMutation()
        if invalidatedMissionControlSelection {
            // A consumed Mission Control selection never donates its queued
            // focus/click callbacks to the ordinary desktop selection path.
            discardDeferredForegroundSignals()
        }
    }

    func beginOwnedForegroundMutation(
        groupID: SnapGroupID,
        windows: [ManagedWindow],
        generation: Int,
        allowsExactIdentityWithTransformedGeometry: Bool = false,
        requiresExistingOwnershipMatch: Bool = false
    ) -> Bool {
        let resolved = windows.map {
            windowService.resolvingWindowServerIdentity(
                $0,
                allowsExactIdentityWithTransformedGeometry:
                    allowsExactIdentityWithTransformedGeometry
            )
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
        if requiresExistingOwnershipMatch {
            // A partially-issued Mission Control transaction may continue only
            // against the exact Window Server identities it originally owned.
            // Rebinding here would let stale attempted-member evidence skip a
            // newly-created/reidentified surface.
            return false
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
        // the fallback reports the final member as a new external selection.
        foregroundSelectionMonitor.invalidateBaseline()
    }

    func automaticGroupRaiseIsSafe(
        for selectedWindow: ManagedWindow,
        allowedWindowServerSelections:
            Set<WindowServerSelectionSnapshot>? = nil,
        allowedAccessibilitySelections: [FocusedWindowIdentity]? = nil,
        allowsExactIdentityWithTransformedGeometry: Bool = false
    ) -> Bool {
        let resolved = windowService.resolvingWindowServerIdentity(
            selectedWindow,
            allowsExactIdentityWithTransformedGeometry:
                allowsExactIdentityWithTransformedGeometry
        )
        guard let selectedWindowID = resolved.cgWindowID else { return false }
        let selectedServerSurface = WindowServerSelectionSnapshot(
            pid: resolved.pid,
            windowID: selectedWindowID
        )
        let selectedAccessibilitySurface = FocusedWindowIdentity(
            pid: resolved.pid,
            stableIdentity: resolved.stableIdentity
        )
        let focusedWindowServerSelection =
            allowsExactIdentityWithTransformedGeometry
                ? windowService.focusedWindowServerSelectionSnapshot(
                    matching: resolved,
                    allowsExactIdentityWithTransformedGeometry: true
                )
                : windowService.focusedWindowServerSelectionSnapshot()
        return ForegroundSafetyPolicy.allowsAutomaticRaise(
            ForegroundSafetyEvidence(
                selectedPID: resolved.pid,
                selectedIdentity: resolved.stableIdentity,
                selectedWindowID: selectedWindowID,
                allowedWindowServerSelections:
                    allowedWindowServerSelections ?? [selectedServerSurface],
                allowedAccessibilitySelections:
                    allowedAccessibilitySelections
                        ?? [selectedAccessibilitySurface],
                windowServerSelection: windowService
                    .windowServerSelectionSnapshot(),
                focusedWindowServerSelection: focusedWindowServerSelection,
                accessibilitySelection: windowService
                    .activeWindowIdentitySnapshot()
            )
        )
    }

    /// Revalidates the selected surface immediately before AXRaise. This is
    /// exclusively the ordinary desktop-selection path. Mission Control uses
    /// its own complete-group ordering transaction because a proxy selection
    /// and a real-window selection have different authorization evidence.
    @discardableResult
    func raiseWindowsForAutomaticSelection(
        _ windows: [ManagedWindow],
        withMainWindow mainWindow: ManagedWindow,
        isRequestCurrent: () -> Bool
    ) -> AutomaticGroupRaiseMutationOutcome {
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
        guard resolvedMain.cgWindowID != nil else { return .notIssued }
        let resolvedFollowers = followers.map {
            windowService.resolvingWindowServerIdentity($0)
        }
        guard resolvedFollowers.allSatisfy({ $0.cgWindowID != nil }) else {
            return .notIssued
        }
        guard let group = explicitGroupStore.group(
            containing: resolvedMain.stableIdentity
        ), beginOwnedForegroundMutation(
            groupID: group.id,
            windows: uniqueWindows,
            generation: groupRaiseGeneration
        ) else {
            return .notIssued
        }
        var allowedWindowServerSelections = Set<WindowServerSelectionSnapshot>()
        var allowedAccessibilitySelections: [FocusedWindowIdentity] = []

        func authorize(_ resolved: ManagedWindow) -> Bool {
            guard let windowID = resolved.cgWindowID else { return false }
            allowedWindowServerSelections.insert(
                WindowServerSelectionSnapshot(
                    pid: resolved.pid,
                    windowID: windowID
                )
            )
            let accessibility = FocusedWindowIdentity(
                pid: resolved.pid,
                stableIdentity: resolved.stableIdentity
            )
            if !allowedAccessibilitySelections.contains(accessibility) {
                allowedAccessibilitySelections.append(accessibility)
            }
            return true
        }

        guard authorize(resolvedMain) else { return .notIssued }

        let initialLiveness = [resolvedMain] + resolvedFollowers
        guard isRequestCurrent(),
              !initialLiveness.contains(where: {
                  self.windowService.windowLiveness(
                      element: $0.element,
                      pid: $0.pid
                  ) == .missing
              }) else {
            return AutomaticGroupRaiseMutationOutcome(
                completed: false,
                attemptedMemberIDs: []
            )
        }
        guard initialLiveness.allSatisfy({
            self.windowService.windowLiveness(
                element: $0.element,
                pid: $0.pid
            ) == .alive
        }),
            automaticGroupRaiseIsSafe(
                for: resolvedMain,
                allowedWindowServerSelections:
                    allowedWindowServerSelections,
                allowedAccessibilitySelections:
                    allowedAccessibilitySelections,
                allowsExactIdentityWithTransformedGeometry: false
            ) else {
            return AutomaticGroupRaiseMutationOutcome(
                completed: false,
                attemptedMemberIDs: []
            )
        }

        var attemptedMemberIDs = Set<String>()
        for follower in resolvedFollowers.reversed() {
            guard isRequestCurrent() else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            guard automaticGroupRaiseIsSafe(
                for: resolvedMain,
                allowedWindowServerSelections:
                    allowedWindowServerSelections,
                allowedAccessibilitySelections:
                    allowedAccessibilitySelections,
                allowsExactIdentityWithTransformedGeometry: false
            ) else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            let liveness = windowService.windowLiveness(
                element: follower.element,
                pid: follower.pid
            )
            guard liveness != .missing else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            guard liveness == .alive else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            // Only an accepted AX request advances the one-shot mutation
            // barrier. Marking a transport failure as attempted permanently
            // skipped that member on every bounded retry and allowed a partial
            // group foreground to masquerade as a complete raise sequence.
            let raiseAccepted = windowService.raise(follower)
            let acceptedMemberIDs = AutomaticGroupRaiseAttemptPolicy
                .acceptedMemberIDs(
                    current: attemptedMemberIDs,
                    memberID: follower.stableIdentity,
                    actionAccepted: raiseAccepted
                )
            guard acceptedMemberIDs != attemptedMemberIDs else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            attemptedMemberIDs = acceptedMemberIDs
            guard authorize(follower) else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
        }

        if !attemptedMemberIDs.contains(resolvedMain.stableIdentity) {
            guard isRequestCurrent() else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            guard automaticGroupRaiseIsSafe(
                for: resolvedMain,
                allowedWindowServerSelections:
                    allowedWindowServerSelections,
                allowedAccessibilitySelections:
                    allowedAccessibilitySelections,
                allowsExactIdentityWithTransformedGeometry: false
            ) else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            let mainLiveness = windowService.windowLiveness(
                element: resolvedMain.element,
                pid: resolvedMain.pid
            )
            guard mainLiveness == .alive else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            let raiseAccepted = windowService.raise(resolvedMain)
            let acceptedMemberIDs = AutomaticGroupRaiseAttemptPolicy
                .acceptedMemberIDs(
                    current: attemptedMemberIDs,
                    memberID: resolvedMain.stableIdentity,
                    actionAccepted: raiseAccepted
                )
            guard acceptedMemberIDs != attemptedMemberIDs else {
                return AutomaticGroupRaiseMutationOutcome(
                    completed: false,
                    attemptedMemberIDs: attemptedMemberIDs
                )
            }
            attemptedMemberIDs = acceptedMemberIDs
        }

        let expectedMemberIDs = Set(uniqueWindows.map(\.stableIdentity))
        return AutomaticGroupRaiseMutationOutcome(
            completed: expectedMemberIDs.isSubset(of: attemptedMemberIDs),
            attemptedMemberIDs: attemptedMemberIDs
        )

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
        let visibleWindows = managedExplicitGroupWindows()
        let scopedWindows: [ManagedWindow]
        if visibleWindows.contains(where: {
            $0.stableIdentity == mainWindow.stableIdentity
        }) {
            scopedWindows = visibleWindows
        } else {
            scopedWindows = visibleWindows + [mainWindow]
        }
        guard case .connected(let groupWindows) = connectedSnapGroupResolution(
            for: mainWindow,
            visibleWindows: scopedWindows
        ) else { return }
        if requiresConnectedPeer, groupWindows.count < 2 { return }
        guard connectedGroupFrontmostEvaluation(groupWindows) == .occluded else {
            return
        }
        raiseWindows(groupWindows, withMainWindow: mainWindow)
    }

}
