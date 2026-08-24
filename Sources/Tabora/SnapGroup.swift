import CoreGraphics
import Foundation

struct SnapGroupID: Hashable, Codable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct SnapGroupLayout: Equatable {
    var zonesByMemberID: [String: SnapZone]
}

enum SnapGroupState: Equatable {
    case active
    case occludedByMaximizedLayer(windowID: String)
    case suspendedForSpaceTransition
    case degraded(missingMemberIDs: Set<String>)
}

struct SnapGroup: Equatable {
    let id: SnapGroupID
    let creationOrder: UInt64
    var displayID: CGDirectDisplayID
    var memberIDs: Set<String>
    var layout: SnapGroupLayout
    var state: SnapGroupState
    var preferredMemberID: String
    var revision: UInt64
}

struct SnapGroupDissolution: Equatable {
    let groupIDs: Set<SnapGroupID>
    let memberIDs: Set<String>
}

struct SnapGroupPolicy {
    var maximumActiveSplitGroups: Int

    // Groups are session-scoped and bounded naturally by the number of live
    // application windows. Do not evict an unrelated group merely because a
    // new independent split is created.
    static let current = SnapGroupPolicy(
        maximumActiveSplitGroups: Int.max
    )
}

enum SystemWindowSelectionDisposition: Equatable {
    case preserveCurrentAuthorization
    case presentSelectedMemberOnly
}

enum GroupFrontmostEvaluation: Equatable {
    case verifiedFrontmost
    case occluded
    case indeterminate
}

enum GroupPreviewActivityEvaluation: Equatable {
    case observed(exposedMembers: Set<WindowServerSelectionSnapshot>)
    case indeterminate
}

enum GroupPreviewActivityPolicy {
    /// Preview activity is presentation-only and member-scoped. This keeps a
    /// system-isolated raised member HOT without refreshing its covered peers.
    /// Missing Window Server evidence never proves that a member became COLD.
    static func evaluate(
        memberSelections: Set<WindowServerSelectionSnapshot>,
        snapshot: [WindowOcclusionSnapshot]
    ) -> GroupPreviewActivityEvaluation {
        guard !memberSelections.isEmpty, !snapshot.isEmpty else {
            return .indeterminate
        }
        let members = snapshot.filter { surface in
            surface.layer == 0
                && memberSelections.contains(
                    WindowServerSelectionSnapshot(
                        pid: surface.pid,
                        windowID: surface.windowID
                    )
                )
        }
        guard members.count == memberSelections.count else {
            return .indeterminate
        }

        let exposedMembers = Set(members.compactMap { member
            -> WindowServerSelectionSnapshot? in
            let memberSelection = WindowServerSelectionSnapshot(
                pid: member.pid,
                windowID: member.windowID
            )
            let isOccluded = snapshot.contains { surface in
                let selection = WindowServerSelectionSnapshot(
                    pid: surface.pid,
                    windowID: surface.windowID
                )
                guard surface.layer == 0,
                      surface.zIndex < member.zIndex,
                      selection != memberSelection else {
                    return false
                }
                let intersection = member.frame.intersection(surface.frame)
                return !intersection.isNull
                    && intersection.width > 1
                    && intersection.height > 1
            }
            return isOccluded ? nil : memberSelection
        })
        return .observed(exposedMembers: exposedMembers)
    }
}

enum GroupFrontmostEvaluationPolicy {
    static func evaluate(
        memberSelections: Set<WindowServerSelectionSnapshot>,
        snapshot: [WindowOcclusionSnapshot]
    ) -> GroupFrontmostEvaluation {
        guard !memberSelections.isEmpty, !snapshot.isEmpty else {
            return .indeterminate
        }
        let members = snapshot.filter { surface in
            surface.layer == 0
                && memberSelections.contains(
                    WindowServerSelectionSnapshot(
                        pid: surface.pid,
                        windowID: surface.windowID
                    )
                )
        }
        guard members.count == memberSelections.count,
              let first = members.first,
              let rearmostIndex = members.map(\.zIndex).max() else {
            return .indeterminate
        }
        let groupBounds = members.dropFirst().reduce(first.frame) {
            $0.union($1.frame)
        }
        let hasOccluder = snapshot.contains { surface in
            let surfaceSelection = WindowServerSelectionSnapshot(
                pid: surface.pid,
                windowID: surface.windowID
            )
            guard surface.layer == 0,
                  surface.zIndex < rearmostIndex,
                  !memberSelections.contains(surfaceSelection) else { return false }
            let intersection = groupBounds.intersection(surface.frame)
            return !intersection.isNull
                && intersection.width > 1
                && intersection.height > 1
        }
        return hasOccluder ? .occluded : .verifiedFrontmost
    }
}

enum GroupForegroundSelectionPolicy {
    /// System application/window switchers do not carry an explicit Tabora
    /// group identity. They may acknowledge a group that is already entirely
    /// frontmost, but they never authorize bringing missing companions up.
    static func disposition(
        groupIsAlreadyFrontmost: Bool
    ) -> SystemWindowSelectionDisposition {
        groupIsAlreadyFrontmost
            ? .preserveCurrentAuthorization
            : .presentSelectedMemberOnly
    }
}

enum MultiMemberReplacementStructuralPolicy {
    static func matchesCapturedStructure(
        expectedMemberIDs: Set<String>,
        expectedZonesByMemberID: [String: SnapZone],
        currentMemberIDs: Set<String>,
        currentZonesByMemberID: [String: SnapZone]
    ) -> Bool {
        expectedMemberIDs == currentMemberIDs
            && expectedZonesByMemberID == currentZonesByMemberID
            && Set(currentZonesByMemberID.keys) == currentMemberIDs
    }
}

enum SnapGroupPlacementEligibilityPolicy {
    private struct WindowServerScene {
        let orderedWindows: [SplitZOrderWindow]
        let identityCounts: [String: Int]
    }

    static func canUseProvisionalPeer(
        existingIdentity: String,
        incomingIdentity: String
    ) -> Bool {
        existingIdentity != incomingIdentity
    }

    static func frontmostGroupIDs(
        groups: [SnapGroup],
        draggedSurface: WindowServerSelectionSnapshot?,
        bindings: [PersistedWindowBinding],
        windowServerSnapshot: [WindowOcclusionSnapshot]
    ) -> Set<SnapGroupID> {
        // Replacement snapping ignores only the surface physically owned by
        // the current drag. Every other Window Server surface remains in the
        // scene, including same-app windows that AX cannot uniquely match.
        // This is the distinction between invading one exposed group and
        // constructing a new group in front of an already covered layout.
        guard let draggedSurface else { return [] }
        let scene = windowServerScene(
            excluding: draggedSurface,
            bindings: bindings,
            snapshot: windowServerSnapshot
        )
        return Set(groups.compactMap { group in
            guard group.memberIDs.allSatisfy({
                scene.identityCounts[$0] == 1
            }), SplitLayoutGeometry.connectedGroupIsFrontmost(
                groupIDs: group.memberIDs,
                orderedWindows: scene.orderedWindows
            ) else { return nil }
            return group.id
        })
    }

    static func wasFrontmostAtPointerDown(
        groupIDs: Set<String>,
        draggedSurface: WindowServerSelectionSnapshot?,
        bindings: [PersistedWindowBinding],
        windowServerSnapshot: [WindowOcclusionSnapshot]
    ) -> Bool {
        guard !groupIDs.isEmpty, let draggedSurface else { return false }
        let scene = windowServerScene(
            excluding: draggedSurface,
            bindings: bindings,
            snapshot: windowServerSnapshot
        )
        guard groupIDs.allSatisfy({ scene.identityCounts[$0] == 1 }) else {
            return false
        }
        return SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: groupIDs,
            orderedWindows: scene.orderedWindows
        )
    }

    private static func windowServerScene(
        excluding draggedSurface: WindowServerSelectionSnapshot,
        bindings: [PersistedWindowBinding],
        snapshot: [WindowOcclusionSnapshot]
    ) -> WindowServerScene {
        var identityCounts: [String: Int] = [:]
        let orderedWindows = snapshot.sorted {
            $0.zIndex < $1.zIndex
        }.compactMap { surface
            -> SplitZOrderWindow? in
            guard surface.layer == 0,
                  surface.pid != draggedSurface.pid
                    || surface.windowID != draggedSurface.windowID else {
                return nil
            }
            let stableIdentity: String
            switch PersistedWindowBindingPolicy.resolve(
                pid: surface.pid,
                windowID: surface.windowID,
                bindings: bindings
            ) {
            case .matched(let identity):
                stableIdentity = identity
                identityCounts[identity, default: 0] += 1
            case .unavailable, .conflicting:
                // Unregistered same-application windows and conflicting
                // identity claims remain real occluders. They need no AX
                // identity to prove that a stored group was not frontmost.
                stableIdentity = "window-server:\(surface.pid):\(surface.windowID)"
            }
            return SplitZOrderWindow(
                stableIdentity: stableIdentity,
                frame: surface.frame
            )
        }
        return WindowServerScene(
            orderedWindows: orderedWindows,
            identityCounts: identityCounts
        )
    }

    static func canAbsorbPlacement(
        wasFrontmostAtPointerDown: Bool?,
        isFrontmostNow: Bool,
        isComplete: Bool
    ) -> Bool {
        (wasFrontmostAtPointerDown ?? true)
            && isFrontmostNow
            && isComplete
    }

    static func relationshipRank(
        conflictingMemberCount: Int,
        multiMemberReplacementHasStraightBoundary: Bool,
        fullGroupReplacementIsExactCover: Bool = false,
        canExtend: Bool
    ) -> Int? {
        if conflictingMemberCount == 1 {
            // Preserve the existing single-member replacement path exactly.
            return 0
        }
        if conflictingMemberCount >= 2 {
            // A blocked multi-member replacement is a hard veto for this
            // group. It must not fall through and become an extension.
            return (multiMemberReplacementHasStraightBoundary
                || fullGroupReplacementIsExactCover) ? 0 : nil
        }
        if canExtend { return 1 }
        return nil
    }
}

enum AssistCandidateExclusionPolicy {
    static func currentExclusions(
        capturedIDs: Set<String>,
        lockedIDs: Set<String>,
        groupedIDs: Set<String>
    ) -> Set<String> {
        capturedIDs.intersection(lockedIDs.union(groupedIDs))
    }
}

enum SnapGroupDeparturePolicy {
    static func retirementMemberIDs(
        captured: Set<String>,
        current: Set<String>
    ) -> Set<String> {
        captured.union(current)
    }

    static func connectionsAfterRetirement(
        existing: Set<SplitConnectionKey>,
        retiredMemberIDs: Set<String>
    ) -> Set<SplitConnectionKey> {
        Set(existing.filter { connection in
            retiredMemberIDs.allSatisfy { !connection.contains($0) }
        })
    }
}

struct GroupWindowServerEvidence {
    let stableIdentity: String
    let pid: pid_t
    let windowID: CGWindowID?
    let expectedFrame: CGRect
}

struct GroupDegradationFingerprint: Equatable {
    let missingMemberIDs: Set<String>
    let geometryDisconnected: Bool
}

struct GroupDegradationEvidence: Equatable {
    let fingerprint: GroupDegradationFingerprint
    let firstObservedAt: TimeInterval
    let firstObservationEpoch: UInt64
    let latestObservationEpoch: UInt64
}

struct GroupDegradationObservation {
    let evidence: GroupDegradationEvidence
    let isConfirmed: Bool
}

enum GroupDegradationConfirmationPolicy {
    static let minimumSettleInterval: TimeInterval = 0.06

    static func observe(
        previous: GroupDegradationEvidence?,
        fingerprint: GroupDegradationFingerprint,
        epoch: UInt64,
        now: TimeInterval,
        minimumSettleInterval: TimeInterval = minimumSettleInterval
    ) -> GroupDegradationObservation {
        guard let previous, previous.fingerprint == fingerprint else {
            return GroupDegradationObservation(
                evidence: GroupDegradationEvidence(
                    fingerprint: fingerprint,
                    firstObservedAt: now,
                    firstObservationEpoch: epoch,
                    latestObservationEpoch: epoch
                ),
                isConfirmed: false
            )
        }
        let isFreshEpoch = epoch != previous.latestObservationEpoch
        let updated = GroupDegradationEvidence(
            fingerprint: fingerprint,
            firstObservedAt: previous.firstObservedAt,
            firstObservationEpoch: previous.firstObservationEpoch,
            latestObservationEpoch: isFreshEpoch
                ? epoch
                : previous.latestObservationEpoch
        )
        let confirmed = isFreshEpoch
            && epoch != previous.firstObservationEpoch
            && now - previous.firstObservedAt >= minimumSettleInterval
        return GroupDegradationObservation(
            evidence: updated,
            isConfirmed: confirmed
        )
    }
}

/// A Space departure is structural only when the same exact group is split
/// between the active desktop and another desktop. All-visible is ordinary
/// operation; all-offscreen is an ordinary Space switch. Every member must
/// still have complete physical identity evidence, and every offscreen member
/// must remain an eligible, non-hidden, non-minimized AX window.
enum GroupSpaceSeparationPolicy {
    static let minimumSettleInterval: TimeInterval = 0.50

    static func fingerprint(
        memberIDs: Set<String>,
        onScreenMemberIDs: Set<String>,
        confirmedExistingMemberIDs: Set<String>,
        eligibleOffscreenMemberIDs: Set<String>
    ) -> GroupDegradationFingerprint? {
        let offscreenMemberIDs = memberIDs.subtracting(onScreenMemberIDs)
        guard memberIDs.count >= 2,
              onScreenMemberIDs.isSubset(of: memberIDs),
              !onScreenMemberIDs.isEmpty,
              !offscreenMemberIDs.isEmpty,
              confirmedExistingMemberIDs == memberIDs,
              offscreenMemberIDs.isSubset(of: eligibleOffscreenMemberIDs)
        else { return nil }
        return GroupDegradationFingerprint(
            missingMemberIDs: offscreenMemberIDs,
            geometryDisconnected: false
        )
    }
}

enum MissionControlActivationIdentityPolicy {
    /// Mission Control changes Window Server geometry without changing the
    /// persisted identity of an existing group member. Explicit proxy
    /// activation therefore proves member existence from exact persisted
    /// PID/window-ID bindings and current layer-zero surfaces, not frame
    /// equality. Geometry remains a separate presentation-settlement check.
    static func exactSelections(
        memberIDs: Set<String>,
        bindings: [PersistedWindowBinding],
        snapshot: [WindowOcclusionSnapshot]
    ) -> Set<WindowServerSelectionSnapshot>? {
        guard memberIDs.count >= 2 else { return nil }
        let targetBindings = bindings.filter {
            memberIDs.contains($0.stableIdentity)
        }
        guard targetBindings.count == memberIDs.count,
              Set(targetBindings.map(\.stableIdentity)) == memberIDs else {
            return nil
        }
        let selections = Set(targetBindings.map {
            WindowServerSelectionSnapshot(
                pid: $0.pid,
                windowID: $0.windowID
            )
        })
        guard selections.count == memberIDs.count,
              selections.allSatisfy({ selection in
                  snapshot.contains { surface in
                      surface.pid == selection.pid
                          && surface.windowID == selection.windowID
                          && surface.layer == 0
                  }
              }) else {
            return nil
        }
        return selections
    }
}

enum GroupPresentationTransitionObservation: Equatable {
    case normal
    case transformed
    case unresolvedLive
    case unavailable
}

struct GroupPresentationTransitionLease: Equatable {
    let groupID: SnapGroupID
    let memberIDs: Set<String>
    let expiresAt: TimeInterval
}

enum GroupWindowServerEvidenceBaselinePolicy {
    static func framesRepresentTheSameDesktopGeometry(
        accessibilityFrame: CGRect,
        windowServerFrame: CGRect,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard accessibilityFrame.width > 1,
              accessibilityFrame.height > 1,
              windowServerFrame.width > 1,
              windowServerFrame.height > 1 else {
            return false
        }
        return abs(accessibilityFrame.minX - windowServerFrame.minX)
                <= tolerance
            && abs(accessibilityFrame.minY - windowServerFrame.minY)
                <= tolerance
            && abs(accessibilityFrame.width - windowServerFrame.width)
                <= tolerance
            && abs(accessibilityFrame.height - windowServerFrame.height)
                <= tolerance
    }
}

enum GroupPresentationTransitionLeasePolicy {
    static let lifetime: TimeInterval = 1.25

    static func make(
        groupID: SnapGroupID,
        memberIDs: Set<String>,
        now: TimeInterval
    ) -> GroupPresentationTransitionLease {
        GroupPresentationTransitionLease(
            groupID: groupID,
            memberIDs: memberIDs,
            expiresAt: now + lifetime
        )
    }

    static func isValid(
        _ lease: GroupPresentationTransitionLease?,
        groupID: SnapGroupID,
        memberIDs: Set<String>,
        now: TimeInterval
    ) -> Bool {
        guard let lease else { return false }
        return lease.groupID == groupID
            && lease.memberIDs == memberIDs
            && now <= lease.expiresAt
    }

    static func retainingUnretired(
        _ leases: [SnapGroupID: GroupPresentationTransitionLease],
        retiring groupIDs: Set<SnapGroupID>
    ) -> [SnapGroupID: GroupPresentationTransitionLease] {
        leases.filter { !groupIDs.contains($0.key) }
    }
}

enum GroupPresentationTransitionPolicy {
    static let defaultMinimumScaleDelta: CGFloat = 0.08
    static let defaultMaximumScaleAnisotropy: CGFloat = 0.04

    static func observe(
        evidence: [GroupWindowServerEvidence],
        expectedMemberCount: Int,
        visibleMemberIDs: Set<String>,
        snapshot: [WindowOcclusionSnapshot]
    ) -> GroupPresentationTransitionObservation {
        guard expectedMemberCount >= 2,
              evidence.count == expectedMemberCount else {
            return .unavailable
        }
        if visibleMemberIDs.count == expectedMemberCount {
            return .normal
        }
        guard unresolvedMembersRemainLive(
            evidence: evidence,
            visibleMemberIDs: visibleMemberIDs,
            snapshot: snapshot
        ) else {
            return .unavailable
        }
        return shouldPreserveLastPresentation(
            evidence: evidence,
            visibleMemberIDs: visibleMemberIDs,
            snapshot: snapshot
        ) ? .transformed : .unresolvedLive
    }

    static func unresolvedMembersRemainLive(
        evidence: [GroupWindowServerEvidence],
        visibleMemberIDs: Set<String>,
        snapshot: [WindowOcclusionSnapshot]
    ) -> Bool {
        let unresolved = evidence.filter {
            !visibleMemberIDs.contains($0.stableIdentity)
        }
        guard !unresolved.isEmpty else { return false }
        return unresolved.allSatisfy { member in
            guard let windowID = member.windowID else { return false }
            return snapshot.contains {
                $0.windowID == windowID
                    && $0.pid == member.pid
                    && $0.layer == 0
            }
        }
    }

    /// Mission Control temporarily scales managed windows in WindowServer
    /// while Accessibility continues to describe their desktop geometry.
    /// Preserve the last validated presentation only when every AX-missing
    /// group member is still the same live layer-zero window and has acquired
    /// a materially different scale. A moved, closed, or minimized window does
    /// not satisfy this policy and therefore continues through normal
    /// fail-closed degradation.
    static func shouldPreserveLastPresentation(
        evidence: [GroupWindowServerEvidence],
        visibleMemberIDs: Set<String>,
        snapshot: [WindowOcclusionSnapshot],
        minimumScaleDelta: CGFloat =
            GroupPresentationTransitionPolicy.defaultMinimumScaleDelta
    ) -> Bool {
        let missing = evidence.filter {
            !visibleMemberIDs.contains($0.stableIdentity)
        }
        guard unresolvedMembersRemainLive(
            evidence: evidence,
            visibleMemberIDs: visibleMemberIDs,
            snapshot: snapshot
        ) else { return false }

        return missing.allSatisfy { member in
            guard let windowID = member.windowID,
                  member.expectedFrame.width > 1,
                  member.expectedFrame.height > 1,
                  let serverWindow = snapshot.first(where: {
                      $0.windowID == windowID
                          && $0.pid == member.pid
                          && $0.layer == 0
                  }) else { return false }
            let widthScale = serverWindow.frame.width
                / member.expectedFrame.width
            let heightScale = serverWindow.frame.height
                / member.expectedFrame.height
            let hasMaterialScaleDelta = abs(widthScale - 1)
                    >= minimumScaleDelta
                || abs(heightScale - 1) >= minimumScaleDelta
            // Mission Control preserves each window's aspect ratio while
            // scaling its Window Server surface. A normal shared/native resize
            // changes one axis independently and must never mint a transition
            // authorization token merely because AX and Window Server settled
            // on adjacent turns.
            return hasMaterialScaleDelta
                && abs(widthScale - heightScale)
                    <= defaultMaximumScaleAnisotropy
        }
    }
}

/// Session-only identity for split groups. Geometry is accepted as evidence
/// when an explicit placement or connection mutation occurs; ordinary refresh
/// passes never manufacture a new group identity.
struct SnapGroupStore {
    private(set) var groupsByID: [SnapGroupID: SnapGroup] = [:]
    private(set) var groupIDByMemberID: [String: SnapGroupID] = [:]
    private(set) var maximizedLayerByDisplayID: [CGDirectDisplayID: String] = [:]
    private var nextCreationOrder: UInt64 = 0
    let policy: SnapGroupPolicy

    init(policy: SnapGroupPolicy = .current) {
        self.policy = policy
    }

    var groups: [SnapGroup] {
        groupsByID.values.sorted {
            if $0.creationOrder != $1.creationOrder {
                return $0.creationOrder < $1.creationOrder
            }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    var connectedMemberCount: Int {
        groupsByID.values.reduce(0) { $0 + $1.memberIDs.count }
    }

    func group(containing memberID: String) -> SnapGroup? {
        guard let groupID = groupIDByMemberID[memberID] else { return nil }
        return groupsByID[groupID]
    }

    func group(id: SnapGroupID) -> SnapGroup? {
        groupsByID[id]
    }

    mutating func registerMaximizedLayer(
        windowID: String,
        displayID: CGDirectDisplayID
    ) {
        _ = dissolveGroup(containing: windowID)
        maximizedLayerByDisplayID = maximizedLayerByDisplayID.filter {
            $0.value != windowID
        }
        maximizedLayerByDisplayID[displayID] = windowID
        updateOcclusionStates()
    }

    mutating func clearMaximizedLayer(windowID: String) {
        maximizedLayerByDisplayID = maximizedLayerByDisplayID.filter {
            $0.value != windowID
        }
        updateOcclusionStates()
    }

    mutating func removeWindow(_ memberID: String) {
        _ = dissolveGroup(containing: memberID)
        clearMaximizedLayer(windowID: memberID)
    }

    /// Removing one visible member invalidates the visual group as a whole.
    /// Individual placement locks remain controller-owned, but no subset keeps
    /// the previous group identity.
    @discardableResult
    mutating func dissolveGroup(containing memberID: String) -> Set<String> {
        guard let group = group(containing: memberID) else { return [] }
        removeGroup(group.id)
        return group.memberIDs
    }

    @discardableResult
    mutating func dissolveGroup(id groupID: SnapGroupID) -> Set<String> {
        guard let group = group(id: groupID) else { return [] }
        removeGroup(groupID)
        return group.memberIDs
    }

    /// Dissolves every current group reached from the supplied member set.
    /// This closes the race where an interaction captured an old group ID but
    /// a pending layout transaction remapped one of those members before the
    /// departure was committed.
    mutating func dissolveGroups(
        intersecting seedMemberIDs: Set<String>
    ) -> SnapGroupDissolution {
        var pendingMemberIDs = seedMemberIDs
        var resolvedMemberIDs = seedMemberIDs
        var dissolvedGroupIDs = Set<SnapGroupID>()

        while let memberID = pendingMemberIDs.first {
            pendingMemberIDs.remove(memberID)
            guard let currentGroup = group(containing: memberID),
                  dissolvedGroupIDs.insert(currentGroup.id).inserted else {
                continue
            }
            let currentMembers = dissolveGroup(id: currentGroup.id)
            pendingMemberIDs.formUnion(
                currentMembers.subtracting(resolvedMemberIDs)
            )
            resolvedMemberIDs.formUnion(currentMembers)
        }
        return SnapGroupDissolution(
            groupIDs: dissolvedGroupIDs,
            memberIDs: resolvedMemberIDs
        )
    }

    /// Returns the other members that must remain disconnected from the
    /// detached window in the legacy adjacency graph.
    @discardableResult
    mutating func detachMember(_ memberID: String) -> Set<String> {
        guard let group = group(containing: memberID) else { return [] }
        let peers = group.memberIDs.subtracting([memberID])
        removeGroup(group.id)
        return peers
    }

    mutating func setPreferredMember(_ memberID: String) {
        guard let groupID = groupIDByMemberID[memberID],
              var group = groupsByID[groupID],
              group.preferredMemberID != memberID else { return }
        group.preferredMemberID = memberID
        group.revision &+= 1
        groupsByID[groupID] = group
    }

    mutating func suspendForSpaceTransition() {
        for groupID in Array(groupsByID.keys) {
            guard var group = groupsByID[groupID] else { continue }
            group.state = .suspendedForSpaceTransition
            group.revision &+= 1
            groupsByID[groupID] = group
        }
    }

    mutating func markActiveAfterSpaceTransition() {
        updateOcclusionStates(forceRevision: true)
    }

    mutating func markDegraded(
        groupID: SnapGroupID,
        missingMemberIDs: Set<String>
    ) {
        guard var group = groupsByID[groupID] else { return }
        let state: SnapGroupState = missingMemberIDs.isEmpty
            ? activeState(for: group.displayID)
            : .degraded(missingMemberIDs: missingMemberIDs)
        guard group.state != state else { return }
        group.state = state
        group.revision &+= 1
        groupsByID[groupID] = group
    }

    mutating func clear() {
        groupsByID.removeAll()
        groupIDByMemberID.removeAll()
        maximizedLayerByDisplayID.removeAll()
        nextCreationOrder = 0
    }

    /// Reconciles only after a user-visible layout mutation (snap, detach, or
    /// completed linked resize). This preserves group identity across passive
    /// geometry refreshes while still using adjacency as fail-closed evidence.
    @discardableResult
    mutating func reconcileAfterLayoutMutation(
        preferredMemberID: String,
        displayID: CGDirectDisplayID,
        placements: [SplitPlacementGeometry],
        detachedConnections: Set<SplitConnectionKey>,
        targetGroupID: SnapGroupID? = nil
    ) -> SnapGroup? {
        // Reconciliation is transactional: rejection must leave the previous
        // group intact so the controller can either roll back the placement or
        // retire every captured member atomically. Destroying membership here
        // loses the only authoritative list while peer locks still exist.
        guard policy.maximumActiveSplitGroups > 0 else { return nil }
        let splitPlacements = placements.filter {
            $0.zone != .maximize
        }
        guard splitPlacements.contains(where: {
            $0.stableIdentity == preferredMemberID
        }) else { return nil }

        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: splitPlacements,
            detachedConnections: detachedConnections
        )
        let connectedIDs = SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: preferredMemberID,
            handles: handles
        )
        guard connectedIDs.count >= 2 else { return nil }
        if targetGroupID != nil {
            // A targeted replacement is atomic only when every placement in
            // the declared successor scope belongs to the same connected
            // component. Never commit a partial successor and silently leave
            // one of its intended members outside the group.
            let intendedIDs = Set(splitPlacements.map(\.stableIdentity))
            guard connectedIDs == intendedIDs else { return nil }
        }

        let intersectingGroupIDs = Set(connectedIDs.compactMap {
            groupIDByMemberID[$0]
        })
        let foreignGroupIDs = targetGroupID.map { targetID in
            intersectingGroupIDs.subtracting([targetID])
        } ?? []
        // Moving members between groups must be an explicit departure and a
        // separate placement transaction. Geometry alone never authorizes an
        // implicit merge or the deletion of a foreign group.
        guard foreignGroupIDs.isEmpty else { return nil }
        guard intersectingGroupIDs.count <= 1 || targetGroupID != nil else {
            return nil
        }
        if let targetGroupID {
            guard groupsByID[targetGroupID] != nil else { return nil }
        }

        let wouldRetainOnlyASubset = targetGroupID == nil
            && intersectingGroupIDs.contains { groupID in
            guard let existing = groupsByID[groupID] else { return false }
            return !existing.memberIDs.isSubset(of: connectedIDs)
        }
        if wouldRetainOnlyASubset {
            return nil
        }
        let retainedGroupID = targetGroupID
            ?? groupIDByMemberID[preferredMemberID]
            ?? intersectingGroupIDs.first
            ?? SnapGroupID()

        if groupsByID[retainedGroupID] == nil,
           groupsByID.count >= max(policy.maximumActiveSplitGroups, 0) {
            return nil
        }

        let zonesByID = Dictionary(
            uniqueKeysWithValues: splitPlacements.compactMap { placement in
                connectedIDs.contains(placement.stableIdentity)
                    ? (placement.stableIdentity, placement.zone)
                    : nil
            }
        )
        let previous = groupsByID[retainedGroupID]

        guard connectedIDs.allSatisfy({ memberID in
            guard let existingGroupID = groupIDByMemberID[memberID] else {
                return true
            }
            return existingGroupID == retainedGroupID
        }) else { return nil }

        // Atomic replacement keeps the group identity while retiring the
        // displaced member mappings only after the complete successor layout
        // has been proven connected.
        if let previous {
            for removedMemberID in previous.memberIDs.subtracting(connectedIDs)
                where groupIDByMemberID[removedMemberID] == retainedGroupID {
                groupIDByMemberID.removeValue(forKey: removedMemberID)
            }
        }

        maximizedLayerByDisplayID = maximizedLayerByDisplayID.filter {
            !connectedIDs.contains($0.value)
        }
        updateOcclusionStates()
        for memberID in connectedIDs {
            groupIDByMemberID[memberID] = retainedGroupID
        }

        let nextState = activeState(for: displayID)
        let layout = SnapGroupLayout(zonesByMemberID: zonesByID)
        let didChange = previous?.displayID != displayID
            || previous?.memberIDs != connectedIDs
            || previous?.layout != layout
            || previous?.state != nextState
            || previous?.preferredMemberID != preferredMemberID
        let revision = didChange
            ? ((previous?.revision ?? 0) &+ 1)
            : (previous?.revision ?? 1)
        let creationOrder: UInt64
        if let previous {
            creationOrder = previous.creationOrder
        } else {
            nextCreationOrder &+= 1
            creationOrder = nextCreationOrder
        }
        let group = SnapGroup(
            id: retainedGroupID,
            creationOrder: creationOrder,
            displayID: displayID,
            memberIDs: connectedIDs,
            layout: layout,
            state: nextState,
            preferredMemberID: preferredMemberID,
            revision: revision
        )
        groupsByID[retainedGroupID] = group
        return group
    }

    private mutating func removeGroup(_ groupID: SnapGroupID) {
        guard let removed = groupsByID.removeValue(forKey: groupID) else {
            return
        }
        for memberID in removed.memberIDs where
            groupIDByMemberID[memberID] == groupID {
            groupIDByMemberID.removeValue(forKey: memberID)
        }
    }

    private func activeState(for displayID: CGDirectDisplayID) -> SnapGroupState {
        if let maximizedWindowID = maximizedLayerByDisplayID[displayID] {
            return .occludedByMaximizedLayer(windowID: maximizedWindowID)
        }
        return .active
    }

    private mutating func updateOcclusionStates(forceRevision: Bool = false) {
        for groupID in Array(groupsByID.keys) {
            guard var group = groupsByID[groupID] else { continue }
            let state = activeState(for: group.displayID)
            guard forceRevision || group.state != state else { continue }
            group.state = state
            group.revision &+= 1
            groupsByID[groupID] = group
        }
    }
}
