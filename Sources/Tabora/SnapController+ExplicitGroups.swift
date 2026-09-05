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
            return succeeded
        }
    }

    func detachFocusedWindowFromExplicitGroup() {
        guard isEnabled,
              !isConstraintMeasurementActive,
              !isConstraintPermissionPromptActive,
              !isRestoreTransactionActive,
              ensurePermission(),
              let focused = windowService.focusedWindow(
                  messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
              ) else { return }
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
        return retireExplicitGroup(departure, reason: .explicitDetach)
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
        _ departure: ExplicitGroupDepartureSnapshot,
        reason: ExplicitGroupDepartureReason = .explicitDetach
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
        commitExplicitGroupDeparture(
            memberIDs: members,
            retiredGroupIDs: retiredGroupIDs,
            reason: reason
        )
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
            groupSpaceMigrationLine.groupDidRetire(groupID: groupID)
            groupForegroundModes.removeValue(forKey: groupID)
            groupDegradationEvidenceByGroupID.removeValue(forKey: groupID)
            groupSpaceSeparationEvidenceByGroupID.removeValue(forKey: groupID)
            directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                forKey: groupID
            )
            groupPresentationFailureCountsByGroupID.removeValue(forKey: groupID)
            handleLivenessFailureCountsByGroupID.removeValue(forKey: groupID)
            missionControlGroupProxyController.hide(groupID: groupID)
        }
        if pendingNativeResizeDeparture?.groupID == departure.groupID {
            pendingNativeResizeDeparture = nil
        }
        stagedGroupDeparture = StagedGroupDeparture(
            draggedIdentity: stableIdentity,
            memberIDs: members,
            retiredGroupIDs: retiredGroupIDs
        )
        retireHandlePresentation(participantIDs: members)
        retireGroupPresentationTransitionState(for: retiredGroupIDs)
        updateSelectionMonitoringState()
        return true
    }

    @discardableResult
    func restoreStagedGroupDepartureIfPossible() -> Bool {
        guard let stagedGroupDeparture else { return true }
        guard dragWindow == nil,
              pendingDragWindow == nil,
              !isWindowMoveConfirmed else {
            // A Space transition can occur while the physical drag continues.
            // Rebuilding the group at that point would erase the staged
            // departure authority before the eventual mouse-up decides whether
            // the member re-snapped or truly left. Only a quiesced gesture may
            // restore the captured structure.
            return false
        }
        // Staging removes explicit membership before the drag outcome is known,
        // but it deliberately keeps the authoritative placement locks. An OS
        // display/Space transition is not departure evidence, so when the
        // gesture has been quiesced rebuild structural membership from that
        // captured member set rather than committing or discarding it.
        let placements = stagedGroupDeparture.memberIDs.compactMap { identity
            -> SplitPlacementGeometry? in
            guard let placement = lockedPlacements[identity],
                  placement.zone != .maximize else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: placement.appliedFrame
            )
        }
        guard placements.count == stagedGroupDeparture.memberIDs.count,
              let preferredPlacement = lockedPlacements[
                  stagedGroupDeparture.draggedIdentity
              ],
              placements.allSatisfy({ placement in
                  lockedPlacements[placement.stableIdentity]?.displayID
                      == preferredPlacement.displayID
              }),
              screen(withDisplayID: preferredPlacement.displayID) != nil else {
            return false
        }
        guard let restoredGroup = explicitGroupStore.reconcileAfterLayoutMutation(
            preferredMemberID: stagedGroupDeparture.draggedIdentity,
            displayID: preferredPlacement.displayID,
            placements: placements,
            detachedConnections: detachedConnections,
            targetGroupID: nil
        ), restoredGroup.memberIDs == stagedGroupDeparture.memberIDs else {
            return false
        }
        self.stagedGroupDeparture = nil
        setAutomaticForegroundMode(forGroupID: restoredGroup.id)
        updateSelectionMonitoringState()
        return true
    }

    func finalizeStagedGroupDepartureIfNeeded() {
        guard let stagedGroupDeparture else { return }
        self.stagedGroupDeparture = nil
        commitExplicitGroupDeparture(
            memberIDs: stagedGroupDeparture.memberIDs,
            retiredGroupIDs: stagedGroupDeparture.retiredGroupIDs,
            reason: .userDragDeparture
        )
    }

    private func commitExplicitGroupDeparture(
        memberIDs members: Set<String>,
        retiredGroupIDs: Set<SnapGroupID>,
        reason _: ExplicitGroupDepartureReason
    ) {
        // Authorization has already happened. Cleanup is one transaction so a
        // retired structural group cannot outlive its handles (or vice versa).
        detachedConnections = SnapGroupDeparturePolicy.connectionsAfterRetirement(
            existing: detachedConnections,
            retiredMemberIDs: members
        )

        let endedSharedResizeInteraction = retireHandleResizeOwnership(
            participantIDs: members
        )
        retireHandlePresentation(participantIDs: members)

        var remainingPlacements = lockedPlacements
        for memberID in members {
            remainingPlacements.removeValue(forKey: memberID)
            restoreFrames.removeValue(forKey: memberID)
            inFlightPlacementIDs.remove(memberID)
            pendingPlacementSnapshots.removeValue(forKey: memberID)
            lastGroupWindowServerEvidenceByIdentity.removeValue(forKey: memberID)
        }
        // Prevent the generic placement observer from turning a group-local
        // retirement into a global Mission Control presentation hide.
        let wasReconcilingPlacementMutation = isReconcilingPlacementMutation
        isReconcilingPlacementMutation = true
        lockedPlacements = remainingPlacements
        isReconcilingPlacementMutation = wasReconcilingPlacementMutation
        updateSelectionMonitoringState()

        if let stagedGroupDeparture,
           !stagedGroupDeparture.memberIDs.isDisjoint(with: members) {
            self.stagedGroupDeparture = nil
        }
        if let activeSession,
           !activeSession.occupiedStableIDs.isDisjoint(with: members) {
            self.activeSession = nil
            isAssistPlacementPending = false
            stopEscapeMonitoring()
            stopAssistLayoutModifierMonitoring()
            picker.hide()
        }
        if let pending = pendingNativeResizeDeparture,
           !pending.memberIDs.isDisjoint(with: members) {
            pendingNativeResizeDeparture = nil
        }

        for groupID in retiredGroupIDs {
            groupSpaceMigrationLine.groupDidRetire(groupID: groupID)
            groupForegroundModes.removeValue(forKey: groupID)
            groupDegradationEvidenceByGroupID.removeValue(forKey: groupID)
            groupSpaceSeparationEvidenceByGroupID.removeValue(forKey: groupID)
            groupPresentationFailureCountsByGroupID.removeValue(forKey: groupID)
            handleGeometryFailureCountsByGroupID.removeValue(forKey: groupID)
            handleLivenessFailureCountsByGroupID.removeValue(forKey: groupID)
            missionControlGroupProxyController.hide(groupID: groupID)
        }
        retireGroupPresentationTransitionState(for: retiredGroupIDs)

        // beginInteraction() intentionally hides every non-active handle while
        // one shared resize is in progress. If this departure terminated that
        // interaction, endInteraction() therefore hid handles belonging to
        // unrelated groups too. Rebuild from the now-committed structural
        // state before returning so Group A retirement cannot leave Group B's
        // presentation waiting for event-driven or 1 Hz Recovery.
        if endedSharedResizeInteraction {
            refreshResizeHandles()
        }
    }

    @discardableResult
    private func retireHandleResizeOwnership(
        participantIDs members: Set<String>
    ) -> Bool {
        let active = handleResizeSession
        let finalizing = finalizingHandleResizeSession
        let ownsActive = active.map {
            !Set($0.participants.keys).isDisjoint(with: members)
        } ?? false
        let ownsFinalizing = finalizing.map {
            !Set($0.participants.keys).isDisjoint(with: members)
        } ?? false
        guard ownsActive || ownsFinalizing else { return false }

        // A generation invalidation makes every late scheduler/final-write
        // callback from the retired group fail its existing session guard.
        liveResizeScheduler.cancelAll()
        let ownedWindows = (active?.participants.values.map(\.window) ?? [])
            + (finalizing?.participants.values.map(\.window) ?? [])
        if !isHandleResizeRollbackActive {
            for window in ownedWindows {
                windowService.cancelFrameOperation(for: window.element)
            }
        }
        if let active {
            inFlightPlacementIDs.subtract(active.participants.keys)
        }
        if let finalizing {
            inFlightPlacementIDs.subtract(finalizing.participants.keys)
        }
        handleResizeSession = nil
        finalizingHandleResizeSession = nil
        isHandleResizeFinalizing = false
        stopEscapeMonitoring()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.endInteraction()
        return true
    }

    private func retireHandlePresentation(participantIDs members: Set<String>) {
        let removedDescriptorIDs = Set(baseResizeHandleDescriptors.compactMap {
            descriptor in
            !descriptor.participantIDs.isDisjoint(with: members)
                ? descriptor.id : nil
        })
        baseResizeHandleDescriptors.removeAll {
            !$0.participantIDs.isDisjoint(with: members)
        }
        lastPresentableResizeHandleDescriptors.removeAll {
            !$0.participantIDs.isDisjoint(with: members)
        }
        quarantinedResizeHandleIDs.subtract(removedDescriptorIDs)
        handleOcclusionFailureCountsByDescriptorID =
            handleOcclusionFailureCountsByDescriptorID.filter {
                !removedDescriptorIDs.contains($0.key)
            }
        handlePresentationGeneration &+= 1
        resizeHandleOverlay.removeHandles(participantIDs: members)
    }

    func resetMissionControlPresentationRetryDebt() {
        groupPresentationFailureCountsByGroupID.removeAll()
        guard scheduledGroupPresentationRetryGeneration != nil else { return }
        groupDegradationRetryGeneration &+= 1
        scheduledGroupPresentationRetryGeneration = nil
    }

    private func spaceSeparationFingerprint(
        for group: SnapGroup,
        onScreenMemberIDs: Set<String>,
        censusByPID: inout [pid_t: WindowServerWindowIDCensus]
    ) -> GroupDegradationFingerprint? {
        let offscreenMemberIDs = group.memberIDs.subtracting(onScreenMemberIDs)
        guard !onScreenMemberIDs.isEmpty,
              !offscreenMemberIDs.isEmpty else { return nil }

        var confirmedExistingMemberIDs = Set<String>()
        var eligibleOffscreenMemberIDs = Set<String>()
        for memberID in group.memberIDs {
            guard let placement = lockedPlacements[memberID],
                  let windowID = placement.cgWindowID else { return nil }
            let census: WindowServerWindowIDCensus
            if let cached = censusByPID[placement.pid] {
                census = cached
            } else {
                census = windowService.windowServerWindowIDCensus(
                    forPID: placement.pid
                )
                censusByPID[placement.pid] = census
            }
            guard census.completeness == .complete,
                  census.windowIDs.contains(windowID) else { return nil }
            confirmedExistingMemberIDs.insert(memberID)

            guard offscreenMemberIDs.contains(memberID) else { continue }
            guard let application = NSRunningApplication(
                processIdentifier: placement.pid
            ), !application.isTerminated, !application.isHidden else {
                return nil
            }
            switch windowService.refreshedPersistedWindow(
                element: placement.element,
                pid: placement.pid,
                expectedStableIdentity: placement.stableIdentity,
                cgWindowID: windowID,
                messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
            ) {
            case .available(let window) where !window.isMinimized:
                eligibleOffscreenMemberIDs.insert(memberID)
            case .available, .missing, .unknown:
                return nil
            }
        }
        return GroupSpaceSeparationPolicy.fingerprint(
            memberIDs: group.memberIDs,
            onScreenMemberIDs: onScreenMemberIDs,
            confirmedExistingMemberIDs: confirmedExistingMemberIDs,
            eligibleOffscreenMemberIDs: eligibleOffscreenMemberIDs
        )
    }

    /// Structural Space reconciliation is independent from Mission Control
    /// proxy presentation. It runs only after the Window Server scene has been
    /// proven to be back at normal desktop geometry. A pending group is
    /// returned as handle-recovery debt so repeated evidence is collected even
    /// when AX can still enumerate an off-Space member.
    func reconcileExplicitGroupsSeparatedAcrossSpaces(
        windowServerSnapshot: [WindowOcclusionSnapshot]
    ) -> Set<SnapGroupID> {
        let activeGroupIDs = Set(explicitGroupStore.groups.map(\.id))
        groupSpaceSeparationEvidenceByGroupID =
            groupSpaceSeparationEvidenceByGroupID.filter {
                activeGroupIDs.contains($0.key)
            }
        directGroupSpaceSeparationEvidenceByGroupID =
            directGroupSpaceSeparationEvidenceByGroupID.filter {
                activeGroupIDs.contains($0.key)
            }
        groupSpaceSeparationObservationEpoch &+= 1
        let observationEpoch = groupSpaceSeparationObservationEpoch
        let observationTime = ProcessInfo.processInfo.systemUptime
        var windowServerCensusByPID:
            [pid_t: WindowServerWindowIDCensus] = [:]
        var pendingGroupIDs = Set<SnapGroupID>()

        for group in explicitGroupStore.groups {
            if groupSpaceMigrationLine.owns(groupID: group.id) {
                directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                pendingGroupIDs.insert(group.id)
                continue
            }
            guard screen(withDisplayID: group.displayID) != nil else {
                directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }
            let normalOnScreenMemberIDs = Set(group.memberIDs.filter {
                memberID in
                guard let evidence = lastGroupWindowServerEvidenceByIdentity[
                    memberID
                ], groupWindowServerEvidenceHasNormalGeometry(
                    evidence,
                    snapshot: windowServerSnapshot
                ) else { return false }
                return true
            })
            if normalOnScreenMemberIDs == group.memberIDs {
                // The Space transition has fully settled back onto one active
                // desktop. This is the missing inverse of
                // suspendForSpaceTransition(); only complete normal geometry
                // may reactivate structural presentation.
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                explicitGroupStore.markDegraded(
                    groupID: group.id,
                    missingMemberIDs: []
                )
                continue
            }
            let isProperDesktopSplit = !normalOnScreenMemberIDs.isEmpty
                && normalOnScreenMemberIDs != group.memberIDs

            if windowSpaceBackend.capabilities.contains(.readWindowSpaces) {
                let relationship = groupSpaceMigrationSubjects(
                    groupID: group.id,
                    presentedMemberIDs: group.memberIDs
                ).map { subjects in
                    GroupSpaceMembershipPolicy.relationship(
                        memberIDs: group.memberIDs,
                        observation: windowSpaceBackend.observe(
                            subjects: subjects
                        )
                    )
                } ?? .unknown
                switch relationship {
                case .knownSame:
                    directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                        forKey: group.id
                    )
                    groupSpaceSeparationEvidenceByGroupID.removeValue(
                        forKey: group.id
                    )
                    if normalOnScreenMemberIDs == group.memberIDs {
                        explicitGroupStore.markDegraded(
                            groupID: group.id,
                            missingMemberIDs: []
                        )
                    }
                    continue
                case .knownDifferent(let spacesByMemberID):
                    missionControlGroupProxyController.hide(groupID: group.id)
                    pendingGroupIDs.insert(group.id)
                    groupSpaceSeparationEvidenceByGroupID.removeValue(
                        forKey: group.id
                    )
                    let observation = DirectGroupSpaceSeparationPolicy.observe(
                        previous:
                            directGroupSpaceSeparationEvidenceByGroupID[group.id],
                        spacesByMemberID: spacesByMemberID,
                        now: observationTime
                    )
                    directGroupSpaceSeparationEvidenceByGroupID[group.id] =
                        observation.evidence
                    guard observation.isConfirmed else { continue }
                    _ = retireExplicitGroup(
                        ExplicitGroupDepartureSnapshot(
                            groupID: group.id,
                            memberIDs: group.memberIDs
                        ),
                        reason: .confirmedSpaceSeparation
                    )
                    directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                        forKey: group.id
                    )
                    pendingGroupIDs.remove(group.id)
                    continue
                case .unknown:
                    // Private observation is available but this sample is not
                    // authoritative. Do not reinterpret visual absence as a
                    // different Space; unknown is deliberately non-destructive.
                    directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                        forKey: group.id
                    )
                    groupSpaceSeparationEvidenceByGroupID.removeValue(
                        forKey: group.id
                    )
                    if isProperDesktopSplit {
                        missionControlGroupProxyController.hide(
                            groupID: group.id
                        )
                        pendingGroupIDs.insert(group.id)
                    }
                    continue
                }
            }

            directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                forKey: group.id
            )
            guard isProperDesktopSplit else {
                // All-offscreen is a valid suspended state. Transformed
                // Mission Control surfaces are not normal geometry, so they
                // also cannot accumulate destructive evidence here.
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }

            missionControlGroupProxyController.hide(groupID: group.id)
            pendingGroupIDs.insert(group.id)
            guard let fingerprint = spaceSeparationFingerprint(
                for: group,
                onScreenMemberIDs: normalOnScreenMemberIDs,
                censusByPID: &windowServerCensusByPID
            ) else {
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }
            let observation = GroupDegradationConfirmationPolicy.observe(
                previous: groupSpaceSeparationEvidenceByGroupID[group.id],
                fingerprint: fingerprint,
                epoch: observationEpoch,
                now: observationTime,
                minimumSettleInterval:
                    GroupSpaceSeparationPolicy.minimumSettleInterval
            )
            groupSpaceSeparationEvidenceByGroupID[group.id] =
                observation.evidence
            guard observation.isConfirmed else { continue }

            let departure = ExplicitGroupDepartureSnapshot(
                groupID: group.id,
                memberIDs: group.memberIDs
            )
            _ = retireExplicitGroup(
                departure,
                reason: .confirmedSpaceSeparation
            )
            groupSpaceSeparationEvidenceByGroupID.removeValue(
                forKey: group.id
            )
            pendingGroupIDs.remove(group.id)
        }
        return pendingGroupIDs
    }

    func refreshMissionControlGroupProxies(
        using providedVisibleWindows: [ManagedWindow]? = nil,
        windowServerSnapshot providedWindowServerSnapshot:
            [WindowOcclusionSnapshot]? = nil,
        windowServerSnapshotCompleteness providedSnapshotCompleteness:
            WindowDiscoveryCompleteness? = nil
    ) {
        guard missionControlGroupPresentationIsEnabled,
              isEnabled,
              isUserSessionActive,
              settings.linkedResizeEnabled,
              !isApplicationInteractionSuppressed else {
            missionControlGroupProxyController.hideAll()
            resetMissionControlPresentationRetryDebt()
            return
        }
        guard !missionControlSelectionTransactionIsActive else {
            // The proxy key callback has already captured one bounded exit.
            // Preview completion and Recovery may not reorder or rebuild any
            // proxy until that selection either reaches the controller or is
            // explicitly rejected.
            return
        }
        if PresentationTransactionOwnershipPolicy
            .preservesMissionControlPresentation(
                snapPlacementInProgress: isSnapPlacementInProgress,
                assistSessionActive: activeSession != nil,
                assistPlacementPending: isAssistPlacementPending
            ) {
            // These transactions explicitly own presentation. Snap start has
            // already invalidated only the affected group; Assist must not
            // rebuild Mission Control proxies behind its screen-saver panels.
            return
        }
        guard handleResizeSession == nil,
              !isHandleResizeFinalizing,
              manualResizeWindow == nil,
              pendingDragWindow == nil,
              dragWindow == nil else {
            missionControlGroupProxyController.hideAll()
            resetMissionControlPresentationRetryDebt()
            return
        }
        let visibleWindows = providedVisibleWindows ?? managedExplicitGroupWindows()
        let windowServerObservation: WindowOcclusionSnapshotObservation
        if let providedWindowServerSnapshot {
            windowServerObservation = WindowOcclusionSnapshotObservation(
                snapshot: providedWindowServerSnapshot,
                completeness: providedSnapshotCompleteness ?? .unknown
            )
        } else {
            windowServerObservation = windowService
                .windowOcclusionSnapshotObservation()
        }
        let windowServerSnapshot = windowServerObservation.snapshot
        groupDegradationObservationEpoch &+= 1
        let observationEpoch = groupDegradationObservationEpoch
        let observationTime = ProcessInfo.processInfo.systemUptime

        updateGroupWindowServerEvidence(
            using: visibleWindows,
            windowServerSnapshot: windowServerSnapshot
        )
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
        var preservedPresentationGroupIDs = Set<SnapGroupID>()
        let activeGroupIDs = Set(explicitGroupStore.groups.map(\.id))
        groupDegradationEvidenceByGroupID =
            groupDegradationEvidenceByGroupID.filter {
                activeGroupIDs.contains($0.key)
            }

        for group in explicitGroupStore.groups {
            if groupSpaceMigrationLine
                .presentationIsFrozenForQueuedMigration(groupID: group.id) {
                // Destination capture is complete, but real windows must not
                // share Mission Control's managed transform. Preserve the exact
                // moved Proxy and its queued badge without recomputing it from
                // source-window geometry. The FIFO transport begins only after
                // stable normal-desktop evidence.
                presentationSuppressedGroupIDs.insert(group.id)
                preservedPresentationGroupIDs.insert(group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }
            if groupSpaceMigrationLine.presentationIsQuarantined(
                groupID: group.id
            ) {
                // A terminal migration consumes this Proxy for the current
                // Mission Control transform. Do not recreate a managed window
                // in its destination Space until normal desktop evidence has
                // rearmed the group; another ordinary window move can otherwise
                // make WindowServer compose the stale and rebuilt participants.
                presentationSuppressedGroupIDs.insert(group.id)
                missionControlGroupProxyController.retireForSpaceMigration(
                    groupID: group.id
                )
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }
            let axMissing = group.memberIDs.subtracting(windowsByIdentity.keys)
            if screen(withDisplayID: group.displayID) == nil {
                // Display/Space topology can settle asynchronously. Keep the
                // structural group and suppress only its presentation. The
                // display-change transaction owns a targeted, expiring rebind
                // debt; never promote a missing display into generic permanent
                // presentation-recovery work.
                presentationSuppressedGroupIDs.insert(group.id)
                missionControlGroupProxyController.hide(groupID: group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }

            let exactOnScreenMemberCount = group.memberIDs.reduce(into: 0) {
                count, memberID in
                guard let placement = lockedPlacements[memberID],
                      let windowID = placement.cgWindowID,
                      windowServerSnapshot.contains(where: {
                        $0.pid == placement.pid
                            && $0.windowID == windowID
                            && $0.layer == 0
                      }) else { return }
                count += 1
            }
            if case .suspendedForSpaceTransition = group.state,
               windowServerObservation.completeness == .complete,
               exactOnScreenMemberCount == 0 {
                // A whole Group on another Space is a normal visibility state,
                // not presentation failure. Preserve its last validated proxy
                // and let the ordinary Space reconciliation reactivate it when
                // every exact member returns at normal desktop geometry.
                presentationSuppressedGroupIDs.insert(group.id)
                preservedPresentationGroupIDs.insert(group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }

            let confirmedClosedMembers = axMissing.filter { memberID in
                guard let placement = lockedPlacements[memberID] else {
                    // A group member without its authoritative placement is an
                    // internal structural inconsistency. It requires repair or
                    // Recovery evidence, but absence of controller metadata is
                    // not proof that the live member closed.
                    return false
                }
                return WindowStructuralPolicy.isConfirmedMissing(
                    windowService.windowLiveness(
                        element: placement.element,
                        pid: placement.pid,
                        messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
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
                groupSpaceSeparationEvidenceByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }

            guard axMissing.isEmpty else {
                // AX-visible/interaction availability is presentation evidence,
                // not structural membership. Preserve the last validated proxy
                // while exact physical identity still owns structural truth; a
                // streamed/unresponsive member must not make the whole group
                // repeatedly leave and re-enter Mission Control.
                presentationSuppressedGroupIDs.insert(group.id)
                preservedPresentationGroupIDs.insert(group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                presentationRecoveryGroupIDs.insert(group.id)
                let physicalMembersAreStillPresent = group.memberIDs.allSatisfy {
                    memberID in
                    guard let placement = lockedPlacements[memberID],
                          let windowID = placement.cgWindowID else {
                        return false
                    }
                    return windowServerSnapshot.contains { surface in
                        surface.pid == placement.pid
                            && surface.windowID == windowID
                            && surface.layer == 0
                    }
                }
                if !physicalMembersAreStillPresent
                    || !missionControlGroupProxyController.hasPresentation(
                        for: group.id
                    ) {
                    // Initial presentation and true physical uncertainty get
                    // the bounded fast-retry burst. Once a validated proxy
                    // exists and physical members remain present, AX-only
                    // unavailability is liveness debt for the 1 Hz watchdog;
                    // it must not drive a global high-frequency refresh loop.
                    fastPresentationRetryGroupIDs.insert(group.id)
                }
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
                preservedPresentationGroupIDs.insert(group.id)
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
                // convert that into a structural departure; without complete
                // physical surfaces we also cannot safely keep stale geometry
                // presented.
                missionControlGroupProxyController.hide(groupID: group.id)
                groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
                presentationRecoveryGroupIDs.insert(group.id)
                fastPresentationRetryGroupIDs.insert(group.id)
                continue
            }
            preservedPresentationGroupIDs.insert(group.id)

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
        let previewsEnabled = settings.windowPreviewsEnabled
        var previewVisibilityEvaluationByGroupID:
            [SnapGroupID: PreviewGroupVisibilityEvaluation] = [:]
        let foregroundPresentationIsSettling =
            pendingSelectionRaiseWorkItem != nil
                || pendingGroupRaiseWorkItem != nil
                || ownedForegroundMutation != nil
        if previewsEnabled {
            windowService.synchronizePreviewOccluderSemanticCache(
                with: windowServerSnapshot,
                completeness: windowServerObservation.completeness
            )
        } else {
            windowService.clearPreviewOccluderSemanticCache()
        }
        let knownManagedSelections = Set(lockedPlacements.values.compactMap {
            placement -> WindowServerSelectionSnapshot? in
            guard let windowID = placement.cgWindowID else { return nil }
            return WindowServerSelectionSnapshot(
                pid: placement.pid,
                windowID: windowID
            )
        })
        for group in explicitGroupStore.groups where previewsEnabled {
            if foregroundPresentationIsSettling {
                // A foreground transaction raises members sequentially. Its
                // intermediate WindowServer ordering is not evidence that the
                // structural group became COLD. Preserve prior normal HOT/COLD
                // state and, because transient capture is stricter, fail closed
                // for Mission Control-only replacement until settlement.
                previewVisibilityEvaluationByGroupID[group.id] = .indeterminate
                continue
            }
            guard let displayFrame = screen(withDisplayID: group.displayID)?.frame
            else {
                previewVisibilityEvaluationByGroupID[group.id] = .indeterminate
                continue
            }
            let members = group.memberIDs.compactMap { memberID
                -> PreviewGroupVisibilityMember? in
                guard let placement = lockedPlacements[memberID],
                      let windowID = placement.cgWindowID else { return nil }
                return PreviewGroupVisibilityMember(
                    selection: WindowServerSelectionSnapshot(
                        pid: placement.pid,
                        windowID: windowID
                    ),
                    frame: windowsByIdentity[memberID]?.frame
                        ?? placement.appliedFrame
                )
            }
            guard members.count == group.memberIDs.count else {
                previewVisibilityEvaluationByGroupID[group.id] = .indeterminate
                continue
            }
            let physical = PreviewGroupVisibilityPolicy.physicalEvaluation(
                members: members,
                displayFrame: displayFrame,
                snapshot: windowServerSnapshot,
                completeness: windowServerObservation.completeness
            )
            previewVisibilityEvaluationByGroupID[group.id] =
                PreviewGroupVisibilityPolicy.evaluation(
                    physical: physical,
                    classification: { candidate in
                        if knownManagedSelections.contains(candidate) {
                            return .qualified
                        }
                        guard missionControlGroupProxyController
                            .previewOccluderClassificationIsNeeded(
                                for: group.id,
                                candidate: candidate
                            ) else {
                            return .qualified
                        }
                        return windowService
                            .previewOccluderSemanticClassification(candidate)
                    }
                )
        }
        let structuralMemberIDsByGroupID = Dictionary(
            uniqueKeysWithValues: explicitGroupStore.groups.map {
                ($0.id, $0.memberIDs)
            }
        )
        missionControlGroupProxyController.update(
            groups: presentableGroups,
            visibleWindowsByIdentity: windowsByIdentity,
            displayOrdinalsByGroupID:
                explicitGroupStore.displayOrdinalsByGroupID,
            preservedGroupIDs: preservedPresentationGroupIDs,
            structuralGroupIDs: Set(explicitGroupStore.groups.map(\.id)),
            structuralMemberIDs: explicitGroupStore.groups.reduce(
                into: Set<String>()
            ) { $0.formUnion($1.memberIDs) },
            structuralMemberIDsByGroupID: structuralMemberIDsByGroupID,
            previewVisibilityEvaluationByGroupID:
                previewVisibilityEvaluationByGroupID,
            previewsEnabled: previewsEnabled,
            previewCacheByteLimit: AppSettings
                .missionControlPreviewMemoryByteLimit(
                    settings.missionControlPreviewMemoryLimitMiB
                ),
            previewProvider: {
                [weak self] windowID, captureIsAuthorized in
                guard let self,
                      self.settings.windowPreviewsEnabled,
                      captureIsAuthorized() else { return nil }
                return self.windowService.previewCGImage(
                    for: windowID,
                    capacityWait:
                        PreviewCaptureAdmissionPolicy
                            .missionControlCapacityWait,
                    shouldCapture: { [weak self] in
                        self?.settings.windowPreviewsEnabled == true
                            && captureIsAuthorized()
                    }
                )
            },
            transientPreviewProvider: {
                [weak self] windowID, resolution, captureIsAuthorized in
                guard let self,
                      self.settings.windowPreviewsEnabled,
                      captureIsAuthorized() else { return nil }
                return self.windowService.previewCGImage(
                    for: windowID,
                    capacityWait:
                        PreviewCaptureAdmissionPolicy
                            .missionControlCapacityWait,
                    resolution: resolution,
                    shouldCapture: { [weak self] in
                        self?.settings.windowPreviewsEnabled == true
                            && captureIsAuthorized()
                    }
                )
            }
        )
        for group in presentableGroups {
            groupSpaceMigrationLine.noteProxyPresentedNormally(
                groupID: group.id
            )
        }
    }

    func activateExplicitGroupFromMissionControlProxy(
        groupID: SnapGroupID,
        presentedMemberIDs: Set<String>
    ) {
        guard !groupSpaceMigrationLine.owns(groupID: groupID) else {
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
            return
        }
        guard missionControlGroupPresentationIsEnabled,
              let group = explicitGroupStore.group(id: groupID),
              MissionControlProxySelectionStructuralPolicy.matchesPresentedMembers(
                  presentedMemberIDs: presentedMemberIDs,
                  currentMemberIDs: group.memberIDs
              ) else {
            discardDeferredForegroundSignals()
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
            return
        }
        if let active = activeMissionControlProxyActivation {
            if active.groupID != groupID
                || active.memberIDs != presentedMemberIDs {
                missionControlGroupProxyController.cancelSelectionTransition(
                    for: groupID
                )
            }
            // One Mission Control exit has exactly one selected group. A later
            // proxy key event may not supersede or restart that transaction.
            return
        }
        // Revision also tracks harmless preferred-member/state changes, so it
        // is not a structural authorization token. The exact member set shown
        // by the selected proxy is the stale-evidence boundary instead.
        discardDeferredForegroundSignals()
        invalidatePendingGroupRaise()
        invalidatePendingSelectionRaise()
        groupRaiseGeneration &+= 1
        let generation = groupRaiseGeneration
        activeMissionControlProxyActivation = MissionControlProxyActivationState(
            groupID: groupID,
            generation: generation,
            memberIDs: group.memberIDs,
            preferredMemberID: group.preferredMemberID
        )
        resizeHandleOverlay.setPresentationSuspended(true)
        // The selected proxy now owns a bounded visual handoff. Do not remove
        // the Window Server surface while Mission Control is still returning
        // it to the desktop; the proxy itself enforces a short visibility
        // ceiling, and success/cancellation below performs final retirement.
        activateExplicitGroupFromMissionControlProxy(
            groupID: groupID,
            generation: generation,
            completedAttempts: 0,
            successfulOrderingPassExists: false,
            passiveTransformObservations: 0,
            unsettledDesktopVerificationDeferrals: 0
        )
    }

    private func activateExplicitGroupFromMissionControlProxy(
        groupID: SnapGroupID,
        generation: Int,
        completedAttempts: Int,
        successfulOrderingPassExists: Bool,
        passiveTransformObservations: Int,
        unsettledDesktopVerificationDeferrals: Int
    ) {
        guard groupRaiseGeneration == generation,
              let activation = activeMissionControlProxyActivation,
              activation.generation == generation,
              activation.groupID == groupID,
              missionControlGroupPresentationIsEnabled,
              let group = explicitGroupStore.group(id: groupID),
              group.memberIDs == activation.memberIDs,
              group.preferredMemberID == activation.preferredMemberID else {
            let clearedActivation =
                activeMissionControlProxyActivation?.generation == generation
            if clearedActivation {
                activeMissionControlProxyActivation = nil
            }
            endOwnedForegroundMutation(generation: generation)
            missionControlGroupProxyController.cancelSelectionTransition(
                for: groupID
            )
            if clearedActivation {
                discardDeferredForegroundSignals()
                refreshResizeHandles()
                scheduleGroupSpaceMigrationForegroundFlushIfReady()
            }
            return
        }

        let activationSnapshot = windowService.windowOcclusionSnapshot()
        guard let validatedGroupWindows = missionControlActivationWindows(
            memberIDs: group.memberIDs,
            snapshot: activationSnapshot
        ), validatedGroupWindows.count == group.memberIDs.count,
           Set(validatedGroupWindows.map(\.stableIdentity)) == group.memberIDs,
           let mainWindow = validatedGroupWindows.first(where: {
               $0.stableIdentity == activation.preferredMemberID
           }) else {
            if MissionControlProxyActivationRetryPolicy.allowsAnotherPass(
                completedAttempts: completedAttempts
            ) {
                scheduleMissionControlProxyActivationRetry(
                    groupID: groupID,
                    generation: generation,
                    completedAttempts: completedAttempts,
                    successfulOrderingPassExists:
                        successfulOrderingPassExists,
                    passiveTransformObservations:
                        passiveTransformObservations,
                    unsettledDesktopVerificationDeferrals:
                        unsettledDesktopVerificationDeferrals
                )
            } else {
                cancelMissionControlProxyActivation(
                    groupID: groupID,
                    generation: generation
                )
            }
            return
        }

        let transformIsObserved =
            missionControlTransitionIsCurrentlyObserved(groupID: groupID)
        if MissionControlVisualHandoffPolicy.shouldSuppressRepeatedOrdering(
            transformIsObserved: transformIsObserved,
            successfulOrderingPassExists: successfulOrderingPassExists,
            completedPassiveObservations: passiveTransformObservations
        ) {
            // The selected group has already received one complete ordering
            // pass. While Window Server is still animating Mission Control,
            // suppress only duplicate AXRaise/focus passes; repeating them at
            // the end of the transform produces a visible final-frame jump.
            scheduleMissionControlProxyActivationRetry(
                groupID: groupID,
                generation: generation,
                completedAttempts: completedAttempts,
                successfulOrderingPassExists: successfulOrderingPassExists,
                passiveTransformObservations:
                    passiveTransformObservations + 1,
                unsettledDesktopVerificationDeferrals: 0,
                advancesActivationAttempt: false
            )
            return
        }

        let frontmostEvaluation = connectedGroupFrontmostEvaluation(
            validatedGroupWindows,
            allowsExactIdentityWithTransformedGeometry: true
        )
        let orderingIsVerified = !transformIsObserved
            && frontmostEvaluation == .verifiedFrontmost

        if orderingIsVerified {
            setAutomaticForegroundMode(forGroupID: groupID)
            activeMissionControlProxyActivation = nil
            endOwnedForegroundMutation(generation: generation)
            explicitGroupStore.setPreferredMember(mainWindow.stableIdentity)
            missionControlGroupProxyController.hide(groupID: groupID)
            discardDeferredForegroundSignals()
            refreshResizeHandles()
            scheduleGroupSpaceMigrationForegroundFlushIfReady()
            return
        }

        if MissionControlVisualHandoffPolicy
            .shouldDeferUnsettledDesktopVerification(
                transformIsObserved: transformIsObserved,
                successfulOrderingPassExists: successfulOrderingPassExists,
                orderingIsVerified: orderingIsVerified,
                completedDeferrals:
                    unsettledDesktopVerificationDeferrals
            ) {
            // The first normal-geometry sample and the final Window Server
            // Z-order sample need not settle in the same compositor turn.
            // Re-observe once before issuing another visible ordering mutation.
            scheduleMissionControlProxyActivationRetry(
                groupID: groupID,
                generation: generation,
                completedAttempts: completedAttempts,
                successfulOrderingPassExists: successfulOrderingPassExists,
                passiveTransformObservations: passiveTransformObservations,
                unsettledDesktopVerificationDeferrals:
                    unsettledDesktopVerificationDeferrals + 1,
                advancesActivationAttempt: false
            )
            return
        }

        guard MissionControlProxyActivationRetryPolicy.allowsAnotherPass(
            completedAttempts: completedAttempts
        ) else {
            cancelMissionControlProxyActivation(
                groupID: groupID,
                generation: generation
            )
            return
        }

        // The proxy click is explicit authorization for this immutable group,
        // so it must not depend on a real member already being frontmost. That
        // would make foregrounding depend on its own postcondition. Perform the
        // exact same whole-group mutation that the working resize toggle uses:
        // raise every companion, then activate/raise the preferred main.
        let orderingPassCompleted = issueMissionControlGroupOrderingPass(
            groupID: groupID,
            generation: generation,
            memberIDs: activation.memberIDs,
            windows: validatedGroupWindows,
            mainWindow: mainWindow
        )

        scheduleMissionControlProxyActivationRetry(
            groupID: groupID,
            generation: generation,
            completedAttempts: completedAttempts,
            successfulOrderingPassExists:
                successfulOrderingPassExists || orderingPassCompleted,
            passiveTransformObservations: passiveTransformObservations,
            unsettledDesktopVerificationDeferrals:
                orderingPassCompleted
                    ? 0
                    : unsettledDesktopVerificationDeferrals
        )
    }

    private func missionControlProxyActivationIsCurrent(
        groupID: SnapGroupID,
        generation: Int,
        memberIDs: Set<String>
    ) -> Bool {
        guard groupRaiseGeneration == generation,
              let current = activeMissionControlProxyActivation else {
            return false
        }
        return current.groupID == groupID
            && current.generation == generation
            && current.memberIDs == memberIDs
            && explicitGroupStore.group(id: groupID)?.memberIDs == memberIDs
    }

    /// Every call is an independent whole-group pass. It never resumes from a
    /// partially accepted member list and never waits for placement geometry.
    private func issueMissionControlGroupOrderingPass(
        groupID: SnapGroupID,
        generation: Int,
        memberIDs: Set<String>,
        windows: [ManagedWindow],
        mainWindow: ManagedWindow
    ) -> Bool {
        var seen = Set<String>()
        let uniqueWindows = windows.filter {
            seen.insert($0.stableIdentity).inserted
        }
        guard uniqueWindows.count == memberIDs.count,
              Set(uniqueWindows.map(\.stableIdentity)) == memberIDs,
              memberIDs.contains(mainWindow.stableIdentity),
              beginOwnedForegroundMutation(
                  groupID: groupID,
                  windows: uniqueWindows,
                  generation: generation,
                  allowsExactIdentityWithTransformedGeometry: true
              ) else {
            return false
        }

        let resolvedWindows = uniqueWindows.map {
            windowService.resolvingWindowServerIdentity(
                $0,
                allowsExactIdentityWithTransformedGeometry: true
            )
        }
        // validatedGroupWindows was just rebuilt from exact persisted
        // identity + current layer-zero Window Server evidence. Repeating a
        // full role/position/size liveness sweep here only adds synchronous AX
        // waits. The actual raise/focus calls remain on the established 0.45 s
        // interactive timeout and fail closed on an invalid/stale element.
        guard Set(resolvedWindows.map(\.stableIdentity)) == memberIDs,
              resolvedWindows.allSatisfy({ $0.cgWindowID != nil }) else {
            return false
        }

        for follower in resolvedWindows where
            follower.stableIdentity != mainWindow.stableIdentity {
            guard missionControlProxyActivationIsCurrent(
                groupID: groupID,
                generation: generation,
                memberIDs: memberIDs
            ) else { return false }
            guard windowService.raise(follower) else { return false }
        }
        guard missionControlProxyActivationIsCurrent(
            groupID: groupID,
            generation: generation,
            memberIDs: memberIDs
        ), let resolvedMain = resolvedWindows.first(where: {
            $0.stableIdentity == mainWindow.stableIdentity
        }) else {
            return false
        }
        windowService.focus(resolvedMain)
        return true
    }

    private func cancelMissionControlProxyActivation(
        groupID: SnapGroupID,
        generation: Int
    ) {
        guard let activation = activeMissionControlProxyActivation,
              activation.groupID == groupID,
              activation.generation == generation else { return }
        activeMissionControlProxyActivation = nil
        endOwnedForegroundMutation(generation: generation)
        missionControlGroupProxyController.cancelSelectionTransition(
            for: groupID
        )
        refreshResizeHandles()
        scheduleGroupSpaceMigrationForegroundFlushIfReady()
        // Failure preserves group membership, placements, and the previous
        // foreground mode. Transition-derived input is consumed rather than
        // falling through to another group below the selected proxy.
        discardDeferredForegroundSignals()
    }

    private func scheduleMissionControlProxyActivationRetry(
        groupID: SnapGroupID,
        generation: Int,
        completedAttempts: Int,
        successfulOrderingPassExists: Bool,
        passiveTransformObservations: Int,
        unsettledDesktopVerificationDeferrals: Int,
        advancesActivationAttempt: Bool = true
    ) {
        guard (!advancesActivationAttempt
                || MissionControlProxyActivationRetryPolicy.allowsAnotherPass(
                    completedAttempts: completedAttempts
                )),
              activeMissionControlProxyActivation?.generation
                == generation else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.groupRaiseGeneration == generation,
                  self.activeMissionControlProxyActivation?.generation
                    == generation else { return }
            self.pendingGroupRaiseWorkItem = nil
            self.activateExplicitGroupFromMissionControlProxy(
                groupID: groupID,
                generation: generation,
                completedAttempts: completedAttempts
                    + (advancesActivationAttempt ? 1 : 0),
                successfulOrderingPassExists:
                    successfulOrderingPassExists,
                passiveTransformObservations:
                    passiveTransformObservations,
                unsettledDesktopVerificationDeferrals:
                    unsettledDesktopVerificationDeferrals
            )
        }
        pendingGroupRaiseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + groupRaiseVerificationDelay,
            execute: workItem
        )
    }
}
