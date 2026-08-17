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

enum MissionControlProxyOrderingPolicy {
    static func isBehindAllRequiredWindows(
        proxyWindowID: CGWindowID,
        requiredWindowIDs: Set<CGWindowID>,
        orderedWindowIDs: [CGWindowID]
    ) -> Bool {
        guard requiredWindowIDs.count >= 2,
              let proxyIndex = orderedWindowIDs.firstIndex(
                of: proxyWindowID
              ) else { return false }
        let requiredIndices = requiredWindowIDs.compactMap {
            orderedWindowIDs.firstIndex(of: $0)
        }
        guard requiredIndices.count == requiredWindowIDs.count,
              let rearmostRequiredIndex = requiredIndices.max() else {
            return false
        }
        return proxyIndex > rearmostRequiredIndex
    }
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
            width: max(Int((Double(sourceWidth) * scale).rounded()), 1),
            height: max(Int((Double(sourceHeight) * scale).rounded()), 1)
        )
    }
}

struct MissionControlGroupProxyMember {
    let frame: CGRect
    let preview: NSImage?
    let icon: NSImage?
}

private struct MissionControlPreviewCacheKey: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
    let stableIdentity: String
}

private struct MissionControlCachedPreview {
    let image: NSImage
    let byteCost: Int
    var accessEpoch: UInt64
}

final class MissionControlGroupProxyController {
    var onSelectGroup: ((SnapGroupID, UInt64) -> Void)?
    var currentTransitionAuthorization: ((SnapGroupID) -> Bool)?

    private var windowsByGroupID: [SnapGroupID: MissionControlGroupProxyWindow] = [:]
    private var cachedPreviews: [MissionControlPreviewCacheKey:
        MissionControlCachedPreview] = [:]
    private var previewAccessEpoch: UInt64 = 0
    private static let maximumCachedPreviewBytes = 32 * 1024 * 1024

    func update(
        groups: [SnapGroup],
        visibleWindowsByIdentity: [String: ManagedWindow],
        previewProvider: (CGWindowID?) -> CGImage?
    ) {
        let presentableGroups = groups.filter { group in
            group.memberIDs.count >= 2
                && group.memberIDs.allSatisfy {
                    visibleWindowsByIdentity[$0] != nil
                }
        }
        let activeGroupIDs = Set(presentableGroups.map(\.id))
        let activeWindows = presentableGroups.flatMap { group in
            group.memberIDs.compactMap { visibleWindowsByIdentity[$0] }
        }
        let activeWindowIDs = Set(activeWindows.compactMap(\.cgWindowID))
        let activePreviewKeys = Set(activeWindows.compactMap { window
            -> MissionControlPreviewCacheKey? in
            guard let windowID = window.cgWindowID else { return nil }
            return MissionControlPreviewCacheKey(
                pid: window.pid,
                windowID: windowID,
                stableIdentity: window.stableIdentity
            )
        })
        // Split the existing bounded preview budget across every currently
        // presentable member, not across a hard-coded layout count. This keeps
        // 2 / 3 / 4 and multiple independent groups on the same policy while
        // allowing normal-size windows to retain substantially more detail
        // than the old fixed 720x480 cap.
        let previewByteBudget = MissionControlPreviewSizingPolicy
            .perImageByteBudget(
                totalByteBudget: Self.maximumCachedPreviewBytes,
                presentableMemberCount: activePreviewKeys.count
            )
        cachedPreviews = cachedPreviews.filter {
            activePreviewKeys.contains($0.key)
        }
        for groupID in Array(windowsByGroupID.keys) where
            !activeGroupIDs.contains(groupID) {
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
            guard bounds.width > 1,
                  bounds.height > 1,
                  Self.coverageRatio(
                      frames: memberWindows.map(\.frame),
                      within: bounds
                  ) >= 0.995 else {
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
            proxyWindow.revision = group.revision
            proxyWindow.currentTransitionAuthorization = { [weak self] groupID in
                self?.currentTransitionAuthorization?(groupID) ?? false
            }
            proxyWindow.onSelected = { [weak self, weak proxyWindow] in
                guard let self, let proxyWindow else { return }
                self.onSelectGroup?(
                    proxyWindow.groupID,
                    proxyWindow.revision
                )
            }
            let members = memberWindows.map { window in
                MissionControlGroupProxyMember(
                    frame: window.frame.offsetBy(
                        dx: -bounds.minX,
                        dy: -bounds.minY
                    ),
                    preview: previewImage(
                        for: window,
                        byteBudget: previewByteBudget,
                        previewProvider: previewProvider
                    ),
                    icon: window.appIcon
                )
            }
            proxyWindow.update(
                title: "グループ \(index + 1)",
                frame: bounds,
                members: members,
                // Multiple groups may occupy the same desktop rectangle. A
                // proxy that is merely behind its own members can still sit
                // above another group's real windows and become a visible,
                // clickable desktop cover. Require every proxy to be behind
                // every currently presentable real group member.
                memberWindowIDs: activeWindowIDs
            )
        }
    }

    var hasPresentationRecoveryDebt: Bool {
        windowsByGroupID.values.contains { $0.needsPresentationRecovery }
    }

    func hideAll() {
        for window in windowsByGroupID.values {
            window.retire()
        }
        windowsByGroupID.removeAll()
        cachedPreviews.removeAll()
    }

    func hide(groupID: SnapGroupID) {
        windowsByGroupID.removeValue(forKey: groupID)?.retire()
    }

    func requireOrderingRevalidation() {
        for window in windowsByGroupID.values {
            window.requireOrderingRevalidation()
        }
    }

    func noteMissionControlTransitionObserved(groupID: SnapGroupID) {
        windowsByGroupID[groupID]?.noteMissionControlTransitionObserved()
    }

    func cancelSelectionTransition(for groupID: SnapGroupID) {
        windowsByGroupID[groupID]?.cancelSelectionTransition()
    }

    func owns(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windowsByGroupID.values.contains { $0 === window }
    }

    private func previewImage(
        for window: ManagedWindow,
        byteBudget: Int,
        previewProvider: (CGWindowID?) -> CGImage?
    ) -> NSImage? {
        guard let windowID = window.cgWindowID else { return nil }
        let key = MissionControlPreviewCacheKey(
            pid: window.pid,
            windowID: windowID,
            stableIdentity: window.stableIdentity
        )
        previewAccessEpoch &+= 1
        if var cached = cachedPreviews[key],
           cached.byteCost <= byteBudget {
            cached.accessEpoch = previewAccessEpoch
            cachedPreviews[key] = cached
            return cached.image
        }
        // The number of active group members may have increased since this
        // image was cached. A formerly valid large preview must be resized to
        // the new shared budget instead of escaping the global memory bound.
        cachedPreviews.removeValue(forKey: key)
        guard let source = previewProvider(windowID),
              let image = Self.makePreviewImage(
                  from: source,
                  byteBudget: byteBudget
              ) else {
            return nil
        }
        let preview = NSImage(cgImage: image, size: window.frame.size)
        let cost = max(image.bytesPerRow * image.height, image.width * image.height * 4)
        cachedPreviews[key] = MissionControlCachedPreview(
            image: preview,
            byteCost: cost,
            accessEpoch: previewAccessEpoch
        )
        trimPreviewCacheIfNeeded()
        return preview
    }

    private func trimPreviewCacheIfNeeded() {
        var totalCost = cachedPreviews.values.reduce(0) {
            $0 + $1.byteCost
        }
        guard totalCost > Self.maximumCachedPreviewBytes else { return }
        for key in cachedPreviews.sorted(by: {
            $0.value.accessEpoch < $1.value.accessEpoch
        }).map(\.key) {
            guard totalCost > Self.maximumCachedPreviewBytes,
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
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func coverageRatio(
        frames: [CGRect],
        within bounds: CGRect
    ) -> CGFloat {
        let clipped = frames.map { $0.intersection(bounds) }.filter {
            !$0.isNull && $0.width > 0 && $0.height > 0
        }
        guard !clipped.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return 0
        }
        let xCoordinates = Set(
            clipped.flatMap { [$0.minX, $0.maxX] }
        ).sorted()
        var coveredArea: CGFloat = 0

        for index in 0..<(xCoordinates.count - 1) {
            let minX = xCoordinates[index]
            let maxX = xCoordinates[index + 1]
            guard maxX > minX else { continue }
            let intervals = clipped.compactMap { frame
                -> ClosedRange<CGFloat>? in
                guard frame.minX < maxX, frame.maxX > minX else {
                    return nil
                }
                return frame.minY...frame.maxY
            }.sorted { $0.lowerBound < $1.lowerBound }
            guard var current = intervals.first else { continue }
            var coveredHeight: CGFloat = 0
            for interval in intervals.dropFirst() {
                if interval.lowerBound <= current.upperBound {
                    current = current.lowerBound...max(
                        current.upperBound,
                        interval.upperBound
                    )
                } else {
                    coveredHeight += current.upperBound - current.lowerBound
                    current = interval
                }
            }
            coveredHeight += current.upperBound - current.lowerBound
            coveredArea += (maxX - minX) * coveredHeight
        }
        return min(max(coveredArea / (bounds.width * bounds.height), 0), 1)
    }
}

private final class MissionControlGroupProxyWindow: NSWindow, NSWindowDelegate {
    var groupID = SnapGroupID()
    var revision: UInt64 = 0
    var onSelected: (() -> Void)?
    var currentTransitionAuthorization: ((SnapGroupID) -> Bool)?

    private let proxyView = MissionControlGroupProxyView()
    private var selectionWasDelivered = false
    private var presentationGeneration = 0
    private var selectionConfirmationGeneration = 0
    private var lastPresentedFrame: CGRect?
    private var lastPresentedMemberWindowIDs: Set<CGWindowID> = []
    private var isSafelyPresented = false
    private var hasOrderingValidationDebt = false
    private var transitionToken: MissionControlTransitionToken?

    var needsPresentationRecovery: Bool {
        hasOrderingValidationDebt && !selectionWasDelivered
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
        sharingType = .none
        contentView = proxyView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(
        title: String,
        frame: CGRect,
        members: [MissionControlGroupProxyMember],
        memberWindowIDs: Set<CGWindowID>
    ) {
        // App activation and AX focus notifications may refresh presentation
        // while the selected proxy is covering the ordered group transition.
        // Do not demote that cover until the controller reports success or
        // explicitly cancels the bounded attempt.
        guard !selectionWasDelivered else { return }
        level = .normal
        self.title = title
        setFrame(frame, display: false)
        proxyView.members = members
        proxyView.needsDisplay = true

        let presentationIsUnchanged = isSafelyPresented
            && lastPresentedFrame.map {
                Self.framesAreApproximatelyEqual($0, frame)
            } == true
            && lastPresentedMemberWindowIDs == memberWindowIDs
        guard !presentationIsUnchanged else { return }

        // The proxy occupies exactly the current split-group bounds and is
        // ordered behind its foreign member windows. It therefore remains
        // covered on the desktop while still being a managed Mission Control
        // participant. This behavior is intentionally experimental.
        presentationGeneration &+= 1
        let generation = presentationGeneration
        transitionToken = nil
        isSafelyPresented = false
        hasOrderingValidationDebt = true
        alphaValue = 0
        ignoresMouseEvents = true
        scheduleOrderingValidation(
            frame: frame,
            memberWindowIDs: memberWindowIDs,
            generation: generation,
            attempt: 0,
            delay: MissionControlProxyOrderingRecoveryPolicy
                .verificationDelays[0]
        )
    }

    func retire() {
        presentationGeneration &+= 1
        selectionConfirmationGeneration &+= 1
        onSelected = nil
        currentTransitionAuthorization = nil
        proxyView.members = []
        lastPresentedFrame = nil
        lastPresentedMemberWindowIDs = []
        isSafelyPresented = false
        hasOrderingValidationDebt = false
        transitionToken = nil
        level = .normal
        alphaValue = 0
        ignoresMouseEvents = true
        orderOut(nil)
    }

    func requireOrderingRevalidation() {
        let remainsSafe = isSafelyBehindAllMembers(
            lastPresentedMemberWindowIDs
        )
        isSafelyPresented = remainsSafe
        transitionToken = nil
        if remainsSafe {
            hasOrderingValidationDebt = false
            return
        }
        // Ordering uncertainty is a presentation authorization failure. Hide
        // synchronously so a large proxy can never remain exposed/clickable,
        // then reacquire ordering with bounded checks. A single transient
        // Window Server snapshot must not permanently remove the MC candidate.
        presentationGeneration &+= 1
        let generation = presentationGeneration
        alphaValue = 0
        ignoresMouseEvents = true
        hasOrderingValidationDebt = true
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
                .verificationDelays[0]
        )
    }

    func noteMissionControlTransitionObserved() {
        guard isSafelyPresented else { return }
        transitionToken = MissionControlTransitionTokenPolicy.make(
            groupID: groupID,
            presentationGeneration: presentationGeneration
        )
    }

    func cancelSelectionTransition() {
        selectionConfirmationGeneration &+= 1
        selectionWasDelivered = false
        isSafelyPresented = false
        hasOrderingValidationDebt = false
        transitionToken = nil
        level = .normal
        alphaValue = 0
        ignoresMouseEvents = true
        orderBack(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !selectionWasDelivered else { return }
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
        // Entering Mission Control can perturb key-window state without the
        // user choosing this proxy. Confirm the selection only after Tabora
        // is genuinely the active/frontmost application. This is a bounded
        // one-shot confirmation, not a capture or polling loop.
        selectionConfirmationGeneration &+= 1
        let generation = selectionConfirmationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self,
                  self.selectionConfirmationGeneration == generation,
                  self.isKeyWindow,
                  NSApp.isActive,
                  NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  MissionControlTransitionTokenPolicy.isValid(
                    self.transitionToken,
                    groupID: self.groupID,
                    presentationGeneration: self.presentationGeneration
                  ),
                  !self.selectionWasDelivered else { return }
            // One-shot authorization: key-window churn cannot replay the same
            // Mission Control transition evidence.
            self.transitionToken = nil
            self.selectionWasDelivered = true
            self.isSafelyPresented = false
            // Keep the selected static composite above the real windows while
            // they settle and are raised as one verified group. Removing the
            // proxy here exposed each AXRaise in sequence and looked like a
            // frame/height correction even though no frame was being written.
            self.level = .floating
            self.orderFrontRegardless()
            self.ignoresMouseEvents = true
            self.onSelected?()
            let transitionGeneration = self.selectionConfirmationGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                [weak self] in
                guard let self,
                      self.selectionConfirmationGeneration
                        == transitionGeneration,
                      self.selectionWasDelivered else { return }
                self.cancelSelectionTransition()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if level != .floating {
            selectionConfirmationGeneration &+= 1
            selectionWasDelivered = false
        }
    }


    private func scheduleOrderingValidation(
        frame: CGRect,
        memberWindowIDs: Set<CGWindowID>,
        generation: Int,
        attempt: Int,
        delay: TimeInterval
    ) {
        let perform = { [weak self] in
            guard let self,
                  self.presentationGeneration == generation,
                  !self.selectionWasDelivered else { return }
            self.alphaValue = 0
            self.ignoresMouseEvents = true
            self.orderBack(nil)
            // Ordering is asynchronous across Window Server. Verify on the
            // next main-loop turn while the proxy is still invisible and
            // non-interactive.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.selectionWasDelivered else { return }
                if self.isSafelyBehindAllMembers(memberWindowIDs) {
                    self.lastPresentedFrame = frame
                    self.lastPresentedMemberWindowIDs = memberWindowIDs
                    self.isSafelyPresented = true
                    self.hasOrderingValidationDebt = false
                    self.alphaValue = 1
                    self.ignoresMouseEvents = false
                    return
                }

                self.isSafelyPresented = false
                self.hasOrderingValidationDebt = true
                if let nextDelay = MissionControlProxyOrderingRecoveryPolicy
                    .delayAfterFailedAttempt(attempt) {
                    self.scheduleOrderingValidation(
                        frame: frame,
                        memberWindowIDs: memberWindowIDs,
                        generation: generation,
                        attempt: attempt + 1,
                        delay: nextDelay
                    )
                } else {
                    // Fast recovery is bounded. Leave explicit debt for the
                    // existing 1 Hz Recovery watchdog rather than keeping a
                    // high-frequency retry loop alive.
                    self.alphaValue = 0
                    self.ignoresMouseEvents = true
                    self.orderOut(nil)
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

    private func isSafelyBehindAllMembers(
        _ memberWindowIDs: Set<CGWindowID>
    ) -> Bool {
        guard windowNumber > 0,
              memberWindowIDs.count >= 2,
              let info = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else { return false }
        let orderedIDs = info.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return MissionControlProxyOrderingPolicy.isBehindAllRequiredWindows(
            proxyWindowID: UInt32(windowNumber),
            requiredWindowIDs: memberWindowIDs,
            orderedWindowIDs: orderedIDs
        )
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
