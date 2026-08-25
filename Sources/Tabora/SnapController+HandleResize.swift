import AppKit

extension SnapController {
    func refreshResizeHandles(
        using providedVisibleWindows: [ManagedWindow]? = nil,
        deferOcclusionRefresh: Bool = false,
        windowServerSnapshot providedWindowServerSnapshot:
            [WindowOcclusionSnapshot]? = nil
    ) {
        let canMaintainGroupPresentation = isEnabled
            && settings.linkedResizeEnabled
            && isUserSessionActive
            && !isSnapPlacementInProgress
            && handleResizeSession == nil
            && !isHandleResizeFinalizing
            && manualResizeWindow == nil
            && !isApplicationInteractionSuppressed
        let snapOrAssistOwnsPresentation =
            PresentationTransactionOwnershipPolicy
                .preservesMissionControlPresentation(
                    snapPlacementInProgress: isSnapPlacementInProgress,
                    assistSessionActive: activeSession != nil,
                    assistPlacementPending: isAssistPlacementPending
                )

        if ResizeHandlePresentationOwnershipPolicy
            .missionControlSelectionOwnsPresentation(
                activationIsActive:
                    missionControlSelectionTransactionIsActive
            ) {
            resizeHandleOverlay.setPresentationSuspended(true)
            return
        }

        guard isEnabled,
              settings.linkedResizeEnabled,
              !isSnapPlacementInProgress,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              manualResizeWindow == nil,
              activeSession == nil,
              !isAssistPlacementPending,
              !isApplicationInteractionSuppressed else {
            // Snap/Assist owns the visible transaction. Snap start already
            // invalidates only the structurally affected group; Assist keeps
            // the remaining validated Mission Control presentation stable. Do
            // not rebuild or globally retire proxies behind those UI layers.
            if snapOrAssistOwnsPresentation {
                // Intentionally preserve current proxy state.
            } else if canMaintainGroupPresentation {
                refreshMissionControlGroupProxies()
            } else {
                missionControlGroupProxyController.hideAll()
                resetGroupPresentationTransitionRecovery()
            }
            if handleResizeSession == nil {
                handlePresentationGeneration &+= 1
                baseResizeHandleDescriptors = []
                lastPresentableResizeHandleDescriptors = []
                quarantinedResizeHandleIDs.removeAll()
                hasValidatedCurrentHandleGeometry = false
                resizeHandleOverlay.hideAll()
                resetHandlePresentationLivenessRecovery()
            }
            return
        }

        guard !explicitGroupStore.groups.isEmpty else {
            handlePresentationGeneration &+= 1
            baseResizeHandleDescriptors = []
            lastPresentableResizeHandleDescriptors = []
            quarantinedResizeHandleIDs.removeAll()
            hasValidatedCurrentHandleGeometry = false
            resizeHandleOverlay.hideAll()
            missionControlGroupProxyController.hideAll()
            resetHandlePresentationLivenessRecovery()
            resetMissionControlPresentationRetryDebt()
            return
        }

        let visibleWindows = providedVisibleWindows ?? managedExplicitGroupWindows()
        let windowServerSnapshot = providedWindowServerSnapshot
            ?? windowService.windowOcclusionSnapshot()
        updateGroupWindowServerEvidence(
            using: visibleWindows,
            windowServerSnapshot: windowServerSnapshot
        )
        if shouldPreserveGroupPresentationDuringWindowServerTransform(
            visibleWindows: visibleWindows,
            using: windowServerSnapshot
        ) {
            // Mission Control owns the current visual transform. Keep both the
            // last validated static proxy and handle geometry intact, but make
            // the desktop-only handles non-presented until normal AX/CG
            // agreement returns.
            isPreservingGroupPresentationForWindowServerTransform = true
            resizeHandleOverlay.setPresentationSuspended(true)
            return
        }
        isPreservingGroupPresentationForWindowServerTransform = false
        let spaceSeparationPendingGroupIDs: Set<SnapGroupID>
        if isUserSessionActive {
            spaceSeparationPendingGroupIDs =
                reconcileExplicitGroupsSeparatedAcrossSpaces(
                    windowServerSnapshot: windowServerSnapshot
                )
        } else {
            // Lock/login transitions can temporarily remove otherwise-live
            // surfaces. They are never Space-separation evidence.
            spaceSeparationPendingGroupIDs = []
        }
        guard !explicitGroupStore.groups.isEmpty else {
            handlePresentationGeneration &+= 1
            baseResizeHandleDescriptors = []
            lastPresentableResizeHandleDescriptors = []
            quarantinedResizeHandleIDs.removeAll()
            hasValidatedCurrentHandleGeometry = false
            resizeHandleOverlay.hideAll()
            missionControlGroupProxyController.hideAll()
            resetHandlePresentationLivenessRecovery()
            resetMissionControlPresentationRetryDebt()
            return
        }
        pruneForegroundStateForActiveGroups()
        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previouslyValidatedDescriptors = baseResizeHandleDescriptors
        var descriptors: [ResizeHandleDescriptor] = []
        var quarantinedDescriptorIDs = Set<String>()
        var incompleteGroupIDs = spaceSeparationPendingGroupIDs
        var interactionUnavailableGroupIDs = Set<SnapGroupID>()

        for screen in NSScreen.screens {
            guard let screenDisplayID = displayID(for: screen) else { continue }
            for group in explicitGroupStore.groups where
                group.displayID == screenDisplayID {
                guard !spaceSeparationPendingGroupIDs.contains(group.id) else {
                    // A split-across-Space group has no complete active-desktop
                    // boundary. Keep its handles absent while structural
                    // evidence is being confirmed.
                    continue
                }
                var interactionUnavailable = false
                let placements = group.memberIDs.compactMap { identity
                    -> SplitPlacementGeometry? in
                    guard let placement = lockedPlacements[identity],
                          placement.displayID == screenDisplayID,
                          !inFlightPlacementIDs.contains(identity) else {
                        return nil
                    }
                    guard let window = windowsByIdentity[identity],
                          windowService.canMoveAndResize(window) else {
                        interactionUnavailable = true
                        return nil
                    }
                    return SplitPlacementGeometry(
                        stableIdentity: identity,
                        zone: placement.zone,
                        frame: window.frame
                    )
                }
                guard placements.count == group.memberIDs.count else {
                    incompleteGroupIDs.insert(group.id)
                    let physicalMembersAreStillPresent = group.memberIDs
                        .allSatisfy { memberID in
                            guard let placement = lockedPlacements[memberID],
                                  placement.displayID == screenDisplayID,
                                  let windowID = placement.cgWindowID else {
                                return false
                            }
                            return windowServerSnapshot.contains { surface in
                                surface.pid == placement.pid
                                    && surface.windowID == windowID
                                    && surface.layer == 0
                            }
                        }
                    if interactionUnavailable, physicalMembersAreStillPresent {
                        interactionUnavailableGroupIDs.insert(group.id)
                        // Retain only the last boundary owned by this exact group.
                        // It is input-quarantined below: it keeps Tabora's arrow
                        // hit region above the native edge, but cannot start a
                        // shared resize until AX eligibility is proven again.
                        let retained = previouslyValidatedDescriptors.filter {
                            $0.displayID == screenDisplayID
                                && $0.participantIDs.isSubset(of: group.memberIDs)
                        }
                        descriptors.append(contentsOf: retained)
                        quarantinedDescriptorIDs.formUnion(retained.map(\.id))
                    }
                    continue
                }
                let geometries = SplitLayoutGeometry.resizeHandleGeometries(
                    placements: placements,
                    detachedConnections: detachedConnections
                )
                guard ResizeHandleGroupPresentationPolicy
                    .presentsCompleteGroup(
                        memberIDs: group.memberIDs,
                        preferredMemberID: group.preferredMemberID,
                        geometries: geometries
                    ) else {
                    incompleteGroupIDs.insert(group.id)
                    continue
                }
                descriptors.append(contentsOf: geometries.map { geometry in
                    let occlusionParticipants = geometry.participantIDs.sorted().compactMap {
                        identity -> WindowOcclusionParticipant? in
                        guard let window = windowsByIdentity[identity] else { return nil }
                        return WindowOcclusionParticipant(
                            pid: window.pid,
                            frame: window.frame,
                            windowID: window.cgWindowID
                        )
                    }
                    return ResizeHandleDescriptor(
                        id: resizeHandleIdentity(
                            displayID: screenDisplayID,
                            geometry: geometry
                        ),
                        displayID: screenDisplayID,
                        axis: geometry.axis,
                        coordinate: geometry.coordinate,
                        span: geometry.span,
                        screenFrame: screen.visibleFrame,
                        participantIDs: geometry.participantIDs,
                        occlusionParticipants: occlusionParticipants,
                        presentationStyle: settings.linkedResizePresentationStyle,
                        showsResizeCursorAdornment: settings
                            .resizeCursorAdornmentEnabled,
                        resizeCursorAdornmentDistance: CGFloat(
                            settings.resizeCursorAdornmentDistance
                        )
                    )
                })
            }
        }
        let descriptorsChanged = descriptors != baseResizeHandleDescriptors
        if descriptorsChanged {
            handlePresentationGeneration &+= 1
            hasValidatedCurrentHandleGeometry = false
        }
        let descriptorIDs = Set(descriptors.map(\.id))
        handleOcclusionFailureCountsByDescriptorID =
            handleOcclusionFailureCountsByDescriptorID.filter {
                descriptorIDs.contains($0.key)
            }
        baseResizeHandleDescriptors = descriptors
        quarantinedResizeHandleIDs = quarantinedDescriptorIDs
        if !incompleteGroupIDs.isEmpty {
            scheduleIncompleteHandleGeometryRefresh(
                for: incompleteGroupIDs,
                fastRetryGroupIDs: incompleteGroupIDs.subtracting(
                    interactionUnavailableGroupIDs
                )
            )
        } else {
            resetIncompleteHandleGeometryRecovery()
        }
        refreshMissionControlGroupProxies(
            using: visibleWindows,
            windowServerSnapshot: windowServerSnapshot
        )
        guard !deferOcclusionRefresh else { return }
        refreshResizeHandleOcclusion(
            force: true,
            using: windowServerSnapshot
        )
    }

    func scheduleIncompleteHandleGeometryRefresh(
        for groupIDs: Set<SnapGroupID>,
        fastRetryGroupIDs: Set<SnapGroupID>? = nil
    ) {
        let activeGroupIDs = Set(explicitGroupStore.groups.map(\.id))
        handleGeometryFailureCountsByGroupID =
            handleGeometryFailureCountsByGroupID.filter {
                activeGroupIDs.contains($0.key) && groupIDs.contains($0.key)
            }
        for groupID in groupIDs {
            handleGeometryFailureCountsByGroupID[groupID, default: 0] += 1
        }
        let groupsEligibleForFastRetry = fastRetryGroupIDs ?? groupIDs
        guard !groupsEligibleForFastRetry.isEmpty,
              scheduledHandleGeometryRetryGeneration == nil else { return }
        let retryableCounts = groupsEligibleForFastRetry.compactMap { groupID -> Int? in
            guard let count = handleGeometryFailureCountsByGroupID[groupID],
                  count <= 6 else { return nil }
            return count
        }
        guard let earliestDebt = retryableCounts.min() else { return }
        handleGeometryRetryGeneration &+= 1
        let generation = handleGeometryRetryGeneration
        scheduledHandleGeometryRetryGeneration = generation
        let delay: TimeInterval
        switch earliestDebt {
        case 1...2: delay = 0.05
        case 3...4: delay = 0.12
        default: delay = 0.30
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.scheduledHandleGeometryRetryGeneration == generation
            else { return }
            self.scheduledHandleGeometryRetryGeneration = nil
            self.refreshResizeHandles()
        }
    }

    func resetIncompleteHandleGeometryRecovery() {
        handleGeometryFailureCountsByGroupID.removeAll()
        guard scheduledHandleGeometryRetryGeneration != nil else { return }
        handleGeometryRetryGeneration &+= 1
        scheduledHandleGeometryRetryGeneration = nil
    }

    func updateGroupWindowServerEvidence(
        using visibleWindows: [ManagedWindow],
        windowServerSnapshot: [WindowOcclusionSnapshot]
    ) {
        let activeMemberIDs = explicitGroupStore.groups.reduce(
            into: Set<String>()
        ) { result, group in
            result.formUnion(group.memberIDs)
        }
        lastGroupWindowServerEvidenceByIdentity =
            lastGroupWindowServerEvidenceByIdentity.filter {
                activeMemberIDs.contains($0.key)
            }
        for window in visibleWindows where
            activeMemberIDs.contains(window.stableIdentity) {
            guard lockedPlacements[window.stableIdentity] != nil,
                  let windowID = window.cgWindowID,
                  let surface = windowServerSnapshot.first(where: {
                      $0.pid == window.pid
                          && $0.windowID == windowID
                          && $0.layer == 0
                  }), GroupWindowServerEvidenceBaselinePolicy
                    .framesRepresentTheSameDesktopGeometry(
                        accessibilityFrame: window.frame,
                        windowServerFrame: surface.frame
                    ) else {
                // During Mission Control AX keeps reporting desktop geometry
                // while Window Server scales the physical surface. Never
                // replace the last proven desktop baseline with transformed
                // geometry. The same rule also prevents a stale placement
                // frame from coupling resize settlement to transition proof.
                continue
            }
            if let previous = lastGroupWindowServerEvidenceByIdentity[
                window.stableIdentity
            ], previous.pid != window.pid
                || previous.windowID != windowID {
                // Do not replace established identity evidence during a
                // transient AX/CG mismatch. A genuine window replacement is
                // handled by the ordinary group invalidation path.
                continue
            }
            lastGroupWindowServerEvidenceByIdentity[window.stableIdentity] =
                GroupWindowServerEvidence(
                    stableIdentity: window.stableIdentity,
                    pid: window.pid,
                    windowID: windowID,
                    expectedFrame: window.frame
                )
        }
    }

    func groupWindowServerEvidenceHasNormalGeometry(
        _ evidence: GroupWindowServerEvidence,
        snapshot: [WindowOcclusionSnapshot]
    ) -> Bool {
        guard let windowID = evidence.windowID,
              let surface = snapshot.first(where: {
                  $0.pid == evidence.pid
                      && $0.windowID == windowID
                      && $0.layer == 0
              }), evidence.expectedFrame.width > 1,
                 evidence.expectedFrame.height > 1 else {
            return false
        }
        let widthScale = surface.frame.width / evidence.expectedFrame.width
        let heightScale = surface.frame.height / evidence.expectedFrame.height
        return abs(widthScale - 1)
                < GroupPresentationTransitionPolicy.defaultMinimumScaleDelta
            && abs(heightScale - 1)
                < GroupPresentationTransitionPolicy.defaultMinimumScaleDelta
    }

    func normalGeometryVisibleGroupMemberIDs(
        visibleWindows: [ManagedWindow],
        snapshot: [WindowOcclusionSnapshot]
    ) -> Set<String> {
        Set(visibleWindows.compactMap { window -> String? in
            guard let expected = lastGroupWindowServerEvidenceByIdentity[
                window.stableIdentity
            ], expected.pid == window.pid,
               expected.windowID == window.cgWindowID,
               groupWindowServerEvidenceHasNormalGeometry(
                   expected,
                   snapshot: snapshot
               ) else {
                return nil
            }
            return window.stableIdentity
        })
    }

    func missionControlTransitionIsCurrentlyObserved(
        groupID: SnapGroupID
    ) -> Bool {
        guard let group = explicitGroupStore.group(id: groupID) else {
            return false
        }
        let evidence = group.memberIDs.compactMap {
            lastGroupWindowServerEvidenceByIdentity[$0]
        }
        guard evidence.count == group.memberIDs.count else { return false }
        let snapshot = windowService.windowOcclusionSnapshot()
        let normalGeometryMemberIDs = Set(evidence.compactMap { expected
            -> String? in
            groupWindowServerEvidenceHasNormalGeometry(
                expected,
                snapshot: snapshot
            ) ? expected.stableIdentity : nil
        })
        return GroupPresentationTransitionPolicy.observe(
            evidence: evidence,
            expectedMemberCount: group.memberIDs.count,
            visibleMemberIDs: normalGeometryMemberIDs,
            snapshot: snapshot
        ) == .transformed
    }

    func shouldPreserveGroupPresentationDuringWindowServerTransform(
        visibleWindows: [ManagedWindow],
        using providedSnapshot: [WindowOcclusionSnapshot]? = nil
    ) -> Bool {
        guard missionControlGroupPresentationIsEnabled,
              !explicitGroupStore.groups.isEmpty else {
            resetGroupPresentationTransitionRecovery()
            return false
        }
        let snapshot = providedSnapshot
            ?? windowService.windowOcclusionSnapshot()
        let normalGeometryMemberIDs = normalGeometryVisibleGroupMemberIDs(
            visibleWindows: visibleWindows,
            snapshot: snapshot
        )
        var observations: [SnapGroupID: GroupPresentationTransitionObservation] = [:]

        for group in explicitGroupStore.groups {
            let evidence = group.memberIDs.compactMap {
                lastGroupWindowServerEvidenceByIdentity[$0]
            }
            observations[group.id] = GroupPresentationTransitionPolicy.observe(
                evidence: evidence,
                expectedMemberCount: group.memberIDs.count,
                visibleMemberIDs: normalGeometryMemberIDs.intersection(
                    group.memberIDs
                ),
                snapshot: snapshot
            )
        }

        let transformedGroupIDs = Set(observations.compactMap { groupID, state in
            state == .transformed ? groupID : nil
        })
        let unresolvedLiveGroupIDs = Set(observations.compactMap { groupID, state in
            state == .unresolvedLive ? groupID : nil
        })
        let normalGroupIDs = Set(observations.compactMap { groupID, state in
            state == .normal ? groupID : nil
        })
        let now = ProcessInfo.processInfo.systemUptime
        let groupsByID = Dictionary(
            uniqueKeysWithValues: explicitGroupStore.groups.map {
                ($0.id, $0)
            }
        )
        groupPresentationTransitionLeasesByGroupID =
            groupPresentationTransitionLeasesByGroupID.filter {
                groupID, lease in
                guard let group = groupsByID[groupID] else { return false }
                return GroupPresentationTransitionLeasePolicy.isValid(
                    lease,
                    groupID: groupID,
                    memberIDs: group.memberIDs,
                    now: now
                )
            }
        let authorizedUnavailableGroupIDs = Set<SnapGroupID>(
            observations.compactMap { (groupID, state) -> SnapGroupID? in
                guard state == .unavailable,
                      let group = groupsByID[groupID],
                      GroupPresentationTransitionLeasePolicy.isValid(
                          groupPresentationTransitionLeasesByGroupID[groupID],
                          groupID: groupID,
                          memberIDs: group.memberIDs,
                          now: now
                      ) else {
                    return nil
                }
                return groupID
            }
        )

        if !transformedGroupIDs.isEmpty {
            // Mission Control is a global Window Server transform, but the
            // evidence authorizing it is group-local. One unrelated group with
            // incomplete AX/CG evidence must not erase a transition already
            // proven by another complete group. The controller's short-lived
            // transform lease is independent from proxy selection authorization.
            for groupID in transformedGroupIDs {
                guard let group = groupsByID[groupID] else { continue }
                groupPresentationTransitionLeasesByGroupID[groupID] =
                    GroupPresentationTransitionLeasePolicy.make(
                        groupID: groupID,
                        memberIDs: group.memberIDs,
                        now: now
                    )
                // This is separate selection authorization. It is issued only
                // to a safely presented proxy and is never read back as the
                // controller's transform-preservation evidence.
                missionControlGroupProxyController
                    .noteMissionControlTransitionObserved(groupID: groupID)
            }
            groupPresentationRecoveryDeadline = max(
                groupPresentationRecoveryDeadline ?? 0,
                now + GroupPresentationTransitionLeasePolicy.lifetime
            )
            return true
        }

        if !unresolvedLiveGroupIDs.isEmpty
            || !authorizedUnavailableGroupIDs.isEmpty {
            // A group that already proved the transform may lose one evidence
            // sample without losing its still-valid group-scoped transform
            // lease. Unavailable evidence never starts or extends that bounded
            // lease by itself.
            guard let deadline = groupPresentationRecoveryDeadline,
                  now <= deadline else {
                // AX/Window Server disagreement by itself is common during
                // ordinary resize, application throttling and constraint
                // settlement. It may continue a transform already proven by
                // an isotropically scaled group, but it cannot start a global
                // Mission Control preservation transaction on its own.
                resetGroupPresentationTransitionRecovery()
                return false
            }
            scheduleGroupPresentationRecoveryChecksIfNeeded()
            return true
        }

        let presentationNeedsOrderingRevalidation =
            groupPresentationRecoveryDeadline != nil
            || isPreservingGroupPresentationForWindowServerTransform
        if presentationNeedsOrderingRevalidation, !normalGroupIDs.isEmpty {
            // Revalidate only groups whose own normal desktop evidence is back.
            // An unrelated unavailable group must not demote a valid proxy.
            missionControlGroupProxyController.requireOrderingRevalidation(
                groupIDs: normalGroupIDs
            )
        }
        resetGroupPresentationTransitionRecovery()
        return false
    }

    func scheduleGroupPresentationRecoveryChecksIfNeeded() {
        guard !groupPresentationRecoveryChecksAreScheduled else { return }
        groupPresentationRecoveryChecksAreScheduled = true
        groupPresentationRecoveryGeneration &+= 1
        let generation = groupPresentationRecoveryGeneration
        let delays: [TimeInterval] = [0.08, 0.24, 0.60, 1.30]
        let finalIndex = delays.index(before: delays.endIndex)
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.groupPresentationRecoveryGeneration == generation
                else { return }
                if index == finalIndex {
                    self.groupPresentationRecoveryChecksAreScheduled = false
                }
                self.refreshResizeHandles()
            }
        }
    }

    func invalidateGroupPresentationTransitionState(
        for groupIDs: Set<SnapGroupID>
    ) {
        guard !groupIDs.isEmpty else { return }
        groupPresentationTransitionLeasesByGroupID =
            GroupPresentationTransitionLeasePolicy.retainingUnretired(
                groupPresentationTransitionLeasesByGroupID,
                retiring: groupIDs
            )
    }

    func retireGroupPresentationTransitionState(
        for retiredGroupIDs: Set<SnapGroupID>
    ) {
        invalidateGroupPresentationTransitionState(for: retiredGroupIDs)

        // Whole-group departure remains intentionally strong, but its
        // presentation cleanup is group-scoped. Only a genuinely global
        // application/OS transition may invalidate unrelated groups' leases.
        if explicitGroupStore.groups.isEmpty {
            resetGroupPresentationTransitionRecovery()
        }
    }

    func resetGroupPresentationTransitionRecovery() {
        guard groupPresentationRecoveryDeadline != nil
                || !groupPresentationTransitionLeasesByGroupID.isEmpty
                || groupPresentationRecoveryChecksAreScheduled
                || isPreservingGroupPresentationForWindowServerTransform else {
            return
        }
        groupPresentationRecoveryGeneration &+= 1
        groupPresentationRecoveryDeadline = nil
        groupPresentationTransitionLeasesByGroupID.removeAll()
        groupPresentationRecoveryChecksAreScheduled = false
        isPreservingGroupPresentationForWindowServerTransform = false
    }

    func refreshResizeHandleOcclusion(
        force: Bool = false,
        using providedSnapshot: [WindowOcclusionSnapshot]? = nil
    ) {
        if ResizeHandlePresentationOwnershipPolicy
            .missionControlSelectionOwnsPresentation(
                activationIsActive:
                    missionControlSelectionTransactionIsActive
            ) {
            resizeHandleOverlay.setPresentationSuspended(true)
            return
        }
        guard !isPreservingGroupPresentationForWindowServerTransform else {
            resizeHandleOverlay.setPresentationSuspended(true)
            return
        }
        guard isEnabled,
              settings.linkedResizeEnabled,
              !isSnapPlacementInProgress,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              manualResizeWindow == nil,
              activeSession == nil,
              !isAssistPlacementPending,
              !isApplicationInteractionSuppressed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastHandleOcclusionRefreshAt
            >= handleOcclusionRefreshInterval else { return }
        lastHandleOcclusionRefreshAt = now

        let snapshot = providedSnapshot
            ?? windowService.windowOcclusionSnapshot()
        var visibleDescriptors: [ResizeHandleDescriptor] = []
        var validatedDescriptors: [ResizeHandleDescriptor] = []
        var incompleteDescriptorIDs = Set<String>()
        for descriptor in baseResizeHandleDescriptors {
            guard let occludingFrames = verifiedOccludingFrames(
                for: descriptor,
                in: snapshot
            ) else {
                // Fail closed only for the ambiguous boundary. Suspending every
                // panel here made one transient AX/CG mismatch disable unrelated
                // handles in three- and four-way layouts.
                incompleteDescriptorIDs.insert(descriptor.id)
                continue
            }
            validatedDescriptors.append(descriptor)
            if !descriptor.isOccluded(by: occludingFrames) {
                visibleDescriptors.append(descriptor)
            }
        }
        let hasIncompleteDescriptor = !incompleteDescriptorIDs.isEmpty
        if !validatedDescriptors.isEmpty || !hasIncompleteDescriptor {
            lastValidatedRecoveryInteractionRegions = validatedDescriptors.map {
                $0.interactionFrame()
            }
        }
        lastRecoverySceneSignature = SplitLayoutGeometry.recoverySceneSignature(
            for: snapshot,
            managedWindowIDs: Set(lockedPlacements.values.compactMap(\.cgWindowID)),
            interactionRegions: lastValidatedRecoveryInteractionRegions
        )
        resizeHandleOverlay.update(
            visibleDescriptors,
            quarantinedIDs: quarantinedResizeHandleIDs.intersection(
                Set(visibleDescriptors.map(\.id))
            )
        )
        resizeHandleOverlay.setInputSuspended(false)
        resizeHandleOverlay.setPresentationSuspended(false)
        lastPresentableResizeHandleDescriptors = visibleDescriptors.filter {
            !quarantinedResizeHandleIDs.contains($0.id)
        }
        hasValidatedCurrentHandleGeometry = visibleDescriptors.contains {
            !quarantinedResizeHandleIDs.contains($0.id)
        } || (!hasIncompleteDescriptor && visibleDescriptors.isEmpty)
        evaluateHandlePresentationLiveness(
            expectedDescriptors: lastPresentableResizeHandleDescriptors
        )
        if hasIncompleteDescriptor {
            for descriptor in validatedDescriptors {
                handleOcclusionFailureCountsByDescriptorID.removeValue(
                    forKey: descriptor.id
                )
            }
            handleIncompleteOcclusionSnapshot(for: incompleteDescriptorIDs)
        } else {
            resetIncompleteHandleOcclusionRecovery()
        }
    }

    func evaluateHandlePresentationLiveness(
        expectedDescriptors: [ResizeHandleDescriptor]
    ) {
        let presentedIDs = resizeHandleOverlay.presentedBoundaryIDs
        let activeGroups = explicitGroupStore.groups
        let activeGroupIDs = Set(activeGroups.map(\.id))
        handleLivenessFailureCountsByGroupID =
            handleLivenessFailureCountsByGroupID.filter {
                activeGroupIDs.contains($0.key)
            }

        var missingGroupIDs = Set<SnapGroupID>()
        for group in activeGroups {
            let expectedIDs = Set(expectedDescriptors.compactMap { descriptor in
                descriptor.participantIDs.isSubset(of: group.memberIDs)
                    ? descriptor.id : nil
            })
            guard !expectedIDs.isEmpty else {
                handleLivenessFailureCountsByGroupID.removeValue(
                    forKey: group.id
                )
                continue
            }
            if expectedIDs.isDisjoint(with: presentedIDs) {
                missingGroupIDs.insert(group.id)
                handleLivenessFailureCountsByGroupID[group.id, default: 0] += 1
            } else {
                handleLivenessFailureCountsByGroupID.removeValue(
                    forKey: group.id
                )
            }
        }

        guard !missingGroupIDs.isEmpty else {
            resetScheduledHandleLivenessRetryIfDebtCleared()
            return
        }
        scheduleHandlePresentationLivenessRetry(for: missingGroupIDs)
    }

    func scheduleHandlePresentationLivenessRetry(
        for groupIDs: Set<SnapGroupID>
    ) {
        guard scheduledHandleLivenessRetryGeneration == nil else { return }
        let retryable = groupIDs.compactMap { groupID -> Int? in
            guard let count = handleLivenessFailureCountsByGroupID[groupID],
                  count <= 6 else { return nil }
            return count
        }
        guard let earliestDebt = retryable.min() else {
            // Bounded fast retry is exhausted. The independent one-second
            // Recovery watchdog owns the remaining liveness debt.
            return
        }
        handleLivenessRetryGeneration &+= 1
        let generation = handleLivenessRetryGeneration
        scheduledHandleLivenessRetryGeneration = generation
        let delay: TimeInterval
        switch earliestDebt {
        case 1...2: delay = 0.05
        case 3...4: delay = 0.12
        default: delay = 0.30
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.scheduledHandleLivenessRetryGeneration == generation
            else { return }
            self.scheduledHandleLivenessRetryGeneration = nil
            guard !self.handleLivenessFailureCountsByGroupID.isEmpty else {
                return
            }
            self.refreshResizeHandles()
        }
    }

    func resetScheduledHandleLivenessRetryIfDebtCleared() {
        guard handleLivenessFailureCountsByGroupID.isEmpty,
              scheduledHandleLivenessRetryGeneration != nil else { return }
        handleLivenessRetryGeneration &+= 1
        scheduledHandleLivenessRetryGeneration = nil
    }

    func resetHandlePresentationLivenessRecovery() {
        handleLivenessFailureCountsByGroupID.removeAll()
        handleLivenessRetryGeneration &+= 1
        scheduledHandleLivenessRetryGeneration = nil
    }

    func verifiedOccludingFrames(
        for descriptor: ResizeHandleDescriptor,
        in snapshot: [WindowOcclusionSnapshot]
    ) -> [CGRect]? {
        guard descriptor.occlusionParticipants.count
                == descriptor.participantIDs.count,
              let occluders = windowService.occludingWindows(
                  above: descriptor.occlusionParticipants,
                  in: snapshot
              ) else { return nil }
        return occluders.compactMap {
            $0.layer == 0 ? $0.frame : nil
        }
    }

    func handleIncompleteOcclusionSnapshot(
        for descriptorIDs: Set<String>
    ) {
        guard !descriptorIDs.isEmpty else { return }
        let activeDescriptorIDs = Set(baseResizeHandleDescriptors.map(\.id))
        handleOcclusionFailureCountsByDescriptorID =
            handleOcclusionFailureCountsByDescriptorID.filter {
                activeDescriptorIDs.contains($0.key)
            }
        for descriptorID in descriptorIDs {
            handleOcclusionFailureCountsByDescriptorID[descriptorID, default: 0] += 1
        }

        // Window Server and Accessibility information can briefly disagree just
        // after a snap, activation, or Space transition. Retry debt belongs to
        // the ambiguous descriptor, so one group's prolonged uncertainty cannot
        // consume another group's immediate recovery budget. A single shared
        // timer still refreshes all descriptors and avoids creating more polling.
        let retryGeneration = handlePresentationGeneration
        guard scheduledHandleOcclusionRetryGeneration != retryGeneration else {
            return
        }
        let retryableCounts = descriptorIDs.compactMap { descriptorID -> Int? in
            guard let count = handleOcclusionFailureCountsByDescriptorID[descriptorID],
                  count <= maximumImmediateHandleOcclusionFailures else {
                return nil
            }
            return count
        }
        guard let earliestDebt = retryableCounts.min() else {
            // The 1-second Recovery pass continues to check long-lived debt.
            return
        }
        scheduledHandleOcclusionRetryGeneration = retryGeneration
        let retryDelay: TimeInterval
        switch earliestDebt {
        case 0...2:
            retryDelay = 0.05
        case 3...5:
            retryDelay = 0.15
        default:
            retryDelay = 0.50
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self,
                  self.scheduledHandleOcclusionRetryGeneration
                    == retryGeneration else { return }
            self.scheduledHandleOcclusionRetryGeneration = nil
            guard self.handlePresentationGeneration == retryGeneration else {
                return
            }
            self.refreshResizeHandleOcclusion(force: true)
        }
    }

    func resetIncompleteHandleOcclusionRecovery() {
        handleOcclusionFailureCountsByDescriptorID.removeAll()
        if scheduledHandleOcclusionRetryGeneration == handlePresentationGeneration {
            scheduledHandleOcclusionRetryGeneration = nil
        }
    }

    func resizeHandleIdentity(
        displayID: CGDirectDisplayID,
        geometry: SplitResizeHandleGeometry
    ) -> String {
        let axis = geometry.axis == .horizontal ? "h" : "v"
        let participants = geometry.participantIDs.sorted().joined(separator: "|")
        return "\(displayID):\(axis):\(participants)"
    }

    func handleResizeHandlePresentationSignal(
        _ signal: ResizeHandlePresentationSignal
    ) {
        guard ResizeHandlePresentationPolicy.shouldSuspend(for: signal) else {
            return
        }
        guard handleResizeSession == nil,
              !isHandleResizeFinalizing else { return }
        resizeHandleOverlay.setPresentationSuspended(true)
        if case .applicationDeactivated = signal { return }
        scheduleHandlePresentationRevalidation()
    }

    func scheduleHandlePresentationRevalidation() {
        handlePresentationRevalidationGeneration &+= 1
        let generation = handlePresentationRevalidationGeneration
        for delay in [0.0, 0.05, 0.12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.handlePresentationRevalidationGeneration
                        == generation,
                      self.handleResizeSession == nil,
                      !self.isHandleResizeFinalizing else { return }
                guard self.pendingSelectionRaiseWorkItem == nil,
                      self.pendingGroupRaiseWorkItem == nil,
                      !self.missionControlSelectionTransactionIsActive,
                      !self.hasDeferredSelectionSignal else { return }
                self.refreshResizeHandles()
            }
        }
    }

    func beginHandleResize(
        interaction presentedInteraction: ResizeHandleInteraction,
        at point: CGPoint
    ) {
        let presentedDescriptors = presentedInteraction.descriptors
        let descriptors = presentedDescriptors.compactMap { presented in
            baseResizeHandleDescriptors.first { $0.id == presented.id }
        }
        guard isEnabled,
              settings.linkedResizeEnabled,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              ensurePermission(),
              descriptors.count == presentedDescriptors.count,
              let displayID = descriptors.first?.displayID,
              descriptors.allSatisfy({ $0.displayID == displayID }),
              let screen = screen(withDisplayID: displayID) else {
            rejectHandleResizeStart()
            return
        }
        let canonicalInteraction: ResizeHandleInteraction
        switch presentedInteraction {
        case .boundary:
            guard descriptors.count == 1 else {
                rejectHandleResizeStart()
                return
            }
            canonicalInteraction = .boundary(descriptors[0])
        case .junction(let presentedID, _, _):
            guard descriptors.count == 2,
                  let horizontal = descriptors.first(where: { $0.axis == .horizontal }),
                  let vertical = descriptors.first(where: { $0.axis == .vertical }),
                  [horizontal.id, vertical.id].sorted().joined(separator: "::")
                    == presentedID,
                  !horizontal.participantIDs.isDisjoint(
                      with: vertical.participantIDs
                  ),
                  horizontal.span.contains(vertical.coordinate),
                  vertical.span.contains(horizontal.coordinate) else {
                rejectHandleResizeStart()
                return
            }
            canonicalInteraction = .junction(
                id: presentedID,
                horizontal: horizontal,
                vertical: vertical
            )
        }
        let allParticipantIDs = canonicalInteraction.participantIDs

        let visibleWindows = managedExplicitGroupWindows()
        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let mainWindow = resolvedHandleMainWindow(
            participantIDs: allParticipantIDs,
            visibleWindows: visibleWindows
        ) else {
            rejectHandleResizeStart()
            return
        }

        var participants: [String: HandleResizeParticipant] = [:]
        for identity in allParticipantIDs {
            guard let window = windowsByIdentity[identity],
                  windowService.canMoveAndResize(
                      window,
                      messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                  ),
                  let placement = lockedPlacements[identity],
                  placement.displayID == displayID else { continue }
            let resolvedIdentity = resolveAppConstraintIdentity(for: window)
            let limits = resolvedIdentity.map {
                appConstraintRegistry.limits(for: $0.identity)
            } ?? .unknown
            let learningIdentity = windowService.isEligibleForConstraintLearning(window)
                ? resolvedIdentity : nil
            participants[identity] = HandleResizeParticipant(
                window: window,
                zone: placement.zone,
                originalFrame: window.frame,
                appConstraintIdentity: learningIdentity?.identity,
                appConstraintDisplayName: learningIdentity?.displayName ?? "App",
                appConstraintLimits: limits,
                targetFrame: window.frame
            )
        }
        guard participants.count == allParticipantIDs.count,
              participants.count >= 2,
              participants[mainWindow.stableIdentity] != nil else {
            rejectHandleResizeStart()
            return
        }

        var boundaries: [HandleResizeBoundary] = []
        for descriptor in canonicalInteraction.descriptors {
            var sides: [String: SplitBoundarySide] = [:]
            var geometry: [SplitResizeParticipantGeometry] = []
            for identity in descriptor.participantIDs {
                guard let participant = participants[identity],
                      let side = SplitLayoutGeometry.boundarySide(
                          for: participant.zone,
                          axis: descriptor.axis
                      ) else {
                    rejectHandleResizeStart()
                    return
                }
                sides[identity] = side
                let minimumLength: CGFloat
                let maximumLength: CGFloat?
                switch descriptor.axis {
                case .horizontal:
                    minimumLength = participant.appConstraintLimits.minWidth
                        ?? SystemGeometryPolicy.minimumWindowLength
                    maximumLength = participant.appConstraintLimits.maxWidth
                case .vertical:
                    minimumLength = participant.appConstraintLimits.minHeight
                        ?? SystemGeometryPolicy.minimumWindowLength
                    maximumLength = participant.appConstraintLimits.maxHeight
                }
                geometry.append(SplitResizeParticipantGeometry(
                    stableIdentity: identity,
                    frame: participant.originalFrame,
                    side: side,
                    minimumLength: minimumLength,
                    maximumLength: maximumLength
                ))
            }
            guard sides.count == descriptor.participantIDs.count,
                  let allowedBoundary = SplitLayoutGeometry.allowedBoundaryRange(
                      axis: descriptor.axis,
                      participants: geometry,
                      screenFrame: screen.visibleFrame
                  ) else {
                rejectHandleResizeStart()
                return
            }
            boundaries.append(HandleResizeBoundary(
                descriptor: descriptor,
                allowedBoundary: allowedBoundary,
                sides: sides,
                coordinate: descriptor.coordinate
            ))
        }

        let groupFrontmostEvaluation = connectedGroupFrontmostEvaluation(
            Array(participants.values.map(\.window))
        )

        // A Window Server change can arrive between the last presentation
        // update and mouseDown. Revalidate immediately before AXRaise so a
        // stale visible handle cannot pull its participants above an
        // intervening window. No interaction state has been mutated yet.
        let occlusionSnapshot = windowService.windowOcclusionSnapshot()
        for descriptor in canonicalInteraction.descriptors {
            guard let occludingFrames = verifiedOccludingFrames(
                for: descriptor,
                in: occlusionSnapshot
            ) else {
                resizeHandleOverlay.endInteraction()
                quarantinedResizeHandleIDs.removeAll()
                resizeHandleOverlay.update([])
                handleIncompleteOcclusionSnapshot(for: [descriptor.id])
                return
            }
            guard !descriptor.isOccluded(by: occludingFrames) else {
                resizeHandleOverlay.endInteraction()
                refreshResizeHandleOcclusion(
                    force: true,
                    using: occlusionSnapshot
                )
                return
            }
        }

        if let group = explicitGroupStore.group(
            containing: mainWindow.stableIdentity
        ), allParticipantIDs.isSubset(of: group.memberIDs) {
            // Grabbing Tabora's shared control is explicit group intent.
            // Authorization is granted only to this validated group.
            setAutomaticForegroundMode(forGroupID: group.id)
        }

        invalidatePendingOperations()
        missionControlGroupProxyController.hideAll()
        activeSession = nil
        stopAssistLayoutModifierMonitoring()
        picker.hide()
        overlay.hide()
        virtualResizeOverlay.hideAll()
        resetDragState()

        // Raise only the participants of this still-active handle. Do not
        // activate every application here; AXRaise preserves the drag event,
        // while the clicked/main participant is raised last.
        if groupFrontmostEvaluation == .occluded {
            raiseWindows(
                participants.values.map(\.window),
                withMainWindow: mainWindow
            )
        }

        let allIdentities = Set(participants.keys)
        let liveIdentities: Set<String>
        switch settings.linkedResizeDisplayMode {
        case .lightweight:
            liveIdentities = []
        case .mainOnly:
            liveIdentities = [mainWindow.stableIdentity]
        case .allWindows:
            liveIdentities = allIdentities
        }
        let virtualIdentities = allIdentities.subtracting(liveIdentities)
        let snapshots = participants.values.map { windowService.snapshot($0.window) }
        let schedulerGeneration = liveResizeScheduler.begin()
        handleResizeSession = HandleResizeSession(
            interactionID: canonicalInteraction.id,
            displayID: displayID,
            screenFrame: screen.visibleFrame,
            mainIdentity: mainWindow.stableIdentity,
            liveIdentities: liveIdentities,
            virtualIdentities: virtualIdentities,
            schedulerGeneration: schedulerGeneration,
            constraintRegistryGeneration: appConstraintRegistry.generation,
            operationGeneration: interactionGeneration,
            departureSnapshot: explicitGroupDepartureSnapshot(
                containing: mainWindow.stableIdentity
            ),
            snapshots: snapshots,
            participants: participants,
            boundaries: boundaries
        )
        inFlightPlacementIDs.formUnion(allIdentities)
        resizeHandleOverlay.beginInteraction(with: canonicalInteraction)
        startEscapeMonitoring()
        updateHandleResize(interaction: canonicalInteraction, at: point)
    }

    func rejectHandleResizeStart() {
        // The panel view enters its local drag state before this controller can
        // revalidate AX/Window Server evidence. A failed validation must cancel
        // that view state as well as declining the controller session.
        resizeHandleOverlay.endInteraction()
        refreshResizeHandles()
    }

    func resolvedHandleMainWindow(
        participantIDs: Set<String>,
        visibleWindows: [ManagedWindow]
    ) -> ManagedWindow? {
        if let focused = windowService.focusedWindow(
            messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
        ),
           participantIDs.contains(focused.stableIdentity),
           let matching = visibleWindows.first(where: {
               $0.stableIdentity == focused.stableIdentity
           }) {
            return matching
        }
        return visibleWindows.first { participantIDs.contains($0.stableIdentity) }
    }

    func updateHandleResize(
        interaction: ResizeHandleInteraction,
        at point: CGPoint
    ) {
        guard var session = handleResizeSession,
              session.interactionID == interaction.id else { return }
        var effectiveBoundaryChanged = false
        for index in session.boundaries.indices {
            var boundary = session.boundaries[index]
            let proposed = boundary.descriptor.axis == .horizontal ? point.x : point.y
            let coordinate = min(
                max(proposed, boundary.allowedBoundary.lowerBound),
                boundary.allowedBoundary.upperBound
            )
            if abs(coordinate - boundary.coordinate) > 0.001 {
                effectiveBoundaryChanged = true
            }
            boundary.coordinate = coordinate
            session.boundaries[index] = boundary
        }
        guard effectiveBoundaryChanged else {
            // The pointer may continue beyond a learned min/max. Once the
            // clamped boundary stops moving, do not rebuild frames or enqueue
            // redundant AX writes/overlay work.
            handleResizeSession = session
            return
        }
        let targetFrames = HandleResizeGeometry.resizedFrames(
            originalFrames: session.participants.mapValues(\.originalFrame),
            boundaries: session.boundaries.map {
                HandleResizeBoundaryGeometry(
                    axis: $0.descriptor.axis,
                    coordinate: $0.coordinate,
                    sides: $0.sides
                )
            }
        )
        for (identity, targetFrame) in targetFrames {
            guard var participant = session.participants[identity] else { continue }
            participant.targetFrame = targetFrame
            session.participants[identity] = participant
        }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let liveRequests = session.liveIdentities.compactMap { identity
            -> LiveResizeRequest? in
            guard let participant = session.participants[identity] else { return nil }
            return LiveResizeRequest(
                stableIdentity: identity,
                element: participant.window.element,
                targetFrame: participant.targetFrame,
                primaryScreenTop: primaryTop
            )
        }
        liveResizeScheduler.submit(
            liveRequests,
            generation: session.schedulerGeneration
        )
        handleResizeSession = session

        let virtualItems = session.virtualIdentities.compactMap { identity
            -> VirtualResizeItem? in
            guard let participant = session.participants[identity] else { return nil }
            return VirtualResizeItem(
                stableIdentity: identity,
                originalFrame: participant.originalFrame,
                targetFrame: participant.targetFrame,
                appIcon: participant.window.appIcon
            )
        }
        let liveFrames = session.liveIdentities.compactMap {
            session.participants[$0]?.targetFrame
        }
        let needsFallbackRaise = virtualResizeOverlay.update(
            items: virtualItems,
            liveFrames: liveFrames,
            liveWindowID: session.participants[session.mainIdentity]?
                .window.cgWindowID,
            screenFrame: session.screenFrame,
            layering: VirtualResizePresentationPolicy.layering(
                liveWindowCount: session.liveIdentities.count,
                virtualWindowCount: session.virtualIdentities.count
            )
        )
        if needsFallbackRaise,
           let main = session.participants[session.mainIdentity] {
            let schedulerGeneration = session.schedulerGeneration
            establishLiveWindowAboveVirtualOverlay(main.window) { controller in
                controller.handleResizeSession?.schedulerGeneration
                    == schedulerGeneration
                    || controller.finalizingHandleResizeSession?.schedulerGeneration
                        == schedulerGeneration
            }
        }
        let movedDescriptors = session.boundaries.map { boundary in
            let descriptor = boundary.descriptor
            return ResizeHandleDescriptor(
                id: descriptor.id,
                displayID: descriptor.displayID,
                axis: descriptor.axis,
                coordinate: boundary.coordinate,
                span: descriptor.span,
                screenFrame: descriptor.screenFrame,
                participantIDs: descriptor.participantIDs,
                occlusionParticipants: descriptor.occlusionParticipants,
                presentationStyle: descriptor.presentationStyle,
                showsResizeCursorAdornment: descriptor.showsResizeCursorAdornment,
                resizeCursorAdornmentDistance: descriptor.resizeCursorAdornmentDistance,
                junctionExclusionSpans: descriptor.junctionExclusionSpans
            )
        }
        quarantinedResizeHandleIDs.removeAll()
        resizeHandleOverlay.update(movedDescriptors)
    }

    func finishHandleResize(
        interaction: ResizeHandleInteraction,
        at point: CGPoint
    ) {
        guard handleResizeSession?.interactionID == interaction.id else { return }
        updateHandleResize(interaction: interaction, at: point)
        guard let session = handleResizeSession else { return }
        // The active panel sits above the virtual canvas so it can own the drag.
        // Remove it synchronously at mouse-up; the post-AX refresh will present
        // only geometry that has passed a fresh occlusion check.
        resizeHandleOverlay.setPresentationSuspended(true)
        updateHandleSettlementOverlay(session, restoreOriginalFrames: false)
        handleResizeSession = nil
        isHandleResizeFinalizing = true
        finalizingHandleResizeSession = session
        stopEscapeMonitoring()
        liveResizeScheduler.stop(generation: session.schedulerGeneration) { [weak self] in
            self?.completeHandleResize(session)
        }
    }

    func completeHandleResize(_ session: HandleResizeSession) {
        guard isHandleResizeFinalizing,
              finalizingHandleResizeSession?.schedulerGeneration
                == session.schedulerGeneration else { return }
        let identities = Set(session.participants.keys)
        let boundaryActuallyMoved = session.boundaries.contains { boundary in
            abs(boundary.coordinate - boundary.descriptor.coordinate) > 0.001
        }
        guard boundaryActuallyMoved else {
            // A click/release on a control is not a resize. Do not manufacture
            // final AX writes or passive learning evidence for a no-op.
            finishHandleResizePresentation(
                identities: identities,
                schedulerGeneration: session.schedulerGeneration
            )
            return
        }
        var pending = session.participants.count
        var allSucceeded = true
        var acceptedWindows: [String: ManagedWindow] = [:]
        var confirmedRejections: [ConfirmedConstraintRejection] = []
        var seenPersistentRejectionKeys = Set<String>()
        var measurementWindowIdentityByApp:
            [AppConstraintIdentity: String] = [:]
        var permissionRequests:
            [AppConstraintIdentity: ConstraintRecordingPermissionRequest] = [:]
        let measurementEpsilon = SystemGeometryPolicy.measurementEpsilon(
            backingScaleFactor: screen(withDisplayID: session.displayID)?
                .backingScaleFactor ?? 1
        )

        for (identity, participant) in session.participants {
            let activeAxes = Set(session.boundaries.compactMap { boundary
                -> ConstraintProbeAxis? in
                HandleResizeConstraintEvidencePolicy.activeAxis(
                    boundaryAxis: boundary.descriptor.axis,
                    originalCoordinate: boundary.descriptor.coordinate,
                    finalCoordinate: boundary.coordinate,
                    participantOwnsBoundary: boundary.sides[identity] != nil
                )
            })
            var requiredCommitSizeAxes: AXFrameSizeAxes = []
            if activeAxes.contains(.width) {
                requiredCommitSizeAxes.insert(.width)
            }
            if activeAxes.contains(.height) {
                requiredCommitSizeAxes.insert(.height)
            }
            windowService.setFrameAnchoredObserved(
                participant.targetFrame,
                sizeConstraintAnchor: participant.zone.sizeConstraintAnchor,
                requiredOuterEdges: participant.zone.requiredOuterEdges,
                requiredCommitSizeAxes: requiredCommitSizeAxes.isEmpty
                    ? nil : requiredCommitSizeAxes,
                skipInitialWriteWhenVerified: session.liveIdentities.contains(identity),
                for: participant.window.element,
                pid: participant.window.pid
            ) { [weak self] observation in
                guard let self else { return }
                guard self.isHandleResizeFinalizing,
                      self.finalizingHandleResizeSession?.schedulerGeneration
                        == session.schedulerGeneration else { return }

                let refreshed = observation.acceptedFrame.map {
                    participant.window.replacingFrame($0)
                } ?? self.windowService.refreshed(participant.window)
                let edgesMatch = refreshed.map {
                    self.matchesRequiredOuterEdges(
                        $0.frame,
                        targetFrame: participant.targetFrame,
                        requiredEdges: participant.zone.requiredOuterEdges
                    )
                } ?? false
                let requiredSizeMatch = refreshed.map {
                    AXFrameSizePolicy.requiredSizeIsCorrect(
                        actual: $0.frame.size,
                        target: participant.targetFrame.size,
                        exactAxes: requiredCommitSizeAxes
                    )
                } ?? false
                allSucceeded = allSucceeded
                    && requiredSizeMatch
                    && AXFrameMutationCommitPolicy.accepts(
                        observation,
                        requiredOuterEdgesMatch: edgesMatch
                    )
                if let refreshed {
                    acceptedWindows[identity] = refreshed
                }

                if let constraintIdentity = participant.appConstraintIdentity,
                   let acceptedFrame = observation.acceptedFrame {
                    let probe = ConstraintProbeContext(
                        identity: constraintIdentity,
                        displayName: participant.appConstraintDisplayName,
                        requestedFrame: participant.targetFrame,
                        acceptedFrame: acceptedFrame,
                        activeAxes: activeAxes,
                        mutationWasSent: observation.mutationWasSent,
                        sizeMutationSucceeded: observation.sizeMutationSucceeded,
                        acceptedFrameIsSettled:
                            observation.acceptedFrameIsSettled,
                        liveness: observation.liveness,
                        screenLimitedAxes:
                            SystemGeometryPolicy.screenLimitedAxes(
                                requestedFrame: participant.targetFrame,
                                acceptedFrame: acceptedFrame,
                                activeAxes: activeAxes,
                                screenFrame: session.screenFrame,
                                epsilon: measurementEpsilon
                            ),
                        systemLimitedAxes:
                            SystemGeometryPolicy.systemLimitedAxes(
                                requestedFrame: participant.targetFrame,
                                acceptedFrame: acceptedFrame,
                                activeAxes: activeAxes,
                                epsilon: measurementEpsilon
                            ),
                        peerLimitedAxes: [],
                        measurementEpsilon: measurementEpsilon,
                        operationGeneration: session.operationGeneration
                    )
                    if observation.settlementEvidence
                        .authorizesPersistentConstraintLearning {
                        let probeAnalysis = ConstraintProbe.analyze(probe)
                        for rejection in probeAnalysis.confirmedRejections {
                            let key = "\(rejection.identity.storageKey)|\(rejection.bound.rawValue)"
                            if seenPersistentRejectionKeys.insert(key).inserted {
                                confirmedRejections.append(rejection)
                                let previousWindowIdentity =
                                    measurementWindowIdentityByApp[
                                        rejection.identity
                                    ]
                                measurementWindowIdentityByApp[
                                    rejection.identity
                                ] = min(
                                    previousWindowIdentity
                                        ?? participant.window.stableIdentity,
                                    participant.window.stableIdentity
                                )
                            }
                        }
                    }
                    // Axis ambiguity stays passive unknown evidence. The
                    // passive resize itself never starts calibration; only a
                    // later explicit choice in the permission prompt may do so.
                }

                pending -= 1
                guard pending == 0 else { return }

                // Freeze learning evidence before structural cleanup. Candidate
                // permission never authorizes the departure; only the already
                // confirmed rejection does.
                for rejection in confirmedRejections {
                    let disposition = self.appConstraintRegistry
                        .observeConfirmedRejection(
                            rejection,
                            popupEnabled:
                                self.settings.constraintRecordingPromptsEnabled
                        )
                    if disposition == .requestPermission {
                        permissionRequests[rejection.identity] = self
                            .mergedConstraintPermissionRequest(
                                existing: permissionRequests[rejection.identity],
                                identity: rejection.identity,
                                displayName: rejection.displayName,
                                windowStableIdentity:
                                    measurementWindowIdentityByApp[
                                        rejection.identity
                                    ]
                            )
                    }
                    // Contradiction/conflict remain verification debt. No
                    // passive resize path starts ConstraintMeasurementEngine
                    // without the later user-authorized prompt decision.
                }

                if !confirmedRejections.isEmpty {
                    // Keep the app-accepted frames. A confirmed constraint
                    // rejection retires only the relationship; rolling peers
                    // back would re-issue geometry the application just refused.
                    if let departure = session.departureSnapshot {
                        _ = self.retireExplicitGroup(
                            departure,
                            reason: .confirmedConstraintRejection
                        )
                    } else {
                        // Shared-resize handles are explicit-group owned. This
                        // branch is defensive and still guarantees no stale
                        // presentation survives an impossible legacy state.
                        self.isHandleResizeFinalizing = false
                        self.finalizingHandleResizeSession = nil
                        self.inFlightPlacementIDs.subtract(identities)
                        self.virtualResizeOverlay.hideAll()
                        self.resizeHandleOverlay.endInteraction()
                        self.refreshResizeHandles()
                    }
                    self.presentConstraintRecordingPermissionRequests(
                        permissionRequests
                    )
                    return
                }

                if allSucceeded,
                   self.interactionGeneration == session.operationGeneration {
                    for (acceptedIdentity, accepted) in acceptedWindows {
                        if var placement = self.lockedPlacements[acceptedIdentity] {
                            placement.appliedFrame = accepted.frame
                            self.lockedPlacements[acceptedIdentity] = placement
                        }
                    }
                    for first in identities {
                        for second in identities where first < second {
                            self.detachedConnections.remove(
                                SplitConnectionKey(first, second)
                            )
                        }
                    }
                    if let main = acceptedWindows[session.mainIdentity] {
                        self.restoreResizeGroupForeground(
                            Array(acceptedWindows.values),
                            mainWindow: main
                        )
                    }
                    self.finishHandleResizePresentation(
                        identities: identities,
                        schedulerGeneration: session.schedulerGeneration
                    )
                } else {
                    // AX unknown/transient failure is not destruction evidence.
                    // Restore the pre-drag transaction and leave the group live.
                    self.isHandleResizeRollbackActive = true
                    self.rollbackTransaction(session.snapshots) { [weak self] _ in
                        guard let self else { return }
                        self.isHandleResizeRollbackActive = false
                        self.finishHandleResizePresentation(
                            identities: identities,
                            schedulerGeneration: session.schedulerGeneration
                        )
                        // A Space/display transition, stop/disable, or newer
                        // interaction may supersede the user-facing continuation
                        // while the physical rollback is settling. Complete the
                        // rollback, but never open a stale permission modal
                        // from the old resize generation.
                        guard self.interactionGeneration
                                == session.operationGeneration else { return }
                        self.presentConstraintRecordingPermissionRequests(
                            permissionRequests
                        )
                    }
                }
            }
        }
    }


    func finishHandleResizePresentation(
        identities: Set<String>,
        schedulerGeneration: Int
    ) {
        guard isHandleResizeFinalizing,
              finalizingHandleResizeSession?.schedulerGeneration
                == schedulerGeneration else { return }
        isHandleResizeFinalizing = false
        finalizingHandleResizeSession = nil
        inFlightPlacementIDs.subtract(identities)
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.endInteraction()
        // Async settlement/rollback may finish after stop, disable, or another
        // application-owned transaction has taken presentation ownership. A
        // stale completion must not resurrect handles/proxies after that newer
        // lifecycle transition.
        if canRefreshPresentationAfterAsyncTransaction {
            refreshResizeHandles()
        } else {
            resizeHandleOverlay.hideAll()
        }
    }

    func cancelHandleResize(restoreOriginalFrames: Bool) {
        guard let session = handleResizeSession else {
            resizeHandleOverlay.endInteraction()
            refreshResizeHandles()
            return
        }
        resizeHandleOverlay.setPresentationSuspended(true)
        updateHandleSettlementOverlay(
            session,
            restoreOriginalFrames: restoreOriginalFrames
        )
        handleResizeSession = nil
        isHandleResizeFinalizing = true
        finalizingHandleResizeSession = session
        stopEscapeMonitoring()
        let identities = Set(session.participants.keys)
        liveResizeScheduler.stop(generation: session.schedulerGeneration) { [weak self] in
            guard let self else { return }
            guard restoreOriginalFrames else {
                self.finishHandleResizePresentation(
                    identities: identities,
                    schedulerGeneration: session.schedulerGeneration
                )
                return
            }
            self.isHandleResizeRollbackActive = true
            self.rollbackTransaction(session.snapshots) { [weak self] _ in
                guard let self else { return }
                self.isHandleResizeRollbackActive = false
                self.finishHandleResizePresentation(
                    identities: identities,
                    schedulerGeneration: session.schedulerGeneration
                )
            }
        }
    }

    func updateHandleSettlementOverlay(
        _ session: HandleResizeSession,
        restoreOriginalFrames: Bool
    ) {
        guard !session.virtualIdentities.isEmpty else {
            virtualResizeOverlay.hideAll()
            return
        }
        let items = session.virtualIdentities.compactMap { identity
            -> VirtualResizeItem? in
            guard let participant = session.participants[identity] else {
                return nil
            }
            let displayedTarget = restoreOriginalFrames
                ? participant.originalFrame
                : participant.targetFrame
            return VirtualResizeItem(
                stableIdentity: identity,
                originalFrame: participant.originalFrame.union(participant.targetFrame),
                targetFrame: displayedTarget,
                appIcon: participant.window.appIcon
            )
        }
        let needsFallbackRaise = virtualResizeOverlay.update(
            items: items,
            liveFrames: session.liveIdentities.compactMap {
                session.participants[$0]?.targetFrame
            },
            liveWindowID: session.participants[session.mainIdentity]?
                .window.cgWindowID,
            screenFrame: session.screenFrame,
            layering: VirtualResizePresentationPolicy.layering(
                liveWindowCount: session.liveIdentities.count,
                virtualWindowCount: session.virtualIdentities.count
            )
        )
        if needsFallbackRaise,
           let main = session.participants[session.mainIdentity] {
            let schedulerGeneration = session.schedulerGeneration
            establishLiveWindowAboveVirtualOverlay(main.window) { controller in
                controller.handleResizeSession?.schedulerGeneration
                    == schedulerGeneration
                    || controller.finalizingHandleResizeSession?.schedulerGeneration
                        == schedulerGeneration
            }
        }
    }

}
