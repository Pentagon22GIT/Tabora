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

final class MissionControlGroupProxyController {
    var onSelectGroup: ((SnapGroupID, Set<String>) -> Void)?
    var currentTransitionAuthorization: ((SnapGroupID) -> Bool)?
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
    private var previewRequestGenerationByKey =
        [MissionControlPreviewCacheKey: UInt64]()
    private var previewCaptureGeneration: UInt64 = 0
    private var previewsAreEnabled = true
    private var hasPendingPreviewCacheApplication = false
    private var previewCacheRefreshNotificationScheduled = false
    private var maximumCachedPreviewBytes = AppSettings
        .missionControlPreviewMemoryByteLimit(
            AppSettings.defaultMissionControlPreviewMemoryLimitMiB
        )
    private var activePreviewKeys = Set<MissionControlPreviewCacheKey>()
    private var activePreviewByteBudget = 0
    private var latestPreviewProvider: ((CGWindowID?) -> CGImage?)?
    private var nextPreviewFreshnessCheckAt: TimeInterval = 0
    private var selectionCandidateGeneration: UInt64 = 0
    private var activeSelectionCandidate: MissionControlProxySelectionCandidate?

    var hasPendingSelectionConfirmation: Bool {
        activeSelectionCandidate != nil
            || windowsByGroupID.values.contains {
                $0.isSelectionConfirmationPending
            }
    }

    func update(
        groups: [SnapGroup],
        visibleWindowsByIdentity: [String: ManagedWindow],
        preservedGroupIDs: Set<SnapGroupID> = [],
        previewsEnabled: Bool,
        previewCacheByteLimit: Int,
        previewProvider: @escaping (CGWindowID?) -> CGImage?
    ) {
        setPreviewCacheByteLimit(previewCacheByteLimit)
        if previewsEnabled != previewsAreEnabled {
            previewCaptureGeneration &+= 1
            previewsAreEnabled = previewsEnabled
        }
        if !previewsEnabled {
            clearPreviewCache()
            activePreviewKeys.removeAll()
            activePreviewByteBudget = 0
            latestPreviewProvider = nil
        }
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
            activePreviewKeys = currentPreviewKeys
            activePreviewByteBudget = previewByteBudget
            latestPreviewProvider = previewProvider
            // Inactive frame-key variants have no current presentation value.
            // Retiring them before new captures guarantees that the complete
            // active set can occupy the configured budget together.
            cachedPreviews = cachedPreviews.filter {
                currentPreviewKeys.contains($0.key)
            }
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

        for (index, group) in presentableGroups.enumerated() {
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
                ) ?? false
            }
            proxyWindow.releaseSelectionConfirmation = {
                [weak self] generation, groupID, memberIDs in
                self?.releaseSelectionConfirmation(
                    generation: generation,
                    groupID: groupID,
                    memberIDs: memberIDs
                )
            }
            proxyWindow.currentTransitionAuthorization = { [weak self] groupID in
                self?.currentTransitionAuthorization?(groupID) ?? false
            }
            proxyWindow.onSelected = { [weak self] groupID, memberIDs in
                self?.onSelectGroup?(groupID, memberIDs)
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
                title: "グループ \(index + 1)",
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

    func setPreviewCacheByteLimit(_ byteLimit: Int) {
        let normalized = max(byteLimit, 0)
        guard maximumCachedPreviewBytes != normalized else { return }
        maximumCachedPreviewBytes = normalized
        clearPreviewCache()
    }

    func clearPreviewCache() {
        previewCaptureGeneration &+= 1
        cachedPreviews.removeAll()
        previewRequestGenerationByKey.removeAll()
        hasPendingPreviewCacheApplication = false
        nextPreviewFreshnessCheckAt = 0
    }

    func refreshStalePreviewCacheIfNeeded(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard previewsAreEnabled,
              now >= nextPreviewFreshnessCheckAt,
              activePreviewByteBudget > 0,
              let previewProvider = latestPreviewProvider else { return }
        nextPreviewFreshnessCheckAt = now
            + MissionControlPreviewFreshnessPolicy.refreshInterval
        for key in activePreviewKeys where
            MissionControlPreviewFreshnessPolicy.needsRefresh(
                capturedAt: cachedPreviews[key]?.capturedAt,
                now: now
            ) {
            schedulePreviewCapture(
                key: key,
                byteBudget: activePreviewByteBudget,
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
    ) -> Bool {
        guard MissionControlProxySelectionCandidatePolicy.matches(
            activeSelectionCandidate,
            generation: generation,
            groupID: groupID,
            memberIDs: memberIDs
        ) else { return false }
        activeSelectionCandidate = nil
        for (candidateGroupID, window) in windowsByGroupID where
            candidateGroupID != groupID {
            window.cancelSelectionTransition()
        }
        return true
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
        if var cached = cachedPreviews[key],
           cached.byteCost <= byteBudget {
            cached.accessEpoch = previewAccessEpoch
            cachedPreviews[key] = cached
            if MissionControlPreviewFreshnessPolicy.needsRefresh(
                capturedAt: cached.capturedAt,
                now: ProcessInfo.processInfo.systemUptime
            ) {
                schedulePreviewCapture(
                    key: key,
                    byteBudget: byteBudget,
                    previewProvider: previewProvider
                )
            }
            return cached.image
        }

        // Never synchronously capture a client window from the main thread.
        // Screen sharing can make Window Server capture slow enough to stall
        // snapping, foregrounding and unrelated groups. Return the icon-backed
        // placeholder immediately and populate this bounded cache off-main.
        cachedPreviews.removeValue(forKey: key)
        schedulePreviewCapture(
            key: key,
            byteBudget: byteBudget,
            previewProvider: previewProvider
        )
        return nil
    }

    private func schedulePreviewCapture(
        key: MissionControlPreviewCacheKey,
        byteBudget: Int,
        previewProvider: @escaping (CGWindowID?) -> CGImage?
    ) {
        guard byteBudget > 0,
              previewRequestGenerationByKey[key] == nil else { return }
        let captureGeneration = previewCaptureGeneration
        previewRequestGenerationByKey[key] = captureGeneration
        previewQueue.addOperation { [weak self] in
            guard let self else { return }
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.previewRequestGenerationByKey[key]
                    == captureGeneration {
                    self.previewRequestGenerationByKey.removeValue(
                        forKey: key
                    )
                }
                guard self.previewCaptureGeneration == captureGeneration,
                      self.previewsAreEnabled,
                      self.activePreviewKeys.contains(key) else { return }
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
                            previewProvider: currentProvider
                        )
                    }
                    return
                }
                guard let (image, cost) = rendered else { return }
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
        for key in cachedPreviews.sorted(by: {
            $0.value.accessEpoch < $1.value.accessEpoch
        }).map(\.key) {
            guard totalCost > maximumCachedPreviewBytes,
                  let removed = cachedPreviews.removeValue(forKey: key) else {
                break
            }
            totalCost -= removed.byteCost
        }
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
        ((UInt64, SnapGroupID, Set<String>) -> Bool)?
    var releaseSelectionConfirmation:
        ((UInt64, SnapGroupID, Set<String>) -> Void)?
    var onSelected: ((SnapGroupID, Set<String>) -> Void)?
    var currentTransitionAuthorization: ((SnapGroupID) -> Bool)?

    private let proxyView = MissionControlGroupProxyView()
    private var selectionWasDelivered = false
    private var selectionConfirmationIsPending = false
    private var presentationGeneration = 0
    private var selectionConfirmationGeneration = 0
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
        setFrame(frame, display: false)
        proxyView.members = members
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
        currentTransitionAuthorization = nil
        selectionConfirmationIsPending = false
        proxyView.members = []
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
        // one-shot confirmation, not a capture or polling loop.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else { return }
            var selectionWasConsumed = false
            defer {
                if !selectionWasConsumed {
                    self.releaseSelectionConfirmation?(
                        selectionCandidateGeneration,
                        selectedGroupID,
                        selectedMemberIDs
                    )
                }
            }
            guard self.selectionConfirmationGeneration == generation else {
                return
            }
            self.selectionConfirmationIsPending = false
            guard
                  self.groupID == selectedGroupID,
                  self.presentedMemberIDs == selectedMemberIDs,
                  self.presentationGeneration
                    == selectedPresentationGeneration,
                  NSApp.isActive,
                  NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  MissionControlTransitionTokenPolicy.isValid(
                    self.transitionToken,
                    groupID: selectedGroupID,
                    presentationGeneration: selectedPresentationGeneration
                  ),
                  !self.selectionWasDelivered,
                  self.consumeSelectionConfirmation?(
                    selectionCandidateGeneration,
                    selectedGroupID,
                    selectedMemberIDs
                  ) == true else { return }
            selectionWasConsumed = true
            // One-shot authorization: key-window churn cannot replay the same
            // Mission Control transition evidence.
            self.transitionToken = nil
            self.selectionWasDelivered = true
            self.isSafelyPresented = false
            self.orderingValidationIsInFlight = false
            // The proxy is the Window Server surface that Mission Control is
            // already returning to the desktop. Keep its frozen composite
            // above the exact group only while the controller performs the
            // first per-window AXRaise sequence. Removing that selected
            // surface in the middle of the compositor transition exposes the
            // members one by one and looks like a final geometry correction,
            // even though no frame mutation is being sent here.
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
                // Never leave a large composite visible if activation cannot
                // settle. Keep the selected surface registered and inert so
                // orderOut itself cannot perturb an in-flight Window Server
                // animation; controller success/cancellation retires it.
                self.alphaValue = 0
                self.ignoresMouseEvents = true
            }
        }
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
    }
}
