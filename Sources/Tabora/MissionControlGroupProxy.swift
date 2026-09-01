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
        let title = position == 1 ? "移動準備中" : "移動待機"
        let queueDescription = total > 1 ? "\(position)/\(total)  •  " : ""
        return MissionControlGroupProxyMigrationPresentation(
            title: title,
            subtitle: queueDescription + "Mission Controlを閉じると移動",
            windowTitle: position == 1
                ? "移動準備中 1/\(total)（Mission Controlを閉じると移動）"
                : "移動待機 \(position)/\(total)"
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

enum MissionControlPreviewFreshnessPolicy {
    static let refreshInterval: TimeInterval = 15
    static let applicationCoalescingInterval: TimeInterval = 0.06

    static func needsRefresh(
        capturedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard let capturedAt else { return true }
        return now - capturedAt >= refreshInterval
    }
}

enum MissionControlPreviewGeometryRefreshPolicy {
    /// A resize is settled only after the frame size has remained unchanged.
    /// The existing one-second Recovery watchdog admits the actual capture, so
    /// normal completion occurs roughly two to three seconds after resize.
    static let settleInterval: TimeInterval = 2
    static let maximumSettledCapturesPerRefresh = 2

    static func deadline(after now: TimeInterval) -> TimeInterval {
        now + settleInterval
    }

    static func resolvedDeadline(
        sizeChanged: Bool,
        pendingDeadline: TimeInterval?,
        now: TimeInterval
    ) -> TimeInterval? {
        if sizeChanged { return deadline(after: now) }
        return pendingDeadline
    }

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
    /// Periodic freshness is derived work. Bound it globally per watchdog
    /// interval even when many members are simultaneously exposed.
    static let maximumPeriodicCapturesPerRefresh = 2
    /// A covered member receives one final settled image, then freezes.
    static let coolingFinalCaptureDelay: TimeInterval = 3

    static func periodicRequestCount(
        staleCount: Int,
        outstandingCount: Int
    ) -> Int {
        let available = max(
            maximumOutstandingCaptureCount - max(outstandingCount, 0),
            0
        )
        return min(
            max(staleCount, 0),
            maximumPeriodicCapturesPerRefresh,
            available
        )
    }

    static func periodicRequestIndices(
        staleCount: Int,
        cursor: Int,
        requestCount: Int
    ) -> [Int] {
        guard staleCount > 0, requestCount > 0 else { return [] }
        let start = max(cursor, 0) % staleCount
        return (0..<min(requestCount, staleCount)).map {
            (start + $0) % staleCount
        }
    }
}

enum MissionControlPreviewActivityPolicy {
    static func desiredHotMemberIDs<GroupID: Hashable>(
        previousHotMemberIDs: Set<String>,
        currentMemberIDsByGroupID: [GroupID: Set<String>],
        observedExposedMemberIDsByGroupID: [GroupID: Set<String>]
    ) -> Set<String> {
        let currentMemberIDs = currentMemberIDsByGroupID.values.reduce(
            into: Set<String>()
        ) { $0.formUnion($1) }
        var desired = previousHotMemberIDs.intersection(currentMemberIDs)
        for (groupID, memberIDs) in currentMemberIDsByGroupID {
            guard let exposed = observedExposedMemberIDsByGroupID[groupID]
            else {
                // An incomplete Window Server census preserves prior activity.
                continue
            }
            desired.subtract(memberIDs)
            desired.formUnion(exposed.intersection(memberIDs))
        }
        return desired
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

private struct MissionControlPreviewCacheKey: Hashable {
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
    let capturedAt: TimeInterval
    var accessEpoch: UInt64
}

private struct MissionControlPreviewRequest {
    let generation: UInt64
    var retryRemaining: Bool
}

final class MissionControlGroupProxyController {
    var onSelectGroup: ((SnapGroupID, Set<String>) -> Void)?
    var onSelectQueuedMigrationGroup: ((SnapGroupID, Set<String>) -> Void)?
    var onSelectionConfirmationTerminated: (() -> Void)?
    var currentTransitionAuthorization: ((SnapGroupID) -> Bool)?
    var selectionConfirmationIsAllowed: ((SnapGroupID) -> Bool)?
    var queuedMigrationSelectionIsAllowed: ((SnapGroupID) -> Bool)?
    var onPreviewCacheReady: (() -> Void)?

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
    private var previewCaptureGeneration: UInt64 = 0
    private var previewsAreEnabled = true
    private var previewCaptureIsSuspended = false
    private var hasPendingPreviewCacheApplication = false
    private var previewCacheRefreshNotificationScheduled = false
    private var maximumCachedPreviewBytes = AppSettings
        .missionControlPreviewMemoryByteLimit(
            AppSettings.defaultMissionControlPreviewMemoryLimitMiB
        )
    private var activePreviewKeys = Set<MissionControlPreviewCacheKey>()
    private var knownPreviewMemberIDs = Set<String>()
    private var hotPreviewKeys = Set<MissionControlPreviewCacheKey>()
    private var immediatePreviewKeys = Set<MissionControlPreviewCacheKey>()
    private var interruptedPreviewKeys = Set<MissionControlPreviewCacheKey>()
    private var coolingPreviewDeadlines:
        [MissionControlPreviewCacheKey: TimeInterval] = [:]
    private var settledGeometryPreviewDeadlines:
        [MissionControlPreviewCacheKey: TimeInterval] = [:]
    private var activePreviewByteBudget = 0
    private var latestPreviewProvider: ((CGWindowID?) -> CGImage?)?
    private var nextPreviewFreshnessCheckAt: TimeInterval = 0
    private var periodicPreviewRefreshCursor = 0
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

    func update(
        groups: [SnapGroup],
        visibleWindowsByIdentity: [String: ManagedWindow],
        displayOrdinalsByGroupID: [SnapGroupID: Int],
        preservedGroupIDs: Set<SnapGroupID> = [],
        exposedPreviewMemberIDsByGroupID: [SnapGroupID: Set<String>] = [:],
        previewsEnabled: Bool,
        previewCacheByteLimit: Int,
        previewProvider: @escaping (CGWindowID?) -> CGImage?
    ) {
        setPreviewCacheByteLimit(previewCacheByteLimit)
        setPreviewsEnabled(previewsEnabled)
        let presentableGroups = groups.filter { group in
            group.memberIDs.count >= 2
                && group.memberIDs.allSatisfy {
                    visibleWindowsByIdentity[$0] != nil
                }
        }
        let activeGroupIDs = Set(presentableGroups.map(\.id))
            .union(preservedGroupIDs)
        let activeWindows = presentableGroups.flatMap { group in
            group.memberIDs.compactMap { visibleWindowsByIdentity[$0] }
        }
        let currentPreviewKeys = Set(activeWindows.compactMap { window
            -> MissionControlPreviewCacheKey? in
            guard let windowID = window.cgWindowID else { return nil }
            return Self.previewCacheKey(
                for: window,
                windowID: windowID
            )
        })
        let previewKeysByGroupID = Dictionary(
            uniqueKeysWithValues: presentableGroups.map { group in
                let keys = Set(group.memberIDs.compactMap { memberID in
                    visibleWindowsByIdentity[memberID].flatMap { window
                        -> MissionControlPreviewCacheKey? in
                        guard let windowID = window.cgWindowID else {
                            return nil
                        }
                        return Self.previewCacheKey(
                            for: window,
                            windowID: windowID
                        )
                    }
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
            // A frame-only key change must not turn a frozen COLD member into
            // a new member and start an unbounded sequence of captures. Carry
            // its derived image to the new geometry key; a size change is
            // refreshed only through the settled-geometry lane below.
            for key in currentPreviewKeys where cachedPreviews[key] == nil {
                if let previous = cachedPreviews.first(where: {
                    Self.representsSamePhysicalWindow($0.key, key)
                })?.value {
                    cachedPreviews[key] = previous
                }
            }
            // Frame-position changes do not alter captured pixels. A size
            // change does, so debounce it by physical identity and retain only
            // the newest active geometry key. Repeated resize samples keep
            // moving this one deadline instead of adding capture operations.
            for key in currentPreviewKeys {
                guard let previousKey = previousActivePreviewKeys.first(where: {
                    Self.representsSamePhysicalWindow($0, key)
                        && $0 != key
                }) else { continue }
                let pendingGeometryDeadline =
                    settledGeometryPreviewDeadlines.first {
                        Self.representsSamePhysicalWindow($0.key, key)
                    }?.value
                settledGeometryPreviewDeadlines =
                    settledGeometryPreviewDeadlines.filter {
                        !Self.representsSamePhysicalWindow($0.key, key)
                    }
                let sizeChanged = previousKey.frameWidth != key.frameWidth
                    || previousKey.frameHeight != key.frameHeight
                if let resolvedDeadline =
                    MissionControlPreviewGeometryRefreshPolicy
                        .resolvedDeadline(
                            sizeChanged: sizeChanged,
                            pendingDeadline: pendingGeometryDeadline,
                            now: activityNow
                        ) {
                    // A position-only key change carries the existing wait;
                    // a real size change starts a new quiet-period deadline.
                    settledGeometryPreviewDeadlines[key] =
                        resolvedDeadline
                }
            }
            // Inactive frame-key variants have no current presentation value.
            // Retiring them before new captures guarantees that the complete
            // active set can occupy the configured budget together.
            cachedPreviews = cachedPreviews.filter {
                currentPreviewKeys.contains($0.key)
            }
            updatePreviewActivity(
                currentPreviewKeys: currentPreviewKeys,
                previewKeysByGroupID: previewKeysByGroupID,
                exposedMemberIDsByGroupID:
                    exposedPreviewMemberIDsByGroupID,
                now: activityNow
            )
            if perImageBudgetBecameSmaller {
                // Adding another group reduces every member's share.
                // Re-encode COLD members once too; otherwise an oversized old
                // cache entry would be rejected and never replaced.
                immediatePreviewKeys.formUnion(currentPreviewKeys)
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
            let members = memberWindows.map { window in
                MissionControlGroupProxyMember(
                    stableIdentity: window.stableIdentity,
                    frame: window.frame.offsetBy(
                        dx: -bounds.minX,
                        dy: -bounds.minY
                    ),
                    preview: previewsEnabled ? previewImage(
                        for: window,
                        byteBudget: previewByteBudget,
                        previewProvider: previewProvider
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
                title: "グループ \(displayOrdinal)",
                frame: bounds,
                members: members,
                requiredWindowIDs: requiredWindowIDs
            )
        }
        hasPendingPreviewCacheApplication = false
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
        maximumCachedPreviewBytes = normalized
        clearPreviewCache()
        // A budget change invalidates every encoded size. Rebuild every active
        // member once; COLD status controls only later periodic refreshes.
        immediatePreviewKeys.formUnion(activePreviewKeys)
    }

    /// Applies user authorization independently of proxy presentation. This is
    /// intentionally callable even while Snap/Assist owns the UI and normal
    /// proxy refresh is suppressed.
    func setPreviewsEnabled(_ enabled: Bool) {
        guard previewsAreEnabled != enabled else { return }
        previewCaptureGeneration &+= 1
        previewsAreEnabled = enabled
        previewQueue.cancelAllOperations()
        previewRequestsByKey.removeAll()
        nextPreviewFreshnessCheckAt = 0
        if enabled {
            immediatePreviewKeys.formUnion(hotPreviewKeys)
            return
        }
        cachedPreviews.removeAll()
        activePreviewKeys.removeAll()
        knownPreviewMemberIDs.removeAll()
        hotPreviewKeys.removeAll()
        immediatePreviewKeys.removeAll()
        interruptedPreviewKeys.removeAll()
        coolingPreviewDeadlines.removeAll()
        settledGeometryPreviewDeadlines.removeAll()
        activePreviewByteBudget = 0
        latestPreviewProvider = nil
        hasPendingPreviewCacheApplication = false
        previewCacheRefreshNotificationScheduled = false
        periodicPreviewRefreshCursor = 0
    }

    func clearPreviewCache() {
        previewCaptureGeneration &+= 1
        previewQueue.cancelAllOperations()
        cachedPreviews.removeAll()
        previewRequestsByKey.removeAll()
        hasPendingPreviewCacheApplication = false
        nextPreviewFreshnessCheckAt = 0
        periodicPreviewRefreshCursor = 0
        settledGeometryPreviewDeadlines.removeAll()
        immediatePreviewKeys.formUnion(hotPreviewKeys)
    }

    func setPreviewCaptureSuspended(_ suspended: Bool) {
        guard previewCaptureIsSuspended != suspended else { return }
        previewCaptureIsSuspended = suspended
        previewCaptureGeneration &+= 1
        interruptedPreviewKeys.formUnion(previewRequestsByKey.keys)
        previewRequestsByKey.removeAll()
        previewQueue.cancelAllOperations()
        nextPreviewFreshnessCheckAt = 0
        if !suspended {
            // A queued/running initial or cooling capture may have been
            // interrupted at lock time. Resume those exact active keys once.
            immediatePreviewKeys.formUnion(
                interruptedPreviewKeys.intersection(activePreviewKeys)
            )
            interruptedPreviewKeys.removeAll()
            immediatePreviewKeys.formUnion(hotPreviewKeys)
        }
    }

    func refreshStalePreviewCacheIfNeeded(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        allowsSettledGeometryRefresh: Bool = true
    ) {
        guard previewsAreEnabled,
              !previewCaptureIsSuspended,
              activePreviewByteBudget > 0,
              let previewProvider = latestPreviewProvider else { return }
        schedulePriorityPreviewCaptures(
            now: now,
            previewProvider: previewProvider
        )
        if now >= nextPreviewFreshnessCheckAt {
            nextPreviewFreshnessCheckAt = now
                + MissionControlPreviewFreshnessPolicy.refreshInterval
            let staleKeys = hotPreviewKeys.filter { key in
                settledGeometryPreviewDeadlines[key] == nil
                    && MissionControlPreviewFreshnessPolicy.needsRefresh(
                        capturedAt: cachedPreviews[key]?.capturedAt,
                        now: now
                    )
            }.sorted(by: Self.previewKeyIsOrderedBefore)
            let requestCount = MissionControlPreviewWorkPolicy
                .periodicRequestCount(
                    staleCount: staleKeys.count,
                    outstandingCount: previewRequestsByKey.count
                )
            let requestIndices = MissionControlPreviewWorkPolicy
                .periodicRequestIndices(
                    staleCount: staleKeys.count,
                    cursor: periodicPreviewRefreshCursor,
                    requestCount: requestCount
                )
            if let lastIndex = requestIndices.last, !staleKeys.isEmpty {
                periodicPreviewRefreshCursor =
                    (lastIndex + 1) % staleKeys.count
            }
            for index in requestIndices {
                let key = staleKeys[index]
                schedulePreviewCapture(
                    key: key,
                    byteBudget: activePreviewByteBudget,
                    previewProvider: previewProvider
                )
            }
        }
        // The resize-settled lane is additive derived work. Existing initial,
        // COLD-final and HOT-periodic requests keep their established order;
        // geometry refresh consumes only the remaining global capacity.
        if allowsSettledGeometryRefresh {
            scheduleSettledGeometryPreviewCaptures(
                now: now,
                previewProvider: previewProvider
            )
        }
    }

    func hide(groupID: SnapGroupID) {
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
        windowID: CGWindowID
    ) -> MissionControlPreviewCacheKey {
        MissionControlPreviewCacheKey(
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

    private func previewImage(
        for window: ManagedWindow,
        byteBudget: Int,
        previewProvider: @escaping (CGWindowID?) -> CGImage?
    ) -> NSImage? {
        guard let windowID = window.cgWindowID else { return nil }
        let key = Self.previewCacheKey(
            for: window,
            windowID: windowID
        )
        previewAccessEpoch &+= 1
        if var cached = cachedPreviews[key] {
            cached.accessEpoch = previewAccessEpoch
            cachedPreviews[key] = cached
            if cached.byteCost > byteBudget,
               (hotPreviewKeys.contains(key)
                    || immediatePreviewKeys.contains(key)
                    || coolingPreviewDeadlines[key] != nil) {
                // Keep the old image visible until the smaller encoding is
                // ready. A budget change must not create an icon-only gap.
                schedulePreviewCapture(
                    key: key,
                    byteBudget: byteBudget,
                    previewProvider: previewProvider,
                    retryRemaining: true
                )
            }
            // Stale-while-revalidate remains visible, but periodic capture is
            // admitted only by refreshStalePreviewCacheIfNeeded(). Calling
            // update for one completed image must not cascade into captures
            // for every other stale group.
            return cached.image
        }

        // Never synchronously capture a client window from the main thread.
        // Screen sharing can make Window Server capture slow enough to stall
        // snapping, foregrounding and unrelated groups. Return the icon-backed
        // placeholder immediately and populate this bounded cache off-main.
        guard settledGeometryPreviewDeadlines[key] == nil else { return nil }
        guard hotPreviewKeys.contains(key)
                || immediatePreviewKeys.contains(key)
                || coolingPreviewDeadlines[key] != nil
                || previewRequestsByKey[key] != nil else {
            return nil
        }
        schedulePreviewCapture(
            key: key,
            byteBudget: byteBudget,
            previewProvider: previewProvider
        )
        return nil
    }

    @discardableResult
    private func schedulePreviewCapture(
        key: MissionControlPreviewCacheKey,
        byteBudget: Int,
        previewProvider: @escaping (CGWindowID?) -> CGImage?,
        retryRemaining: Bool = false,
        allowsPendingGeometryRefresh: Bool = false
    ) -> Bool {
        if var existing = previewRequestsByKey[key] {
            if retryRemaining && !existing.retryRemaining {
                existing.retryRemaining = true
                previewRequestsByKey[key] = existing
            }
            return true
        }
        guard previewsAreEnabled,
              byteBudget > 0,
              !previewCaptureIsSuspended,
              allowsPendingGeometryRefresh
                || settledGeometryPreviewDeadlines[key] == nil,
              previewRequestsByKey.count
                < MissionControlPreviewWorkPolicy
                    .maximumOutstandingCaptureCount,
              activePreviewKeys.contains(key) else { return false }
        let captureGeneration = previewCaptureGeneration
        previewRequestsByKey[key] = MissionControlPreviewRequest(
            generation: captureGeneration,
            retryRemaining: retryRemaining
        )
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation,
                  !operation.isCancelled else { return }
            let rendered: (CGImage, Int)? = previewProvider(key.windowID).flatMap { source in
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
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let completedRequest = self.previewRequestsByKey[key]
                if completedRequest?.generation == captureGeneration {
                    self.previewRequestsByKey.removeValue(forKey: key)
                }
                guard self.previewCaptureGeneration == captureGeneration,
                      self.previewsAreEnabled,
                      self.activePreviewKeys.contains(key) else { return }
                guard self.settledGeometryPreviewDeadlines[key] == nil else {
                    // A request admitted before the latest resize must not
                    // satisfy that new geometry. Its result is disposable;
                    // the newest settled deadline retains ownership. This also
                    // rejects a settled request if resize moved away and back
                    // to the same rounded frame key while it was running.
                    return
                }
                guard byteBudget == self.activePreviewByteBudget else {
                    // The number of active members changed while this capture
                    // was running. Never insert an image rendered against the
                    // old larger share; immediately requeue this exact active
                    // key using the current globally divided budget.
                    if self.activePreviewByteBudget > 0,
                       let currentProvider = self.latestPreviewProvider {
                        self.schedulePreviewCapture(
                            key: key,
                            byteBudget: self.activePreviewByteBudget,
                            previewProvider: currentProvider,
                            retryRemaining:
                                completedRequest?.retryRemaining ?? false
                        )
                    }
                    return
                }
                guard let (image, cost) = rendered else {
                    if completedRequest?.retryRemaining == true,
                       let currentProvider = self.latestPreviewProvider {
                        _ = self.schedulePreviewCapture(
                            key: key,
                            byteBudget: self.activePreviewByteBudget,
                            previewProvider: currentProvider,
                            retryRemaining: false
                        )
                    }
                    // Fill any remaining initial/cooling slots even when this
                    // provider returned nil. A failed member must not stall all
                    // later candidate images behind it.
                    if let currentProvider = self.latestPreviewProvider {
                        self.schedulePriorityPreviewCaptures(
                            now: ProcessInfo.processInfo.systemUptime,
                            previewProvider: currentProvider
                        )
                    }
                    return
                }
                self.previewAccessEpoch &+= 1
                let preview = NSImage(
                    cgImage: image,
                    size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
                )
                self.cachedPreviews[key] = MissionControlCachedPreview(
                    image: preview,
                    byteCost: cost,
                    capturedAt: ProcessInfo.processInfo.systemUptime,
                    accessEpoch: self.previewAccessEpoch
                )
                self.trimPreviewCacheIfNeeded()
                self.hasPendingPreviewCacheApplication = true
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

    private func updatePreviewActivity(
        currentPreviewKeys: Set<MissionControlPreviewCacheKey>,
        previewKeysByGroupID:
            [SnapGroupID: Set<MissionControlPreviewCacheKey>],
        exposedMemberIDsByGroupID: [SnapGroupID: Set<String>],
        now: TimeInterval
    ) {
        let previousKnownMemberIDs = knownPreviewMemberIDs
        let memberIDsByGroupID = previewKeysByGroupID.mapValues { keys in
            Set(keys.map(\.stableIdentity))
        }
        let desiredHotMemberIDs = MissionControlPreviewActivityPolicy
            .desiredHotMemberIDs(
                previousHotMemberIDs: Set(
                    hotPreviewKeys.map(\.stableIdentity)
                ),
                currentMemberIDsByGroupID: memberIDsByGroupID,
                observedExposedMemberIDsByGroupID:
                    exposedMemberIDsByGroupID
            )
        let desiredHotKeys = Set(currentPreviewKeys.filter {
            desiredHotMemberIDs.contains($0.stableIdentity)
        })
        let previousHotMemberIDs = Set(
            hotPreviewKeys.map(\.stableIdentity)
        )

        let newKeys = currentPreviewKeys.filter {
            !previousKnownMemberIDs.contains($0.stableIdentity)
        }
        // Every new member gets one initial image even when it is already
        // covered. This is finite, presentation-only work.
        immediatePreviewKeys.formUnion(newKeys)

        let newlyHotMemberIDs = desiredHotMemberIDs.subtracting(
            previousHotMemberIDs
        )
        let newlyHot = Set(desiredHotKeys.filter {
            newlyHotMemberIDs.contains($0.stableIdentity)
        })
        immediatePreviewKeys.formUnion(newlyHot)
        coolingPreviewDeadlines = coolingPreviewDeadlines.filter {
            !desiredHotMemberIDs.contains($0.key.stableIdentity)
        }

        let newlyColdMemberIDs = previousHotMemberIDs.subtracting(
            desiredHotMemberIDs
        )
        for key in currentPreviewKeys where
            newlyColdMemberIDs.contains(key.stableIdentity) {
            coolingPreviewDeadlines[key] = now
                + MissionControlPreviewWorkPolicy.coolingFinalCaptureDelay
        }

        knownPreviewMemberIDs = Set(
            currentPreviewKeys.map(\.stableIdentity)
        )
        hotPreviewKeys = desiredHotKeys
        immediatePreviewKeys.formIntersection(currentPreviewKeys)
        interruptedPreviewKeys.formIntersection(currentPreviewKeys)
        coolingPreviewDeadlines = coolingPreviewDeadlines.filter {
            currentPreviewKeys.contains($0.key)
                && !desiredHotKeys.contains($0.key)
        }
        settledGeometryPreviewDeadlines =
            settledGeometryPreviewDeadlines.filter {
                currentPreviewKeys.contains($0.key)
            }
    }

    private func schedulePriorityPreviewCaptures(
        now: TimeInterval,
        previewProvider: @escaping (CGWindowID?) -> CGImage?
    ) {
        let immediate = immediatePreviewKeys.sorted(
            by: Self.previewKeyIsOrderedBefore
        )
        for key in immediate {
            guard previewRequestsByKey.count
                    < MissionControlPreviewWorkPolicy
                        .maximumOutstandingCaptureCount else { break }
            if schedulePreviewCapture(
                key: key,
                byteBudget: activePreviewByteBudget,
                previewProvider: previewProvider,
                retryRemaining: true
            ) {
                immediatePreviewKeys.remove(key)
            }
        }

        let cooling = coolingPreviewDeadlines.filter {
            $0.value <= now
        }.map(\.key).sorted(by: Self.previewKeyIsOrderedBefore)
        for key in cooling {
            guard previewRequestsByKey.count
                    < MissionControlPreviewWorkPolicy
                        .maximumOutstandingCaptureCount else { break }
            let geometryDeadline = settledGeometryPreviewDeadlines[key]
            if let geometryDeadline, geometryDeadline > now { continue }
            let alsoFulfillsGeometryRefresh = geometryDeadline != nil
            if alsoFulfillsGeometryRefresh,
               previewRequestsByKey[key] != nil {
                // An earlier request cannot satisfy the newer resize. Keep
                // both owners queued until that request retires.
                continue
            }
            if schedulePreviewCapture(
                key: key,
                byteBudget: activePreviewByteBudget,
                previewProvider: previewProvider,
                retryRemaining: true,
                allowsPendingGeometryRefresh:
                    alsoFulfillsGeometryRefresh
            ) {
                coolingPreviewDeadlines.removeValue(forKey: key)
                if alsoFulfillsGeometryRefresh {
                    settledGeometryPreviewDeadlines.removeValue(forKey: key)
                    immediatePreviewKeys.remove(key)
                }
            }
        }
    }

    private func scheduleSettledGeometryPreviewCaptures(
        now: TimeInterval,
        previewProvider: @escaping (CGWindowID?) -> CGImage?
    ) {
        let settled = settledGeometryPreviewDeadlines.filter {
            $0.value <= now
                && previewRequestsByKey[$0.key] == nil
                && coolingPreviewDeadlines[$0.key] == nil
        }.map(\.key).sorted(by: Self.previewKeyIsOrderedBefore)
        let settledRequestCount = MissionControlPreviewGeometryRefreshPolicy
            .requestCount(
                dueCount: settled.count,
                outstandingCount: previewRequestsByKey.count
        )
        for key in settled.prefix(settledRequestCount) {
            if schedulePreviewCapture(
                key: key,
                byteBudget: activePreviewByteBudget,
                previewProvider: previewProvider,
                retryRemaining: true,
                allowsPendingGeometryRefresh: true
            ) {
                settledGeometryPreviewDeadlines.removeValue(forKey: key)
                // One settled capture also satisfies coincident initial,
                // budget-reencode or COLD-final ownership for this exact key.
                immediatePreviewKeys.remove(key)
                coolingPreviewDeadlines.removeValue(forKey: key)
            }
        }
    }


    private func schedulePreviewCacheRefreshNotification() {
        guard !previewCacheRefreshNotificationScheduled else { return }
        previewCacheRefreshNotificationScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + MissionControlPreviewFreshnessPolicy
                    .applicationCoalescingInterval
        ) { [weak self] in
            guard let self else { return }
            self.previewCacheRefreshNotificationScheduled = false
            guard self.hasPendingPreviewCacheApplication,
                  self.previewsAreEnabled else { return }
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
        }
    }

    private static func previewKeyIsOrderedBefore(
        _ lhs: MissionControlPreviewCacheKey,
        _ rhs: MissionControlPreviewCacheKey
    ) -> Bool {
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

private final class MissionControlGroupProxyWindow: NSWindow, NSWindowDelegate {
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

    var isSelectionConfirmationPending: Bool {
        selectionConfirmationIsPending
    }

    var needsPresentationRecovery: Bool {
        hasOrderingValidationDebt && !selectionWasDelivered
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

    func retire() {
        presentationGeneration &+= 1
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
            guard let self else { return }
            guard self.selectionConfirmationGeneration == selectionGeneration,
                  self.groupID == selectedGroupID,
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
