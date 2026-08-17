import AppKit

extension SnapController {
    @discardableResult
    func reconcileExplicitGroupAfterLayoutMutation(
        preferredMemberID: String,
        targetGroupID: SnapGroupID? = nil,
        memberScope: Set<String>? = nil
    ) -> Bool {
        guard let placement = lockedPlacements[preferredMemberID] else {
            if let departure = explicitGroupDepartureSnapshot(
                containing: preferredMemberID
            ) {
                _ = retireExplicitGroup(departure)
            } else {
                explicitGroupStore.removeWindow(preferredMemberID)
            }
            updateSelectionMonitoringState()
            refreshMissionControlGroupProxies()
            return false
        }
        let existingGroup = explicitGroupStore.group(
            containing: preferredMemberID
        )
        let effectiveTargetGroupID = targetGroupID ?? existingGroup?.id
        let effectiveMemberScope = memberScope ?? existingGroup?.memberIDs
        if placement.zone == .maximize {
            explicitGroupStore.registerMaximizedLayer(
                windowID: preferredMemberID,
                displayID: placement.displayID
            )
            updateSelectionMonitoringState()
            refreshMissionControlGroupProxies()
            return true
        } else {
            let placements = lockedPlacements.compactMap { identity, item
                -> SplitPlacementGeometry? in
                guard item.displayID == placement.displayID,
                      effectiveMemberScope?.contains(identity) ?? true else {
                    return nil
                }
                return SplitPlacementGeometry(
                    stableIdentity: identity,
                    zone: item.zone,
                    frame: item.appliedFrame
                )
            }
            let reconciled = explicitGroupStore.reconcileAfterLayoutMutation(
                preferredMemberID: preferredMemberID,
                displayID: placement.displayID,
                placements: placements,
                detachedConnections: detachedConnections,
                targetGroupID: effectiveTargetGroupID
            )
            let provisionalSingleIsValid = effectiveTargetGroupID == nil
                && placements.filter({ $0.zone != .maximize }).count == 1
            let succeeded = reconciled != nil || provisionalSingleIsValid
            updateSelectionMonitoringState()
            refreshMissionControlGroupProxies()
            return succeeded
        }
    }

    func detachFocusedWindowFromExplicitGroup() {
        guard isEnabled,
              ensurePermission(),
              let focused = windowService.focusedWindow() else { return }
        detachWindowFromExplicitGroup(focused.stableIdentity)
    }

    func detachWindowFromExplicitGroup(_ stableIdentity: String) {
        guard dissolveExplicitGroupForUserDeparture(
            containing: stableIdentity
        ) else { return }
        refreshResizeHandles()
    }

    /// A user-driven departure invalidates the complete split group. Keep the
    /// windows at their current frames, but remove every former member from
    /// Tabora's placement/restore state so no visually incomplete subgroup
    /// survives or is silently manufactured by passive reconciliation.
    @discardableResult
    func dissolveExplicitGroupForUserDeparture(
        containing stableIdentity: String
    ) -> Bool {
        guard let departure = explicitGroupDepartureSnapshot(
            containing: stableIdentity
        ) else { return false }
        return retireExplicitGroup(departure)
    }

    func explicitGroupDepartureSnapshot(
        containing stableIdentity: String
    ) -> ExplicitGroupDepartureSnapshot? {
        guard let group = explicitGroupStore.group(
            containing: stableIdentity
        ), group.memberIDs.count >= 2 else { return nil }
        return ExplicitGroupDepartureSnapshot(
            groupID: group.id,
            memberIDs: group.memberIDs
        )
    }

    /// Retire from the interaction-start snapshot, not from a late lookup.
    /// This remains complete even if another observer has already removed the
    /// group mapping while its placement locks are still present.
    @discardableResult
    func retireExplicitGroup(
        _ departure: ExplicitGroupDepartureSnapshot
    ) -> Bool {
        let dissolution = explicitGroupStore.dissolveGroups(
            intersecting: departure.memberIDs
        )
        let members = SnapGroupDeparturePolicy.retirementMemberIDs(
            captured: departure.memberIDs,
            current: dissolution.memberIDs
        )
        guard members.count >= 2 else { return false }
        let retiredGroupIDs = dissolution.groupIDs.union([departure.groupID])
        for groupID in retiredGroupIDs {
            groupForegroundModes.removeValue(forKey: groupID)
            groupDegradationEvidenceByGroupID.removeValue(forKey: groupID)
        }
        applyCompleteGroupDeparture(memberIDs: members)
        return true
    }

    @discardableResult
    func stageExplicitGroupDepartureForDrag(
        containing stableIdentity: String
    ) -> Bool {
        let departure = explicitGroupDepartureSnapshot(
            containing: stableIdentity
        ) ?? pendingNativeResizeDeparture.flatMap {
            $0.memberIDs.contains(stableIdentity) ? $0 : nil
        }
        guard let departure else { return false }
        let dissolution = explicitGroupStore.dissolveGroups(
            intersecting: departure.memberIDs
        )
        let members = SnapGroupDeparturePolicy.retirementMemberIDs(
            captured: departure.memberIDs,
            current: dissolution.memberIDs
        )
        guard members.count >= 2 else { return false }
        let retiredGroupIDs = dissolution.groupIDs.union([departure.groupID])
        for groupID in retiredGroupIDs {
            groupForegroundModes.removeValue(forKey: groupID)
            groupDegradationEvidenceByGroupID.removeValue(forKey: groupID)
        }
        if pendingNativeResizeDeparture?.groupID == departure.groupID {
            pendingNativeResizeDeparture = nil
        }
        stagedGroupDeparture = StagedGroupDeparture(
            draggedIdentity: stableIdentity,
            memberIDs: members
        )
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll()
        resetGroupPresentationTransitionRecovery()
        updateSelectionMonitoringState()
        return true
    }

    func finalizeStagedGroupDepartureIfNeeded() {
        guard let stagedGroupDeparture else { return }
        self.stagedGroupDeparture = nil
        applyCompleteGroupDeparture(
            memberIDs: stagedGroupDeparture.memberIDs
        )
    }

    private func applyCompleteGroupDeparture(memberIDs members: Set<String>) {
        detachedConnections = SnapGroupDeparturePolicy
            .connectionsAfterRetirement(
                existing: detachedConnections,
                retiredMemberIDs: members
            )
        var remainingPlacements = lockedPlacements
        for memberID in members {
            remainingPlacements.removeValue(forKey: memberID)
            restoreFrames.removeValue(forKey: memberID)
            inFlightPlacementIDs.remove(memberID)
            pendingPlacementSnapshots.removeValue(forKey: memberID)
            constraintHints.removeValue(forKey: memberID)
        }
        lockedPlacements = remainingPlacements
        if let stagedGroupDeparture,
           !stagedGroupDeparture.memberIDs.isDisjoint(with: members) {
            self.stagedGroupDeparture = nil
        }
        if let activeSession,
           !activeSession.occupiedStableIDs.isDisjoint(with: members) {
            self.activeSession = nil
            isAssistPlacementPending = false
            stopEscapeMonitoring()
            picker.hide()
        }
        missionControlGroupProxyController.hideAll()
        for memberID in members {
            lastGroupWindowServerEvidenceByIdentity.removeValue(
                forKey: memberID
            )
        }
        resetGroupPresentationTransitionRecovery()
    }

    func resetMissionControlPresentationRetryDebt() {
        groupPresentationFailureCountsByGroupID.removeAll()
        guard scheduledGroupPresentationRetryGeneration != nil else { return }
        groupDegradationRetryGeneration &+= 1
        scheduledGroupPresentationRetryGeneration = nil
    }

    func refreshMissionControlGroupProxies(
        using providedVisibleWindows: [ManagedWindow]? = nil,
        windowServerSnapshot providedWindowServerSnapshot:
            [WindowOcclusionSnapshot]? = nil
    ) {
        guard missionControlGroupPresentationIsEnabled,
              isEnabled,
              isUserSessionActive,
              settings.linkedResizeEnabled,
              !isSnapPlacementInProgress,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              manualResizeWindow == nil,
              pendingDragWindow == nil,
              dragWindow == nil,
              activeSession == nil,
              !isAssistPlacementPending,
              !isApplicationUIVisible else {
            missionControlGroupProxyController.hideAll()
            resetMissionControlPresentationRetryDebt()
            return
        }
        let visibleWindows = providedVisibleWindows ?? managedVisibleWindows()
        let windowServerSnapshot = providedWindowServerSnapshot
            ?? windowService.windowOcclusionSnapshot()
        groupDegradationObservationEpoch &+= 1
        let observationEpoch = groupDegradationObservationEpoch
        let observationTime = ProcessInfo.processInfo.systemUptime

        updateGroupWindowServerEvidence(using: visibleWindows)
        if providedVisibleWindows == nil,
           shouldPreserveGroupPresentationDuringWindowServerTransform(
               visibleWindows: visibleWindows,
               using: windowServerSnapshot
           ) {
            // Mission Control/Space transforms are global desktop states, so
            // this is one of the few legitimate global presentation suspends.
            isPreservingGroupPresentationForWindowServerTransform = true
            resizeHandleOverlay.setPresentationSuspended(true)
            return
        }
        if providedVisibleWindows == nil {
            isPreservingGroupPresentationForWindowServerTransform = false
        }

        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var presentationRecoveryGroupIDs = Set<SnapGroupID>()
        var fastPresentationRetryGroupIDs = Set<SnapGroupID>()
        var presentationSuppressedGroupIDs = Set<SnapGroupID>()
        let activeGroupIDs = Set(explicitGroupStore.groups.map(\.id))
        groupDegradationEvidenceByGroupID =
            groupDegradationEvidenceByGroupID.filter {
                activeGroupIDs.contains($0.key)
            }

        for group in explicitGroupStore.groups {
            let axMissing = group.memberIDs.subtracting(windowsByIdentity.keys)
            if screen(withDisplayID: group.displayID) == nil {
                // Display/Space topology can settle asynchronously. Keep the
                // structural group, suppress only its presentation, and let
                // Recovery obtain a fresh observation.
                presentationSuppressedGroupIDs.insert(group.id)
                missionControlGroupProxyController.hide(groupID: group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                presentationRecoveryGroupIDs.insert(group.id)
                fastPresentationRetryGroupIDs.insert(group.id)
                continue
            }

            let confirmedClosedMembers = axMissing.filter { memberID in
                guard let placement = lockedPlacements[memberID] else {
                    // A group member without its authoritative placement is an
                    // internal structural inconsistency, not an AX timeout.
                    return true
                }
                return WindowStructuralPolicy.isConfirmedMissing(
                    windowService.windowLiveness(
                        element: placement.element,
                        pid: placement.pid
                    )
                )
            }
            if let closedMemberID = confirmedClosedMembers.first {
                _ = dissolveExplicitGroupForUserDeparture(
                    containing: closedMemberID
                )
                groupDegradationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }

            guard axMissing.isEmpty else {
                // AX-visible/interaction availability is presentation evidence,
                // not structural membership. Unknown members retain the group.
                presentationSuppressedGroupIDs.insert(group.id)
                missionControlGroupProxyController.hide(groupID: group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                presentationRecoveryGroupIDs.insert(group.id)
                fastPresentationRetryGroupIDs.insert(group.id)
                continue
            }

            let placements = group.memberIDs.compactMap { memberID
                -> SplitPlacementGeometry? in
                guard let window = windowsByIdentity[memberID],
                      let placement = lockedPlacements[memberID],
                      placement.displayID == group.displayID else { return nil }
                return SplitPlacementGeometry(
                    stableIdentity: memberID,
                    zone: placement.zone,
                    frame: window.frame
                )
            }
            guard placements.count == group.memberIDs.count else {
                presentationSuppressedGroupIDs.insert(group.id)
                missionControlGroupProxyController.hide(groupID: group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                presentationRecoveryGroupIDs.insert(group.id)
                fastPresentationRetryGroupIDs.insert(group.id)
                continue
            }

            let handles = SplitLayoutGeometry.resizeHandleGeometries(
                placements: placements,
                detachedConnections: detachedConnections
            )
            let connected = SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: group.preferredMemberID,
                handles: handles
            )
            guard connected != group.memberIDs else {
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                explicitGroupStore.markDegraded(
                    groupID: group.id,
                    missingMemberIDs: []
                )
                continue
            }

            presentationSuppressedGroupIDs.insert(group.id)
            missionControlGroupProxyController.hide(groupID: group.id)
            let physicalMembersAreStillPresent = group.memberIDs.allSatisfy {
                memberID in
                guard let placement = lockedPlacements[memberID],
                      let windowID = placement.cgWindowID else { return false }
                return windowServerSnapshot.contains { surface in
                    surface.pid == placement.pid
                        && surface.windowID == windowID
                        && surface.layer == 0
                }
            }
            guard physicalMembersAreStillPresent else {
                // Window Server evidence is incomplete/indeterminate. Never
                // convert that into a structural departure.
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                presentationRecoveryGroupIDs.insert(group.id)
                fastPresentationRetryGroupIDs.insert(group.id)
                continue
            }

            let fingerprint = GroupDegradationFingerprint(
                missingMemberIDs: group.memberIDs.subtracting(connected),
                geometryDisconnected: true
            )
            let observation = GroupDegradationConfirmationPolicy.observe(
                previous: groupDegradationEvidenceByGroupID[group.id],
                fingerprint: fingerprint,
                epoch: observationEpoch,
                now: observationTime
            )
            groupDegradationEvidenceByGroupID[group.id] = observation.evidence
            presentationRecoveryGroupIDs.insert(group.id)
            if !observation.isConfirmed {
                fastPresentationRetryGroupIDs.insert(group.id)
            }
            // A settled passive geometry mismatch is presentation/recovery debt,
            // not authorization to destroy structural membership. True departure
            // is committed only by the dedicated native-resize/drag paths or a
            // confirmed missing member. The 1 Hz Recovery watchdog keeps checking
            // geometry debt after bounded fast retries are exhausted.
        }

        // Presentation availability is not structural membership. Keep debt
        // per group, use only a finite startup-style retry burst, then let the
        // existing 1 Hz Recovery watchdog re-observe without spinning a second
        // high-frequency main loop.
        groupPresentationFailureCountsByGroupID =
            groupPresentationFailureCountsByGroupID.filter {
                activeGroupIDs.contains($0.key)
                    && presentationRecoveryGroupIDs.contains($0.key)
            }
        for groupID in presentationRecoveryGroupIDs {
            groupPresentationFailureCountsByGroupID[groupID, default: 0] =
                min(
                    groupPresentationFailureCountsByGroupID[groupID] ?? 0,
                    MissionControlGroupPresentationRetryPolicy
                        .maximumFastRetryCount + 1
                )
        }
        for groupID in fastPresentationRetryGroupIDs {
            let previous = groupPresentationFailureCountsByGroupID[groupID]
                ?? 0
            groupPresentationFailureCountsByGroupID[groupID] = min(
                previous + 1,
                MissionControlGroupPresentationRetryPolicy
                    .maximumFastRetryCount + 1
            )
        }

        if fastPresentationRetryGroupIDs.isEmpty {
            if scheduledGroupPresentationRetryGeneration != nil {
                groupDegradationRetryGeneration &+= 1
                scheduledGroupPresentationRetryGeneration = nil
            }
        } else if scheduledGroupPresentationRetryGeneration == nil {
            let nextDelay: TimeInterval? =
                fastPresentationRetryGroupIDs.compactMap {
                    (groupID: SnapGroupID) -> TimeInterval? in
                    guard let failureCount =
                            groupPresentationFailureCountsByGroupID[groupID]
                    else { return nil }
                    return MissionControlGroupPresentationRetryPolicy.delay(
                        forFailureCount: failureCount
                    )
                }.min()
            if let nextDelay {
                groupDegradationRetryGeneration &+= 1
                let generation = groupDegradationRetryGeneration
                scheduledGroupPresentationRetryGeneration = generation
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + nextDelay
                ) { [weak self] in
                    guard let self,
                          self.scheduledGroupPresentationRetryGeneration
                            == generation else { return }
                    self.scheduledGroupPresentationRetryGeneration = nil
                    self.refreshResizeHandles()
                }
            }
        }

        let presentableGroups = explicitGroupStore.groups.filter {
            guard !presentationSuppressedGroupIDs.contains($0.id) else {
                return false
            }
            if case .degraded = $0.state { return false }
            if case .suspendedForSpaceTransition = $0.state { return false }
            return true
        }
        missionControlGroupProxyController.update(
            groups: presentableGroups,
            visibleWindowsByIdentity: windowsByIdentity,
            previewProvider: { [weak self] windowID in
                guard let self, self.settings.windowPreviewsEnabled else {
                    return nil
                }
                return self.windowService.previewCGImage(for: windowID)
            }
        )
    }

    func activateExplicitGroupFromMissionControlProxy(
        groupID: SnapGroupID,
        revision: UInt64
    ) {
        guard missionControlGroupPresentationIsEnabled,
              let group = explicitGroupStore.group(id: groupID) else { return }
        // Harmless state/preferred-member changes can advance the revision
        // between drawing the proxy and delivering its click. The stable group
        // identity plus the fresh geometry and selection checks below are the
        // authoritative safety evidence.
        let currentRevision = group.revision
        _ = revision
        // The proxy click is an explicit group selection, not a desktop click
        // at the same screen coordinate. Never replay that coordinate after
        // the proxy disappears, where it would resolve to the formerly top
        // window beneath the proxy and undo the requested selection.
        deferredPlainClickPoint = nil
        invalidatePendingGroupRaise()
        invalidatePendingSelectionRaise()
        groupRaiseGeneration &+= 1
        let generation = groupRaiseGeneration
        activeMissionControlProxyActivationGeneration = generation
        missionControlProxyFocusRequestedGeneration = nil
        activateExplicitGroupFromMissionControlProxy(
            groupID: groupID,
            revision: currentRevision,
            generation: generation,
            completedAttempts: 0
        )
    }

    private func activateExplicitGroupFromMissionControlProxy(
        groupID: SnapGroupID,
        revision: UInt64,
        generation: Int,
        completedAttempts: Int
    ) {
        guard groupRaiseGeneration == generation,
              activeMissionControlProxyActivationGeneration == generation,
              missionControlGroupPresentationIsEnabled,
              let group = explicitGroupStore.group(id: groupID) else {
            if activeMissionControlProxyActivationGeneration == generation {
                activeMissionControlProxyActivationGeneration = nil
                missionControlProxyFocusRequestedGeneration = nil
            }
            endOwnedForegroundMutation(generation: generation)
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
            replayDeferredForegroundSignalIfNeeded()
            return
        }
        let visibleWindows = managedVisibleWindows()
        let groupWindows = visibleWindows.filter {
            group.memberIDs.contains($0.stableIdentity)
        }
        guard groupWindows.count == group.memberIDs.count,
              let mainWindow = groupWindows.first(where: {
                  $0.stableIdentity == group.preferredMemberID
              }) else {
            if completedAttempts
                < maximumMissionControlProxyActivationSettleAttempts {
                scheduleMissionControlProxyActivationRetry(
                    groupID: groupID,
                    revision: revision,
                    generation: generation,
                    completedAttempts: completedAttempts
                )
                return
            }
            activeMissionControlProxyActivationGeneration = nil
            missionControlProxyFocusRequestedGeneration = nil
            endOwnedForegroundMutation(generation: generation)
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
            refreshMissionControlGroupProxies(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }
        guard let validatedGroupWindows = connectedSnapGroupWindows(
            for: mainWindow,
            visibleWindows: visibleWindows
        ), Set(validatedGroupWindows.map(\.stableIdentity)) == group.memberIDs else {
            if completedAttempts
                < maximumMissionControlProxyActivationSettleAttempts {
                scheduleMissionControlProxyActivationRetry(
                    groupID: groupID,
                    revision: revision,
                    generation: generation,
                    completedAttempts: completedAttempts
                )
                return
            }
            activeMissionControlProxyActivationGeneration = nil
            missionControlProxyFocusRequestedGeneration = nil
            endOwnedForegroundMutation(generation: generation)
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
            refreshMissionControlGroupProxies(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }

        if connectedGroupFrontmostEvaluation(validatedGroupWindows)
            == .verifiedFrontmost {
            setAutomaticForegroundMode(forGroupID: groupID)
            activeMissionControlProxyActivationGeneration = nil
            missionControlProxyFocusRequestedGeneration = nil
            endOwnedForegroundMutation(generation: generation)
            explicitGroupStore.setPreferredMember(mainWindow.stableIdentity)
            missionControlGroupProxyController.hideAll()
            refreshResizeHandles(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }

        if !beginOwnedForegroundMutation(
               groupID: groupID,
               windows: validatedGroupWindows,
               generation: generation
           ) {
            guard completedAttempts
                    < maximumMissionControlProxyActivationSettleAttempts else {
                setSoloForegroundMode(memberID: mainWindow.stableIdentity)
                activeMissionControlProxyActivationGeneration = nil
                missionControlProxyFocusRequestedGeneration = nil
                missionControlGroupProxyController.cancelSelectionTransition(
                    for: groupID
                )
                refreshResizeHandles(using: visibleWindows)
                replayDeferredForegroundSignalIfNeeded()
                return
            }
            scheduleMissionControlProxyActivationRetry(
                groupID: groupID,
                revision: revision,
                generation: generation,
                completedAttempts: completedAttempts
            )
            return
        }

        if missionControlProxyFocusRequestedGeneration != generation {
            // Selecting the proxy makes Tabora the temporary active app.
            // Activate only the recorded main member first, then let the same
            // fail-closed AX/WindowServer agreement used by ordinary group
            // raises authorize the companion raises.
            windowService.focus(mainWindow)
            missionControlProxyFocusRequestedGeneration = generation
        }
        if automaticGroupRaiseIsSafe(for: mainWindow),
           raiseWindowsForAutomaticSelection(
               validatedGroupWindows,
               withMainWindow: mainWindow,
               isRequestCurrent: { [weak self] in
                   guard let self,
                         self.groupRaiseGeneration == generation,
                         self.explicitGroupStore.group(id: groupID) != nil
                   else { return false }
                   return true
               }
           ) {
            // AXRaise acceptance precedes the Window Server Z-order update.
            // Keep the static composite covering the transition until a later
            // bounded observation proves every real member is frontmost.
            scheduleMissionControlProxyActivationRetry(
                groupID: groupID,
                revision: revision,
                generation: generation,
                completedAttempts: completedAttempts
            )
            return
        }

        guard completedAttempts
                < maximumMissionControlProxyActivationSettleAttempts else {
            // The explicit proxy request did not reach its complete-frontmost
            // postcondition. The main window may still have been selected by
            // macOS, but presenting shared resize controls for an
            // incomplete foreground group would be unsafe.
            setSoloForegroundMode(memberID: mainWindow.stableIdentity)
            activeMissionControlProxyActivationGeneration = nil
            missionControlProxyFocusRequestedGeneration = nil
            endOwnedForegroundMutation(generation: generation)
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
            refreshResizeHandles(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }
        scheduleMissionControlProxyActivationRetry(
            groupID: groupID,
            revision: revision,
            generation: generation,
            completedAttempts: completedAttempts
        )
    }

    private func scheduleMissionControlProxyActivationRetry(
        groupID: SnapGroupID,
        revision: UInt64,
        generation: Int,
        completedAttempts: Int
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.groupRaiseGeneration == generation else { return }
            self.pendingGroupRaiseWorkItem = nil
            self.activateExplicitGroupFromMissionControlProxy(
                groupID: groupID,
                revision: revision,
                generation: generation,
                completedAttempts: completedAttempts + 1
            )
        }
        pendingGroupRaiseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + groupRaiseVerificationDelay,
            execute: workItem
        )
    }
}
