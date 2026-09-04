import AppKit
import CoreGraphics

struct DisplayTopologyGroupRecoveryCandidate: Equatable {
    let groupID: SnapGroupID
    let memberIDs: Set<String>
    let sourceDisplayID: CGDirectDisplayID
    let sourceVisibleFrame: CGRect?
}

struct DisplayTopologyGroupRecoveryDebt {
    let candidate: DisplayTopologyGroupRecoveryCandidate
    let topologyGeneration: Int
    let watchdogEligibleAt: TimeInterval
    let expiresAt: TimeInterval
    var watchdogAttemptCount: Int
}

enum DisplayTopologyGroupRecoveryPolicy {
    static let localRetryDelays: [TimeInterval] = [0.15, 0.35, 0.75, 1.25]
    // The ordinary 1 Hz watchdog receives only unresolved candidates after the
    // notification-owned retries. The debt self-expires; it never becomes a
    // permanent whole-scene polling responsibility.
    static let watchdogLifetime: TimeInterval = 6.0
    // Keep watchdog ownership strictly after the final notification-owned pass.
    // Using the exact same timestamp leaves ordering to the run loop and can
    // skip the final 1.25 s settlement under load.
    static let watchdogHandoffDelay: TimeInterval = 0.15
    // The resident watchdog must remain bounded even if a removed display held
    // an unusually large number of groups. Notification-owned settlement may
    // inspect the whole event set; 1 Hz borrows at most two exact debts/tick.
    static let maximumWatchdogGroupAttemptsPerTick = 2
}

extension SnapController {
    func recordCurrentDisplayGeometrySnapshot() {
        // Merge instead of replacing. macOS can publish several screen-change
        // notifications for one unplug sequence; preserving the last geometry
        // of an already-disappeared display is required to project restore
        // frames safely if a later notification owns the successful recovery.
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            lastKnownVisibleFrameByDisplayID[displayID] = screen.visibleFrame
        }
    }

    func beginMissionControlTransientPreviewSessionIfNeeded() {
        guard !missionControlGroupProxyController.hasTransientPreviewSession,
              settings.windowPreviewsEnabled,
              let topology = windowSpaceBackend.managedDisplaySpaceTopology()
        else { return }

        let visibleSpaceIDs = topology.visibleSpaceIDs
        guard !visibleSpaceIDs.isEmpty else { return }
        var eligibleGroupIDs = Set<SnapGroupID>()

        for group in explicitGroupStore.groups {
            guard group.state != .suspendedForSpaceTransition,
                  missionControlGroupProxyController.hasPresentation(for: group.id),
                  let subjects = groupSpaceMigrationSubjects(
                    groupID: group.id,
                    presentedMemberIDs: group.memberIDs
                  ) else { continue }
            let observation = windowSpaceBackend.observe(subjects: subjects)
            guard WindowSpaceSubjectIdentityPolicy.hasUniquePhysicalSurfaces(
                memberIDs: group.memberIDs,
                observation: observation
            ) else { continue }
            guard case .knownSame(let spaceID) = GroupSpaceMembershipPolicy
                .relationship(
                    memberIDs: group.memberIDs,
                    observation: observation
                ),
                visibleSpaceIDs.contains(spaceID),
                windowSpaceBackend.isUserSpace(spaceID) == true else {
                continue
            }
            eligibleGroupIDs.insert(group.id)
        }
        missionControlGroupProxyController.beginTransientPreviewSession(
            targetGroupIDs: eligibleGroupIDs
        )
    }

    func displayTopologyRecoveryCandidates()
        -> [DisplayTopologyGroupRecoveryCandidate] {
        explicitGroupStore.groups.compactMap { group in
            guard screen(withDisplayID: group.displayID) == nil else {
                return nil
            }
            return DisplayTopologyGroupRecoveryCandidate(
                groupID: group.id,
                memberIDs: group.memberIDs,
                sourceDisplayID: group.displayID,
                sourceVisibleFrame: lastKnownVisibleFrameByDisplayID[
                    group.displayID
                ]
            )
        }
    }

    func installDisplayTopologyRecoveryDebts(
        candidates: [DisplayTopologyGroupRecoveryCandidate],
        topologyGeneration: Int,
        eventStartedAt: TimeInterval
    ) {
        displayTopologyRecoveryDebtsByGroupID.removeAll()
        mergeDisplayTopologyRecoveryDebts(
            candidates: candidates,
            topologyGeneration: topologyGeneration,
            eventStartedAt: eventStartedAt
        )
    }

    private func mergeDisplayTopologyRecoveryDebts(
        candidates: [DisplayTopologyGroupRecoveryCandidate],
        topologyGeneration: Int,
        eventStartedAt: TimeInterval
    ) {
        guard !candidates.isEmpty else { return }
        let watchdogEligibleAt = eventStartedAt
            + (DisplayTopologyGroupRecoveryPolicy.localRetryDelays.last ?? 0)
            + DisplayTopologyGroupRecoveryPolicy.watchdogHandoffDelay
        let expiresAt = watchdogEligibleAt
            + DisplayTopologyGroupRecoveryPolicy.watchdogLifetime
        for candidate in candidates where
            displayTopologyRecoveryDebtsByGroupID[candidate.groupID] == nil {
            displayTopologyRecoveryDebtsByGroupID[candidate.groupID] =
                DisplayTopologyGroupRecoveryDebt(
                    candidate: candidate,
                    topologyGeneration: topologyGeneration,
                    watchdogEligibleAt: watchdogEligibleAt,
                    expiresAt: expiresAt,
                    watchdogAttemptCount: 0
                )
        }
    }

    func scheduleDisplayTopologyGroupRecovery(
        topologyGeneration: Int,
        eventStartedAt: TimeInterval
    ) {
        // Schedule the bounded settlement even when the notification callback
        // still sees the old NSScreen list. macOS may publish the screen list
        // a little later than the notification itself. No repeating timer is
        // created; these are the only event-owned topology discovery passes.
        for delay in DisplayTopologyGroupRecoveryPolicy.localRetryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.displayTopologyGeneration == topologyGeneration
                else { return }
                self.mergeDisplayTopologyRecoveryDebts(
                    candidates: self.displayTopologyRecoveryCandidates(),
                    topologyGeneration: topologyGeneration,
                    eventStartedAt: eventStartedAt
                )
                let restoredAny = self.attemptDisplayTopologyGroupRecovery(
                    topologyGeneration: topologyGeneration,
                    now: ProcessInfo.processInfo.systemUptime,
                    allowWatchdogPhase: false
                )
                if restoredAny { self.refreshResizeHandles() }
            }
        }
    }

    /// Extremely narrow temporary delegation to the existing 1 Hz watchdog.
    /// There is no global Space scan here: only candidates created by a recent
    /// display-change notification are retried, and every debt expires.
    @discardableResult
    func recoverDisplayTopologyGroupsFromWatchdogIfNeeded(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard !displayTopologyRecoveryDebtsByGroupID.isEmpty else {
            return false
        }
        return attemptDisplayTopologyGroupRecovery(
            topologyGeneration: displayTopologyGeneration,
            now: now,
            allowWatchdogPhase: true
        )
    }

    @discardableResult
    private func attemptDisplayTopologyGroupRecovery(
        topologyGeneration: Int,
        now: TimeInterval,
        allowWatchdogPhase: Bool
    ) -> Bool {
        var restoredAny = false

        // Expiration/generation pruning is cheap and always global so stale debt
        // cannot keep the 1 Hz gate armed. Expensive recovery attempts are capped
        // below when the watchdog owns the pass.
        for (groupID, debt) in Array(displayTopologyRecoveryDebtsByGroupID) {
            guard debt.topologyGeneration == topologyGeneration,
                  now <= debt.expiresAt else {
                displayTopologyRecoveryDebtsByGroupID.removeValue(forKey: groupID)
                continue
            }
        }
        var debts = Array(displayTopologyRecoveryDebtsByGroupID)
        if allowWatchdogPhase {
            debts = debts
                .filter { now >= $0.value.watchdogEligibleAt }
                .sorted {
                    if $0.value.watchdogAttemptCount
                        != $1.value.watchdogAttemptCount {
                        return $0.value.watchdogAttemptCount
                            < $1.value.watchdogAttemptCount
                    }
                    return $0.key.rawValue.uuidString
                        < $1.key.rawValue.uuidString
                }
            if debts.count
                > DisplayTopologyGroupRecoveryPolicy
                    .maximumWatchdogGroupAttemptsPerTick {
                debts = Array(
                    debts.prefix(
                        DisplayTopologyGroupRecoveryPolicy
                            .maximumWatchdogGroupAttemptsPerTick
                    )
                )
            }
        }

        for (groupID, debt) in debts {
            guard let currentGroup = explicitGroupStore.group(id: groupID),
                  currentGroup.memberIDs == debt.candidate.memberIDs,
                  currentGroup.displayID == debt.candidate.sourceDisplayID else {
                displayTopologyRecoveryDebtsByGroupID.removeValue(forKey: groupID)
                continue
            }
            // A display with the same ID is back. This is no longer a loss
            // recovery candidate; the normal presentation path owns it.
            guard screen(withDisplayID: currentGroup.displayID) == nil else {
                displayTopologyRecoveryDebtsByGroupID.removeValue(forKey: groupID)
                continue
            }
            if tryRebindGroupAfterDisplayLoss(debt.candidate) {
                displayTopologyRecoveryDebtsByGroupID.removeValue(forKey: groupID)
                restoredAny = true
            } else if allowWatchdogPhase,
                      var currentDebt = displayTopologyRecoveryDebtsByGroupID[
                        groupID
                      ] {
                currentDebt.watchdogAttemptCount += 1
                displayTopologyRecoveryDebtsByGroupID[groupID] = currentDebt
            }
        }
        pruneUnownedDisplayGeometrySnapshots()
        return restoredAny
    }

    private func pruneUnownedDisplayGeometrySnapshots() {
        let currentDisplayIDs = Set(
            NSScreen.screens.compactMap { displayID(for: $0) }
        )
        let recoveryDisplayIDs = Set(
            displayTopologyRecoveryDebtsByGroupID.values.map {
                $0.candidate.sourceDisplayID
            }
        )
        let retainedDisplayIDs = currentDisplayIDs.union(recoveryDisplayIDs)
        lastKnownVisibleFrameByDisplayID = lastKnownVisibleFrameByDisplayID
            .filter { retainedDisplayIDs.contains($0.key) }
    }

    private func tryRebindGroupAfterDisplayLoss(
        _ candidate: DisplayTopologyGroupRecoveryCandidate
    ) -> Bool {
        guard let group = explicitGroupStore.group(id: candidate.groupID),
              group.displayID == candidate.sourceDisplayID,
              group.memberIDs == candidate.memberIDs,
              screen(withDisplayID: group.displayID) == nil,
              let subjects = groupSpaceMigrationSubjects(
                groupID: group.id,
                presentedMemberIDs: group.memberIDs
              ) else { return false }

        let observation = windowSpaceBackend.observe(subjects: subjects)
        guard WindowSpaceSubjectIdentityPolicy.hasUniquePhysicalSurfaces(
            memberIDs: group.memberIDs,
            observation: observation
        ) else { return false }
        guard case .knownSame(let destinationSpaceID) =
                GroupSpaceMembershipPolicy.relationship(
                    memberIDs: group.memberIDs,
                    observation: observation
                ),
              windowSpaceBackend.isUserSpace(destinationSpaceID) == true,
              let topology = windowSpaceBackend.managedDisplaySpaceTopology()
        else {
            // Split or unknown Space evidence is intentionally non-destructive.
            return false
        }
        let managedDisplayIdentifiers = topology.managedDisplayIdentifiers(
            for: destinationSpaceID
        )
        guard !managedDisplayIdentifiers.isEmpty else { return false }

        var refreshedWindows: [String: ManagedWindow] = [:]
        var destinationDisplayID: CGDirectDisplayID?
        var destinationScreen: NSScreen?
        for memberID in group.memberIDs {
            guard let placement = lockedPlacements[memberID],
                  placement.stableIdentity == memberID,
                  let memberObservation = observation.member(memberID),
                  memberObservation.membership.singleUserCandidate
                    == destinationSpaceID,
                  let windowID = memberObservation.windowID else {
                return false
            }
            let refreshed: ManagedWindow
            switch windowService.refreshedPersistedWindow(
                element: placement.element,
                pid: placement.pid,
                expectedStableIdentity: memberID,
                cgWindowID: windowID,
                messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
            ) {
            case .available(let window):
                refreshed = window
            case .missing, .unknown:
                return false
            }
            let memberCenter = CGPoint(
                x: refreshed.frame.midX,
                y: refreshed.frame.midY
            )
            guard let memberScreen = displayRecoveryScreen(
                strictlyContaining: memberCenter
            ),
                  let memberDisplayID = displayID(for: memberScreen) else {
                return false
            }
            if let destinationDisplayID {
                guard destinationDisplayID == memberDisplayID else {
                    // macOS split the group across physical displays. Do not
                    // guess or move windows in this first-stage recovery.
                    return false
                }
            } else {
                destinationDisplayID = memberDisplayID
                destinationScreen = memberScreen
            }
            refreshedWindows[memberID] = refreshed
        }
        guard refreshedWindows.count == group.memberIDs.count,
              let destinationDisplayID,
              let destinationScreen,
              destinationDisplayID != candidate.sourceDisplayID else {
            return false
        }

        // Rebinding a structurally intact group whose windows were scattered by
        // macOS would create permanent handle/proxy geometry debt and make the
        // low-frequency watchdog re-observe an unrecoverable layout forever.
        // First-stage display recovery is therefore observation-only: adopt the
        // new display only when macOS preserved a complete connected split.
        let reboundGeometry = group.memberIDs.compactMap { memberID
            -> SplitPlacementGeometry? in
            guard let placement = lockedPlacements[memberID],
                  let window = refreshedWindows[memberID] else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: memberID,
                zone: placement.zone,
                frame: window.frame
            )
        }
        guard reboundGeometry.count == group.memberIDs.count else {
            return false
        }
        let reboundHandles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: reboundGeometry,
            detachedConnections: detachedConnections
        )
        let reboundConnectedMembers =
            SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: group.preferredMemberID,
                handles: reboundHandles
            )
        guard reboundConnectedMembers == group.memberIDs else {
            return false
        }

        // Space IDs can be shared across displays when macOS is not using
        // separate Spaces. Cross-check the private topology identifier against
        // the physical screen on which every refreshed member was observed.
        let topologyConfirmsDestination = managedDisplayIdentifiers.contains {
            identifier in
            guard let topologyScreen = screenForManagedDisplayIdentifier(
                identifier
            ) else { return false }
            return displayID(for: topologyScreen) == destinationDisplayID
        }
        guard topologyConfirmsDestination else { return false }

        // Build the entire controller-side mutation before changing either the
        // group store or a placement. No guard inside the commit phase may
        // leave a partially rebound group.
        var reboundPlacements: [String: LockedPlacement] = [:]
        var reboundRestoreFrames: [String: CGRect] = [:]
        for memberID in group.memberIDs {
            guard let oldPlacement = lockedPlacements[memberID],
                  let window = refreshedWindows[memberID] else { return false }
            reboundPlacements[memberID] = LockedPlacement(
                element: oldPlacement.element,
                pid: oldPlacement.pid,
                stableIdentity: oldPlacement.stableIdentity,
                cgWindowID: window.cgWindowID ?? oldPlacement.cgWindowID,
                zone: oldPlacement.zone,
                displayID: destinationDisplayID,
                appliedFrame: window.frame
            )
            if let sourceVisibleFrame = candidate.sourceVisibleFrame,
               let oldRestore = restoreFrames[memberID] {
                reboundRestoreFrames[memberID] = projectDisplayRecoveryFrame(
                    oldRestore,
                    from: sourceVisibleFrame,
                    to: destinationScreen.visibleFrame
                )
            }
        }
        guard reboundPlacements.count == group.memberIDs.count else {
            return false
        }

        guard let rebound = explicitGroupStore
            .rebindDisplayAfterValidatedEnvironmentTransition(
                groupID: group.id,
                displayID: destinationDisplayID
            ),
            rebound.id == group.id,
            rebound.memberIDs == group.memberIDs else { return false }

        isReconcilingPlacementMutation = true
        for (memberID, placement) in reboundPlacements {
            lockedPlacements[memberID] = placement
        }
        for (memberID, frame) in reboundRestoreFrames {
            restoreFrames[memberID] = frame
        }
        isReconcilingPlacementMutation = false

        // The validated rebind commits a complete, connected group in the new
        // environment. Old Space/degradation confirmation samples describe the
        // vanished environment and must be retired together with the store
        // state so the next observation starts from a clean generation.
        directGroupSpaceSeparationEvidenceByGroupID.removeValue(forKey: group.id)
        groupSpaceSeparationEvidenceByGroupID.removeValue(forKey: group.id)
        groupDegradationEvidenceByGroupID.removeValue(forKey: group.id)
        missionControlGroupProxyController.notePreviewGeometryMutation(
            memberIDs: group.memberIDs
        )
        updateSelectionMonitoringState()
        return true
    }

    func screenForManagedDisplayIdentifier(
        _ managedDisplayIdentifier: String
    ) -> NSScreen? {
        if managedDisplayIdentifier.caseInsensitiveCompare("Main") == .orderedSame {
            return screen(withDisplayID: CGMainDisplayID())
        }
        let identifier = managedDisplayIdentifier.uppercased()
        return NSScreen.screens.first { screen in
            guard let displayID = displayID(for: screen),
                  let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(
                    displayID
                  ) else { return false }
            let uuid = unmanagedUUID.takeRetainedValue()
            return (CFUUIDCreateString(nil, uuid) as String).uppercased()
                == identifier
        }
    }

    private func displayRecoveryScreen(
        strictlyContaining point: CGPoint
    ) -> NSScreen? {
        // Display-loss recovery needs physical containment evidence. The normal
        // screen(containing:) helper intentionally falls back to the nearest
        // display for pointer/placement UX, which is too permissive here: a
        // still-settling off-screen window must keep recovery unresolved rather
        // than be attributed to a nearby display. Overlapping/mirrored screen
        // frames are ambiguous physical evidence and therefore fail closed too.
        let containingScreens = NSScreen.screens.filter { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x < frame.maxX
                && point.y >= frame.minY && point.y < frame.maxY
        }
        guard containingScreens.count == 1 else { return nil }
        return containingScreens[0]
    }

    private func projectDisplayRecoveryFrame(
        _ frame: CGRect,
        from source: CGRect,
        to destination: CGRect
    ) -> CGRect {
        guard source.width > 1, source.height > 1 else { return frame }
        let normalizedX = (frame.minX - source.minX) / source.width
        let normalizedY = (frame.minY - source.minY) / source.height
        var projected = CGRect(
            x: destination.minX + normalizedX * destination.width,
            y: destination.minY + normalizedY * destination.height,
            width: min(frame.width, destination.width),
            height: min(frame.height, destination.height)
        )
        projected.origin.x = min(
            max(projected.minX, destination.minX),
            destination.maxX - projected.width
        )
        projected.origin.y = min(
            max(projected.minY, destination.minY),
            destination.maxY - projected.height
        )
        return projected
    }
}
