import AppKit

struct MissionControlTransitionToken: Equatable {
    let groupID: SnapGroupID
    let presentationGeneration: Int
    let observedAt: TimeInterval
    let expiresAt: TimeInterval
}

enum MissionControlTransitionTokenPolicy {
    static let lifetime: TimeInterval = 2.0

    static func make(
        groupID: SnapGroupID,
        presentationGeneration: Int,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> MissionControlTransitionToken {
        MissionControlTransitionToken(
            groupID: groupID,
            presentationGeneration: presentationGeneration,
            observedAt: now,
            expiresAt: now + lifetime
        )
    }

    static func isValid(
        _ token: MissionControlTransitionToken?,
        groupID: SnapGroupID,
        presentationGeneration: Int,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let token else { return false }
        return token.groupID == groupID
            && token.presentationGeneration == presentationGeneration
            && now >= token.observedAt
            && now <= token.expiresAt
    }
}

struct MissionControlGroupProxyMigrationPresentation: Equatable {
    let title: String
    let subtitle: String
    let windowTitle: String
}

enum MissionControlGroupProxyMigrationTypographyPolicy {
    static let titleMaximumPointSize: CGFloat = 48
    static let titleHeightScale: CGFloat = 0.25
}

enum MissionControlGroupProxyMigrationPresentationPolicy {
    static func presentation(
        queuePosition: Int,
        queueTotal: Int
    ) -> MissionControlGroupProxyMigrationPresentation {
        let position = max(queuePosition, 1)
        let total = max(queueTotal, position)
        let title = position == 1
            ? L10n.text("migration.proxy.ready")
            : L10n.text("migration.proxy.waiting")
        let subtitle = total > 1
            ? L10n.format("migration.proxy.subtitle.queued", position, total)
            : L10n.text("migration.proxy.subtitle")
        return MissionControlGroupProxyMigrationPresentation(
            title: title,
            subtitle: subtitle,
            windowTitle: position == 1
                ? L10n.format("migration.proxy.window_title.ready", total)
                : L10n.format("migration.proxy.window_title.waiting", position, total)
        )
    }
}

struct MissionControlProxyOrderingSurface: Equatable {
    let windowID: CGWindowID?
    let frame: CGRect
    let belongsToTargetGroup: Bool
}

enum MissionControlProxyOrderingScopePolicy {
    static func requiredWindowIDs(
        proxyFrame: CGRect,
        surfaces: [MissionControlProxyOrderingSurface]
    ) -> Set<CGWindowID>? {
        let ownSurfaces = surfaces.filter(\.belongsToTargetGroup)
        guard ownSurfaces.count >= 2,
              ownSurfaces.allSatisfy({ $0.windowID != nil }) else {
            return nil
        }

        var required = Set(ownSurfaces.compactMap(\.windowID))
        guard required.count == ownSurfaces.count else { return nil }

        for surface in surfaces where !surface.belongsToTargetGroup {
            let intersection = proxyFrame.intersection(surface.frame)
            guard !intersection.isNull,
                  intersection.width > 1,
                  intersection.height > 1 else { continue }
            guard let windowID = surface.windowID else { return nil }
            required.insert(windowID)
        }
        return required
    }
}


enum MissionControlProxyOrderingObservation: Equatable {
    case verifiedBehind
    case confirmedUnsafe
    case unresolved
}

enum MissionControlProxyOrderingPolicy {
    static func observation(
        proxyWindowID: CGWindowID,
        requiredWindowIDs: Set<CGWindowID>,
        orderedWindowIDs: [CGWindowID]
    ) -> MissionControlProxyOrderingObservation {
        guard requiredWindowIDs.count >= 2,
              let proxyIndex = orderedWindowIDs.firstIndex(
                of: proxyWindowID
              ) else { return .unresolved }
        let requiredIndices = requiredWindowIDs.compactMap {
            orderedWindowIDs.firstIndex(of: $0)
        }
        guard requiredIndices.count == requiredWindowIDs.count,
              let rearmostRequiredIndex = requiredIndices.max() else {
            return .unresolved
        }
        return proxyIndex > rearmostRequiredIndex
            ? .verifiedBehind
            : .confirmedUnsafe
    }

    static func isBehindAllRequiredWindows(
        proxyWindowID: CGWindowID,
        requiredWindowIDs: Set<CGWindowID>,
        orderedWindowIDs: [CGWindowID]
    ) -> Bool {
        observation(
            proxyWindowID: proxyWindowID,
            requiredWindowIDs: requiredWindowIDs,
            orderedWindowIDs: orderedWindowIDs
        ) == .verifiedBehind
    }
}

enum MissionControlProxySelectionStructuralPolicy {
    static func matchesPresentedMembers(
        presentedMemberIDs: Set<String>,
        currentMemberIDs: Set<String>
    ) -> Bool {
        presentedMemberIDs.count >= 2
            && presentedMemberIDs == currentMemberIDs
    }
}

enum MissionControlProxySelectionDeliveryPolicy {
    static func allowsPresentationMutation(
        selectionWasDelivered: Bool,
        confirmationIsPending: Bool
    ) -> Bool {
        !selectionWasDelivered && !confirmationIsPending
    }

    static func cancelsOnWindowResign(
        selectionWasDelivered: Bool,
        confirmationIsPending: Bool
    ) -> Bool {
        !selectionWasDelivered && !confirmationIsPending
    }
}

enum MissionControlProxySelectionConfirmationSettlementPolicy {
    // The first observation retains the established handoff latency. Later
    // observations are only for the exact captured candidate when Mission
    // Control has returned the proxy before AppKit/workspace activation has
    // finished publishing. This is bounded derived work, not polling.
    static let observationDelays: [TimeInterval] = [0.14, 0.06, 0.10]

    static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard observationDelays.indices.contains(attempt) else { return nil }
        return observationDelays[attempt]
    }
}

enum MissionControlProxySelectionConfirmationDisposition: Equatable {
    case rejected
    case normalGroupActivation
    case queuedMigrationForegroundIntent
}

struct MissionControlProxySelectionCandidate: Equatable {
    let generation: UInt64
    let groupID: SnapGroupID
    let memberIDs: Set<String>
}

enum MissionControlProxySelectionCandidatePolicy {
    static func matches(
        _ candidate: MissionControlProxySelectionCandidate?,
        generation: UInt64,
        groupID: SnapGroupID,
        memberIDs: Set<String>
    ) -> Bool {
        candidate == MissionControlProxySelectionCandidate(
            generation: generation,
            groupID: groupID,
            memberIDs: memberIDs
        )
    }
}

enum MissionControlSelectedProxyPresentationPolicy {
    static func allowsGenericOrderingRevalidation(
        selectionWasDelivered: Bool
    ) -> Bool {
        !selectionWasDelivered
    }

    // Normal completion removes the selected cover as soon as the exact group
    // is verified frontmost. This is only a fail-safe visibility ceiling: the
    // transparent Window Server participant remains transaction-owned until
    // the controller succeeds or explicitly cancels it.
    static let maximumVisibleHandoffLifetime: TimeInterval = 0.50
}

enum MissionControlProxyOrderingRecoveryPolicy {
    static let verificationDelays: [TimeInterval] = [0, 0.04, 0.12, 0.28]

    static func delayAfterFailedAttempt(_ attempt: Int) -> TimeInterval? {
        let nextAttempt = attempt + 1
        guard verificationDelays.indices.contains(nextAttempt) else {
            return nil
        }
        return verificationDelays[nextAttempt]
    }
}

enum MissionControlGroupPresentationRetryPolicy {
    static let maximumFastRetryCount = 6

    static func delay(forFailureCount count: Int) -> TimeInterval? {
        switch count {
        case 1...2: return 0.06
        case 3...4: return 0.15
        case 5...maximumFastRetryCount: return 0.35
        default: return nil
        }
    }
}

struct MissionControlPreviewPixelSize: Equatable {
    let width: Int
    let height: Int
}

enum MissionControlPreviewSizingPolicy {
    static let bytesPerPixel = 4

    static func perImageByteBudget(
        totalByteBudget: Int,
        presentableMemberCount: Int
    ) -> Int {
        guard totalByteBudget > 0 else { return 0 }
        return totalByteBudget / max(presentableMemberCount, 1)
    }

    static func targetPixelSize(
        sourceWidth: Int,
        sourceHeight: Int,
        byteBudget: Int
    ) -> MissionControlPreviewPixelSize? {
        guard sourceWidth > 0, sourceHeight > 0, byteBudget > 0 else {
            return nil
        }
        let sourcePixels = Double(sourceWidth) * Double(sourceHeight)
        let maximumPixels = Double(byteBudget / bytesPerPixel)
        guard maximumPixels > 0 else { return nil }
        let scale = min(sqrt(maximumPixels / sourcePixels), 1)
        return MissionControlPreviewPixelSize(
            width: max(
                Int((Double(sourceWidth) * scale).rounded(.down)), 1
            ),
            height: max(
                Int((Double(sourceHeight) * scale).rounded(.down)), 1
            )
        )
    }

    static func reducedPixelSize(
        width: Int,
        height: Int,
        actualByteCost: Int,
        byteBudget: Int
    ) -> MissionControlPreviewPixelSize? {
        guard width > 0, height > 0,
              actualByteCost > byteBudget,
              byteBudget >= bytesPerPixel else { return nil }
        let scale = min(
            sqrt(Double(byteBudget) / Double(actualByteCost)) * 0.98,
            0.98
        )
        var nextWidth = max(
            Int((Double(width) * scale).rounded(.down)), 1
        )
        var nextHeight = max(
            Int((Double(height) * scale).rounded(.down)), 1
        )
        if nextWidth == width, nextHeight == height {
            if width >= height, width > 1 {
                nextWidth -= 1
            } else if height > 1 {
                nextHeight -= 1
            } else {
                return nil
            }
        }
        return MissionControlPreviewPixelSize(
            width: nextWidth,
            height: nextHeight
        )
    }
}

enum MissionControlPreviewGeometryRefreshPolicy {
    static let maximumSettledCapturesPerRefresh = 2

    static func requestCount(
        dueCount: Int,
        outstandingCount: Int
    ) -> Int {
        let available = max(
            MissionControlPreviewWorkPolicy.maximumOutstandingCaptureCount
                - max(outstandingCount, 0),
            0
        )
        return min(
            max(dueCount, 0),
            maximumSettledCapturesPerRefresh,
            available
        )
    }
}

enum MissionControlPreviewWorkPolicy {
    /// Two captures may run and two more may wait. A large number of groups
    /// must not create an equally large Window Server backlog.
    static let maximumOutstandingCaptureCount = 4
    static let maximumQueuedOperationCount = 8
    /// Time never creates capture work. It only prevents repeated state and
    /// geometry triggers from flooding WindowServer. A retained trigger is
    /// retried once at this boundary and may be superseded by stronger work.
    static let triggerCaptureCooldown: TimeInterval = 1
    static let confirmationInterval: TimeInterval = 0.15
    static let applicationCoalescingInterval: TimeInterval = 0.06
}

enum MissionControlPreviewTriggerReason:
    Int, CaseIterable, Comparable, Hashable {
    case coldConfirmed = 0
    case initial = 1
    case geometryConfirmed = 2

    static func < (
        lhs: MissionControlPreviewTriggerReason,
        rhs: MissionControlPreviewTriggerReason
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum MissionControlPreviewTriggerPolicy {
    static let requiredStableObservationCount = 2

    static func merged(
        _ current: MissionControlPreviewTriggerReason?,
        with incoming: MissionControlPreviewTriggerReason
    ) -> MissionControlPreviewTriggerReason {
        max(current ?? incoming, incoming)
    }

    static func nextStableObservationCount(
        previousCount: Int?,
        representsSameCandidate: Bool
    ) -> Int {
        representsSameCandidate ? max(previousCount ?? 0, 0) + 1 : 1
    }

    static func isConfirmed(observationCount: Int) -> Bool {
        observationCount >= requiredStableObservationCount
    }

    static func isConfirmed(
        observationCount: Int,
        firstObservedAt: TimeInterval,
        now: TimeInterval,
        minimumStableInterval: TimeInterval
    ) -> Bool {
        isConfirmed(observationCount: observationCount)
            && max(now - firstObservedAt, 0) >= minimumStableInterval
    }

    static func captureMatchesCurrentGeometry(
        admittedRevision: UInt64,
        currentRevision: UInt64
    ) -> Bool {
        admittedRevision == currentRevision
    }

    static func canReuseCapturedPixels(
        representsSamePhysicalWindow: Bool,
        displayMatches: Bool,
        pixelSizeMatches: Bool
    ) -> Bool {
        representsSamePhysicalWindow && displayMatches && pixelSizeMatches
    }

    static func shouldObserveGeometryFallback(
        sizeChanged: Bool,
        displayChanged: Bool,
        hasOutstandingCurrentGeometryWork: Bool
    ) -> Bool {
        (sizeChanged || displayChanged)
            && !hasOutstandingCurrentGeometryWork
    }

    static func shouldRetainDebtAfterCaptureFailure(
        hasReusableActiveKey: Bool
    ) -> Bool {
        // One active-geometry capture gets exactly one retry. If that retry
        // also fails, drop this trigger and let a future real trigger try again.
        // Debt is retained only when presentability vanished, because the work
        // was blocked by target validation rather than exhausted by capture.
        !hasReusableActiveKey
    }

    static func cooldownRemaining(
        reason: MissionControlPreviewTriggerReason,
        lastCaptureAt: TimeInterval?,
        now: TimeInterval
    ) -> TimeInterval {
        guard reason != .initial, let lastCaptureAt else { return 0 }
        return max(
            MissionControlPreviewWorkPolicy.triggerCaptureCooldown
                - max(now - lastCaptureAt, 0),
            0
        )
    }
}

enum MissionControlPreviewColdCaptureAuthorizationPolicy {
    static func allowsCommit(
        reason: MissionControlPreviewTriggerReason,
        admittedRevision: UInt64?,
        currentRevision: UInt64
    ) -> Bool {
        reason != .coldConfirmed || admittedRevision == currentRevision
    }
}

enum MissionControlPreviewColdConfirmationFingerprint: Equatable {
    /// Once AX has positively identified normal content, continuity belongs to
    /// the Group's qualified occlusion state rather than one window ID.
    case qualifiedOcclusion
    /// Semantic evidence remains exact-surface-specific. Group-level physical
    /// continuity is tracked separately so unrelated UNKNOWN identities are
    /// never treated as the same AX classification while fallback stays finite.
    case unknown(WindowServerSelectionSnapshot)
}

struct MissionControlPreviewColdConfirmationEvidence: Equatable {
    let fingerprint: MissionControlPreviewColdConfirmationFingerprint
    let observationCount: Int
    let firstObservedAt: TimeInterval
    /// Candidate semantics stay exact, but physical Group occlusion has its
    /// own bounded continuity. This prevents UNKNOWN candidates that churn
    /// between Window Server identities from restarting the 0.15 s passive
    /// confirmation forever while the Group never becomes top again.
    let continuousOcclusionObservationCount: Int
    let continuousOcclusionFirstObservedAt: TimeInterval
}

struct MissionControlPreviewColdConfirmationObservation: Equatable {
    let evidence: MissionControlPreviewColdConfirmationEvidence
    let isConfirmed: Bool
}

enum MissionControlPreviewColdConfirmationPolicy {
    static func observe(
        previous: MissionControlPreviewColdConfirmationEvidence?,
        candidate: WindowServerSelectionSnapshot,
        semantic: PreviewOccluderSemanticClassification,
        now: TimeInterval,
        minimumStableInterval: TimeInterval =
            MissionControlPreviewWorkPolicy.confirmationInterval
    ) -> MissionControlPreviewColdConfirmationObservation? {
        let fingerprint: MissionControlPreviewColdConfirmationFingerprint
        switch semantic {
        case .qualified:
            fingerprint = .qualifiedOcclusion
        case .unknown:
            fingerprint = .unknown(candidate)
        case .auxiliary:
            return nil
        }
        let continuesPrevious = previous?.fingerprint == fingerprint
        let firstObservedAt = continuesPrevious
            ? (previous?.firstObservedAt ?? now)
            : now
        let count = MissionControlPreviewTriggerPolicy
            .nextStableObservationCount(
                previousCount: previous?.observationCount,
                representsSameCandidate: continuesPrevious
            )

        // Reaching this policy means the Group is still physically occluded
        // and no candidate has been positively excluded as AUXILIARY. Keep a
        // second, Group-level continuity budget that is intentionally
        // independent of exact UNKNOWN identity. HOT / AUXILIARY / incomplete
        // observations clear the controller evidence before the next call.
        let continuesPhysicalOcclusion = previous != nil
        let continuousOcclusionFirstObservedAt = continuesPhysicalOcclusion
            ? (previous?.continuousOcclusionFirstObservedAt ?? now)
            : now
        let continuousOcclusionObservationCount =
            MissionControlPreviewTriggerPolicy.nextStableObservationCount(
                previousCount:
                    previous?.continuousOcclusionObservationCount,
                representsSameCandidate: continuesPhysicalOcclusion
            )

        let evidence = MissionControlPreviewColdConfirmationEvidence(
            fingerprint: fingerprint,
            observationCount: count,
            firstObservedAt: firstObservedAt,
            continuousOcclusionObservationCount:
                continuousOcclusionObservationCount,
            continuousOcclusionFirstObservedAt:
                continuousOcclusionFirstObservedAt
        )
        let semanticConfirmation =
            MissionControlPreviewTriggerPolicy.isConfirmed(
                observationCount: count,
                firstObservedAt: firstObservedAt,
                now: now,
                minimumStableInterval: minimumStableInterval
            )
        // The Group-level budget confirms only continuous physical occlusion;
        // it never combines candidate semantics. AUXILIARY never reaches this
        // point, so a positively excluded surface still breaks the sequence.
        let continuousOcclusionConfirmation =
            MissionControlPreviewTriggerPolicy.isConfirmed(
                observationCount: continuousOcclusionObservationCount,
                firstObservedAt: continuousOcclusionFirstObservedAt,
                now: now,
                minimumStableInterval: minimumStableInterval
            )
        return MissionControlPreviewColdConfirmationObservation(
            evidence: evidence,
            isConfirmed: semanticConfirmation || continuousOcclusionConfirmation
        )
    }
}

enum PreviewOccluderSemanticClassification: Equatable {
    case qualified
    case auxiliary
    case unknown
}

struct PreviewGroupVisibilityMember: Equatable {
    let selection: WindowServerSelectionSnapshot
    /// Unexpanded normal-desktop geometry. The shared Window Server snapshot
    /// intentionally retains its historical 1 pt tolerance; Preview uses the
    /// managed member frame to avoid turning that shared tolerance into a
    /// cross-display occlusion.
    let frame: CGRect
}

enum PreviewGroupPhysicalVisibilityEvaluation: Equatable {
    case visibleTop
    case occluded(candidates: [WindowServerSelectionSnapshot])
    case notVisible
    case indeterminate
}

enum PreviewGroupVisibilityEvaluation: Equatable {
    case hot
    case occluded(
        candidate: WindowServerSelectionSnapshot,
        semantic: PreviewOccluderSemanticClassification
    )
    case coldNotVisible
    case indeterminate
}

enum PreviewGroupVisibilityPolicy {
    /// Preview alone needs member-relative z-order. Foreground, raise and
    /// resize safety continue to use GroupFrontmostEvaluationPolicy.
    static func physicalEvaluation(
        members: [PreviewGroupVisibilityMember],
        displayFrame: CGRect,
        snapshot: [WindowOcclusionSnapshot],
        completeness: WindowDiscoveryCompleteness
    ) -> PreviewGroupPhysicalVisibilityEvaluation {
        guard completeness == .complete,
              !members.isEmpty,
              displayFrame.width > 1,
              displayFrame.height > 1 else {
            return .indeterminate
        }

        let memberSelections = members.map(\.selection)
        guard Set(memberSelections).count == members.count else {
            return .indeterminate
        }
        let memberBySelection = Dictionary(
            uniqueKeysWithValues: zip(memberSelections, members)
        )
        let physicalMembers = snapshot.filter { surface in
            surface.layer == 0
                && memberBySelection[selection(for: surface)] != nil
        }
        guard !physicalMembers.isEmpty else { return .notVisible }
        guard physicalMembers.count == members.count else {
            return .indeterminate
        }

        let memberSelectionSet = Set(memberBySelection.keys)
        let candidates = snapshot.compactMap { surface
            -> WindowServerSelectionSnapshot? in
            let surfaceSelection = selection(for: surface)
            guard surface.layer == 0,
                  !memberSelectionSet.contains(surfaceSelection) else {
                return nil
            }
            let clippedCandidate = surface.frame.intersection(displayFrame)
            guard !clippedCandidate.isNull,
                  clippedCandidate.width > 1,
                  clippedCandidate.height > 1 else { return nil }

            let occludesMember = physicalMembers.contains { physicalMember in
                guard surface.zIndex < physicalMember.zIndex,
                      let member = memberBySelection[
                        selection(for: physicalMember)
                      ] else { return false }
                let clippedMember = member.frame.intersection(displayFrame)
                guard !clippedMember.isNull else { return false }
                let intersection = clippedMember.intersection(clippedCandidate)
                return !intersection.isNull
                    && intersection.width > 1
                    && intersection.height > 1
            }
            return occludesMember ? surfaceSelection : nil
        }
        return candidates.isEmpty ? .visibleTop : .occluded(candidates: candidates)
    }

    static func evaluation(
        physical: PreviewGroupPhysicalVisibilityEvaluation,
        classification: (WindowServerSelectionSnapshot)
            -> PreviewOccluderSemanticClassification
    ) -> PreviewGroupVisibilityEvaluation {
        switch physical {
        case .visibleTop:
            return .hot
        case .notVisible:
            return .coldNotVisible
        case .indeterminate:
            return .indeterminate
        case .occluded(let candidates):
            var firstUnknown: WindowServerSelectionSnapshot?
            for candidate in candidates {
                switch classification(candidate) {
                case .qualified:
                    return .occluded(
                        candidate: candidate,
                        semantic: .qualified
                    )
                case .auxiliary:
                    continue
                case .unknown:
                    if firstUnknown == nil { firstUnknown = candidate }
                }
            }
            if let firstUnknown {
                return .occluded(
                    candidate: firstUnknown,
                    semantic: .unknown
                )
            }
            return .hot
        }
    }

    private static func selection(
        for surface: WindowOcclusionSnapshot
    ) -> WindowServerSelectionSnapshot {
        WindowServerSelectionSnapshot(
            pid: surface.pid,
            windowID: surface.windowID
        )
    }
}

enum MissionControlPreviewDisplayFairnessPolicy {
    /// Interleave displays while preserving deterministic order inside each.
    /// This prevents one busy display from occupying all four global slots.
    static func interleavedIndices<DisplayID: Hashable & Comparable>(
        displayIDs: [DisplayID]
    ) -> [Int] {
        var buckets: [DisplayID: [Int]] = [:]
        for (index, displayID) in displayIDs.enumerated() {
            buckets[displayID, default: []].append(index)
        }
        let orderedDisplays = buckets.keys.sorted()
        var result: [Int] = []
        var offset = 0
        while result.count < displayIDs.count {
            var appended = false
            for displayID in orderedDisplays {
                guard let bucket = buckets[displayID], offset < bucket.count
                else { continue }
                result.append(bucket[offset])
                appended = true
            }
            guard appended else { break }
            offset += 1
        }
        return result
    }

    /// Preserve FIFO order inside each display, then take one demand from each
    /// display per round. Newly generated work therefore cannot repeatedly
    /// overtake older groups, including groups sharing the same display.
    static func fairFIFOIndices<DisplayID: Hashable & Comparable>(
        displayIDs: [DisplayID],
        enqueueOrders: [UInt64]
    ) -> [Int] {
        guard displayIDs.count == enqueueOrders.count else { return [] }
        let fifoIndices = displayIDs.indices.sorted {
            if enqueueOrders[$0] != enqueueOrders[$1] {
                return enqueueOrders[$0] < enqueueOrders[$1]
            }
            return $0 < $1
        }
        let relativeIndices = interleavedIndices(
            displayIDs: fifoIndices.map { displayIDs[$0] }
        )
        return relativeIndices.map { fifoIndices[$0] }
    }
}

enum MissionControlPreviewAdmissionPolicy {
    static func allowsCapture(
        previewsEnabled: Bool,
        captureSuspended: Bool,
        desktopPresentationIsStable: Bool,
        byteBudget: Int,
        outstandingCount: Int,
        queuedOperationCount: Int,
        keyIsActive: Bool
    ) -> Bool {
        previewsEnabled
            && !captureSuspended
            && desktopPresentationIsStable
            && byteBudget > 0
            && outstandingCount
                < MissionControlPreviewWorkPolicy.maximumOutstandingCaptureCount
            && queuedOperationCount
                < MissionControlPreviewWorkPolicy.maximumQueuedOperationCount
            && keyIsActive
    }
}

enum MissionControlProxyStructuralUpdatePolicy {
    static func requiresOrderingRestart(
        lastFrame: CGRect?,
        newFrame: CGRect,
        lastMemberWindowIDs: Set<CGWindowID>,
        requiredMemberWindowIDs: Set<CGWindowID>?,
        presentationIsStableOrValidating: Bool
    ) -> Bool {
        guard let lastFrame,
              let requiredMemberWindowIDs,
              framesAreApproximatelyEqual(lastFrame, newFrame),
              lastMemberWindowIDs == requiredMemberWindowIDs,
              presentationIsStableOrValidating else {
            return true
        }
        return false
    }

    private static func framesAreApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }
}

struct MissionControlGroupProxyMember {
    let stableIdentity: String
    let frame: CGRect
    let preview: NSImage?
    let icon: NSImage?
}

struct MissionControlPreviewCacheKey: Hashable {
    let displayID: CGDirectDisplayID
    let pid: pid_t
    let windowID: CGWindowID
    let stableIdentity: String
    let frameMinX: Int
    let frameMinY: Int
    let frameWidth: Int
    let frameHeight: Int
}

private struct MissionControlCachedPreview {
    let image: NSImage
    let byteCost: Int
    var accessEpoch: UInt64
}

private struct MissionControlPreviewRequest {
    let generation: UInt64
    let geometryRevision: UInt64
    let coldAuthorizationRevision: UInt64?
    let reason: MissionControlPreviewTriggerReason
    var retryRemaining: Bool
}

private struct MissionControlPendingPreviewResult {
    let preview: MissionControlCachedPreview
    let reason: MissionControlPreviewTriggerReason
    let geometryRevision: UInt64
    let coldAuthorizationRevision: UInt64?
}

struct MissionControlPreviewGeometryConfirmationCandidate {
    let key: MissionControlPreviewCacheKey
    var observationCount: Int
    let firstObservedAt: TimeInterval

    mutating func advance(
        matching currentKey: MissionControlPreviewCacheKey,
        now: TimeInterval
    ) -> Bool? {
        // Translation does not change captured pixels or restart size/display
        // settlement. Requiring the full cache key here can strand this debt
        // because the observation fallback deliberately ignores position.
        guard MissionControlGroupProxyController.canReuseCapturedPixels(
            from: key, for: currentKey
        ) else { return nil }
        observationCount = MissionControlPreviewTriggerPolicy
            .nextStableObservationCount(
                previousCount: observationCount,
                representsSameCandidate: true
            )
        return MissionControlPreviewTriggerPolicy.isConfirmed(
            observationCount: observationCount,
            firstObservedAt: firstObservedAt,
            now: now,
            minimumStableInterval:
                MissionControlPreviewWorkPolicy.confirmationInterval
        )
    }
}

final class MissionControlGroupProxyController {
    typealias PreviewCaptureAuthorization = () -> Bool
    typealias PreviewProvider = (
        CGWindowID?,
        @escaping PreviewCaptureAuthorization
    ) -> CGImage?
    var onSelectGroup: ((SnapGroupID, Set<String>) -> Void)?
    var onSelectQueuedMigrationGroup: ((SnapGroupID, Set<String>) -> Void)?
    var onSelectionConfirmationTerminated: (() -> Void)?
    var currentTransitionAuthorization: ((SnapGroupID) -> Bool)?
    var selectionConfirmationIsAllowed: ((SnapGroupID) -> Bool)?
    var queuedMigrationSelectionIsAllowed: ((SnapGroupID) -> Bool)?
    var onPreviewCacheReady: (() -> Void)?
    var onPreviewConfirmationNeeded: (() -> Void)?

    private var windowsByGroupID: [SnapGroupID: MissionControlGroupProxyWindow] = [:]
    private var cachedPreviews: [MissionControlPreviewCacheKey:
        MissionControlCachedPreview] = [:]
    private var previewAccessEpoch: UInt64 = 0
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Tabora.MissionControlPreview"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var previewRequestsByKey =
        [MissionControlPreviewCacheKey: MissionControlPreviewRequest]()
    private var pendingPreviewResults =
        [MissionControlPreviewCacheKey: MissionControlPendingPreviewResult]()
    private var previewCaptureGeneration: UInt64 = 0
    private var previewsAreEnabled = true
    private var previewCaptureIsSuspended = false
    private var desktopPresentationIsStable = true
    private var hasPendingPreviewCacheApplication = false
    private var previewCacheRefreshNotificationScheduled = false
    private var maximumCachedPreviewBytes = AppSettings
        .missionControlPreviewMemoryByteLimit(
            AppSettings.defaultMissionControlPreviewMemoryLimitMiB
        )
    private var activePreviewKeys = Set<MissionControlPreviewCacheKey>()
    // Structural membership owns finite Preview debt. AX/CG presentability only
    // decides whether that debt can run now; a transient census omission must
    // never manufacture a new member or erase already-authorized work.
    private var structuralPreviewMemberIDs = Set<String>()
    private var knownPreviewMemberIDs = Set<String>()
    private var hotPreviewGroupIDs = Set<SnapGroupID>()
    private var coldVisiblePreviewGroupIDs = Set<SnapGroupID>()
    private var coldNotVisiblePreviewGroupIDs = Set<SnapGroupID>()
    private var coldConfirmationEvidenceByGroupID:
        [SnapGroupID: MissionControlPreviewColdConfirmationEvidence] = [:]
    private var physicalFallbackCandidateByGroupID:
        [SnapGroupID: WindowServerSelectionSnapshot] = [:]
    private var pendingCaptureReasons:
        [MissionControlPreviewCacheKey: MissionControlPreviewTriggerReason] = [:]
    private var pendingCaptureEnqueueOrders:
        [MissionControlPreviewCacheKey: UInt64] = [:]
    private var deferredCaptureReasonsByMemberID:
        [String: MissionControlPreviewTriggerReason] = [:]
    private var deferredCaptureEnqueueOrdersByMemberID: [String: UInt64] = [:]
    private var nextPendingCaptureEnqueueOrder: UInt64 = 0
    // Observation fallback exists only for geometry changes that do not cross a
    // Tabora transaction boundary (for example, app/OS-owned resize). It is one
    // candidate per structural member and never reacts to position-only motion.
    private var geometryConfirmationCandidates:
        [String: MissionControlPreviewGeometryConfirmationCandidate] = [:]
    private var lastCaptureAtByPhysicalIdentity: [String: TimeInterval] = [:]
    private var geometryRevisionByPhysicalIdentity: [String: UInt64] = [:]
    // Unlike generation cancellation, this revokes only obsolete COLD work for
    // one structural member. Initial and geometry-triggered captures remain
    // valid when a Group becomes HOT or leaves the visible desktop.
    private var coldCaptureAuthorizationRevisionByMemberID: [String: UInt64] = [:]
    private var confirmationGeneration: UInt64 = 0
    private var confirmationRefreshIsScheduled = false
    private var cooldownGeneration: UInt64 = 0
    private var cooldownRefreshIsScheduled = false
    private var cooldownRefreshDeadline: TimeInterval?
    private var activePreviewByteBudget = 0
    private var latestPreviewProvider: PreviewProvider?
    private var latestTransientPreviewProvider:
        MissionControlTransientPreviewCapturer.PreviewProvider?
    // Mission Control-only snapshots never enter the normal Preview cache.
    // Their sole ownership is the current transform session.
    private var transientPreviewPlansByGroupID:
        [SnapGroupID: MissionControlTransientPreviewGroupPlan] = [:]
    // Optional transient work is stricter than normal HOT persistence. Only a
    // complete current WindowServer observation proving the whole Group frontmost
    // may authorize it; Mission Control entry then freezes that atomic group set.
    private var transientAuthorizedHotGroupIDs = Set<SnapGroupID>()
    private var transientPreviewSessionPlansByGroupID:
        [SnapGroupID: MissionControlTransientPreviewGroupPlan] = [:]
    private var transientPreviewSessionGeneration: UInt64 = 0
    private var transientPreviewTargetGroupIDs = Set<SnapGroupID>()
    private var transientTransformObservationCount = 0
    private var transientTransformFirstObservedAt: TimeInterval?
    private var transientLastTransformFingerprint:
        MissionControlTransientTransformFingerprint?
    private var transientCaptureHasStarted = false
    private var transientPreviewAppliedGroupIDs = Set<SnapGroupID>()
    private let transientPreviewCapturer = MissionControlTransientPreviewCapturer()
    private var selectionCandidateGeneration: UInt64 = 0
    private var activeSelectionCandidate: MissionControlProxySelectionCandidate?

    var hasPendingSelectionConfirmation: Bool {
        activeSelectionCandidate != nil
            || windowsByGroupID.values.contains {
                $0.isSelectionConfirmationPending
            }
    }

    var selectionConfirmationOwnerGroupID: SnapGroupID? {
        activeSelectionCandidate?.groupID
    }

    /// Once the bounded UNKNOWN fallback has accepted one exact physical
    /// candidate, repeated Recovery ticks need not repeat the same failed AX
    /// query. A different candidate is always classified normally.
    func previewOccluderClassificationIsNeeded(
        for groupID: SnapGroupID,
        candidate: WindowServerSelectionSnapshot
    ) -> Bool {
        physicalFallbackCandidateByGroupID[groupID] != candidate
    }

    func update(
        groups: [SnapGroup],
        visibleWindowsByIdentity: [String: ManagedWindow],
        displayOrdinalsByGroupID: [SnapGroupID: Int],
        preservedGroupIDs: Set<SnapGroupID> = [],
        structuralGroupIDs: Set<SnapGroupID>,
        structuralMemberIDs: Set<String>,
        structuralMemberIDsByGroupID: [SnapGroupID: Set<String>],
        previewVisibilityEvaluationByGroupID:
            [SnapGroupID: PreviewGroupVisibilityEvaluation] = [:],
        previewsEnabled: Bool,
        previewCacheByteLimit: Int,
        previewProvider: @escaping PreviewProvider,
        transientPreviewProvider: @escaping MissionControlTransientPreviewCapturer.PreviewProvider
    ) {
        setPreviewCacheByteLimit(previewCacheByteLimit)
        structuralPreviewMemberIDs = structuralMemberIDs
        setPreviewsEnabled(previewsEnabled)
        let presentableGroups = groups.filter { group in
            group.memberIDs.count >= 2
                && group.memberIDs.allSatisfy {
                    visibleWindowsByIdentity[$0] != nil
                }
        }
        let activeGroupIDs = Set(presentableGroups.map(\.id))
            .union(preservedGroupIDs)
        if transientPreviewTargetGroupIDs.isEmpty {
            transientPreviewPlansByGroupID = transientPreviewPlansByGroupID
                .filter { activeGroupIDs.contains($0.key) }
        }
        // Ordering scope is independent from Preview capture. Keep the full
        // presentable member set even though Preview keys are now built through
        // previewKeyByMemberID below.
        let activeWindows = presentableGroups.flatMap { group in
            group.memberIDs.compactMap { visibleWindowsByIdentity[$0] }
        }
        let previewKeyByMemberID = Dictionary(
            presentableGroups.flatMap { group in
                group.memberIDs.compactMap { memberID
                    -> (String, MissionControlPreviewCacheKey)? in
                    guard let window = visibleWindowsByIdentity[memberID],
                          let windowID = window.cgWindowID else { return nil }
                    return (
                        memberID,
                        Self.previewCacheKey(
                            for: window,
                            windowID: windowID,
                            displayID: group.displayID
                        )
                    )
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let currentPreviewKeys = Set(previewKeyByMemberID.values)
        let previewKeysByGroupID = Dictionary(
            uniqueKeysWithValues: presentableGroups.map { group in
                let keys = Set(group.memberIDs.compactMap { memberID in
                    previewKeyByMemberID[memberID]
                })
                return (group.id, keys)
            }
        )
        // Split the existing bounded preview budget across every currently
        // presentable member, not across a hard-coded layout count. This keeps
        // 2 / 3 / 4 and multiple independent groups on the same policy while
        // allowing normal-size windows to retain substantially more detail
        // than the old fixed 720x480 cap.
        let previewByteBudget = MissionControlPreviewSizingPolicy
            .perImageByteBudget(
                totalByteBudget: maximumCachedPreviewBytes,
                presentableMemberCount: currentPreviewKeys.count
            )
        if previewsEnabled {
            let activityNow = ProcessInfo.processInfo.systemUptime
            let previousActivePreviewKeys = activePreviewKeys
            let perImageBudgetBecameSmaller = activePreviewByteBudget > 0
                && previewByteBudget < activePreviewByteBudget
            activePreviewKeys = currentPreviewKeys
            activePreviewByteBudget = previewByteBudget
            latestPreviewProvider = previewProvider
            latestTransientPreviewProvider = transientPreviewProvider
            // A frame-only key change must not turn a structurally known member
            // into a new member and start an unbounded sequence of captures. Carry
            // its derived image to the new key; committed size/display mutations
            // receive one explicit geometry debt from their transaction owner.
            for key in currentPreviewKeys where cachedPreviews[key] == nil {
                if let previous = cachedPreviews.first(where: {
                    Self.representsSamePhysicalWindow($0.key, key)
                })?.value {
                    cachedPreviews[key] = previous
                }
            }
            for key in currentPreviewKeys {
                if let previousPending = pendingCaptureReasons.first(where: {
                    Self.representsSamePhysicalWindow($0.key, key)
                        && $0.key != key
                }) {
                    enqueueCapture(
                        key: key,
                        reason: previousPending.value
                    )
                }
            }
            // Keep one current key for each presentable member, while allowing
            // a temporarily absent structural member to retain its last bounded
            // image. This avoids both AX-gap data loss and stale frame-key
            // accumulation when ordinary ordering/position observations change.
            let presentablePreviewMemberIDs = Set(
                currentPreviewKeys.map(\.stableIdentity)
            )
            cachedPreviews = cachedPreviews.filter { entry in
                guard structuralPreviewMemberIDs.contains(
                    entry.key.stableIdentity
                ) else { return false }
                if presentablePreviewMemberIDs.contains(
                    entry.key.stableIdentity
                ) {
                    return currentPreviewKeys.contains(entry.key)
                }
                return true
            }
            reconcileDeferredPreviewDebt(currentPreviewKeys: currentPreviewKeys)
            advanceGeometryConfirmations(
                currentPreviewKeys: currentPreviewKeys,
                now: activityNow
            )
            // Explicit Tabora transactions own their geometry debt directly.
            // This fallback restores only the pre-existing safety net for
            // app/OS-owned size or display changes. Position-only movement is
            // ignored, and repeated resize samples replace one candidate.
            for key in currentPreviewKeys {
                guard let previousKey = previousActivePreviewKeys.first(where: {
                    Self.representsSamePhysicalWindow($0, key) && $0 != key
                }) else { continue }
                let sizeChanged = previousKey.frameWidth != key.frameWidth
                    || previousKey.frameHeight != key.frameHeight
                let displayChanged = previousKey.displayID != key.displayID
                guard MissionControlPreviewTriggerPolicy
                    .shouldObserveGeometryFallback(
                        sizeChanged: sizeChanged,
                        displayChanged: displayChanged,
                        hasOutstandingCurrentGeometryWork:
                            hasOutstandingCurrentGeometryWork(for: key)
                    ) else { continue }
                observeGeometryCandidate(key, now: activityNow)
            }
            updatePreviewActivity(
                currentPreviewKeys: currentPreviewKeys,
                previewKeysByGroupID: previewKeysByGroupID,
                structuralGroupIDs: structuralGroupIDs,
                structuralMemberIDsByGroupID: structuralMemberIDsByGroupID,
                visibilityEvaluationByGroupID:
                    previewVisibilityEvaluationByGroupID
            )
            // Activity must revoke an old visible epoch before completed COLD
            // pixels are validated. Otherwise a not-visible/HOT observation
            // and an already-finished capture could race within this main-thread
            // update and commit in the wrong order.
            commitValidatedPreviewResults(
                currentPreviewKeys: currentPreviewKeys
            )
            if desktopPresentationIsStable {
                transientAuthorizedHotGroupIDs =
                    MissionControlTransientPreviewEligibilityPolicy
                        .authorizedHotGroupIDs(
                            currentGroupIDs: Set(previewKeysByGroupID.keys),
                            currentEvaluationByGroupID:
                                previewVisibilityEvaluationByGroupID
                        )
            }
            if perImageBudgetBecameSmaller {
                // Budget changes are cache-management work, not WindowServer
                // freshness work. Re-encode locally instead of recapturing every
                // active member merely because another group appeared.
                reencodeCachedPreviewsForActiveBudget()
            }
            schedulePriorityPreviewCaptures(
                now: activityNow,
                previewProvider: previewProvider
            )
        }
        for groupID in Array(windowsByGroupID.keys) where
            !activeGroupIDs.contains(groupID) {
            guard windowsByGroupID[groupID]?.allowsPresentationMutation
                    != false else {
                // A click-confirmation lease owns this exact proxy for one
                // bounded turn. Structural validation still occurs before the
                // callback can authorize real windows.
                continue
            }
            transientPreviewAppliedGroupIDs.remove(groupID)
            windowsByGroupID.removeValue(forKey: groupID)?.retire()
        }

        for group in presentableGroups {
            guard let displayOrdinal = displayOrdinalsByGroupID[group.id]
            else { continue }
            let memberWindows = group.memberIDs.compactMap {
                visibleWindowsByIdentity[$0]
            }
            guard let first = memberWindows.first else { continue }
            let bounds = memberWindows.dropFirst().reduce(first.frame) {
                $0.union($1.frame)
            }
            guard bounds.width > 1, bounds.height > 1 else {
                transientPreviewAppliedGroupIDs.remove(group.id)
                windowsByGroupID.removeValue(forKey: group.id)?.retire()
                continue
            }

            let proxyWindow: MissionControlGroupProxyWindow
            if let existing = windowsByGroupID[group.id] {
                proxyWindow = existing
            } else {
                proxyWindow = MissionControlGroupProxyWindow()
                windowsByGroupID[group.id] = proxyWindow
            }
            proxyWindow.groupID = group.id
            proxyWindow.presentedMemberIDs = group.memberIDs
            proxyWindow.beginSelectionConfirmation = {
                [weak self] groupID, memberIDs in
                self?.beginSelectionConfirmation(
                    groupID: groupID,
                    memberIDs: memberIDs
                ) ?? 0
            }
            proxyWindow.consumeSelectionConfirmation = {
                [weak self] generation, groupID, memberIDs in
                self?.consumeSelectionConfirmation(
                    generation: generation,
                    groupID: groupID,
                    memberIDs: memberIDs
                ) ?? .rejected
            }
            proxyWindow.releaseSelectionConfirmation = {
                [weak self] generation, groupID, memberIDs in
                self?.releaseSelectionConfirmation(
                    generation: generation,
                    groupID: groupID,
                    memberIDs: memberIDs
                )
            }
            proxyWindow.onSelectionConfirmationTerminated = { [weak self] in
                self?.onSelectionConfirmationTerminated?()
            }
            proxyWindow.currentTransitionAuthorization = { [weak self] groupID in
                self?.currentTransitionAuthorization?(groupID) ?? false
            }
            proxyWindow.onSelected = { [weak self] groupID, memberIDs in
                self?.onSelectGroup?(groupID, memberIDs)
            }
            proxyWindow.onQueuedMigrationSelected = {
                [weak self] groupID, memberIDs in
                self?.onSelectQueuedMigrationGroup?(groupID, memberIDs)
            }
            if transientPreviewTargetGroupIDs.isEmpty,
               memberWindows.allSatisfy({ $0.cgWindowID != nil }) {
                let sourceMembers = memberWindows.compactMap { window
                    -> MissionControlTransientPreviewMemberPlan? in
                    guard let windowID = window.cgWindowID else { return nil }
                    let relativeFrame = window.frame.offsetBy(
                        dx: -bounds.minX,
                        dy: -bounds.minY
                    )
                    return MissionControlTransientPreviewMemberPlan(
                        stableIdentity: window.stableIdentity,
                        pid: window.pid,
                        windowID: windowID,
                        relativeFrame: relativeFrame,
                        targetPixelSize: MissionControlPreviewPixelSize(
                            width: max(Int((relativeFrame.width * 2).rounded()), 1),
                            height: max(Int((relativeFrame.height * 2).rounded()), 1)
                        ),
                        byteBudget: .max
                    )
                }
                if sourceMembers.count == memberWindows.count {
                    transientPreviewPlansByGroupID[group.id] =
                        MissionControlTransientPreviewGroupPlan(
                            groupID: group.id,
                            groupRevision: group.revision,
                            displayID: group.displayID,
                            proxyFrame: bounds,
                            members: sourceMembers.sorted {
                                $0.stableIdentity < $1.stableIdentity
                            }
                        )
                }
            }
            let members = memberWindows.map { window in
                MissionControlGroupProxyMember(
                    stableIdentity: window.stableIdentity,
                    frame: window.frame.offsetBy(
                        dx: -bounds.minX,
                        dy: -bounds.minY
                    ),
                    preview: previewsEnabled ? previewImage(
                        for: window,
                        displayID: group.displayID
                    ) : nil,
                    icon: window.appIcon
                )
            }
            let orderingSurfaces = activeWindows.map { window in
                MissionControlProxyOrderingSurface(
                    windowID: window.cgWindowID,
                    frame: window.frame,
                    belongsToTargetGroup: group.memberIDs.contains(
                        window.stableIdentity
                    )
                )
            }
            let requiredWindowIDs = MissionControlProxyOrderingScopePolicy
                .requiredWindowIDs(
                    proxyFrame: bounds,
                    surfaces: orderingSurfaces
                )
            proxyWindow.update(
                title: L10n.format("group.number", displayOrdinal),
                frame: bounds,
                members: members,
                requiredWindowIDs: requiredWindowIDs
            )
        }
        hasPendingPreviewCacheApplication = false
    }

    var hasTransientPreviewSession: Bool {
        !transientPreviewTargetGroupIDs.isEmpty
            || transientCaptureHasStarted
            || !transientPreviewAppliedGroupIDs.isEmpty
    }

    var transientPreviewSessionNeedsStabilityObservation: Bool {
        !transientPreviewTargetGroupIDs.isEmpty && !transientCaptureHasStarted
    }

    func beginTransientPreviewSession(targetGroupIDs: Set<SnapGroupID>) {
        guard previewsAreEnabled,
              !previewCaptureIsSuspended,
              transientPreviewTargetGroupIDs.isEmpty,
              transientPreviewAppliedGroupIDs.isEmpty else { return }
        let eligiblePlans = targetGroupIDs.compactMap { groupID
            -> (SnapGroupID, MissionControlTransientPreviewGroupPlan)? in
            guard transientAuthorizedHotGroupIDs.contains(groupID),
                  let plan = transientPreviewPlansByGroupID[groupID],
                  !plan.members.isEmpty,
                  windowsByGroupID[groupID] != nil else { return nil }
            return (groupID, plan)
        }
        guard !eligiblePlans.isEmpty else { return }
        transientPreviewSessionGeneration &+= 1
        transientPreviewSessionPlansByGroupID = Dictionary(
            uniqueKeysWithValues: eligiblePlans
        )
        transientPreviewTargetGroupIDs = Set(
            transientPreviewSessionPlansByGroupID.keys
        )
        transientTransformObservationCount = 0
        transientTransformFirstObservedAt = nil
        transientLastTransformFingerprint = nil
        transientCaptureHasStarted = false
        // Invalidates an accepted result from a previous logical session. The
        // capturer's physical single-flight gate remains closed until any
        // already-issued direct-window capture has actually quiesced.
        transientPreviewCapturer.cancel()
    }

    func noteTransientMissionControlTransformObservation(
        windowServerSnapshot: [WindowOcclusionSnapshot],
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !transientPreviewTargetGroupIDs.isEmpty,
              !transientCaptureHasStarted else { return }
        let targetWindowIDs = Set(
            transientPreviewTargetGroupIDs.flatMap { groupID in
                transientPreviewSessionPlansByGroupID[groupID]?.members
                    .map(\.windowID)
                    ?? []
            }
        )
        guard !targetWindowIDs.isEmpty else { return }
        let framePairs = windowServerSnapshot.compactMap { observation
            -> (CGWindowID, CGRect)? in
            guard observation.layer == 0,
                  targetWindowIDs.contains(observation.windowID) else {
                return nil
            }
            return (observation.windowID, observation.frame)
        }
        let observedWindowIDs = Set(framePairs.map(\.0))
        guard framePairs.count == targetWindowIDs.count,
              observedWindowIDs == targetWindowIDs else {
            transientTransformObservationCount = 0
            transientTransformFirstObservedAt = nil
            transientLastTransformFingerprint = nil
            return
        }
        let frames = Dictionary(
            framePairs,
            uniquingKeysWith: { first, _ in first }
        )
        let fingerprint = MissionControlTransientTransformFingerprint(
            framesByWindowID: frames
        )
        if let previous = transientLastTransformFingerprint,
           MissionControlTransientTransformStabilityPolicy
            .representsSameSettledGeometry(previous, fingerprint) {
            transientTransformObservationCount += 1
        } else {
            transientTransformObservationCount = 1
            transientTransformFirstObservedAt = now
            transientLastTransformFingerprint = fingerprint
        }
        guard transientTransformObservationCount
                >= MissionControlTransientTransformStabilityPolicy
                    .requiredStableObservations,
              let firstObservedAt = transientTransformFirstObservedAt,
              now - firstObservedAt
                >= MissionControlTransientTransformStabilityPolicy
                    .minimumStableInterval else { return }
        startTransientPreviewCapture()
    }

    func endTransientPreviewSession(
        preservingAppliedGroupIDs preservedGroupIDs: Set<SnapGroupID> = []
    ) {
        guard hasTransientPreviewSession else { return }
        transientPreviewSessionGeneration &+= 1
        transientPreviewCapturer.cancel()
        transientPreviewTargetGroupIDs.removeAll()
        transientPreviewSessionPlansByGroupID.removeAll()
        transientTransformObservationCount = 0
        transientTransformFirstObservedAt = nil
        transientLastTransformFingerprint = nil
        transientCaptureHasStarted = false

        let discardGroupIDs = transientPreviewAppliedGroupIDs
            .subtracting(preservedGroupIDs)
        for groupID in discardGroupIDs {
            windowsByGroupID[groupID]?.discardTransientPreviews()
        }
        transientPreviewAppliedGroupIDs.formIntersection(preservedGroupIDs)
    }

    private func startTransientPreviewCapture() {
        guard !transientCaptureHasStarted else { return }
        let generation = transientPreviewSessionGeneration
        let targetPlans = transientPreviewTargetGroupIDs.compactMap {
            transientPreviewSessionPlansByGroupID[$0]
        }
        let totalBudget = MissionControlTransientPreviewPolicy.byteLimit(
            normalPreviewByteLimit: maximumCachedPreviewBytes
        )
        let admittedPlans = MissionControlTransientPreviewPolicy.admittedPlans(
            targetPlans,
            totalByteBudget: totalBudget
        )
        let memberCount = admittedPlans.reduce(0) { $0 + $1.members.count }
        let perImageBudget = MissionControlPreviewSizingPolicy
            .perImageByteBudget(
                totalByteBudget: totalBudget,
                presentableMemberCount: memberCount
            )
        guard perImageBudget > 0, !admittedPlans.isEmpty else {
            // No amount of retrying this exact session can create budget.
            transientCaptureHasStarted = true
            return
        }
        let plans = admittedPlans.compactMap { plan
            -> MissionControlTransientPreviewGroupPlan? in
            let members = plan.members.compactMap { member
                -> MissionControlTransientPreviewMemberPlan? in
                let sourceWidth = max(
                    Int((member.relativeFrame.width * 2).rounded()), 1
                )
                let sourceHeight = max(
                    Int((member.relativeFrame.height * 2).rounded()), 1
                )
                guard let target = MissionControlPreviewSizingPolicy
                    .targetPixelSize(
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        byteBudget: perImageBudget
                    ) else { return nil }
                return MissionControlTransientPreviewMemberPlan(
                    stableIdentity: member.stableIdentity,
                    pid: member.pid,
                    windowID: member.windowID,
                    relativeFrame: member.relativeFrame,
                    targetPixelSize: target,
                    byteBudget: perImageBudget
                )
            }
            guard members.count == plan.members.count else { return nil }
            return MissionControlTransientPreviewGroupPlan(
                groupID: plan.groupID,
                groupRevision: plan.groupRevision,
                displayID: plan.displayID,
                proxyFrame: plan.proxyFrame,
                members: members
            )
        }

        guard let previewProvider = latestTransientPreviewProvider else {
            return
        }
        let admitted = transientPreviewCapturer.capture(
            generation: generation,
            plans: plans,
            previewProvider: previewProvider,
            onGroupReady: { [weak self] result in
                self?.applyTransientPreviewResult(
                    result,
                    generation: generation
                )
            },
            onFinished: {}
        )
        // A false result means a canceled physical request from a previous MC
        // session has not quiesced yet. Leave the logical gate open so the
        // existing bounded transform-recovery observations may retry.
        if admitted {
            transientCaptureHasStarted = true
        }
    }

    private func applyTransientPreviewResult(
        _ result: MissionControlTransientPreviewGroupResult,
        generation: UInt64
    ) {
        guard generation == transientPreviewSessionGeneration,
              transientPreviewTargetGroupIDs.contains(result.groupID),
              !desktopPresentationIsStable,
              !CGEventSource.buttonState(
                  .combinedSessionState,
                  button: .left
              ),
              previewsAreEnabled,
              let plan = transientPreviewSessionPlansByGroupID[result.groupID],
              plan.groupRevision == result.groupRevision,
              result.previewsByMemberID.count == plan.members.count,
              let window = windowsByGroupID[result.groupID],
              window.allowsTransientPreviewMutation else { return }
        let stableMemberIDs = Set(plan.members.map(\.stableIdentity))
        guard stableMemberIDs.count == plan.members.count else { return }
        let frames = Dictionary(
            plan.members.map { ($0.stableIdentity, $0.relativeFrame) },
            uniquingKeysWith: { first, _ in first }
        )
        let previewPairs = plan.members.compactMap { member
            -> (String, NSImage)? in
            guard let image = result.previewsByMemberID[
                member.stableIdentity
            ] else { return nil }
            return (
                member.stableIdentity,
                NSImage(
                    cgImage: image,
                    size: member.relativeFrame.size
                )
            )
        }
        let previews = Dictionary(
            previewPairs,
            uniquingKeysWith: { first, _ in first }
        )
        guard previews.count == plan.members.count else { return }
        if window.applyTransientPreviews(
            previews,
            expectedFramesByMemberID: frames
        ) {
            transientPreviewAppliedGroupIDs.insert(result.groupID)
        }
    }

    var hasPresentationRecoveryDebt: Bool {
        windowsByGroupID.values.contains { $0.needsPresentationRecovery }
    }

    var hasPendingPreviewCacheRefresh: Bool {
        hasPendingPreviewCacheApplication
    }

    func hasPresentation(for groupID: SnapGroupID) -> Bool {
        windowsByGroupID[groupID] != nil
    }

    func spaceDescriptor(
        for groupID: SnapGroupID
    ) -> GroupSpaceProxyDescriptor? {
        guard let window = windowsByGroupID[groupID],
              window.presentedMemberIDs.count >= 2,
              window.windowNumber > 0 else { return nil }
        return GroupSpaceProxyDescriptor(
            groupID: groupID,
            memberIDs: window.presentedMemberIDs,
            windowID: CGWindowID(window.windowNumber),
            frame: window.frame
        )
    }

    func retireForSpaceMigration(groupID: SnapGroupID) {
        transientPreviewAppliedGroupIDs.remove(groupID)
        windowsByGroupID.removeValue(forKey: groupID)?.retire()
        if activeSelectionCandidate?.groupID == groupID {
            activeSelectionCandidate = nil
        }
    }

    func markSpaceMigrationQueued(groupID: SnapGroupID) {
        windowsByGroupID[groupID]?.setSpaceMigrationQueued(
            position: 1,
            total: 1
        )
        if activeSelectionCandidate?.groupID == groupID {
            activeSelectionCandidate = nil
        }
    }

    func updateSpaceMigrationQueuePresentation(
        groupID: SnapGroupID,
        position: Int,
        total: Int
    ) {
        windowsByGroupID[groupID]?.setSpaceMigrationQueued(
            position: position,
            total: total
        )
    }

    func restoreAfterSpaceMigrationSourceCancellation(
        groupID: SnapGroupID
    ) {
        windowsByGroupID[groupID]?
            .restoreAfterSpaceMigrationSourceCancellation()
        if activeSelectionCandidate?.groupID == groupID {
            activeSelectionCandidate = nil
        }
    }

    func hideAll(clearPreviewCache: Bool = false) {
        endTransientPreviewSession()
        for window in windowsByGroupID.values {
            window.retire()
        }
        windowsByGroupID.removeAll()
        activeSelectionCandidate = nil
        if clearPreviewCache {
            self.clearPreviewCache()
        }
    }

    /// Retires presentation that is unrelated to the exact Mission Control
    /// selection handoff. Unlike hideAll(), this preserves the selected
    /// managed surface and its candidate generation across Active Space
    /// publication while still removing every unowned proxy immediately.
    func retireUnownedProxies(
        preservingGroupIDs preservedGroupIDs: Set<SnapGroupID>
    ) {
        for groupID in Array(windowsByGroupID.keys) where
            !preservedGroupIDs.contains(groupID) {
            transientPreviewAppliedGroupIDs.remove(groupID)
            windowsByGroupID.removeValue(forKey: groupID)?.retire()
        }
        if let candidate = activeSelectionCandidate,
           !preservedGroupIDs.contains(candidate.groupID) {
            activeSelectionCandidate = nil
        }
    }

    func setPreviewCacheByteLimit(_ byteLimit: Int) {
        let normalized = max(byteLimit, 0)
        guard maximumCachedPreviewBytes != normalized else { return }
        endTransientPreviewSession()
        maximumCachedPreviewBytes = normalized
        clearPreviewCache()
        // clearPreviewCache() rebuilds every non-resizing active member once;
        // a geometry candidate retains ownership of a concurrent resize.
    }

    /// Applies user authorization independently of proxy presentation. This is
    /// intentionally callable even while Snap/Assist owns the UI and normal
    /// proxy refresh is suppressed.
    func setPreviewsEnabled(_ enabled: Bool) {
        guard previewsAreEnabled != enabled else { return }
        if !enabled { endTransientPreviewSession() }
        previewCaptureGeneration &+= 1
        previewsAreEnabled = enabled
        previewQueue.cancelAllOperations()
        let interrupted = previewRequestsByKey
        previewRequestsByKey.removeAll()
        if enabled {
            for (key, request) in interrupted where activePreviewKeys.contains(key) {
                enqueueCapture(key: key, reason: request.reason)
            }
            enqueueCapture(keys: activePreviewKeys, reason: .initial)
            return
        }
        cachedPreviews.removeAll()
        pendingPreviewResults.removeAll()
        activePreviewKeys.removeAll()
        structuralPreviewMemberIDs.removeAll()
        knownPreviewMemberIDs.removeAll()
        hotPreviewGroupIDs.removeAll()
        coldVisiblePreviewGroupIDs.removeAll()
        coldNotVisiblePreviewGroupIDs.removeAll()
        coldConfirmationEvidenceByGroupID.removeAll()
        physicalFallbackCandidateByGroupID.removeAll()
        geometryConfirmationCandidates.removeAll()
        transientAuthorizedHotGroupIDs.removeAll()
        pendingCaptureReasons.removeAll()
        pendingCaptureEnqueueOrders.removeAll()
        deferredCaptureReasonsByMemberID.removeAll()
        deferredCaptureEnqueueOrdersByMemberID.removeAll()
        lastCaptureAtByPhysicalIdentity.removeAll()
        geometryRevisionByPhysicalIdentity.removeAll()
        coldCaptureAuthorizationRevisionByMemberID.removeAll()
        cancelConfirmationRefresh()
        cancelCooldownRefresh()
        activePreviewByteBudget = 0
        latestPreviewProvider = nil
        latestTransientPreviewProvider = nil
        hasPendingPreviewCacheApplication = false
        previewCacheRefreshNotificationScheduled = false
    }

    func clearPreviewCache() {
        // A user-requested Preview cache purge is also an ownership boundary
        // for Mission Control-only pixels. Do not let a separately-budgeted
        // transient image survive an explicit clear operation.
        endTransientPreviewSession()
        previewCaptureGeneration &+= 1
        previewQueue.cancelAllOperations()
        cachedPreviews.removeAll()
        pendingPreviewResults.removeAll()
        previewRequestsByKey.removeAll()
        transientAuthorizedHotGroupIDs.removeAll()
        hasPendingPreviewCacheApplication = false
        coldConfirmationEvidenceByGroupID.removeAll()
        pendingCaptureReasons.removeAll()
        pendingCaptureEnqueueOrders.removeAll()
        deferredCaptureReasonsByMemberID.removeAll()
        deferredCaptureEnqueueOrdersByMemberID.removeAll()
        cancelConfirmationRefresh()
        cancelCooldownRefresh()
        enqueueCapture(
            keys: Set(activePreviewKeys.filter {
                geometryConfirmationCandidates[$0.stableIdentity] == nil
            }),
            reason: .initial
        )
        if !geometryConfirmationCandidates.isEmpty {
            scheduleConfirmationRefreshIfNeeded()
        }
        let activeMemberIDs = Set(activePreviewKeys.map(\.stableIdentity))
        for memberID in structuralPreviewMemberIDs.subtracting(activeMemberIDs) {
            deferCaptureReason(.initial, memberID: memberID)
        }
    }

    func setPreviewCaptureSuspended(_ suspended: Bool) {
        guard previewCaptureIsSuspended != suspended else { return }
        if suspended {
            endTransientPreviewSession()
            transientAuthorizedHotGroupIDs.removeAll()
            preserveGeometryCandidatesAsDebt()
            // A login/session boundary breaks contiguous visual evidence.
            coldConfirmationEvidenceByGroupID.removeAll()
        }
        previewCaptureIsSuspended = suspended
        previewCaptureGeneration &+= 1
        let interrupted = previewRequestsByKey
        previewRequestsByKey.removeAll()
        previewQueue.cancelAllOperations()
        for (key, request) in interrupted {
            preserveCaptureDebt(key: key, reason: request.reason)
        }
        if suspended {
            // A completed-but-uncommitted desktop image belongs to the old
            // login-session scene. Preserve only its trigger debt, never its
            // pixels, so wake/session resume cannot publish stale geometry.
            for (key, result) in pendingPreviewResults {
                preserveCaptureDebt(key: key, reason: result.reason)
            }
            pendingPreviewResults.removeAll()
            hasPendingPreviewCacheApplication = false
            cancelConfirmationRefresh()
            cancelCooldownRefresh()
        } else if !coldConfirmationEvidenceByGroupID.isEmpty {
            scheduleConfirmationRefreshIfNeeded()
        }
    }

    func setDesktopPresentationStable(_ stable: Bool) {
        guard desktopPresentationIsStable != stable else { return }
        if !stable {
            preserveGeometryCandidatesAsDebt()
            // Mission Control and Space transforms may reorder and rescale
            // surfaces. No pre-transform COLD candidate may be joined to a
            // post-transform observation.
            coldConfirmationEvidenceByGroupID.removeAll()
        }
        desktopPresentationIsStable = stable
        previewCaptureGeneration &+= 1
        let interrupted = previewRequestsByKey
        previewRequestsByKey.removeAll()
        previewQueue.cancelAllOperations()
        hasPendingPreviewCacheApplication = false
        if stable {
            for (key, request) in interrupted {
                preserveCaptureDebt(key: key, reason: request.reason)
            }
            if !coldConfirmationEvidenceByGroupID.isEmpty {
                scheduleConfirmationRefreshIfNeeded()
            }
        } else {
            for (key, result) in pendingPreviewResults {
                preserveCaptureDebt(key: key, reason: result.reason)
            }
            pendingPreviewResults.removeAll()
            for (key, request) in interrupted {
                preserveCaptureDebt(key: key, reason: request.reason)
            }
            cancelConfirmationRefresh()
            cancelCooldownRefresh()
        }
    }

    /// Records one finite Preview refresh debt from a successful Tabora-owned
    /// geometry transaction. The transaction itself is the confirmation
    /// boundary. A separate bounded observation fallback exists only for
    /// size/display changes that occur outside Tabora-owned transactions. If the
    /// structural member is temporarily not presentable, the debt waits by
    /// stable identity until an ordinary presentation refresh resolves its key.
    func notePreviewGeometryMutation(memberIDs: Set<String>) {
        guard previewsAreEnabled, !memberIDs.isEmpty else { return }
        for memberID in memberIDs where
            structuralPreviewMemberIDs.contains(memberID) {
            // A successful Tabora transaction is stronger evidence than an
            // observation candidate. It owns exactly one geometry debt.
            geometryConfirmationCandidates.removeValue(forKey: memberID)
            queueConfirmedGeometryRefresh(
                memberID: memberID,
                preferredKey: activePreviewKeys.first(where: {
                    $0.stableIdentity == memberID
                }),
                advancesRevision: true
            )
        }
    }

    private func queueConfirmedGeometryRefresh(
        memberID: String,
        preferredKey: MissionControlPreviewCacheKey?,
        advancesRevision: Bool
    ) {
        guard structuralPreviewMemberIDs.contains(memberID) else { return }
        if advancesRevision {
            geometryRevisionByPhysicalIdentity[memberID, default: 0] &+= 1
        }
        for key in Array(pendingCaptureReasons.keys) where
            key.stableIdentity == memberID {
            pendingCaptureReasons.removeValue(forKey: key)
            pendingCaptureEnqueueOrders.removeValue(forKey: key)
        }
        deferredCaptureReasonsByMemberID.removeValue(forKey: memberID)
        deferredCaptureEnqueueOrdersByMemberID.removeValue(forKey: memberID)
        let targetKey = preferredKey.flatMap { key in
            activePreviewKeys.contains(key) ? key : nil
        } ?? activePreviewKeys.first(where: {
            $0.stableIdentity == memberID
        })
        if let targetKey {
            enqueueCapture(key: targetKey, reason: .geometryConfirmed)
        } else {
            deferCaptureReason(.geometryConfirmed, memberID: memberID)
        }
    }

    private func hasOutstandingCurrentGeometryWork(
        for key: MissionControlPreviewCacheKey
    ) -> Bool {
        if pendingCaptureReasons[key] == .geometryConfirmed { return true }
        if deferredCaptureReasonsByMemberID[key.stableIdentity]
            == .geometryConfirmed {
            return true
        }
        if previewRequestsByKey.contains(where: { entry in
            entry.value.reason == .geometryConfirmed
                && Self.canReuseCapturedPixels(from: entry.key, for: key)
        }) {
            return true
        }
        return pendingPreviewResults.contains(where: { entry in
            entry.value.reason == .geometryConfirmed
                && Self.canReuseCapturedPixels(from: entry.key, for: key)
        })
    }

    private func observeGeometryCandidate(
        _ key: MissionControlPreviewCacheKey,
        now: TimeInterval
    ) {
        guard structuralPreviewMemberIDs.contains(key.stableIdentity) else {
            return
        }
        let alreadyAwaitingGeometry =
            geometryConfirmationCandidates[key.stableIdentity] != nil
        // Invalidate an older in-flight geometry immediately, but do not create
        // WindowServer work until this newest observed size/display settles.
        geometryRevisionByPhysicalIdentity[key.stableIdentity, default: 0] &+= 1
        for pendingKey in Array(pendingCaptureReasons.keys) where
            pendingKey.stableIdentity == key.stableIdentity {
            pendingCaptureReasons.removeValue(forKey: pendingKey)
            pendingCaptureEnqueueOrders.removeValue(forKey: pendingKey)
        }
        deferredCaptureReasonsByMemberID.removeValue(forKey: key.stableIdentity)
        deferredCaptureEnqueueOrdersByMemberID.removeValue(
            forKey: key.stableIdentity
        )
        geometryConfirmationCandidates[key.stableIdentity] =
            MissionControlPreviewGeometryConfirmationCandidate(
                key: key,
                observationCount: 1,
                firstObservedAt: now
            )
        // Debounce continuous external resize without stealing a confirmation
        // turn from another line. If no COLD candidate or queued capture needs
        // the shared timer, move it to the newest geometry event. Otherwise let
        // the justified earlier turn run; the time gate will request one final
        // geometry pass only if the newest sample has not settled yet.
        if alreadyAwaitingGeometry,
           coldConfirmationEvidenceByGroupID.isEmpty,
           pendingCaptureReasons.isEmpty {
            cancelConfirmationRefresh()
        }
        scheduleConfirmationRefreshIfNeeded()
    }

    private func advanceGeometryConfirmations(
        currentPreviewKeys: Set<MissionControlPreviewCacheKey>,
        now: TimeInterval
    ) {
        let currentByMemberID = Dictionary(
            uniqueKeysWithValues: currentPreviewKeys.map {
                ($0.stableIdentity, $0)
            }
        )
        for memberID in Array(geometryConfirmationCandidates.keys) {
            guard structuralPreviewMemberIDs.contains(memberID) else {
                geometryConfirmationCandidates.removeValue(forKey: memberID)
                continue
            }
            guard let currentKey = currentByMemberID[memberID] else {
                // Missing AX/CG presentation breaks contiguous settle evidence,
                // but the observed geometry change itself remains real work.
                // Keep one finite debt by structural identity and wait for an
                // ordinary presentation refresh instead of adding a monitor.
                geometryConfirmationCandidates.removeValue(forKey: memberID)
                deferCaptureReason(.geometryConfirmed, memberID: memberID)
                continue
            }
            guard var candidate = geometryConfirmationCandidates[memberID],
                  let isConfirmed = candidate.advance(
                    matching: currentKey, now: now
                  ) else {
                // A new size/display is handled by the observation fallback.
                continue
            }
            if isConfirmed {
                geometryConfirmationCandidates.removeValue(forKey: memberID)
                queueConfirmedGeometryRefresh(
                    memberID: memberID,
                    preferredKey: currentKey,
                    // Every observed key change already advanced the revision.
                    advancesRevision: false
                )
            } else {
                geometryConfirmationCandidates[memberID] = candidate
                scheduleConfirmationRefreshIfNeeded()
            }
        }
    }

    private func preserveGeometryCandidatesAsDebt() {
        for (memberID, candidate) in geometryConfirmationCandidates where
            structuralPreviewMemberIDs.contains(memberID) {
            if let activeKey = activePreviewKeys.first(where: {
                $0.stableIdentity == memberID
            }) {
                enqueueCapture(key: activeKey, reason: .geometryConfirmed)
            } else {
                deferCaptureReason(
                    .geometryConfirmed,
                    memberID: candidate.key.stableIdentity
                )
            }
        }
        geometryConfirmationCandidates.removeAll()
    }

    func processPendingPreviewCapturesIfNeeded(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        allowsGeometryRefresh: Bool = true
    ) {
        guard previewsAreEnabled,
              !previewCaptureIsSuspended,
              desktopPresentationIsStable,
              activePreviewByteBudget > 0,
              let previewProvider = latestPreviewProvider else { return }
        schedulePriorityPreviewCaptures(
            now: now,
            previewProvider: previewProvider,
            allowsGeometryRefresh: allowsGeometryRefresh
        )
    }

    func hide(groupID: SnapGroupID) {
        transientPreviewAppliedGroupIDs.remove(groupID)
        if activeSelectionCandidate?.groupID == groupID {
            activeSelectionCandidate = nil
        }
        windowsByGroupID.removeValue(forKey: groupID)?.retire()
    }

    func requireOrderingRevalidation() {
        requireOrderingRevalidation(groupIDs: Set(windowsByGroupID.keys))
    }

    func requireOrderingRevalidation(groupIDs: Set<SnapGroupID>) {
        for groupID in groupIDs {
            windowsByGroupID[groupID]?.requireOrderingRevalidation()
        }
    }

    func noteMissionControlTransitionObserved(groupID: SnapGroupID) {
        windowsByGroupID[groupID]?.noteMissionControlTransitionObserved()
    }

    func cancelSelectionTransition(for groupID: SnapGroupID) {
        windowsByGroupID[groupID]?.cancelSelectionTransition()
        transientPreviewAppliedGroupIDs.remove(groupID)
    }

    private func beginSelectionConfirmation(
        groupID: SnapGroupID,
        memberIDs: Set<String>
    ) -> UInt64 {
        selectionCandidateGeneration &+= 1
        activeSelectionCandidate = MissionControlProxySelectionCandidate(
            generation: selectionCandidateGeneration,
            groupID: groupID,
            memberIDs: memberIDs
        )
        return selectionCandidateGeneration
    }

    private func consumeSelectionConfirmation(
        generation: UInt64,
        groupID: SnapGroupID,
        memberIDs: Set<String>
    ) -> MissionControlProxySelectionConfirmationDisposition {
        guard MissionControlProxySelectionCandidatePolicy.matches(
            activeSelectionCandidate,
            generation: generation,
            groupID: groupID,
            memberIDs: memberIDs
        ) else {
            return .rejected
        }
        let disposition: MissionControlProxySelectionConfirmationDisposition
        if queuedMigrationSelectionIsAllowed?(groupID) == true {
            disposition = .queuedMigrationForegroundIntent
        } else if selectionConfirmationIsAllowed?(groupID) != false {
            disposition = .normalGroupActivation
        } else {
            return .rejected
        }
        activeSelectionCandidate = nil
        for (candidateGroupID, window) in windowsByGroupID where
            candidateGroupID != groupID {
            window.cancelSelectionTransition()
        }
        return disposition
    }

    private func releaseSelectionConfirmation(
        generation: UInt64,
        groupID: SnapGroupID,
        memberIDs: Set<String>
    ) {
        guard MissionControlProxySelectionCandidatePolicy.matches(
            activeSelectionCandidate,
            generation: generation,
            groupID: groupID,
            memberIDs: memberIDs
        ) else { return }
        activeSelectionCandidate = nil
    }

    func owns(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windowsByGroupID.values.contains { $0 === window }
    }

    private static func previewCacheKey(
        for window: ManagedWindow,
        windowID: CGWindowID,
        displayID: CGDirectDisplayID
    ) -> MissionControlPreviewCacheKey {
        MissionControlPreviewCacheKey(
            displayID: displayID,
            pid: window.pid,
            windowID: windowID,
            stableIdentity: window.stableIdentity,
            frameMinX: Int(window.frame.minX.rounded()),
            frameMinY: Int(window.frame.minY.rounded()),
            frameWidth: max(Int(window.frame.width.rounded()), 1),
            frameHeight: max(Int(window.frame.height.rounded()), 1)
        )
    }

    private static func representsSamePhysicalWindow(
        _ lhs: MissionControlPreviewCacheKey,
        _ rhs: MissionControlPreviewCacheKey
    ) -> Bool {
        lhs.pid == rhs.pid
            && lhs.windowID == rhs.windowID
            && lhs.stableIdentity == rhs.stableIdentity
    }

    static func canReuseCapturedPixels(
        from source: MissionControlPreviewCacheKey,
        for destination: MissionControlPreviewCacheKey
    ) -> Bool {
        MissionControlPreviewTriggerPolicy.canReuseCapturedPixels(
            representsSamePhysicalWindow:
                representsSamePhysicalWindow(source, destination),
            displayMatches: source.displayID == destination.displayID,
            pixelSizeMatches:
                source.frameWidth == destination.frameWidth
                    && source.frameHeight == destination.frameHeight
        )
    }

    private func previewImage(
        for window: ManagedWindow,
        displayID: CGDirectDisplayID
    ) -> NSImage? {
        guard let windowID = window.cgWindowID else { return nil }
        let key = Self.previewCacheKey(
            for: window,
            windowID: windowID,
            displayID: displayID
        )
        previewAccessEpoch &+= 1
        if var cached = cachedPreviews[key] {
            cached.accessEpoch = previewAccessEpoch
            cachedPreviews[key] = cached
            // Stale-while-revalidate remains visible while a trigger-owned
            // replacement is admitted through the shared queue.
            return cached.image
        }

        // Never synchronously capture a client window from the main thread.
        // Screen sharing can make Window Server capture slow enough to stall
        // snapping, foregrounding and unrelated groups. Return the icon-backed
        // placeholder immediately and populate this bounded cache off-main.
        return nil
    }

    @discardableResult
    private func schedulePreviewCapture(
        key: MissionControlPreviewCacheKey,
        reason: MissionControlPreviewTriggerReason,
        byteBudget: Int,
        previewProvider: @escaping PreviewProvider,
        retryRemaining: Bool = false
    ) -> Bool {
        if previewRequestsByKey[key] != nil {
            // A capture admitted before a later trigger cannot satisfy that
            // trigger merely because its key is unchanged. Retain one merged
            // follow-up demand; completion will reopen capacity.
            enqueueCapture(key: key, reason: reason)
            return false
        }
        if previewRequestsByKey.keys.contains(where: {
            Self.representsSamePhysicalWindow($0, key)
        }) {
            enqueueCapture(key: key, reason: reason)
            return false
        }
        if pendingPreviewResults.keys.contains(where: {
            Self.representsSamePhysicalWindow($0, key)
        }) {
            enqueueCapture(key: key, reason: reason)
            return false
        }
        guard MissionControlPreviewAdmissionPolicy.allowsCapture(
            previewsEnabled: previewsAreEnabled,
            captureSuspended: previewCaptureIsSuspended,
            desktopPresentationIsStable: desktopPresentationIsStable,
            byteBudget: byteBudget,
            outstandingCount:
                previewRequestsByKey.count + pendingPreviewResults.count,
            queuedOperationCount: previewQueue.operationCount,
            keyIsActive: activePreviewKeys.contains(key)
        ) else { return false }
        let captureGeneration = previewCaptureGeneration
        let geometryRevision = geometryRevisionByPhysicalIdentity[
            key.stableIdentity,
            default: 0
        ]
        let coldAuthorizationRevision = reason == .coldConfirmed
            ? coldCaptureAuthorizationRevisionByMemberID[
                key.stableIdentity,
                default: 0
            ]
            : nil
        previewRequestsByKey[key] = MissionControlPreviewRequest(
            generation: captureGeneration,
            geometryRevision: geometryRevision,
            coldAuthorizationRevision: coldAuthorizationRevision,
            reason: reason,
            retryRemaining: retryRemaining
        )
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation,
                  !operation.isCancelled else { return }
            let captureIsAuthorized: PreviewCaptureAuthorization = {
                [weak operation] in
                operation?.isCancelled == false
            }
            let source = previewProvider(
                key.windowID,
                captureIsAuthorized
            )
            // The provider may have waited for the shared capture slot. If this
            // request was cancelled during that wait, do not turn the denied
            // physical capture into a Preview retry or derived-image task.
            guard captureIsAuthorized() else { return }
            let rendered: (CGImage, Int)? = source.flatMap { source in
                guard let image = Self.makePreviewImage(
                    from: source,
                    byteBudget: byteBudget
                ) else { return nil }
                let cost = max(
                    image.bytesPerRow * image.height,
                    image.width * image.height * 4
                )
                return (image, cost)
            }
            guard captureIsAuthorized() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let completedRequest = self.previewRequestsByKey[key]
                if completedRequest?.generation == captureGeneration {
                    self.previewRequestsByKey.removeValue(forKey: key)
                }
                guard self.previewCaptureGeneration == captureGeneration,
                      self.previewsAreEnabled,
                      self.desktopPresentationIsStable,
                      self.structuralPreviewMemberIDs.contains(key.stableIdentity)
                else { return }
                let completedReason = completedRequest?.reason ?? reason
                let completedColdAuthorizationRevision = completedRequest?
                    .coldAuthorizationRevision ?? coldAuthorizationRevision
                guard MissionControlPreviewColdCaptureAuthorizationPolicy
                    .allowsCommit(
                        reason: completedReason,
                        admittedRevision: completedColdAuthorizationRevision,
                        currentRevision:
                            self.coldCaptureAuthorizationRevisionByMemberID[
                                key.stableIdentity,
                                default: 0
                            ]
                    ) else {
                    // The Group became HOT or left the visible desktop after
                    // this COLD capture was admitted. Drop its pixels and retry
                    // budget without cancelling unrelated queue work.
                    self.scheduleConfirmationRefreshIfNeeded()
                    return
                }
                guard MissionControlPreviewTriggerPolicy
                    .captureMatchesCurrentGeometry(
                        admittedRevision: geometryRevision,
                        currentRevision:
                            self.geometryRevisionByPhysicalIdentity[
                                key.stableIdentity,
                                default: 0
                            ]
                    ) else {
                    // A successful Tabora-owned geometry transaction overtook
                    // this physical capture. Its newer finite debt is already
                    // queued; request one bounded Preview-only refresh so that
                    // queue progress does not wait for the 1 Hz Recovery pass.
                    self.scheduleConfirmationRefreshIfNeeded()
                    return
                }
                let resultKey = self.activePreviewKeys.first(where: {
                    Self.canReuseCapturedPixels(from: key, for: $0)
                })
                guard let (capturedImage, _) = rendered else {
                    let retryReason = completedReason
                    if let resultKey, completedRequest?.retryRemaining == true,
                       let currentProvider = self.latestPreviewProvider {
                        // Do not turn admission contention into a fresh
                        // retry budget. This trigger already performed one
                        // WindowServer attempt; if its single direct retry
                        // cannot be admitted now, finish the trigger here.
                        _ = self.schedulePreviewCapture(
                            key: resultKey,
                            reason: retryReason,
                            byteBudget: self.activePreviewByteBudget,
                            previewProvider: currentProvider,
                            retryRemaining: false
                        )
                    } else if MissionControlPreviewTriggerPolicy
                        .shouldRetainDebtAfterCaptureFailure(
                            hasReusableActiveKey: resultKey != nil
                        ) {
                        // Structural presence survived but the current AX target
                        // disappeared. Preserve one reason by identity. A second
                        // actual capture failure at an active geometry is final.
                        self.deferCaptureReason(
                            retryReason,
                            memberID: key.stableIdentity
                        )
                    }
                    self.scheduleConfirmationRefreshIfNeeded()
                    return
                }
                let effectiveBudget = self.activePreviewByteBudget > 0
                    ? self.activePreviewByteBudget : max(byteBudget, 1)
                guard let image = byteBudget == effectiveBudget
                    ? capturedImage
                    : Self.makePreviewImage(
                        from: capturedImage,
                        byteBudget: effectiveBudget
                    ) else {
                    // This is local derived-image processing, not a missing AX
                    // target. Re-capturing WindowServer cannot be assumed to fix
                    // it, so do not convert the failure into persistent debt.
                    // One confirmation turn only lets unrelated queued work use
                    // the slot that just became free.
                    self.scheduleConfirmationRefreshIfNeeded()
                    return
                }
                let cost = max(
                    image.bytesPerRow * image.height,
                    image.width * image.height * 4
                )
                self.previewAccessEpoch &+= 1
                let preview = NSImage(
                    cgImage: image,
                    size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
                )
                let cached = MissionControlCachedPreview(
                    image: preview,
                    byteCost: cost,
                    accessEpoch: self.previewAccessEpoch
                )
                if let resultKey {
                    self.pendingPreviewResults[resultKey] =
                        MissionControlPendingPreviewResult(
                            preview: cached,
                            reason: completedReason,
                            geometryRevision: geometryRevision,
                            coldAuthorizationRevision:
                                completedColdAuthorizationRevision
                        )
                    self.hasPendingPreviewCacheApplication = true
                } else {
                    // The member is structurally live but temporarily absent
                    // from the AX presentation census. Store completed pixels in
                    // the bounded cache immediately so they do not occupy one of
                    // the four execution/result slots. A later matching key may
                    // reuse them; a geometry revision invalidates them.
                    self.cachedPreviews[key] = cached
                    self.lastCaptureAtByPhysicalIdentity[key.stableIdentity] =
                        ProcessInfo.processInfo.systemUptime
                    self.trimPreviewCacheIfNeeded()
                }
                // Never mutate a managed proxy from an asynchronous capture
                // completion. Ask the controller for one coalesced normal update
                // instead. That update revalidates identity/geometry and already
                // refuses to rebuild presentation during a Window Server transform.
                self.schedulePreviewCacheRefreshNotification()
            }
        }
        previewQueue.addOperation(operation)
        return true
    }

    private func commitValidatedPreviewResults(
        currentPreviewKeys: Set<MissionControlPreviewCacheKey>
    ) {
        guard desktopPresentationIsStable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for key in Array(pendingPreviewResults.keys) {
            guard let result = pendingPreviewResults.removeValue(forKey: key),
                  structuralPreviewMemberIDs.contains(key.stableIdentity),
                  MissionControlPreviewColdCaptureAuthorizationPolicy
                      .allowsCommit(
                        reason: result.reason,
                        admittedRevision: result.coldAuthorizationRevision,
                        currentRevision:
                            coldCaptureAuthorizationRevisionByMemberID[
                                key.stableIdentity,
                                default: 0
                            ]
                      ),
                  MissionControlPreviewTriggerPolicy
                      .captureMatchesCurrentGeometry(
                        admittedRevision: result.geometryRevision,
                        currentRevision:
                            geometryRevisionByPhysicalIdentity[
                                key.stableIdentity,
                                default: 0
                            ]
                      ) else { continue }
            previewAccessEpoch &+= 1
            var validated = result.preview
            validated.accessEpoch = previewAccessEpoch
            if let validatedKey = currentPreviewKeys.first(where: {
                Self.canReuseCapturedPixels(from: key, for: $0)
            }) {
                cachedPreviews[validatedKey] = validated
                lastCaptureAtByPhysicalIdentity[validatedKey.stableIdentity] = now
            } else {
                // AX presentation can disappear after capture completed but
                // before the coalesced application refresh. Structural
                // membership owns the completed pixels; keep them in the
                // bounded cache instead of dropping valid finite work. A later
                // geometry mutation advances the revision and prevents stale
                // reuse at a changed size.
                cachedPreviews[key] = validated
                lastCaptureAtByPhysicalIdentity[key.stableIdentity] = now
            }
        }
        trimPreviewCacheIfNeeded()
    }

    private func enqueueCapture(
        keys: Set<MissionControlPreviewCacheKey>,
        reason: MissionControlPreviewTriggerReason
    ) {
        for key in keys {
            enqueueCapture(key: key, reason: reason)
        }
    }

    private func enqueueCapture(
        key: MissionControlPreviewCacheKey,
        reason: MissionControlPreviewTriggerReason
    ) {
        guard activePreviewKeys.contains(key) else { return }
        var mergedReason = reason
        var oldestEnqueueOrder = pendingCaptureEnqueueOrders[key]
        for previousKey in Array(pendingCaptureReasons.keys) where
            previousKey != key
                && Self.representsSamePhysicalWindow(previousKey, key) {
            mergedReason = MissionControlPreviewTriggerPolicy.merged(
                pendingCaptureReasons[previousKey],
                with: mergedReason
            )
            if let previousOrder = pendingCaptureEnqueueOrders[previousKey] {
                oldestEnqueueOrder = min(
                    oldestEnqueueOrder ?? previousOrder,
                    previousOrder
                )
            }
            pendingCaptureReasons.removeValue(forKey: previousKey)
            pendingCaptureEnqueueOrders.removeValue(forKey: previousKey)
        }
        pendingCaptureReasons[key] = MissionControlPreviewTriggerPolicy.merged(
            pendingCaptureReasons[key],
            with: mergedReason
        )
        if pendingCaptureEnqueueOrders[key] == nil {
            if let oldestEnqueueOrder {
                pendingCaptureEnqueueOrders[key] = oldestEnqueueOrder
            } else {
                nextPendingCaptureEnqueueOrder &+= 1
                pendingCaptureEnqueueOrders[key] =
                    nextPendingCaptureEnqueueOrder
            }
        }
    }

    private func scheduleConfirmationRefreshIfNeeded() {
        guard !confirmationRefreshIsScheduled,
              previewsAreEnabled,
              !previewCaptureIsSuspended,
              desktopPresentationIsStable else { return }
        confirmationRefreshIsScheduled = true
        confirmationGeneration &+= 1
        let generation = confirmationGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + MissionControlPreviewWorkPolicy.confirmationInterval
        ) { [weak self] in
            guard let self,
                  self.confirmationGeneration == generation else { return }
            self.confirmationRefreshIsScheduled = false
            self.onPreviewConfirmationNeeded?()
        }
    }

    private func cancelConfirmationRefresh() {
        confirmationGeneration &+= 1
        confirmationRefreshIsScheduled = false
    }

    private func scheduleCooldownRefreshIfNeeded(after delay: TimeInterval) {
        guard previewsAreEnabled,
              !previewCaptureIsSuspended,
              desktopPresentationIsStable,
              delay > 0 else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        if cooldownRefreshIsScheduled,
           let currentDeadline = cooldownRefreshDeadline,
           currentDeadline <= deadline {
            return
        }
        cooldownRefreshIsScheduled = true
        cooldownRefreshDeadline = deadline
        cooldownGeneration &+= 1
        let generation = cooldownGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.cooldownGeneration == generation else { return }
            self.cooldownRefreshIsScheduled = false
            self.cooldownRefreshDeadline = nil
            self.onPreviewConfirmationNeeded?()
        }
    }

    private func cancelCooldownRefresh() {
        cooldownGeneration &+= 1
        cooldownRefreshIsScheduled = false
        cooldownRefreshDeadline = nil
    }

    private func previewKeysInFairDisplayOrder(
        _ keys: [MissionControlPreviewCacheKey]
    ) -> [MissionControlPreviewCacheKey] {
        let ordered = keys.sorted(by: Self.previewKeyIsOrderedBefore)
        let indices = MissionControlPreviewDisplayFairnessPolicy
            .fairFIFOIndices(
                displayIDs: ordered.map(\.displayID),
                enqueueOrders: ordered.map {
                    pendingCaptureEnqueueOrders[$0] ?? UInt64.max
                }
            )
        return indices.map { ordered[$0] }
    }

    private func updatePreviewActivity(
        currentPreviewKeys: Set<MissionControlPreviewCacheKey>,
        previewKeysByGroupID:
            [SnapGroupID: Set<MissionControlPreviewCacheKey>],
        structuralGroupIDs: Set<SnapGroupID>,
        structuralMemberIDsByGroupID: [SnapGroupID: Set<String>],
        visibilityEvaluationByGroupID:
            [SnapGroupID: PreviewGroupVisibilityEvaluation]
    ) {
        let previousKnownMemberIDs = knownPreviewMemberIDs
        // Group activity is structural state. Temporary AX/CG presentation
        // loss is indeterminate evidence, not a HOT/COLD transition. Retire
        // activity only when the explicit Group itself leaves the store.
        hotPreviewGroupIDs.formIntersection(structuralGroupIDs)
        coldVisiblePreviewGroupIDs.formIntersection(structuralGroupIDs)
        coldNotVisiblePreviewGroupIDs.formIntersection(structuralGroupIDs)
        coldConfirmationEvidenceByGroupID =
            coldConfirmationEvidenceByGroupID.filter {
                structuralGroupIDs.contains($0.key)
            }
        physicalFallbackCandidateByGroupID =
            physicalFallbackCandidateByGroupID.filter {
                structuralGroupIDs.contains($0.key)
            }

        let newKeys = currentPreviewKeys.filter {
            !previousKnownMemberIDs.contains($0.stableIdentity)
        }
        // Only a structurally new member owns initial capture. A temporary AX/CG
        // absence does not clear known membership, so return from that absence
        // cannot retrigger .initial.
        enqueueCapture(keys: newKeys, reason: .initial)

        for groupID in structuralGroupIDs {
            let keys = previewKeysByGroupID[groupID] ?? []
            let memberIDs = structuralMemberIDsByGroupID[groupID] ?? []
            let evaluation = visibilityEvaluationByGroupID[groupID]
                ?? .indeterminate
            switch evaluation {
            case .hot:
                hotPreviewGroupIDs.insert(groupID)
                coldVisiblePreviewGroupIDs.remove(groupID)
                coldNotVisiblePreviewGroupIDs.remove(groupID)
                physicalFallbackCandidateByGroupID.removeValue(
                    forKey: groupID
                )
                clearColdConfirmation(for: groupID)
                clearColdConfirmedDebt(memberIDs: memberIDs)
            case .occluded(let candidate, let semantic):
                coldNotVisiblePreviewGroupIDs.remove(groupID)
                guard hotPreviewGroupIDs.contains(groupID) else {
                    coldVisiblePreviewGroupIDs.insert(groupID)
                    if semantic == .unknown {
                        physicalFallbackCandidateByGroupID[groupID] = candidate
                    } else {
                        physicalFallbackCandidateByGroupID.removeValue(
                            forKey: groupID
                        )
                    }
                    clearColdConfirmation(for: groupID)
                    // Already COLD, newly visible while occluded, or never
                    // observed HOT: no HOT -> COLD-visible transition exists.
                    continue
                }
                let now = ProcessInfo.processInfo.systemUptime
                guard let observation =
                    MissionControlPreviewColdConfirmationPolicy.observe(
                        previous: coldConfirmationEvidenceByGroupID[groupID],
                        candidate: candidate,
                        semantic: semantic,
                        now: now
                    ) else {
                    clearColdConfirmation(for: groupID)
                    continue
                }
                if observation.isConfirmed {
                    clearColdConfirmation(for: groupID)
                    hotPreviewGroupIDs.remove(groupID)
                    coldVisiblePreviewGroupIDs.insert(groupID)
                    if semantic == .unknown {
                        physicalFallbackCandidateByGroupID[groupID] = candidate
                    } else {
                        physicalFallbackCandidateByGroupID.removeValue(
                            forKey: groupID
                        )
                    }
                    enqueueCapture(keys: keys, reason: .coldConfirmed)
                } else {
                    coldConfirmationEvidenceByGroupID[groupID] =
                        observation.evidence
                    scheduleConfirmationRefreshIfNeeded()
                }
            case .coldNotVisible:
                // End the old visible epoch without a final capture. A later
                // occluded return therefore cannot inherit stale HOT or debt.
                hotPreviewGroupIDs.remove(groupID)
                coldVisiblePreviewGroupIDs.remove(groupID)
                coldNotVisiblePreviewGroupIDs.insert(groupID)
                physicalFallbackCandidateByGroupID.removeValue(
                    forKey: groupID
                )
                clearColdConfirmation(for: groupID)
                clearColdConfirmedDebt(memberIDs: memberIDs)
            case .indeterminate:
                // Unknown WindowServer evidence preserves the confirmed Group
                // activity state, but it breaks an in-progress HOT -> COLD
                // candidate. Two separated occlusion samples may not be joined
                // across an incomplete census.
                clearColdConfirmation(for: groupID)
            }
        }

        knownPreviewMemberIDs.formUnion(
            currentPreviewKeys.map(\.stableIdentity)
        )
        knownPreviewMemberIDs.formIntersection(structuralPreviewMemberIDs)

        // Only structural departure may retire finite debt/revision ownership.
        deferredCaptureReasonsByMemberID = deferredCaptureReasonsByMemberID.filter {
            structuralPreviewMemberIDs.contains($0.key)
        }
        deferredCaptureEnqueueOrdersByMemberID =
            deferredCaptureEnqueueOrdersByMemberID.filter {
                deferredCaptureReasonsByMemberID[$0.key] != nil
            }
        lastCaptureAtByPhysicalIdentity = lastCaptureAtByPhysicalIdentity.filter {
            structuralPreviewMemberIDs.contains($0.key)
        }
        geometryRevisionByPhysicalIdentity =
            geometryRevisionByPhysicalIdentity.filter {
            structuralPreviewMemberIDs.contains($0.key)
        }
        coldCaptureAuthorizationRevisionByMemberID =
            coldCaptureAuthorizationRevisionByMemberID.filter {
                structuralPreviewMemberIDs.contains($0.key)
            }
    }

    private func clearColdConfirmation(for groupID: SnapGroupID) {
        coldConfirmationEvidenceByGroupID.removeValue(forKey: groupID)
    }

    private func clearColdConfirmedDebt(memberIDs: Set<String>) {
        guard !memberIDs.isEmpty else { return }
        // A running capture cannot be cancelled without also disturbing shared
        // queue behavior. Advance only the affected members' authorization so
        // an old COLD result is rejected both on completion and at commit.
        let admittedColdMemberIDs = Set(
            previewRequestsByKey.compactMap { key, request in
                request.reason == .coldConfirmed
                    && memberIDs.contains(key.stableIdentity)
                    && request.coldAuthorizationRevision
                        == coldCaptureAuthorizationRevisionByMemberID[
                            key.stableIdentity,
                            default: 0
                        ]
                    ? key.stableIdentity : nil
            }
        ).union(
            pendingPreviewResults.compactMap { key, result in
                result.reason == .coldConfirmed
                    && memberIDs.contains(key.stableIdentity)
                    && result.coldAuthorizationRevision
                        == coldCaptureAuthorizationRevisionByMemberID[
                            key.stableIdentity,
                            default: 0
                        ]
                    ? key.stableIdentity : nil
            }
        )
        for memberID in admittedColdMemberIDs {
            coldCaptureAuthorizationRevisionByMemberID[memberID, default: 0]
                &+= 1
        }
        for key in Array(pendingCaptureReasons.keys) where
            pendingCaptureReasons[key] == .coldConfirmed
                && memberIDs.contains(key.stableIdentity) {
            pendingCaptureReasons.removeValue(forKey: key)
            pendingCaptureEnqueueOrders.removeValue(forKey: key)
        }
        for key in Array(pendingPreviewResults.keys) where
            pendingPreviewResults[key]?.reason == .coldConfirmed
                && memberIDs.contains(key.stableIdentity) {
            pendingPreviewResults.removeValue(forKey: key)
        }
        for memberID in memberIDs where
            deferredCaptureReasonsByMemberID[memberID] == .coldConfirmed {
            deferredCaptureReasonsByMemberID.removeValue(forKey: memberID)
            deferredCaptureEnqueueOrdersByMemberID.removeValue(forKey: memberID)
        }
        hasPendingPreviewCacheApplication = !pendingPreviewResults.isEmpty
    }

    private func reconcileDeferredPreviewDebt(
        currentPreviewKeys: Set<MissionControlPreviewCacheKey>
    ) {
        let currentByMemberID = Dictionary(
            uniqueKeysWithValues: currentPreviewKeys.map { ($0.stableIdentity, $0) }
        )

        for key in Array(pendingCaptureReasons.keys) where
            !currentPreviewKeys.contains(key) {
            guard let reason = pendingCaptureReasons.removeValue(forKey: key) else {
                continue
            }
            let order = pendingCaptureEnqueueOrders.removeValue(forKey: key)
            guard structuralPreviewMemberIDs.contains(key.stableIdentity) else {
                continue
            }
            deferredCaptureReasonsByMemberID[key.stableIdentity] =
                MissionControlPreviewTriggerPolicy.merged(
                    deferredCaptureReasonsByMemberID[key.stableIdentity],
                    with: reason
                )
            if let order {
                deferredCaptureEnqueueOrdersByMemberID[key.stableIdentity] = min(
                    deferredCaptureEnqueueOrdersByMemberID[key.stableIdentity]
                        ?? order,
                    order
                )
            }
        }

        for (memberID, key) in currentByMemberID {
            guard let reason = deferredCaptureReasonsByMemberID.removeValue(
                forKey: memberID
            ) else { continue }
            let order = deferredCaptureEnqueueOrdersByMemberID.removeValue(
                forKey: memberID
            )
            enqueueCapture(key: key, reason: reason)
            if let order {
                pendingCaptureEnqueueOrders[key] = min(
                    pendingCaptureEnqueueOrders[key] ?? order,
                    order
                )
            }
        }
    }

    private func schedulePriorityPreviewCaptures(
        now: TimeInterval,
        previewProvider: @escaping PreviewProvider,
        allowsGeometryRefresh: Bool = true
    ) {
        let orderedKeys = previewKeysInFairDisplayOrder(
            Array(pendingCaptureReasons.keys)
        )
        var admittedGeometryCount = previewRequestsByKey.values.filter {
            $0.reason == .geometryConfirmed
        }.count
        var shortestCooldown: TimeInterval?
        for key in orderedKeys {
            guard previewRequestsByKey.count + pendingPreviewResults.count
                    < MissionControlPreviewWorkPolicy
                        .maximumOutstandingCaptureCount else { break }
            guard let reason = pendingCaptureReasons[key] else { continue }
            // Any trigger for this physical member waits behind the newest
            // unsettled geometry. This prevents COLD/initial work from becoming
            // a continuous resize capture lane.
            if geometryConfirmationCandidates[key.stableIdentity] != nil {
                continue
            }
            if reason == .geometryConfirmed, !allowsGeometryRefresh {
                continue
            }
            if reason == .geometryConfirmed,
               admittedGeometryCount >= MissionControlPreviewGeometryRefreshPolicy
                    .maximumSettledCapturesPerRefresh {
                continue
            }
            let remaining = MissionControlPreviewTriggerPolicy
                .cooldownRemaining(
                    reason: reason,
                    lastCaptureAt:
                        lastCaptureAtByPhysicalIdentity[key.stableIdentity],
                    now: now
                )
            if remaining > 0 {
                shortestCooldown = min(shortestCooldown ?? remaining, remaining)
                continue
            }
            if schedulePreviewCapture(
                key: key,
                reason: reason,
                byteBudget: activePreviewByteBudget,
                previewProvider: previewProvider,
                retryRemaining: true
            ) {
                if pendingCaptureReasons[key] == reason {
                    pendingCaptureReasons.removeValue(forKey: key)
                    pendingCaptureEnqueueOrders.removeValue(forKey: key)
                }
                if reason == .geometryConfirmed {
                    admittedGeometryCount += 1
                }
            }
        }
        if let shortestCooldown {
            scheduleCooldownRefreshIfNeeded(after: shortestCooldown)
        }
    }


    private func preserveCaptureDebt(
        key: MissionControlPreviewCacheKey,
        reason: MissionControlPreviewTriggerReason
    ) {
        if activePreviewKeys.contains(key) {
            enqueueCapture(key: key, reason: reason)
        } else {
            deferCaptureReason(reason, memberID: key.stableIdentity)
        }
    }

    private func deferCaptureReason(
        _ reason: MissionControlPreviewTriggerReason,
        memberID: String
    ) {
        guard structuralPreviewMemberIDs.contains(memberID) else { return }
        deferredCaptureReasonsByMemberID[memberID] =
            MissionControlPreviewTriggerPolicy.merged(
                deferredCaptureReasonsByMemberID[memberID],
                with: reason
            )
        if deferredCaptureEnqueueOrdersByMemberID[memberID] == nil {
            nextPendingCaptureEnqueueOrder &+= 1
            deferredCaptureEnqueueOrdersByMemberID[memberID] =
                nextPendingCaptureEnqueueOrder
        }
    }

    private func reencodeCachedPreviewsForActiveBudget() {
        guard activePreviewByteBudget > 0 else { return }
        for key in Array(cachedPreviews.keys) where
            activePreviewKeys.contains(key) {
            guard let cached = cachedPreviews[key],
                  cached.byteCost > activePreviewByteBudget else { continue }
            var proposed = NSRect(
                x: 0, y: 0,
                width: cached.image.size.width,
                height: cached.image.size.height
            )
            guard let source = cached.image.cgImage(
                forProposedRect: &proposed,
                context: nil,
                hints: nil
            ),
            let image = Self.makePreviewImage(
                from: source,
                byteBudget: activePreviewByteBudget
            ) else {
                cachedPreviews.removeValue(forKey: key)
                // Local budget adaptation normally requires no WindowServer
                // work. If local re-encoding itself fails, retain exactly one
                // finite initial debt so Preview=ON does not silently degrade
                // to an icon for this live member.
                enqueueCapture(key: key, reason: .initial)
                continue
            }
            previewAccessEpoch &+= 1
            cachedPreviews[key] = MissionControlCachedPreview(
                image: NSImage(
                    cgImage: image,
                    size: NSSize(
                        width: CGFloat(image.width),
                        height: CGFloat(image.height)
                    )
                ),
                byteCost: max(
                    image.bytesPerRow * image.height,
                    image.width * image.height * 4
                ),
                accessEpoch: previewAccessEpoch
            )
        }
        trimPreviewCacheIfNeeded()
    }

    private func schedulePreviewCacheRefreshNotification() {
        guard !previewCacheRefreshNotificationScheduled else { return }
        previewCacheRefreshNotificationScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + MissionControlPreviewWorkPolicy
                    .applicationCoalescingInterval
        ) { [weak self] in
            guard let self else { return }
            self.previewCacheRefreshNotificationScheduled = false
            guard self.hasPendingPreviewCacheApplication,
                  self.previewsAreEnabled,
                  self.desktopPresentationIsStable else { return }
            self.onPreviewCacheReady?()
        }
    }

    private func trimPreviewCacheIfNeeded() {
        var totalCost = cachedPreviews.values.reduce(0) {
            $0 + $1.byteCost
        }
        guard totalCost > maximumCachedPreviewBytes else { return }
        // Current members are already encoded against total/count. Evicting
        // one of them would violate Preview=ON by turning a valid candidate
        // into an icon. Only stale geometry/member variants are disposable.
        for key in cachedPreviews.filter({
            !activePreviewKeys.contains($0.key)
        }).sorted(by: {
            $0.value.accessEpoch < $1.value.accessEpoch
        }).map(\.key) {
            guard totalCost > maximumCachedPreviewBytes,
                  let removed = cachedPreviews.removeValue(forKey: key) else {
                break
            }
            totalCost -= removed.byteCost
            if structuralPreviewMemberIDs.contains(key.stableIdentity),
               knownPreviewMemberIDs.contains(key.stableIdentity) {
                deferCaptureReason(.initial, memberID: key.stableIdentity)
            }
        }
    }

    private static func previewKeyIsOrderedBefore(
        _ lhs: MissionControlPreviewCacheKey,
        _ rhs: MissionControlPreviewCacheKey
    ) -> Bool {
        if lhs.displayID != rhs.displayID {
            return lhs.displayID < rhs.displayID
        }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
        if lhs.stableIdentity != rhs.stableIdentity {
            return lhs.stableIdentity < rhs.stableIdentity
        }
        if lhs.frameMinX != rhs.frameMinX { return lhs.frameMinX < rhs.frameMinX }
        if lhs.frameMinY != rhs.frameMinY { return lhs.frameMinY < rhs.frameMinY }
        if lhs.frameWidth != rhs.frameWidth { return lhs.frameWidth < rhs.frameWidth }
        return lhs.frameHeight < rhs.frameHeight
    }

    private static func makePreviewImage(
        from source: CGImage,
        byteBudget: Int
    ) -> CGImage? {
        guard let target = MissionControlPreviewSizingPolicy.targetPixelSize(
            sourceWidth: source.width,
            sourceHeight: source.height,
            byteBudget: byteBudget
        ) else { return nil }
        let sourceByteCost = max(
            source.bytesPerRow * source.height,
            source.width * source.height
                * MissionControlPreviewSizingPolicy.bytesPerPixel
        )
        if target.width == source.width,
           target.height == source.height,
           sourceByteCost <= byteBudget {
            return source
        }
        var width = target.width
        var height = target.height
        if sourceByteCost > byteBudget,
           width == source.width,
           height == source.height {
            // Pixel count is only an estimate. A source can have padded rows,
            // so tighten the target when its actual storage exceeds budget.
            let paddedScale = min(
                sqrt(Double(byteBudget) / Double(sourceByteCost)),
                1
            )
            width = max(
                Int((Double(source.width) * paddedScale).rounded(.down)), 1
            )
            height = max(
                Int((Double(source.height) * paddedScale).rounded(.down)), 1
            )
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        for _ in 0..<8 {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return nil }
            let storageCost = max(
                context.bytesPerRow * height,
                width * height
                    * MissionControlPreviewSizingPolicy.bytesPerPixel
            )
            if storageCost > byteBudget {
                guard let reduced = MissionControlPreviewSizingPolicy
                    .reducedPixelSize(
                        width: width,
                        height: height,
                        actualByteCost: storageCost,
                        byteBudget: byteBudget
                    ) else { return nil }
                width = reduced.width
                height = reduced.height
                continue
            }
            context.interpolationQuality = .high
            context.draw(
                source,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            guard let image = context.makeImage() else { return nil }
            let imageCost = max(
                image.bytesPerRow * image.height,
                image.width * image.height
                    * MissionControlPreviewSizingPolicy.bytesPerPixel
            )
            if imageCost <= byteBudget { return image }
            guard let reduced = MissionControlPreviewSizingPolicy
                .reducedPixelSize(
                    width: width,
                    height: height,
                    actualByteCost: imageCost,
                    byteBudget: byteBudget
                ) else { return nil }
            width = reduced.width
            height = reduced.height
        }
        return nil
    }

}

final class MissionControlGroupProxyWindow: NSWindow, NSWindowDelegate {
    var groupID = SnapGroupID()
    var presentedMemberIDs = Set<String>()
    var beginSelectionConfirmation: ((SnapGroupID, Set<String>) -> UInt64)?
    var consumeSelectionConfirmation:
        ((UInt64, SnapGroupID, Set<String>) ->
            MissionControlProxySelectionConfirmationDisposition)?
    var releaseSelectionConfirmation:
        ((UInt64, SnapGroupID, Set<String>) -> Void)?
    var onSelected: ((SnapGroupID, Set<String>) -> Void)?
    var onQueuedMigrationSelected: ((SnapGroupID, Set<String>) -> Void)?
    var onSelectionConfirmationTerminated: (() -> Void)?
    var currentTransitionAuthorization: ((SnapGroupID) -> Bool)?

    private let proxyView = MissionControlGroupProxyView()
    private var selectionWasDelivered = false
    private var selectionConfirmationIsPending = false
    private var presentationGeneration = 0
    private var selectionConfirmationGeneration = 0
    private var normalPresentationTitle = ""
    private var lastPresentedFrame: CGRect?
    private var lastPresentedMemberWindowIDs: Set<CGWindowID> = []
    private var isSafelyPresented = false
    private var hasOrderingValidationDebt = false
    private var orderingValidationIsInFlight = false
    private var transitionToken: MissionControlTransitionToken?
    private var normalMembersBeforeTransientPreview:
        [MissionControlGroupProxyMember]?

    var isSelectionConfirmationPending: Bool {
        selectionConfirmationIsPending
    }

    var needsPresentationRecovery: Bool {
        hasOrderingValidationDebt && !selectionWasDelivered
    }

    var allowsTransientPreviewMutation: Bool {
        !selectionWasDelivered
            && !selectionConfirmationIsPending
            && proxyView.spaceMigrationQueuePosition == nil
    }

    var allowsPresentationMutation: Bool {
        MissionControlProxySelectionDeliveryPolicy
            .allowsPresentationMutation(
                selectionWasDelivered: selectionWasDelivered,
                confirmationIsPending: selectionConfirmationIsPending
            )
    }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        delegate = self
        level = .normal
        collectionBehavior = [.managed, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        sharingType = .readOnly
        contentView = proxyView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(
        title: String,
        frame: CGRect,
        members: [MissionControlGroupProxyMember],
        requiredWindowIDs: Set<CGWindowID>?
    ) {
        // App activation and AX focus notifications may refresh presentation
        // while the selected proxy is covering the ordered group transition.
        // Do not demote that cover until the controller reports success or
        // explicitly cancels the bounded attempt.
        guard allowsPresentationMutation else { return }
        level = .normal
        self.title = title
        normalPresentationTitle = title
        setFrame(frame, display: false)
        // A normal presentation update re-establishes the canonical Preview
        // source and terminates any stale Mission Control-only ownership.
        normalMembersBeforeTransientPreview = nil
        proxyView.members = members.sorted {
            $0.stableIdentity < $1.stableIdentity
        }
        proxyView.spaceMigrationQueuePosition = nil
        proxyView.spaceMigrationQueueTotal = 0
        proxyView.needsDisplay = true

        let requiresOrderingRestart =
            MissionControlProxyStructuralUpdatePolicy
                .requiresOrderingRestart(
                    lastFrame: lastPresentedFrame,
                    newFrame: frame,
                    lastMemberWindowIDs: lastPresentedMemberWindowIDs,
                    requiredMemberWindowIDs: requiredWindowIDs,
                    presentationIsStableOrValidating: isSafelyPresented
                        || orderingValidationIsInFlight
                )
        guard requiresOrderingRestart else { return }

        // The proxy occupies exactly the current split-group bounds and is
        // ordered behind its own member windows. It therefore remains
        // covered on the desktop while still being a managed Mission Control
        // participant. This behavior is intentionally experimental.
        presentationGeneration &+= 1
        let generation = presentationGeneration
        transitionToken = nil
        isSafelyPresented = false
        hasOrderingValidationDebt = true
        alphaValue = 0
        ignoresMouseEvents = true
        guard let requiredWindowIDs else {
            // The target group's own Window Server identities are mandatory.
            // Keep explicit recovery debt instead of authorizing the proxy from
            // a partial ordering snapshot.
            lastPresentedFrame = frame
            lastPresentedMemberWindowIDs = []
            orderingValidationIsInFlight = false
            // Ordering authorization is unresolved. Preserve the controller-owned
            // recovery debt, but withdraw this transparent managed surface from
            // Window Server until a later update can re-prove safe desktop ordering.
            // Leaving it registered here creates an invisible Mission Control
            // participant with no authorized presentation or input.
            orderOut(nil)
            return
        }
        // Capture structural identity before asynchronous verification starts.
        // Preview-only updates can now refresh the view without invalidating
        // or restarting this exact in-flight ordering transaction.
        lastPresentedFrame = frame
        lastPresentedMemberWindowIDs = requiredWindowIDs
        scheduleOrderingValidation(
            frame: frame,
            memberWindowIDs: requiredWindowIDs,
            generation: generation,
            attempt: 0,
            delay: MissionControlProxyOrderingRecoveryPolicy
                .verificationDelays[0]
        )
    }

    func applyTransientPreviews(
        _ previewsByMemberID: [String: NSImage],
        expectedFramesByMemberID: [String: CGRect]
    ) -> Bool {
        guard allowsTransientPreviewMutation,
              !previewsByMemberID.isEmpty,
              previewsByMemberID.count == expectedFramesByMemberID.count else {
            return false
        }
        let currentIDs = Set(proxyView.members.map(\.stableIdentity))
        let replacementIDs = Set(previewsByMemberID.keys)
        guard replacementIDs.isSubset(of: currentIDs),
              replacementIDs == Set(expectedFramesByMemberID.keys) else {
            return false
        }
        var replacement: [MissionControlGroupProxyMember] = []
        for member in proxyView.members {
            guard replacementIDs.contains(member.stableIdentity) else {
                replacement.append(member)
                continue
            }
            guard let preview = previewsByMemberID[member.stableIdentity],
                  let expectedFrame =
                    expectedFramesByMemberID[member.stableIdentity],
                  abs(member.frame.minX - expectedFrame.minX) < 1,
                  abs(member.frame.minY - expectedFrame.minY) < 1,
                  abs(member.frame.width - expectedFrame.width) < 1,
                  abs(member.frame.height - expectedFrame.height) < 1 else {
                return false
            }
            replacement.append(
                MissionControlGroupProxyMember(
                    stableIdentity: member.stableIdentity,
                    frame: member.frame,
                    preview: preview,
                    icon: member.icon
                )
            )
        }
        // Pixel-only mutation. Mission Control continues owning the exact same
        // managed NSWindow, frame, level, ordering and transform. Keep the
        // normal members so an unselected/invalidated session can discard the
        // temporary pixels synchronously without touching the normal cache.
        if normalMembersBeforeTransientPreview == nil {
            normalMembersBeforeTransientPreview = proxyView.members
        }
        proxyView.members = replacement.sorted {
            $0.stableIdentity < $1.stableIdentity
        }
        proxyView.needsDisplay = true
        displayIfNeeded()
        return true
    }


    func discardTransientPreviews() {
        guard let normalMembersBeforeTransientPreview else { return }
        proxyView.members = normalMembersBeforeTransientPreview
        self.normalMembersBeforeTransientPreview = nil
        // Release transient image ownership immediately, but do not force an
        // extra Window Server draw during Mission Control exit. A surviving
        // proxy redraws normally on the next safe presentation update.
        proxyView.needsDisplay = true
    }

    func retire() {
        presentationGeneration &+= 1
        normalMembersBeforeTransientPreview = nil
        selectionConfirmationGeneration &+= 1
        selectionWasDelivered = false
        beginSelectionConfirmation = nil
        consumeSelectionConfirmation = nil
        releaseSelectionConfirmation = nil
        onSelected = nil
        onQueuedMigrationSelected = nil
        onSelectionConfirmationTerminated = nil
        currentTransitionAuthorization = nil
        selectionConfirmationIsPending = false
        proxyView.spaceMigrationQueuePosition = nil
        proxyView.spaceMigrationQueueTotal = 0
        proxyView.members = []
        normalPresentationTitle = ""
        lastPresentedFrame = nil
        lastPresentedMemberWindowIDs = []
        isSafelyPresented = false
        hasOrderingValidationDebt = false
        orderingValidationIsInFlight = false
        transitionToken = nil
        level = .normal
        alphaValue = 0
        ignoresMouseEvents = true
        orderOut(nil)
    }

    func setSpaceMigrationQueued(position: Int, total: Int) {
        let normalizedPosition = max(position, 1)
        let normalizedTotal = max(total, normalizedPosition)
        let wasQueued = proxyView.spaceMigrationQueuePosition != nil
        proxyView.spaceMigrationQueuePosition = normalizedPosition
        proxyView.spaceMigrationQueueTotal = normalizedTotal
        if !wasQueued {
            // Keep the exact managed surface and its settled Mission Control
            // geometry. Only its pixels change; ordering, frame and collection
            // behavior remain untouched until the normal desktop dispatch.
            selectionConfirmationGeneration &+= 1
            selectionConfirmationIsPending = false
            selectionWasDelivered = false
            transitionToken = nil
            ignoresMouseEvents = true
        }
        title = MissionControlGroupProxyMigrationPresentationPolicy
            .presentation(
                queuePosition: normalizedPosition,
                queueTotal: normalizedTotal
            ).windowTitle
        proxyView.needsDisplay = true
        displayIfNeeded()
    }

    func restoreAfterSpaceMigrationSourceCancellation() {
        guard proxyView.spaceMigrationQueuePosition != nil else { return }
        selectionConfirmationGeneration &+= 1
        selectionConfirmationIsPending = false
        selectionWasDelivered = false
        proxyView.spaceMigrationQueuePosition = nil
        proxyView.spaceMigrationQueueTotal = 0
        if !normalPresentationTitle.isEmpty {
            title = normalPresentationTitle
        }
        if isSafelyPresented,
           currentTransitionAuthorization?(groupID) == true {
            transitionToken = MissionControlTransitionTokenPolicy.make(
                groupID: groupID,
                presentationGeneration: presentationGeneration
            )
        } else {
            transitionToken = nil
        }
        ignoresMouseEvents = true
        proxyView.needsDisplay = true
        displayIfNeeded()
    }

    func requireOrderingRevalidation() {
        // Selection confirmation owns this proxy until delivery. Generic
        // ordering recovery must not mutate it during that bounded handoff.
        guard !selectionConfirmationIsPending,
              MissionControlSelectedProxyPresentationPolicy
            .allowsGenericOrderingRevalidation(
                selectionWasDelivered: selectionWasDelivered
            ) else { return }

        let observation = orderingObservationBehindAllMembers(
            lastPresentedMemberWindowIDs
        )
        transitionToken = nil
        switch observation {
        case .verifiedBehind:
            isSafelyPresented = true
            hasOrderingValidationDebt = false
            orderingValidationIsInFlight = false
            return

        case .confirmedUnsafe:
            // This is real negative ordering evidence. Hide synchronously,
            // then use the existing bounded orderBack/revalidation path.
            isSafelyPresented = false
            hasOrderingValidationDebt = true
            presentationGeneration &+= 1
            let generation = presentationGeneration
            alphaValue = 0
            ignoresMouseEvents = true
            guard let frame = lastPresentedFrame,
                  !lastPresentedMemberWindowIDs.isEmpty else {
                orderOut(nil)
                return
            }
            scheduleOrderingValidation(
                frame: frame,
                memberWindowIDs: lastPresentedMemberWindowIDs,
                generation: generation,
                attempt: 0,
                delay: MissionControlProxyOrderingRecoveryPolicy
                    .verificationDelays[0],
                reorderBeforeValidation: true,
                preservePresentedLeaseOnUnresolved: false
            )

        case .unresolved:
            // A previously verified, unchanged proxy keeps its bounded
            // last-known-good ordering lease while Window Server evidence is
            // temporarily incomplete. Do not turn one missing snapshot into
            // physical Mission Control withdrawal. New/unverified proxies do
            // not receive this lease and remain fail-closed.
            let canPreserveLease = isSafelyPresented
                && lastPresentedFrame != nil
                && !lastPresentedMemberWindowIDs.isEmpty
            presentationGeneration &+= 1
            let generation = presentationGeneration
            hasOrderingValidationDebt = true
            guard let frame = lastPresentedFrame,
                  !lastPresentedMemberWindowIDs.isEmpty else {
                isSafelyPresented = false
                alphaValue = 0
                ignoresMouseEvents = true
                orderOut(nil)
                return
            }
            if canPreserveLease {
                // Preserve the managed Window Server participant, but do not
                // let incomplete ordering evidence grant new desktop input
                // ownership. Verification re-enables interaction.
                ignoresMouseEvents = true
            } else {
                isSafelyPresented = false
                alphaValue = 0
                ignoresMouseEvents = true
            }
            scheduleOrderingValidation(
                frame: frame,
                memberWindowIDs: lastPresentedMemberWindowIDs,
                generation: generation,
                attempt: 0,
                delay: MissionControlProxyOrderingRecoveryPolicy
                    .verificationDelays[0],
                reorderBeforeValidation: !canPreserveLease,
                preservePresentedLeaseOnUnresolved: canPreserveLease
            )
        }
    }

    func noteMissionControlTransitionObserved() {
        guard isSafelyPresented else { return }
        transitionToken = MissionControlTransitionTokenPolicy.make(
            groupID: groupID,
            presentationGeneration: presentationGeneration
        )
    }

    func cancelSelectionTransition() {
        presentationGeneration &+= 1
        discardTransientPreviews()
        selectionConfirmationGeneration &+= 1
        selectionWasDelivered = false
        selectionConfirmationIsPending = false
        isSafelyPresented = false
        orderingValidationIsInFlight = false
        hasOrderingValidationDebt = lastPresentedFrame != nil
            && !lastPresentedMemberWindowIDs.isEmpty
        transitionToken = nil
        level = .normal
        alphaValue = 0
        ignoresMouseEvents = true
        // Once a proxy has been selected, cancellation must remove that exact
        // cover from Window Server. orderBack() kept the managed window alive
        // as a Mission Control participant and allowed a stale composite to
        // remain visible until the transition ended. Recovery may rebuild it
        // later from fresh ordering evidence.
        orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !selectionWasDelivered,
              !selectionConfirmationIsPending else { return }
        if !MissionControlTransitionTokenPolicy.isValid(
            transitionToken,
            groupID: groupID,
            presentationGeneration: presentationGeneration
        ), currentTransitionAuthorization?(groupID) == true {
            // A user may remain in Mission Control longer than the token's
            // short stale-evidence lease. Re-prove the transform on demand at
            // the key event instead of extending the lease or adding polling.
            transitionToken = MissionControlTransitionTokenPolicy.make(
                groupID: groupID,
                presentationGeneration: presentationGeneration
            )
        }
        guard MissionControlTransitionTokenPolicy.isValid(
            transitionToken,
            groupID: groupID,
            presentationGeneration: presentationGeneration
        ) else { return }
        // Entering Mission Control can perturb key-window state without the
        // user choosing this proxy. Confirm the selection only after Tabora
        // is genuinely the active/frontmost application. This is a bounded
        // confirmation settlement, not a capture or polling loop.
        selectionConfirmationGeneration &+= 1
        let generation = selectionConfirmationGeneration
        selectionConfirmationIsPending = true
        let selectedGroupID = groupID
        let selectedMemberIDs = presentedMemberIDs
        let selectedPresentationGeneration = presentationGeneration
        guard let selectionCandidateGeneration = beginSelectionConfirmation?(
            selectedGroupID,
            selectedMemberIDs
        ), selectionCandidateGeneration != 0 else {
            selectionConfirmationIsPending = false
            return
        }
        scheduleSelectionConfirmationSettlement(
            selectionGeneration: generation,
            candidateGeneration: selectionCandidateGeneration,
            selectedGroupID: selectedGroupID,
            selectedMemberIDs: selectedMemberIDs,
            selectedPresentationGeneration: selectedPresentationGeneration,
            attempt: 0
        )
    }

    private func scheduleSelectionConfirmationSettlement(
        selectionGeneration: Int,
        candidateGeneration: UInt64,
        selectedGroupID: SnapGroupID,
        selectedMemberIDs: Set<String>,
        selectedPresentationGeneration: Int,
        attempt: Int
    ) {
        guard let delay = MissionControlProxySelectionConfirmationSettlementPolicy
            .delay(forAttempt: attempt) else {
            terminateSelectionConfirmation(
                candidateGeneration: candidateGeneration,
                selectedGroupID: selectedGroupID,
                selectedMemberIDs: selectedMemberIDs
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // A retired callback has no authority to terminate a newer pending
            // selection on this same proxy, even if its own token is invalid.
            guard let self,
                  self.selectionConfirmationGeneration == selectionGeneration
            else { return }
            guard self.groupID == selectedGroupID,
                  self.presentedMemberIDs == selectedMemberIDs,
                  self.presentationGeneration
                    == selectedPresentationGeneration,
                  MissionControlTransitionTokenPolicy.isValid(
                    self.transitionToken,
                    groupID: selectedGroupID,
                    presentationGeneration: selectedPresentationGeneration
                  ),
                  !self.selectionWasDelivered else {
                self.terminateSelectionConfirmation(
                    candidateGeneration: candidateGeneration,
                    selectedGroupID: selectedGroupID,
                    selectedMemberIDs: selectedMemberIDs
                )
                return
            }

            let applicationIsSettled = NSApp.isActive
                && NSWorkspace.shared.frontmostApplication?
                    .processIdentifier
                    == ProcessInfo.processInfo.processIdentifier
            guard applicationIsSettled else {
                if MissionControlProxySelectionConfirmationSettlementPolicy
                    .delay(forAttempt: attempt + 1) != nil {
                    self.scheduleSelectionConfirmationSettlement(
                        selectionGeneration: selectionGeneration,
                        candidateGeneration: candidateGeneration,
                        selectedGroupID: selectedGroupID,
                        selectedMemberIDs: selectedMemberIDs,
                        selectedPresentationGeneration:
                            selectedPresentationGeneration,
                        attempt: attempt + 1
                    )
                } else {
                    self.terminateSelectionConfirmation(
                        candidateGeneration: candidateGeneration,
                        selectedGroupID: selectedGroupID,
                        selectedMemberIDs: selectedMemberIDs
                    )
                }
                return
            }

            guard let confirmationDisposition =
                    self.consumeSelectionConfirmation?(
                        candidateGeneration,
                        selectedGroupID,
                        selectedMemberIDs
                    ),
                  confirmationDisposition != .rejected else {
                self.terminateSelectionConfirmation(
                    candidateGeneration: candidateGeneration,
                    selectedGroupID: selectedGroupID,
                    selectedMemberIDs: selectedMemberIDs
                )
                return
            }
            self.selectionConfirmationIsPending = false
            // One-shot authorization: key-window churn cannot replay the same
            // Mission Control transition evidence.
            self.transitionToken = nil
            self.selectionWasDelivered = true
            self.isSafelyPresented = false
            self.orderingValidationIsInFlight = false

            switch confirmationDisposition {
            case .rejected:
                return
            case .queuedMigrationForegroundIntent:
                // A queued migration selection authorizes only a future,
                // post-transport z-order pass. Do not reuse the ordinary
                // selected-Proxy floating handoff because no AXRaise happens
                // in this Mission Control exit and the composite would flash
                // above the real windows for no useful purpose. Keep the exact
                // managed surface inert until migration retires it.
                self.level = .normal
                self.alphaValue = 0
                self.ignoresMouseEvents = true
                self.onQueuedMigrationSelected?(
                    selectedGroupID,
                    selectedMemberIDs
                )
            case .normalGroupActivation:
                // The proxy is the Window Server surface that Mission Control
                // is already returning to the desktop. Keep its frozen
                // composite above the exact group only while the controller
                // performs the first per-window AXRaise sequence.
                self.level = .floating
                self.orderFrontRegardless()
                self.ignoresMouseEvents = true
                self.onSelected?(selectedGroupID, selectedMemberIDs)
                let handoffGeneration = self.selectionConfirmationGeneration
                DispatchQueue.main.asyncAfter(
                    deadline: .now()
                        + MissionControlSelectedProxyPresentationPolicy
                            .maximumVisibleHandoffLifetime
                ) { [weak self] in
                    guard let self,
                          self.selectionConfirmationGeneration
                            == handoffGeneration,
                          self.selectionWasDelivered else { return }
                    // Never leave a large composite visible if activation
                    // cannot settle. Keep the selected surface registered and
                    // inert so orderOut itself cannot perturb an in-flight
                    // Window Server animation; controller success/cancellation
                    // retires it.
                    self.alphaValue = 0
                    self.ignoresMouseEvents = true
                }
            }
        }
    }

    private func terminateSelectionConfirmation(
        candidateGeneration: UInt64,
        selectedGroupID: SnapGroupID,
        selectedMemberIDs: Set<String>
    ) {
        guard selectionConfirmationIsPending else { return }
        selectionConfirmationIsPending = false
        releaseSelectionConfirmation?(
            candidateGeneration,
            selectedGroupID,
            selectedMemberIDs
        )
        cancelSelectionTransition()
        onSelectionConfirmationTerminated?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Mission Control may resign the proxy while completing the very exit
        // that selected it. The captured key event remains authoritative for
        // the bounded confirmation turn; NSApp/frontmost/token checks below
        // still reject incidental key churn on Mission Control entry.
        guard MissionControlProxySelectionDeliveryPolicy
            .cancelsOnWindowResign(
                selectionWasDelivered: selectionWasDelivered,
                confirmationIsPending: selectionConfirmationIsPending
            ) else { return }
        if level != .floating {
            selectionConfirmationGeneration &+= 1
            selectionWasDelivered = false
            selectionConfirmationIsPending = false
        }
    }


    private func scheduleOrderingValidation(
        frame: CGRect,
        memberWindowIDs: Set<CGWindowID>,
        generation: Int,
        attempt: Int,
        delay: TimeInterval,
        reorderBeforeValidation: Bool = true,
        preservePresentedLeaseOnUnresolved: Bool = false
    ) {
        orderingValidationIsInFlight = true
        let perform = { [weak self] in
            guard let self,
                  self.presentationGeneration == generation,
                  !self.selectionWasDelivered,
                  !self.selectionConfirmationIsPending else { return }
            if reorderBeforeValidation {
                self.alphaValue = 0
                self.ignoresMouseEvents = true
                self.orderBack(nil)
            }
            // Ordering is asynchronous across Window Server. Verify on the
            // next main-loop turn. A preserved lease performs observation only;
            // confirmed unsafe evidence switches back to the normal hidden
            // orderBack/revalidation path.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.selectionWasDelivered,
                      !self.selectionConfirmationIsPending else { return }
                let observation = self.orderingObservationBehindAllMembers(
                    memberWindowIDs
                )
                switch observation {
                case .verifiedBehind:
                    self.lastPresentedFrame = frame
                    self.lastPresentedMemberWindowIDs = memberWindowIDs
                    self.isSafelyPresented = true
                    self.hasOrderingValidationDebt = false
                    self.orderingValidationIsInFlight = false
                    self.alphaValue = 1
                    self.ignoresMouseEvents = false
                    return

                case .confirmedUnsafe:
                    self.isSafelyPresented = false
                    self.hasOrderingValidationDebt = true
                    self.alphaValue = 0
                    self.ignoresMouseEvents = true
                    if let nextDelay = MissionControlProxyOrderingRecoveryPolicy
                        .delayAfterFailedAttempt(attempt) {
                        self.scheduleOrderingValidation(
                            frame: frame,
                            memberWindowIDs: memberWindowIDs,
                            generation: generation,
                            attempt: attempt + 1,
                            delay: nextDelay,
                            reorderBeforeValidation: true,
                            preservePresentedLeaseOnUnresolved: false
                        )
                    } else {
                        self.orderingValidationIsInFlight = false
                        self.orderOut(nil)
                    }

                case .unresolved:
                    self.hasOrderingValidationDebt = true
                    if let nextDelay = MissionControlProxyOrderingRecoveryPolicy
                        .delayAfterFailedAttempt(attempt) {
                        self.scheduleOrderingValidation(
                            frame: frame,
                            memberWindowIDs: memberWindowIDs,
                            generation: generation,
                            attempt: attempt + 1,
                            delay: nextDelay,
                            reorderBeforeValidation:
                                !preservePresentedLeaseOnUnresolved,
                            preservePresentedLeaseOnUnresolved:
                                preservePresentedLeaseOnUnresolved
                        )
                    } else {
                        // Last-known-good presentation is only a bounded lease.
                        // If Window Server never yields complete evidence, fail
                        // closed and hand residual liveness debt to Recovery.
                        self.isSafelyPresented = false
                        self.orderingValidationIsInFlight = false
                        self.alphaValue = 0
                        self.ignoresMouseEvents = true
                        self.orderOut(nil)
                    }
                }
            }
        }

        if delay <= 0 {
            perform()
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: perform
            )
        }
    }

    private func orderingObservationBehindAllMembers(
        _ memberWindowIDs: Set<CGWindowID>
    ) -> MissionControlProxyOrderingObservation {
        guard windowNumber > 0,
              memberWindowIDs.count >= 2,
              let info = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else { return .unresolved }
        let orderedIDs = info.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return MissionControlProxyOrderingPolicy.observation(
            proxyWindowID: UInt32(windowNumber),
            requiredWindowIDs: memberWindowIDs,
            orderedWindowIDs: orderedIDs
        )
    }

}

private final class MissionControlGroupProxyView: NSView {
    var members: [MissionControlGroupProxyMember] = []
    var spaceMigrationQueuePosition: Int?
    var spaceMigrationQueueTotal = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for member in members {
            let rect = member.frame.intersection(bounds)
            guard rect.width > 1, rect.height > 1 else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            if let preview = member.preview {
                preview.draw(
                    in: rect,
                    from: .zero,
                    operation: .copy,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
            } else {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                if let icon = member.icon {
                    let side = min(64, rect.width * 0.28, rect.height * 0.28)
                    icon.draw(
                        in: CGRect(
                            x: rect.midX - side / 2,
                            y: rect.midY - side / 2,
                            width: side,
                            height: side
                        )
                    )
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let queuePosition = spaceMigrationQueuePosition else { return }

        NSColor.black.withAlphaComponent(0.58).setFill()
        bounds.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let presentation =
            MissionControlGroupProxyMigrationPresentationPolicy.presentation(
                queuePosition: queuePosition,
                queueTotal: spaceMigrationQueueTotal
            )
        let title = presentation.title
        let subtitle = presentation.subtitle
        let horizontalInset = max(8, min(48, bounds.width * 0.07))
        let verticalInset = max(8, min(42, bounds.height * 0.07))
        let availableWidth = max(bounds.width - horizontalInset * 2, 1)
        let availableHeight = max(bounds.height - verticalInset * 2, 1)
        let titleFont = fittedFont(
            text: title,
            weight: .bold,
            maximumPointSize: min(
                MissionControlGroupProxyMigrationTypographyPolicy
                    .titleMaximumPointSize,
                availableHeight
                    * MissionControlGroupProxyMigrationTypographyPolicy
                        .titleHeightScale
            ),
            maximumWidth: availableWidth,
            maximumHeight: availableHeight * 0.30
        )
        let subtitleFont = fittedFont(
            text: subtitle,
            weight: .semibold,
            maximumPointSize: min(18, availableHeight * 0.09),
            maximumWidth: availableWidth,
            maximumHeight: availableHeight * 0.16
        )
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: paragraph
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        let spacing = max(5, min(22, availableHeight * 0.035))
        let totalHeight = titleSize.height + spacing + subtitleSize.height
        title.draw(
            in: CGRect(
                x: horizontalInset,
                y: bounds.midY - totalHeight / 2,
                width: availableWidth,
                height: titleSize.height
            ),
            withAttributes: titleAttributes
        )
        subtitle.draw(
            in: CGRect(
                x: horizontalInset,
                y: bounds.midY - totalHeight / 2
                    + titleSize.height + spacing,
                width: availableWidth,
                height: subtitleSize.height
            ),
            withAttributes: subtitleAttributes
        )
    }

    private func fittedFont(
        text: String,
        weight: NSFont.Weight,
        maximumPointSize: CGFloat,
        maximumWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> NSFont {
        var pointSize = max(1, maximumPointSize)
        for _ in 0..<2 {
            let font = NSFont.systemFont(ofSize: pointSize, weight: weight)
            let size = text.size(withAttributes: [.font: font])
            guard size.width > 0, size.height > 0 else { return font }
            let scale = min(
                1,
                maximumWidth / size.width,
                maximumHeight / size.height
            )
            pointSize = max(1, pointSize * scale)
        }
        return NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
