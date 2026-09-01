import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum GroupSpaceMigrationForegroundFlushOwnershipPolicy {
    static func allowsFlush(
        proxyActivationIsActive: Bool,
        proxyConfirmationIsPending: Bool
    ) -> Bool {
        !proxyActivationIsActive && !proxyConfirmationIsPending
    }
}

private final class GroupMigrationFrameBatch {
    private var pending: Set<String>
    private var allSucceeded = true
    private var didFinish = false
    private let completion: (Bool) -> Void

    init(memberIDs: Set<String>, completion: @escaping (Bool) -> Void) {
        pending = memberIDs
        self.completion = completion
    }

    func resolve(memberID: String, succeeded: Bool) {
        guard !didFinish, pending.remove(memberID) != nil else { return }
        if !succeeded { allSucceeded = false }
        if pending.isEmpty { finish(allSucceeded) }
    }

    func expire() { finish(false) }

    private func finish(_ succeeded: Bool) {
        guard !didFinish else { return }
        didFinish = true
        completion(succeeded && pending.isEmpty)
    }
}

extension SnapController: GroupSpaceMigrationHost {
    func groupSpaceProxyDescriptor(
        groupID: SnapGroupID
    ) -> GroupSpaceProxyDescriptor? {
        missionControlGroupProxyController.spaceDescriptor(for: groupID)
    }

    func groupSpaceMigrationSubjects(
        groupID: SnapGroupID,
        presentedMemberIDs: Set<String>
    ) -> [WindowSpaceSubject]? {
        guard let group = explicitGroupStore.group(id: groupID),
              group.memberIDs == presentedMemberIDs else { return nil }
        let subjects = group.memberIDs.compactMap { memberID
            -> WindowSpaceSubject? in
            guard let placement = lockedPlacements[memberID],
                  placement.stableIdentity == memberID else { return nil }
            return WindowSpaceSubject(
                stableIdentity: memberID,
                element: placement.element,
                pid: placement.pid,
                cachedWindowID: placement.cgWindowID
            )
        }
        return subjects.count == group.memberIDs.count ? subjects : nil
    }

    func captureGroupSpaceMigration(
        groupID: SnapGroupID,
        presentedMemberIDs: Set<String>,
        proxyWindowID: CGWindowID,
        sourceSpace: TaboraSpaceID,
        destinationSpace: TaboraSpaceID,
        destinationManagedDisplayIdentifier: String,
        observedMembers: WindowSpaceObservation
    ) -> GroupSpaceMigrationCaptureResolution {
        guard groupSpaceMigrationCanBegin else {
            return .retryableObservation
        }
        guard let group = explicitGroupStore.group(id: groupID),
              group.memberIDs == presentedMemberIDs,
              let proxy = groupSpaceProxyDescriptor(groupID: groupID),
              proxy.windowID == proxyWindowID,
              proxy.memberIDs == group.memberIDs else {
            return .rejected
        }
        guard let sourceScreen = screen(withDisplayID: group.displayID),
              let destinationScreen = migrationDestinationScreen(
                  managedDisplayIdentifier: destinationManagedDisplayIdentifier
              ),
              let destinationDisplayID = displayID(for: destinationScreen)
        else { return .retryableObservation }
        guard WindowSpaceSubjectIdentityPolicy.hasUniquePhysicalSurfaces(
            memberIDs: group.memberIDs,
            observation: observedMembers
        ) else { return .rejected }

        var members: [GroupSpaceMigrationMember] = []
        for memberID in group.memberIDs.sorted() {
            guard let placement = lockedPlacements[memberID],
                  placement.displayID == group.displayID,
                  placement.stableIdentity == memberID,
                  let observation = observedMembers.member(memberID),
                  observation.membership.singleUserCandidate == sourceSpace,
                  let windowID = observation.windowID else { return .rejected }
            let refreshed: ManagedWindow
            switch windowService.refreshedPersistedWindow(
                element: placement.element,
                pid: placement.pid,
                expectedStableIdentity: memberID,
                cgWindowID: windowID,
                messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
            ) {
            case .available(let window): refreshed = window
            case .missing: return .rejected
            case .unknown: return .retryableObservation
            }
            let limits = resolveAppConstraintIdentity(for: refreshed).map {
                appConstraintRegistry.limits(for: $0.identity)
            } ?? .unknown
            members.append(GroupSpaceMigrationMember(
                stableIdentity: memberID,
                element: placement.element,
                pid: placement.pid,
                windowID: windowID,
                zone: placement.zone,
                sourceFrame: refreshed.frame,
                limits: limits
            ))
        }
        let layout = GroupMigrationLayoutPlanner.plan(
            members: members.map {
                GroupMigrationLayoutMember(
                    stableIdentity: $0.stableIdentity,
                    zone: $0.zone,
                    sourceFrame: $0.sourceFrame,
                    limits: $0.limits
                )
            },
            sourceVisibleFrame: sourceScreen.visibleFrame,
            destinationVisibleFrame: destinationScreen.visibleFrame
        )
        guard members.count == group.memberIDs.count,
              layout.frames != nil else { return .rejected }
        let destinationRestoreFrames = Dictionary(
            uniqueKeysWithValues: group.memberIDs.compactMap { memberID in
                restoreFrames[memberID].map {
                    (
                        memberID,
                        projectMigrationFrame(
                            $0,
                            from: sourceScreen.visibleFrame,
                            to: destinationScreen.visibleFrame
                        )
                    )
                }
            }
        )

        return .ready(GroupSpaceMigrationCapture(
            transactionID: UUID(),
            structuralSnapshot: GroupSpaceStructuralSnapshot(
                groupID: group.id,
                memberIDs: group.memberIDs,
                zonesByMemberID: Dictionary(
                    uniqueKeysWithValues: members.map {
                        ($0.stableIdentity, $0.zone)
                    }
                ),
                displayID: group.displayID
            ),
            preferredMemberID: group.preferredMemberID,
            members: members,
            sourceSpace: sourceSpace,
            destinationSpace: destinationSpace,
            sourceVisibleFrame: sourceScreen.visibleFrame,
            destinationVisibleFrame: destinationScreen.visibleFrame,
            destinationDisplayID: destinationDisplayID,
            proxyWindowID: proxyWindowID,
            plannedLayout: layout,
            destinationRestoreFrames: destinationRestoreFrames
        ))
    }

    func groupSpaceMigrationStructureMatches(
        _ snapshot: GroupSpaceStructuralSnapshot
    ) -> Bool {
        guard let group = explicitGroupStore.group(id: snapshot.groupID),
              group.memberIDs == snapshot.memberIDs,
              group.displayID == snapshot.displayID else { return false }
        let zones = Dictionary(uniqueKeysWithValues: snapshot.memberIDs.compactMap {
            memberID -> (String, SnapZone)? in
            guard let placement = lockedPlacements[memberID] else { return nil }
            return (memberID, placement.zone)
        })
        return zones == snapshot.zonesByMemberID
    }

    func recordGroupSpaceMigrationForegroundIntent(
        groupID: SnapGroupID,
        presentedMemberIDs: Set<String>
    ) {
        guard settings.missionControlGroupMigrationEnabled,
              groupSpaceMigrationLine.owns(groupID: groupID),
              groupSpaceMigrationLine.presentationIsFrozenForQueuedMigration(
                  groupID: groupID
              ),
              let group = explicitGroupStore.group(id: groupID),
              group.memberIDs == presentedMemberIDs,
              group.memberIDs.count >= 2 else {
            return
        }
        groupSpaceMigrationForegroundIntentSequence &+= 1
        groupSpaceMigrationForegroundIntents[groupID] =
            GroupSpaceMigrationForegroundIntent(
                groupID: groupID,
                memberIDs: group.memberIDs,
                preferredMemberID: group.preferredMemberID,
                sequence: groupSpaceMigrationForegroundIntentSequence,
                migrationCompleted: false
            )
        // The selected queued Proxy is explicit authorization only for the
        // post-migration ordering pass. Never donate its app/key-window churn
        // to the ordinary foreground-selection fallback.
        discardDeferredForegroundSignals()
    }

    func resetGroupSpaceMigrationForegroundIntents() {
        groupSpaceMigrationForegroundFlushGeneration &+= 1
        pendingGroupSpaceMigrationForegroundWorkItem?.cancel()
        pendingGroupSpaceMigrationForegroundWorkItem = nil
        groupSpaceMigrationForegroundIntents.removeAll()
    }

    private func cancelPendingGroupSpaceMigrationForegroundFlush() {
        groupSpaceMigrationForegroundFlushGeneration &+= 1
        pendingGroupSpaceMigrationForegroundWorkItem?.cancel()
        pendingGroupSpaceMigrationForegroundWorkItem = nil
    }

    private func noteGroupSpaceMigrationForegroundTerminal(
        groupID: SnapGroupID,
        terminalState: GroupSpaceMigrationTerminalState
    ) {
        guard var intent = groupSpaceMigrationForegroundIntents[groupID] else {
            return
        }
        guard GroupSpaceMigrationForegroundIntentPolicy
            .survivesTerminalState(terminalState) else {
            groupSpaceMigrationForegroundIntents.removeValue(forKey: groupID)
            return
        }
        intent.migrationCompleted = true
        groupSpaceMigrationForegroundIntents[groupID] = intent
    }

    func scheduleGroupSpaceMigrationForegroundFlushIfReady() {
        guard !groupSpaceMigrationLine.hasPendingOrActiveTransactions,
              !groupSpaceMigrationForegroundIntents.isEmpty,
              GroupSpaceMigrationForegroundFlushOwnershipPolicy.allowsFlush(
                proxyActivationIsActive:
                    activeMissionControlProxyActivation != nil,
                proxyConfirmationIsPending: missionControlGroupProxyController
                    .hasPendingSelectionConfirmation
              ),
              settings.missionControlGroupMigrationEnabled,
              isEnabled, isControllerRunning else {
            return
        }
        cancelPendingGroupSpaceMigrationForegroundFlush()
        let generation = groupSpaceMigrationForegroundFlushGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.groupSpaceMigrationForegroundFlushGeneration
                    == generation else { return }
            self.pendingGroupSpaceMigrationForegroundWorkItem = nil
            self.performGroupSpaceMigrationForegroundFlush(
                generation: generation
            )
        }
        pendingGroupSpaceMigrationForegroundWorkItem = workItem
        // One normal main-loop turn is enough here: physical move verification,
        // destination layout and group commit have already completed. Avoid a
        // longer retry loop that could unexpectedly re-raise a group after the
        // user's next desktop action.
        DispatchQueue.main.async(execute: workItem)
    }

    private func performGroupSpaceMigrationForegroundFlush(generation: Int) {
        guard groupSpaceMigrationForegroundFlushGeneration == generation,
              !groupSpaceMigrationLine.hasPendingOrActiveTransactions,
              GroupSpaceMigrationForegroundFlushOwnershipPolicy.allowsFlush(
                proxyActivationIsActive:
                    activeMissionControlProxyActivation != nil,
                proxyConfirmationIsPending: missionControlGroupProxyController
                    .hasPendingSelectionConfirmation
              ),
              settings.missionControlGroupMigrationEnabled,
              isEnabled, isControllerRunning else { return }

        let intents = GroupSpaceMigrationForegroundIntentPolicy
            .orderedCompletedIntents(
                Array(groupSpaceMigrationForegroundIntents.values)
            )
        // Every recorded intent is one-shot. Any stale/invalid group is simply
        // skipped; foreground presentation can never become migration truth or
        // trigger a transport retry.
        groupSpaceMigrationForegroundIntents.removeAll()
        guard !intents.isEmpty else { return }

        // The entire batch is one explicit foreground action. Oldest intent is
        // raised first; the most recently clicked queued group is raised last
        // and therefore owns the final topmost position. Resolve each group
        // immediately before its own pass so an earlier app activation cannot
        // make the next group's relative follower ordering stale.
        invalidatePendingGroupRaise()
        invalidatePendingSelectionRaise()
        let foregroundGeneration = groupRaiseGeneration
        discardDeferredForegroundSignals()
        defer {
            endOwnedForegroundMutation(generation: foregroundGeneration)
            discardDeferredForegroundSignals()
        }

        for intent in intents {
            guard groupSpaceMigrationForegroundFlushGeneration == generation,
                  !groupSpaceMigrationLine.hasPendingOrActiveTransactions,
                  let currentGroup = explicitGroupStore.group(id: intent.groupID),
                  currentGroup.memberIDs == intent.memberIDs,
                  currentGroup.preferredMemberID == intent.preferredMemberID
            else { continue }

            let windowsFrontToBack = persistedVisibleWindowsForExactGroupMembers(
                stableIDs: intent.memberIDs
            )
            guard windowsFrontToBack.count == intent.memberIDs.count,
                  Set(windowsFrontToBack.map(\.stableIdentity))
                    == intent.memberIDs,
                  beginOwnedForegroundMutation(
                      groupID: intent.groupID,
                      windows: windowsFrontToBack,
                      generation: foregroundGeneration
                  ) else {
                continue
            }

            let resolved = windowsFrontToBack.map {
                windowService.resolvingWindowServerIdentity($0)
            }
            // persistedVisibleWindowsForExactGroupMembers() has already
            // matched every member against its exact current layer-zero
            // Window Server surface and rebuilt ManagedWindow using bounded AX
            // observation. A second full liveness sweep here duplicated role /
            // position / size messaging on the main run loop without creating
            // a stronger identity boundary. Keep the established 0.45 s
            // interactive budget for the actual AXRaise/focus mutations below.
            guard Set(resolved.map(\.stableIdentity)) == intent.memberIDs,
                  resolved.allSatisfy({ $0.cgWindowID != nil }),
                  let resolvedMain = resolved.first(where: {
                      $0.stableIdentity == intent.preferredMemberID
                  }) else {
                continue
            }

            let windowsByIdentity = Dictionary(
                uniqueKeysWithValues: resolved.map {
                    ($0.stableIdentity, $0)
                }
            )
            let followerRaiseOrder =
                GroupSpaceMigrationForegroundIntentPolicy.followerRaiseOrder(
                    frontToBackMemberIDs: resolved.map(\.stableIdentity),
                    preferredMemberID: resolvedMain.stableIdentity
                )
            var groupPassSucceeded = true
            for followerID in followerRaiseOrder {
                guard groupSpaceMigrationForegroundFlushGeneration
                        == generation,
                      let follower = windowsByIdentity[followerID],
                      windowService.raise(follower) else {
                    groupPassSucceeded = false
                    break
                }
            }
            guard groupPassSucceeded,
                  groupSpaceMigrationForegroundFlushGeneration == generation
            else { continue }
            windowService.focus(resolvedMain)
        }
    }

    func groupSpaceMigrationDidBegin(_ capture: GroupSpaceMigrationCapture) {
        cancelPendingGroupSpaceMigrationForegroundFlush()
        discardDeferredForegroundSignals()
        // Capturing one group must not cancel an already-delivered explicit
        // Proxy selection for a different group. Same-group ownership remains
        // mutually exclusive and is cancelled fail-closed.
        let activeSelectionBelongsToAnotherGroup =
            activeMissionControlProxyActivation.map {
                $0.groupID != capture.structuralSnapshot.groupID
            } ?? false
        invalidatePendingGroupRaise(
            preservingMissionControlProxyActivation:
                activeSelectionBelongsToAnotherGroup
        )
        invalidatePendingSelectionRaise()
        resizeHandleOverlay.setPresentationSuspended(true)
        clearSpaceSeparationEvidence(for: capture.structuralSnapshot.groupID)
        missionControlGroupProxyController.markSpaceMigrationQueued(
            groupID: capture.structuralSnapshot.groupID
        )
        groupSpaceMigrationReservationShadowPresenter.reserve(
            capture: capture,
            groupLabel: groupSpaceMigrationReservationLabel(
                for: capture.structuralSnapshot.groupID
            )
        )
        groupSpaceMigrationReservationShadowObserver.reservationDidBegin(
            capture
        )
    }

    func groupSpaceMigrationDidRefreshCapture(
        _ capture: GroupSpaceMigrationCapture
    ) {
        groupSpaceMigrationReservationShadowPresenter.refreshCapture(capture)
        groupSpaceMigrationReservationShadowObserver.reservationDidRefresh(
            capture
        )
    }

    func updateGroupSpaceMigrationQueuePresentation(
        groupID: SnapGroupID,
        position: Int,
        total: Int
    ) {
        missionControlGroupProxyController
            .updateSpaceMigrationQueuePresentation(
                groupID: groupID,
                position: position,
                total: total
            )
        groupSpaceMigrationReservationShadowPresenter.updateQueue(
            groupID: groupID,
            position: position,
            total: total
        )
    }

    func groupSpaceMigrationDestinationEntryFrames(
        _ capture: GroupSpaceMigrationCapture
    ) -> [String: CGRect]? {
        let frames = currentMigrationFrames(capture)
        return frames.count == capture.members.count ? frames : nil
    }

    func applyGroupSpaceMigrationLayout(
        _ capture: GroupSpaceMigrationCapture,
        frames: [String: CGRect],
        completion: @escaping (Bool, [String: CGRect]) -> Void
    ) {
        runMigrationFrameBatch(capture, frames: frames) { [weak self] success in
            guard let self else { completion(false, [:]); return }
            let accepted = self.currentMigrationFrames(capture)
            let allAccepted = success
                && accepted.count == capture.members.count
                && frames.allSatisfy { identity, planned in
                    accepted[identity].map {
                        self.migrationFramesMatch($0, planned)
                    } == true
                }
            completion(allAccepted, allAccepted ? accepted : [:])
        }
    }

    func restoreGroupSpaceMigrationEntryFrames(
        _ capture: GroupSpaceMigrationCapture,
        frames: [String: CGRect],
        completion: @escaping () -> Void
    ) {
        runMigrationFrameBatch(capture, frames: frames) { _ in completion() }
    }

    func commitGroupSpaceMigration(
        _ capture: GroupSpaceMigrationCapture,
        acceptedFrames: [String: CGRect]
    ) -> Bool {
        guard groupSpaceMigrationStructureMatches(capture.structuralSnapshot),
              acceptedFrames.count == capture.members.count else {
            return false
        }
        let placements = capture.members.compactMap { member
            -> SplitPlacementGeometry? in
            acceptedFrames[member.stableIdentity].map {
                SplitPlacementGeometry(
                    stableIdentity: member.stableIdentity,
                    zone: member.zone,
                    frame: $0
                )
            }
        }
        guard placements.count == capture.members.count,
              let committed = explicitGroupStore.reconcileAfterLayoutMutation(
                  preferredMemberID: capture.preferredMemberID,
                  displayID: capture.destinationDisplayID,
                  placements: placements,
                  detachedConnections: detachedConnections,
                  targetGroupID: capture.structuralSnapshot.groupID
              ),
              committed.id == capture.structuralSnapshot.groupID,
              committed.memberIDs == capture.structuralSnapshot.memberIDs
        else { return false }

        isReconcilingPlacementMutation = true
        defer { isReconcilingPlacementMutation = false }
        for member in capture.members {
            guard let frame = acceptedFrames[member.stableIdentity] else {
                return false
            }
            lockedPlacements[member.stableIdentity] = LockedPlacement(
                element: member.element,
                pid: member.pid,
                stableIdentity: member.stableIdentity,
                cgWindowID: member.windowID,
                zone: member.zone,
                displayID: capture.destinationDisplayID,
                appliedFrame: frame
            )
            if let restoreFrame = capture.destinationRestoreFrames[
                member.stableIdentity
            ] {
                restoreFrames[member.stableIdentity] = restoreFrame
            }
        }
        return true
    }

    func dissolveGroupSpaceMigration(_ capture: GroupSpaceMigrationCapture) {
        for member in capture.members {
            windowService.cancelFrameOperation(for: member.element)
        }
        _ = retireExplicitGroup(
            ExplicitGroupDepartureSnapshot(
                groupID: capture.structuralSnapshot.groupID,
                memberIDs: capture.structuralSnapshot.memberIDs
            ),
            reason: .failedSpaceMigration
        )
    }

    func retireGroupSpaceMigrationProxy(groupID: SnapGroupID) {
        missionControlGroupProxyController.retireForSpaceMigration(
            groupID: groupID
        )
    }

    func restoreGroupSpaceMigrationProxyAfterSourceCancellation(
        groupID: SnapGroupID
    ) {
        groupSpaceMigrationReservationShadowPresenter.cancelReservation(
            groupID: groupID
        )
        groupSpaceMigrationReservationShadowObserver.reservationDidEnd(
            groupID: groupID
        )
        missionControlGroupProxyController
            .restoreAfterSpaceMigrationSourceCancellation(
                groupID: groupID
            )
    }

    func groupSpaceMigrationDidFinish(
        _ capture: GroupSpaceMigrationCapture,
        terminalState: GroupSpaceMigrationTerminalState
    ) {
        noteGroupSpaceMigrationForegroundTerminal(
            groupID: capture.structuralSnapshot.groupID,
            terminalState: terminalState
        )
        groupSpaceMigrationReservationShadowPresenter.finish(
            groupID: capture.structuralSnapshot.groupID
        )
        groupSpaceMigrationReservationShadowObserver.reservationDidEnd(
            groupID: capture.structuralSnapshot.groupID
        )
        // Do not cancel an unrelated explicit Proxy-selection transaction
        // that may share the Mission Control exit. Only discard the generic
        // fallback baseline owned by the migration lifecycle.
        foregroundSelectionMonitor.invalidateBaseline()
        clearSpaceSeparationEvidence(for: capture.structuralSnapshot.groupID)
        let migrationWorkRemains = groupSpaceMigrationLine
            .hasPendingOrActiveTransactions
        resizeHandleOverlay.setPresentationSuspended(migrationWorkRemains)
        if !migrationWorkRemains && canRefreshPresentationAfterAsyncTransaction {
            refreshResizeHandles()
        }
        if !migrationWorkRemains {
            scheduleGroupSpaceMigrationForegroundFlushIfReady()
        }
    }

    private func groupSpaceMigrationReservationLabel(
        for groupID: SnapGroupID
    ) -> String {
        guard let displayOrdinal = explicitGroupStore.displayOrdinal(
            for: groupID
        ) else {
            return "グループ"
        }
        return "グループ \(displayOrdinal)"
    }

    func groupSpaceMigrationDidDetectUnavailableAPI(
        _ notice: GroupSpaceMigrationAPIUnavailableNotice
    ) {
        // The migration line calls this only after normal desktop evidence has
        // returned. Defer one main-loop turn so the existing proxy/handle
        // recovery mutation finishes before application UI is presented.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.settings.missionControlGroupMigrationEnabled else {
                return
            }
            self.onGroupSpaceMigrationAPIUnavailable?(notice)
        }
    }

    private func clearSpaceSeparationEvidence(for groupID: SnapGroupID) {
        directGroupSpaceSeparationEvidenceByGroupID.removeValue(forKey: groupID)
        groupSpaceSeparationEvidenceByGroupID.removeValue(forKey: groupID)
    }

    private func migrationDestinationScreen(
        managedDisplayIdentifier: String
    ) -> NSScreen? {
        let identifier = managedDisplayIdentifier.uppercased()
        return NSScreen.screens.first(where: { screen in
            guard let displayID = displayID(for: screen),
                  let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(
                      displayID
                  )
            else { return false }
            // The CoreGraphics "Create" function returns an owned CF object
            // as Unmanaged on this SDK. Consume that +1 exactly once before
            // passing the value to another Core Foundation function.
            let uuid = unmanagedUUID.takeRetainedValue()
            return (CFUUIDCreateString(nil, uuid) as String).uppercased()
                == identifier
        })
    }

    private func runMigrationFrameBatch(
        _ capture: GroupSpaceMigrationCapture,
        frames: [String: CGRect],
        completion: @escaping (Bool) -> Void
    ) {
        guard frames.count == capture.members.count else {
            completion(false)
            return
        }
        let batch = GroupMigrationFrameBatch(
            memberIDs: Set(capture.members.map(\.stableIdentity)),
            completion: completion
        )
        let membersByIdentity = Dictionary(
            uniqueKeysWithValues: capture.members.map {
                ($0.stableIdentity, $0)
            }
        )
        let lanes = GroupMigrationFrameSchedulingPolicy.lanes(
            subjects: capture.members.map {
                GroupMigrationFrameWriteSubject(
                    stableIdentity: $0.stableIdentity,
                    pid: $0.pid
                )
            }
        )
        func runLane(_ identities: [String], at index: Int = 0) {
            guard identities.indices.contains(index) else { return }
            let identity = identities[index]
            guard let member = membersByIdentity[identity],
                  let frame = frames[identity] else {
                batch.resolve(memberID: identity, succeeded: false)
                runLane(identities, at: index + 1)
                return
            }
            windowService.setFrameReliably(frame, for: member.element) {
                succeeded in
                batch.resolve(memberID: identity, succeeded: succeeded)
                runLane(identities, at: index + 1)
            }
        }
        for lane in lanes {
            runLane(lane)
        }
        let maximumLaneLength = lanes.map(\.count).max() ?? 1
        DispatchQueue.main.asyncAfter(
            deadline: .now() + GroupMigrationFrameSchedulingPolicy
                .completionTimeout(maximumLaneLength: maximumLaneLength)
        ) {
            batch.expire()
        }
    }

    private func currentMigrationFrames(
        _ capture: GroupSpaceMigrationCapture
    ) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: capture.members.compactMap { member in
            windowService.currentFrame(of: member.element, pid: member.pid).map {
                (member.stableIdentity, $0)
            }
        })
    }

    private func migrationFramesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1
            && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }

    private func projectMigrationFrame(
        _ frame: CGRect,
        from source: CGRect,
        to destination: CGRect
    ) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        return CGRect(
            x: destination.minX
                + (frame.minX - source.minX) / source.width
                    * destination.width,
            y: destination.minY
                + (frame.minY - source.minY) / source.height
                    * destination.height,
            width: frame.width / source.width * destination.width,
            height: frame.height / source.height * destination.height
        )
    }
}
