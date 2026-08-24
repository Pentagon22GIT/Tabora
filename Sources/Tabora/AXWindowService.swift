import AppKit
import ApplicationServices
import CoreGraphics



struct AXFrameSizeAxes: OptionSet {
    let rawValue: Int

    static let width = AXFrameSizeAxes(rawValue: 1 << 0)
    static let height = AXFrameSizeAxes(rawValue: 1 << 1)
}

enum AXFrameSizePolicy {
    static func historicalCorrectionAxes(
        requiredOuterEdges: SnapOuterEdges
    ) -> AXFrameSizeAxes {
        var result: AXFrameSizeAxes = []
        // Preserve the historical correction/timeout behavior. These combined
        // edge sets mean that both opposite screen edges constrain that size.
        if requiredOuterEdges.contains(.horizontal) { result.insert(.width) }
        if requiredOuterEdges.contains(.vertical) { result.insert(.height) }
        return result
    }

    static func commitAxes(
        requiredOuterEdges: SnapOuterEdges,
        explicitCommitAxes: AXFrameSizeAxes?
    ) -> AXFrameSizeAxes {
        explicitCommitAxes ?? historicalCorrectionAxes(
            requiredOuterEdges: requiredOuterEdges
        )
    }

    static func requiredSizeIsCorrect(
        actual: CGSize,
        target: CGSize,
        exactAxes: AXFrameSizeAxes,
        tolerance: CGFloat = 1
    ) -> Bool {
        (!exactAxes.contains(.width)
            || abs(actual.width - target.width) <= tolerance)
            && (!exactAxes.contains(.height)
                || abs(actual.height - target.height) <= tolerance)
    }

    static func targetDistance(
        actual: CGSize,
        target: CGSize,
        exactAxes: AXFrameSizeAxes
    ) -> CGFloat {
        var result: CGFloat = 0
        if exactAxes.contains(.width) {
            result += abs(actual.width - target.width)
        }
        if exactAxes.contains(.height) {
            result += abs(actual.height - target.height)
        }
        return result
    }
}

enum FrameOperationOwnershipPolicy {
    static func key(pid: pid_t, elementHash: String) -> String {
        "ax:\(pid):\(elementHash)"
    }
}

enum AXFrameSettlementMode {
    /// Existing callers require the exact requested frame and may use the
    /// historical bounded correction sequence while that target is settling.
    case requireExactTarget

    /// Initial snap placement may discover a previously-unknown application
    /// size boundary. Once a different accepted frame is stably observed,
    /// return that new evidence instead of reissuing the same impossible size
    /// mutation. A caller may then authorize a new geometry plan.
    case returnSettledConstraintResult
}

enum AXFrameSettlementPolicy {
    /// Initial snap may stop exact-target correction only after the app has
    /// accepted a different, stable frame and target progress has stopped.
    /// This converts the settled frame into observation evidence; it does not
    /// itself authorize a second mutation. Existing exact-target callers never
    /// take this path.
    static func shouldReturnSettledConstraintResult(
        mode: AXFrameSettlementMode,
        placementIsAcceptable: Bool,
        mutationWasSent: Bool,
        sizeMutationSucceeded: Bool,
        acceptedSizeIsStable: Bool,
        settledAfterFinalSizeRequest: Bool,
        targetProgressWasObserved: Bool,
        secondsWithoutTargetProgress: TimeInterval
    ) -> Bool {
        return mode == .returnSettledConstraintResult
            && !placementIsAcceptable
            && mutationWasSent
            && sizeMutationSucceeded
            && acceptedSizeIsStable
            && settledAfterFinalSizeRequest
            && targetProgressWasObserved
            && secondsWithoutTargetProgress >= 0.10
    }
}

enum AXFrameSettlementEvidence: Equatable {
    case exactTarget
    case operationLocalAlternative
    case boundedAlternative
    case unresolved

    var authorizesPersistentConstraintLearning: Bool {
        self == .boundedAlternative
    }
}

struct AXFrameMutationObservation {
    let requestedFrame: CGRect
    let acceptedFrame: CGRect?
    let mutationWasSent: Bool
    let sizeMutationSucceeded: Bool
    let acceptedFrameIsSettled: Bool
    let liveness: WindowLiveness
    let completedSuccessfully: Bool
    let settlementEvidence: AXFrameSettlementEvidence
}

enum PlacementReadinessResult {
    case ready(ManagedWindow)
    case unavailable
    case indeterminate
}

enum PersistedWindowRefreshObservation {
    case available(ManagedWindow)
    case missing
    case unknown
}

struct ManagedWindow {
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let appIcon: NSImage?
    let frame: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let cgWindowID: CGWindowID?

    var stableIdentity: String {
        Self.stableIdentity(for: element, pid: pid)
    }

    static func stableIdentity(
        for element: AXUIElement,
        pid: pid_t
    ) -> String {
        "ax:\(pid):\(CFHash(element))"
    }

    func replacingFrame(_ newFrame: CGRect) -> ManagedWindow {
        ManagedWindow(
            element: element,
            pid: pid,
            title: title,
            appIcon: appIcon,
            frame: newFrame,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            cgWindowID: cgWindowID
        )
    }

    func replacingCGWindowID(_ newWindowID: CGWindowID?) -> ManagedWindow {
        ManagedWindow(
            element: element,
            pid: pid,
            title: title,
            appIcon: appIcon,
            frame: frame,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            cgWindowID: newWindowID
        )
    }
}

struct ManagedWindowBinding {
    let element: AXUIElement
    let identity: PersistedWindowBinding
}

struct WindowSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let stableIdentity: String
    let frame: CGRect
    let wasFullscreen: Bool
}

struct WindowOcclusionSnapshot {
    let windowID: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let zIndex: Int
    let layer: Int
}

struct WindowOcclusionSnapshotObservation {
    let snapshot: [WindowOcclusionSnapshot]
    let completeness: WindowDiscoveryCompleteness

    static let unknown = WindowOcclusionSnapshotObservation(
        snapshot: [],
        completeness: .unknown
    )
}

struct WindowOcclusionParticipant: Equatable {
    let pid: pid_t
    let frame: CGRect
    let windowID: CGWindowID?
}

struct FocusedWindowIdentity: Equatable {
    let pid: pid_t
    let stableIdentity: String
}

struct ActiveWindowIdentitySnapshot: Equatable {
    let pid: pid_t
    let focusedIdentity: String?
    let mainIdentity: String?
    let hasBlockingModalSurface: Bool

    init(
        pid: pid_t,
        focusedIdentity: String?,
        mainIdentity: String?,
        hasBlockingModalSurface: Bool = false
    ) {
        self.pid = pid
        self.focusedIdentity = focusedIdentity
        self.mainIdentity = mainIdentity
        self.hasBlockingModalSurface = hasBlockingModalSurface
    }

    var preferredIdentity: FocusedWindowIdentity? {
        guard let stableIdentity = mainIdentity ?? focusedIdentity else {
            return nil
        }
        return FocusedWindowIdentity(
            pid: pid,
            stableIdentity: stableIdentity
        )
    }

    func contains(_ stableIdentity: String) -> Bool {
        focusedIdentity == stableIdentity || mainIdentity == stableIdentity
    }

    var hasDistinctFocusedSurface: Bool {
        guard let focusedIdentity, let mainIdentity else { return false }
        return focusedIdentity != mainIdentity
    }
}

struct FocusedWindowPollState {
    private(set) var hasBaseline = false
    private(set) var lastSnapshot: ActiveWindowIdentitySnapshot?

    mutating func observe(
        _ currentSnapshot: ActiveWindowIdentitySnapshot?
    ) -> FocusedWindowIdentity? {
        guard hasBaseline else {
            hasBaseline = true
            lastSnapshot = currentSnapshot
            return nil
        }
        guard currentSnapshot != lastSnapshot else { return nil }
        let previousSnapshot = lastSnapshot
        lastSnapshot = currentSnapshot
        guard let currentSnapshot else { return nil }

        if currentSnapshot.pid != previousSnapshot?.pid {
            return currentSnapshot.preferredIdentity
        }
        if currentSnapshot.mainIdentity != previousSnapshot?.mainIdentity,
           let mainIdentity = currentSnapshot.mainIdentity {
            return FocusedWindowIdentity(
                pid: currentSnapshot.pid,
                stableIdentity: mainIdentity
            )
        }
        if currentSnapshot.focusedIdentity
            != previousSnapshot?.focusedIdentity,
           let focusedIdentity = currentSnapshot.focusedIdentity {
            return FocusedWindowIdentity(
                pid: currentSnapshot.pid,
                stableIdentity: focusedIdentity
            )
        }
        return nil
    }

    mutating func reset() {
        hasBaseline = false
        lastSnapshot = nil
    }
}

struct FocusedWindowSettlementState {
    static func nextObservationCount(
        previousIdentity: String?,
        currentIdentity: String?,
        previousCount: Int
    ) -> Int {
        guard let currentIdentity else { return 0 }
        guard previousIdentity == currentIdentity else { return 1 }
        return previousCount + 1
    }
}

struct WindowServerSelectionSnapshot: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

struct WindowServerSelectionPollState {
    private(set) var hasBaseline = false
    private(set) var lastSnapshot: WindowServerSelectionSnapshot?

    mutating func observe(
        _ currentSnapshot: WindowServerSelectionSnapshot?
    ) -> WindowServerSelectionSnapshot? {
        guard hasBaseline else {
            hasBaseline = true
            lastSnapshot = currentSnapshot
            return nil
        }
        guard currentSnapshot != lastSnapshot else { return nil }
        lastSnapshot = currentSnapshot
        return currentSnapshot
    }

    mutating func reset() {
        hasBaseline = false
        lastSnapshot = nil
    }
}

enum AXMessagingTimeoutPolicy {
    /// Passive/optional observations run on the main actor in several existing
    /// call paths. Bound one accessibility message to the existing 10 Hz
    /// observation cadence so an unresponsive/captured application cannot
    /// indefinitely stall unrelated groups or display-transition recovery.
    static let passiveObservation: Float = 0.10

    /// Interactive operations already use a 0.45 s placement-readiness bound.
    /// Reuse that established interaction budget for individual AX messages.
    /// A timeout remains unknown/procedural failure; callers must verify the
    /// semantic postcondition before rollback or structural cleanup.
    static let interactiveOperation: Float = 0.45

    /// Short send-side budget only for the disposable 60 Hz pointer-following
    /// restore animation. Never use this for snap, rollback, restore, group, or
    /// App Constraint correctness.
    static let animationMutation: Float = passiveObservation
}

enum PreviewCaptureAdmissionPolicy {
    /// Both preview systems are derived background work. If the other system
    /// briefly owns both global capture slots, wait off-main for one
    /// established interactive readiness interval instead of consuming a
    /// finite retry as an immediate contention failure.
    static let maximumCapacityWait: TimeInterval = 0.45
    static let assistCapacityWait = maximumCapacityWait
    static let missionControlCapacityWait = maximumCapacityWait

    static func effectiveWait(
        requested: TimeInterval,
        isMainThread: Bool
    ) -> TimeInterval {
        guard !isMainThread, requested.isFinite, requested > 0 else { return 0 }
        return min(requested, maximumCapacityWait)
    }
}

final class AXWindowService {
    private struct CGWindowRecord {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let frame: CGRect
        let zIndex: Int
    }

    private enum PersistedManagedWindowResolution {
        case unavailable
        case matched(ManagedWindow)
        case rejected
    }

    // Preview capture is derived state. Bound cross-subsystem capture
    // concurrency without holding a lock across the legacy synchronous Window
    // Server capture call. At most two captures may be active. Callers may wait
    // off-main for one bounded readiness interval so brief cross-subsystem
    // contention does not consume their finite image retries.
    private static let maximumConcurrentPreviewCaptures = 2
    private static let previewCaptureAdmission = DispatchSemaphore(
        value: maximumConcurrentPreviewCaptures
    )

    private var hasPromptedForPermission = false
    private var frameOperationGenerations: [String: Int] = [:]
    private var frameAnimationTimers: [String: Timer] = [:]
    private var nextFrameOperationGeneration = 0

    var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        if isTrusted { return true }
        guard !hasPromptedForPermission else { return false }
        hasPromptedForPermission = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func focusedWindow(
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = copyAttribute(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            messagingTimeout: messagingTimeout
        ) else { return nil }
        return makeManagedWindow(
            window,
            pid: app.processIdentifier,
            app: app,
            cgWindowID: nil,
            messagingTimeout: messagingTimeout
        )
    }

    func activeWindowIdentitySnapshot() -> ActiveWindowIdentitySnapshot? {
        guard isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow: AXUIElement? = copyAttribute(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        )
        let mainWindow: AXUIElement? = copyAttribute(
            appElement,
            kAXMainWindowAttribute as CFString,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        )
        guard focusedWindow != nil || mainWindow != nil else { return nil }
        let focusedIsModal = focusedWindow.map(isModalSurface) ?? false
        let mainIsModal = mainWindow.map(isModalSurface) ?? false
        let focusedHasSheets = focusedWindow.map(hasAttachedSheets) ?? false
        let mainHasSheets = mainWindow.map(hasAttachedSheets) ?? false
        return ActiveWindowIdentitySnapshot(
            pid: app.processIdentifier,
            focusedIdentity: focusedWindow.map {
                ManagedWindow.stableIdentity(
                    for: $0,
                    pid: app.processIdentifier
                )
            },
            mainIdentity: mainWindow.map {
                ManagedWindow.stableIdentity(
                    for: $0,
                    pid: app.processIdentifier
                )
            },
            hasBlockingModalSurface: focusedIsModal
                || mainIsModal
                || focusedHasSheets
                || mainHasSheets
        )
    }

    func windowServerSelectionSnapshot() -> WindowServerSelectionSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = application.processIdentifier
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for item in info {
            guard ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0,
                  ((item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNumber.int32Value == pid,
                  let idNumber = item[kCGWindowNumber as String] as? NSNumber else {
                continue
            }
            return WindowServerSelectionSnapshot(
                pid: pid,
                windowID: CGWindowID(idNumber.uint32Value)
            )
        }
        return nil
    }

    func focusedWindowServerSelectionSnapshot() -> WindowServerSelectionSnapshot? {
        guard let focusedWindow = focusedWindow() else { return nil }
        let resolved = resolvingWindowServerIdentity(focusedWindow)
        guard let windowID = resolved.cgWindowID else { return nil }
        return WindowServerSelectionSnapshot(
            pid: resolved.pid,
            windowID: windowID
        )
    }

    func focusedWindowServerSelectionSnapshot(
        matching exactWindow: ManagedWindow,
        allowsExactIdentityWithTransformedGeometry: Bool
    ) -> WindowServerSelectionSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == exactWindow.pid,
              let focusedWindow = focusedWindow(),
              focusedWindow.pid == exactWindow.pid,
              focusedWindow.stableIdentity == exactWindow.stableIdentity else {
            return nil
        }
        let resolved = resolvingWindowServerIdentity(
            exactWindow,
            allowsExactIdentityWithTransformedGeometry:
                allowsExactIdentityWithTransformedGeometry
        )
        guard let windowID = resolved.cgWindowID else { return nil }
        return WindowServerSelectionSnapshot(
            pid: resolved.pid,
            windowID: windowID
        )
    }

    func refreshed(
        _ window: ManagedWindow,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> ManagedWindow? {
        guard let app = NSRunningApplication(processIdentifier: window.pid),
              !app.isTerminated else { return nil }
        return makeManagedWindow(
            window.element,
            pid: window.pid,
            app: app,
            cgWindowID: window.cgWindowID,
            messagingTimeout: messagingTimeout
        )
    }

    func refreshedFrame(
        _ window: ManagedWindow,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> CGRect? {
        guard let app = NSRunningApplication(processIdentifier: window.pid),
              !app.isTerminated else { return nil }
        return frame(of: window.element, messagingTimeout: messagingTimeout)
    }

    func currentFrame(of element: AXUIElement, pid: pid_t) -> CGRect? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              isWindowAlive(element: element, pid: pid) else { return nil }
        return frame(of: element)
    }

    func resolvingWindowServerIdentity(
        _ window: ManagedWindow,
        allowsExactIdentityWithTransformedGeometry: Bool = false
    ) -> ManagedWindow {
        let records = onscreenWindowRecords()
        if let windowID = window.cgWindowID,
           records.contains(where: { record in
               guard record.id == windowID, record.pid == window.pid else {
                   return false
               }
               return allowsExactIdentityWithTransformedGeometry
                   || visibleGeometryMatches(axWindow: window, cgWindow: record)
           }) {
            return window
        }
        let unresolved = window.replacingCGWindowID(nil)
        let candidates = records.filter {
            $0.pid == unresolved.pid
                && visibleGeometryMatches(axWindow: unresolved, cgWindow: $0)
        }
        let scored = candidates.enumerated().map { index, candidate in
            WindowMatchScore(
                candidateIndex: index,
                score: matchScore(axWindow: unresolved, cgWindow: candidate)
            )
        }
        guard let bestIndex = WindowMatchingPolicy.uniqueBestCandidate(
            in: scored
        ) else { return unresolved }
        return unresolved.replacingCGWindowID(candidates[bestIndex].id)
    }

    func windowServerFrame(_ window: ManagedWindow) -> CGRect? {
        guard let windowID = window.cgWindowID else { return nil }
        let requestedIDs = [NSNumber(value: windowID)] as CFArray
        let descriptions = CGWindowListCreateDescriptionFromArray(requestedIDs)
            as? [[String: Any]] ?? []
        guard let item = descriptions.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }),
              (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == window.pid,
              ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0 else {
            return nil
        }
        let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
        guard let bounds = CGRect(
            dictionaryRepresentation: boundsDictionary as CFDictionary
        ), bounds.width > 0, bounds.height > 0 else { return nil }
        return cgBoundsToCocoa(bounds)
    }

    func visibleWindows(
        excludingStableIDs excludedStableIDs: Set<String> = [],
        persistedBindings: [ManagedWindowBinding] = []
    ) -> [ManagedWindow] {
        matchedVisibleWindows(
            excludingStableIDs: excludedStableIDs,
            persistedBindings: persistedBindings
        )
    }

    /// Resolve only exact, already-persisted members from current Window Server
    /// records. Background group presentation/handle maintenance must not turn
    /// into a whole-desktop AX census: an unresponsive streamed application is
    /// allowed to make its own member temporarily unknown without blocking
    /// unrelated groups. No fuzzy reassignment is performed here.
    func persistedVisibleWindows(
        persistedBindings: [ManagedWindowBinding],
        stableIDs: Set<String>
    ) -> [ManagedWindow] {
        guard !stableIDs.isEmpty else { return [] }
        let requestedBindings = persistedBindings.filter {
            stableIDs.contains($0.identity.stableIdentity)
        }
        guard !requestedBindings.isEmpty else { return [] }

        let bindingsByPID = Dictionary(
            grouping: requestedBindings,
            by: { $0.identity.pid }
        )
        var result: [(window: ManagedWindow, zIndex: Int)] = []
        var seen = Set<String>()

        for record in onscreenWindowRecords() {
            guard let processBindings = bindingsByPID[record.pid],
                  let app = NSRunningApplication(processIdentifier: record.pid),
                  app.activationPolicy == .regular,
                  !app.isTerminated else { continue }
            if case .matched(let window) = persistedManagedWindow(
                matching: record,
                app: app,
                bindings: processBindings,
                messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
            ), stableIDs.contains(window.stableIdentity),
               seen.insert(window.stableIdentity).inserted {
                result.append((window, record.zIndex))
            }
        }

        return result
            .sorted { lhs, rhs in
                if lhs.zIndex == rhs.zIndex {
                    return lhs.window.stableIdentity < rhs.window.stableIdentity
                }
                return lhs.zIndex < rhs.zIndex
            }
            .map(\.window)
    }

    /// Resolves only already-persisted members for an explicit Mission Control
    /// group activation. During the Window Server transform, AX keeps desktop
    /// geometry while CG reports scaled geometry, so geometry equality is not an
    /// existence test here. Exact PID/window ID, AX stable identity, liveness,
    /// and the current layer-zero Window Server surface all remain mandatory.
    func missionControlActivationWindows(
        persistedBindings: [ManagedWindowBinding],
        memberIDs: Set<String>,
        snapshot providedSnapshot: [WindowOcclusionSnapshot]? = nil
    ) -> [ManagedWindow]? {
        guard memberIDs.count >= 2 else { return nil }
        let bindings = persistedBindings.filter {
            memberIDs.contains($0.identity.stableIdentity)
        }
        guard bindings.count == memberIDs.count,
              Set(bindings.map(\.identity.stableIdentity)) == memberIDs else {
            return nil
        }
        let snapshot = providedSnapshot ?? windowOcclusionSnapshot()
        guard MissionControlActivationIdentityPolicy.exactSelections(
            memberIDs: memberIDs,
            bindings: bindings.map(\.identity),
            snapshot: snapshot
        ) != nil else {
            return nil
        }

        var result: [ManagedWindow] = []
        result.reserveCapacity(bindings.count)
        for binding in bindings {
            let pid = binding.identity.pid
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  !app.isTerminated,
                  ManagedWindow.stableIdentity(
                      for: binding.element,
                      pid: pid
                  ) == binding.identity.stableIdentity,
                  !WindowStructuralPolicy.isConfirmedMissing(
                      windowLiveness(element: binding.element, pid: pid)
                  ),
                  let window = makeManagedWindow(
                      binding.element,
                      pid: pid,
                      app: app,
                      cgWindowID: binding.identity.windowID
                  ),
                  !window.isMinimized else {
                return nil
            }
            result.append(window)
        }
        return Set(result.map(\.stableIdentity)) == memberIDs ? result : nil
    }

    /// Resolve only the application owning the exact frontmost surface. This
    /// keeps mouse-down acquisition bounded instead of enumerating AX windows
    /// for every running app, while retaining small movable windows.
    func pointerHitTestWindow(
        at point: CGPoint,
        persistedBindings: [ManagedWindowBinding] = [],
        snapshot providedSnapshot: [WindowOcclusionSnapshot]? = nil,
        eventHandlerWindowID: CGWindowID? = nil
    ) -> ManagedWindow? {
        let snapshot = providedSnapshot ?? windowOcclusionSnapshot()
        guard let evidence = pointerDragSurfaceEvidence(
            at: point,
            snapshot: snapshot,
            eventHandlerWindowID: eventHandlerWindowID
        ) else { return nil }
        return resolvePointerDragSurface(
            evidence,
            persistedBindings: persistedBindings
        )
    }

    func pointerDragSurfaceEvidence(
        at point: CGPoint,
        snapshot: [WindowOcclusionSnapshot],
        eventHandlerWindowID: CGWindowID? = nil
    ) -> PointerDragSurfaceEvidence? {
        PointerDragSurfaceEvidencePolicy.capture(
            at: point,
            snapshot: snapshot,
            eventHandlerWindowID: eventHandlerWindowID
        )
    }

    /// Resolve only the physical surface captured at mouse-down. This may be
    /// retried after activation settles, but never falls back to whichever AX
    /// window later happens to become focused.
    func resolvePointerDragSurface(
        _ evidence: PointerDragSurfaceEvidence,
        persistedBindings: [ManagedWindowBinding] = []
    ) -> ManagedWindow? {
        let currentRecords = onscreenWindowRecords()
        guard let record = currentRecords.first(where: {
            $0.id == evidence.selection.windowID
                && $0.pid == evidence.selection.pid
        }), PointerDragSurfaceEvidencePolicy.stillMatches(
            evidence,
            pid: record.pid,
            windowID: record.id,
            frame: record.frame
        ), let app = NSRunningApplication(processIdentifier: record.pid),
           app.activationPolicy == .regular, !app.isTerminated else {
            return nil
        }

        switch persistedManagedWindow(
            matching: record,
            app: app,
            bindings: persistedBindings,
            messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) {
        case .matched(let knownWindow):
            return knownWindow
        case .rejected:
            return nil
        case .unavailable:
            break
        }

        // This is an exact, user-initiated pointer transaction. Resolve only
        // the owning application, but do not require focus to have already
        // settled: first-action quality depends on matching the exact physical
        // Window ID even while activation is still catching up.
        let presentWindowIDs = Set(currentRecords.compactMap { item in
            item.pid == record.pid ? item.id : nil
        })
        let presentBindings = persistedBindings.filter {
            $0.identity.pid == record.pid
                && presentWindowIDs.contains($0.identity.windowID)
        }
        let registeredIdentities = Set(
            presentBindings.map(\.identity.stableIdentity)
        )
        let registeredWindowIDs = Set(presentBindings.map(\.identity.windowID))
        let matches = matchedWindows(
            for: app,
            cgWindows: currentRecords.filter {
                $0.pid == record.pid && !registeredWindowIDs.contains($0.id)
            },
            excludingStableIDs: registeredIdentities,
            usesFocusedWindowHint: false,
            messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
        )
        return matches.map(\.window).first { window in
            window.cgWindowID == evidence.selection.windowID
                && !window.isMinimized
                && canMoveAndResize(
                    window,
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                )
        }
    }

    private func matchedVisibleWindows(
        excludingStableIDs excludedStableIDs: Set<String>,
        persistedBindings: [ManagedWindowBinding]
    ) -> [ManagedWindow] {
        let cgWindows = onscreenWindowRecords()
        let visiblePIDs = Set(cgWindows.map(\.pid))
        let presentWindowIDsByPID = Dictionary(
            grouping: cgWindows,
            by: { $0.pid }
        ).mapValues { Set($0.map(\.id)) }
        var orderedResult: [(window: ManagedWindow, zIndex: Int)] = []
        var seen = Set<String>()
        var claimedWindowIDs = Set<CGWindowID>()
        let persistedBindingsByPID = Dictionary(
            grouping: persistedBindings,
            by: { $0.identity.pid }
        )

        // Registered placements already own an exact Window Server identity.
        // Resolve those before the geometry/title matcher: two same-app
        // windows may legitimately share both a frame and a title, which
        // otherwise creates an irresolvable tie and makes whole groups vanish
        // from foreground/reconciliation observations.
        for record in cgWindows {
            guard let processBindings = persistedBindingsByPID[record.pid],
                  record.pid != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(
                      processIdentifier: record.pid
                  ), app.activationPolicy == .regular,
                  !app.isTerminated else { continue }
            switch persistedManagedWindow(
                matching: record,
                app: app,
                bindings: processBindings
            ) {
            case .matched(let managed):
                claimedWindowIDs.insert(record.id)
                guard !managed.isMinimized,
                      !excludedStableIDs.contains(managed.stableIdentity),
                      seen.insert(managed.stableIdentity).inserted else {
                    continue
                }
                orderedResult.append((managed, record.zIndex))
            case .rejected:
                // A conflicting or stale exact claim must not be reassigned
                // by a fuzzy match to a different AX window.
                claimedWindowIDs.insert(record.id)
            case .unavailable:
                break
            }
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard visiblePIDs.contains(pid), pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let presentWindowIDs = presentWindowIDsByPID[pid] ?? []
            let registeredIdentities = Set(
                persistedBindingsByPID[pid, default: []].compactMap {
                    binding in
                    presentWindowIDs.contains(binding.identity.windowID)
                        ? binding.identity.stableIdentity
                        : nil
                }
            )
            let matches = matchedWindows(
                for: app,
                cgWindows: cgWindows.filter {
                    !claimedWindowIDs.contains($0.id)
                },
                excludingStableIDs: registeredIdentities
            )
            for match in matches {
                let managed = match.window
                guard
                      let managedWindowID = managed.cgWindowID,
                      !claimedWindowIDs.contains(managedWindowID),
                      !managed.isMinimized,
                      managed.frame.width > 180,
                      managed.frame.height > 100,
                      canMoveAndResize(managed),
                      !excludedStableIDs.contains(managed.stableIdentity),
                      seen.insert(managed.stableIdentity).inserted else { continue }
                orderedResult.append(match)
            }
        }

        return orderedResult
            .sorted { lhs, rhs in
                if lhs.zIndex == rhs.zIndex {
                    return lhs.window.stableIdentity < rhs.window.stableIdentity
                }
                return lhs.zIndex < rhs.zIndex
            }
            .map(\.window)
    }

    private func persistedManagedWindow(
        matching record: CGWindowRecord,
        app: NSRunningApplication,
        bindings: [ManagedWindowBinding],
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> PersistedManagedWindowResolution {
        switch PersistedWindowBindingPolicy.resolve(
            pid: record.pid,
            windowID: record.id,
            bindings: bindings.map(\.identity)
        ) {
        case .unavailable:
            return .unavailable
        case .conflicting:
            return .rejected
        case .matched(let stableIdentity):
            guard let binding = bindings.first(where: {
                $0.identity.stableIdentity == stableIdentity
                    && $0.identity.pid == record.pid
                    && $0.identity.windowID == record.id
            }),
                  ManagedWindow.stableIdentity(
                      for: binding.element,
                      pid: record.pid
                  ) == stableIdentity,
                  !WindowStructuralPolicy.isConfirmedMissing(
                      windowLiveness(
                          element: binding.element,
                          pid: record.pid,
                          messagingTimeout: messagingTimeout
                      )
                  ),
                  let knownWindow = makeManagedWindow(
                      binding.element,
                      pid: record.pid,
                      app: app,
                      cgWindowID: record.id,
                      messagingTimeout: messagingTimeout
                  ),
                  !knownWindow.isMinimized,
                  visibleGeometryMatches(
                      axWindow: knownWindow,
                      cgWindow: record
                  ) else {
                return .rejected
            }
            return .matched(knownWindow)
        }
    }

    func windowIdentityCensus(forPID pid: pid_t) -> WindowIdentityCensus {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else { return .unknown }
        let appElement = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = copyAttribute(
            appElement,
            kAXWindowsAttribute as CFString,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        ) else {
            return .unknown
        }
        // kAXWindows is the structural census. Do not require frame access or
        // move/resize eligibility here: a modal/sheet transition or a
        // temporarily non-settable window still existed at drag start.
        return WindowIdentityCensus(
            identities: Set(windows.map {
                ManagedWindow.stableIdentity(for: $0, pid: pid)
            }),
            completeness: .complete
        )
    }

    func windowIdentities(forPID pid: pid_t) -> Set<String> {
        windowIdentityCensus(forPID: pid).identities
    }

    func windowServerWindowIDCensus(
        forPID pid: pid_t
    ) -> WindowServerWindowIDCensus {
        // No on-screen restriction: a hidden/minimized pre-existing surface must
        // not become "new" merely because it appears during a detach gesture.
        guard let info = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return .unknown }
        let ids = Set(info.compactMap { item -> CGWindowID? in
            guard ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0,
                  let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNumber.int32Value == pid,
                  let idNumber = item[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            return CGWindowID(idNumber.uint32Value)
        })
        return WindowServerWindowIDCensus(
            windowIDs: ids,
            completeness: .complete
        )
    }

    func visibleStableIdentities() -> Set<String> {
        Set(visibleWindows().map(\.stableIdentity))
    }

    func windowOcclusionSnapshotObservation()
        -> WindowOcclusionSnapshotObservation {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .unknown
        }
        let snapshot = info.enumerated().compactMap { index, item
            -> WindowOcclusionSnapshot? in
            guard let id = item[kCGWindowNumber as String] as? NSNumber,
                  let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
                  pid.int32Value != currentPID,
                  ((item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else {
                return nil
            }
            guard let boundsDictionary = item[kCGWindowBounds as String]
                as? [String: Any] else { return nil }
            guard let bounds = CGRect(
                dictionaryRepresentation: boundsDictionary as CFDictionary
            ), bounds.width > 0, bounds.height > 0 else { return nil }
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return WindowOcclusionSnapshot(
                windowID: CGWindowID(id.uint32Value),
                pid: pid.int32Value,
                frame: cgBoundsToCocoa(bounds).insetBy(dx: -1, dy: -1),
                zIndex: index,
                layer: layer
            )
        }
        return WindowOcclusionSnapshotObservation(
            snapshot: snapshot,
            completeness: .complete
        )
    }

    func windowOcclusionSnapshot() -> [WindowOcclusionSnapshot] {
        windowOcclusionSnapshotObservation().snapshot
    }

    func occludingWindows(
        above participants: [WindowOcclusionParticipant],
        in snapshot: [WindowOcclusionSnapshot]
    ) -> [WindowOcclusionSnapshot]? {
        guard !participants.isEmpty else { return [] }
        var participantWindowIDs = Set<CGWindowID>()
        var availableWindowIDs = Set(snapshot.map(\.windowID))

        for participant in participants {
            if let windowID = participant.windowID,
               availableWindowIDs.contains(windowID),
               let directMatch = snapshot.first(where: {
                   $0.windowID == windowID
                       && $0.pid == participant.pid
                       && $0.layer == 0
                       && occlusionGeometryMatches(
                           participantFrame: participant.frame,
                           snapshotFrame: $0.frame
                       )
               }) {
                participantWindowIDs.insert(directMatch.windowID)
                availableWindowIDs.remove(directMatch.windowID)
                continue
            }

            let candidates = snapshot.filter {
                availableWindowIDs.contains($0.windowID)
                    && $0.pid == participant.pid
                    && $0.layer == 0
                    && occlusionGeometryMatches(
                        participantFrame: participant.frame,
                        snapshotFrame: $0.frame
                    )
            }.sorted {
                occlusionGeometryDistance(
                    participantFrame: participant.frame,
                    snapshotFrame: $0.frame
                ) < occlusionGeometryDistance(
                    participantFrame: participant.frame,
                    snapshotFrame: $1.frame
                )
            }
            guard let bestMatch = candidates.first else { return nil }
            if candidates.count > 1 {
                let firstDistance = occlusionGeometryDistance(
                    participantFrame: participant.frame,
                    snapshotFrame: bestMatch.frame
                )
                let secondDistance = occlusionGeometryDistance(
                    participantFrame: participant.frame,
                    snapshotFrame: candidates[1].frame
                )
                guard secondDistance - firstDistance > 1 else { return nil }
            }
            participantWindowIDs.insert(bestMatch.windowID)
            availableWindowIDs.remove(bestMatch.windowID)
        }

        let participantIndices = snapshot.compactMap { item in
            participantWindowIDs.contains(item.windowID) ? item.zIndex : nil
        }
        guard participantIndices.count == participants.count,
              let rearmostParticipantIndex = participantIndices.max() else { return nil }
        return snapshot.filter {
            $0.zIndex < rearmostParticipantIndex
                && !participantWindowIDs.contains($0.windowID)
        }
    }

    private func occlusionGeometryMatches(
        participantFrame: CGRect,
        snapshotFrame: CGRect
    ) -> Bool {
        let sizeDelta = abs(snapshotFrame.width - participantFrame.width)
            + abs(snapshotFrame.height - participantFrame.height)
        let originDelta = abs(snapshotFrame.minX - participantFrame.minX)
            + abs(snapshotFrame.minY - participantFrame.minY)
        let referenceLength = max(
            min(participantFrame.width, participantFrame.height),
            1
        )
        return sizeDelta <= max(24, referenceLength * 0.08)
            && originDelta <= max(48, referenceLength * 0.12)
    }

    private func occlusionGeometryDistance(
        participantFrame: CGRect,
        snapshotFrame: CGRect
    ) -> CGFloat {
        abs(snapshotFrame.width - participantFrame.width)
            + abs(snapshotFrame.height - participantFrame.height)
            + abs(snapshotFrame.minX - participantFrame.minX)
            + abs(snapshotFrame.minY - participantFrame.minY)
    }

    func windowLiveness(
        element: AXUIElement,
        pid: pid_t,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> WindowLiveness {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else { return .missing }

        return withMessagingTimeout(
            element,
            timeout: messagingTimeout
        ) {
            var roleValue: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            if roleResult == .invalidUIElement { return .missing }
            guard roleResult == .success else { return .unknown }
            guard (roleValue as? String) == kAXWindowRole else {
                return .missing
            }

            // Position/size are liveness probes only. cannotComplete/timeout
            // remains transient evidence and never authorizes structural
            // destruction. The bounded per-element lease protects main-thread
            // liveness without changing the unknown-vs-missing contract.
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            let positionResult = AXUIElementCopyAttributeValue(
                element,
                kAXPositionAttribute as CFString,
                &positionValue
            )
            let sizeResult = AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
            )
            if positionResult == .invalidUIElement
                || sizeResult == .invalidUIElement {
                return .missing
            }
            guard positionResult == .success, sizeResult == .success else {
                return .unknown
            }
            return .alive
        }
    }

    func isWindowAlive(element: AXUIElement, pid: pid_t) -> Bool {
        windowLiveness(element: element, pid: pid) == .alive
    }


    func moveAndResizeCapability(
        _ window: ManagedWindow,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> WindowInteractionCapabilityObservation {
        guard let application = NSRunningApplication(
            processIdentifier: window.pid
        ), !application.isTerminated else {
            return .unavailable
        }
        guard WindowSnapEligibilityPolicy.isEligible(
            bundleIdentifier: application.bundleIdentifier
        ) else {
            return .unavailable
        }
        let move = attributeSettableObservation(
            kAXPositionAttribute as CFString,
            on: window.element,
            messagingTimeout: messagingTimeout
        )
        let resize = attributeSettableObservation(
            kAXSizeAttribute as CFString,
            on: window.element,
            messagingTimeout: messagingTimeout
        )
        return WindowInteractionCapabilityObservation.combining(move, resize)
    }

    func canMoveAndResize(
        _ window: ManagedWindow,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> Bool {
        moveAndResizeCapability(
            window,
            messagingTimeout: messagingTimeout
        ) == .available
    }

    func refreshedPersistedWindow(
        element: AXUIElement,
        pid: pid_t,
        expectedStableIdentity: String,
        cgWindowID: CGWindowID?,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> PersistedWindowRefreshObservation {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            return .missing
        }
        switch windowLiveness(
            element: element,
            pid: pid,
            messagingTimeout: messagingTimeout
        ) {
        case .missing:
            return .missing
        case .unknown:
            return .unknown
        case .alive:
            break
        }
        guard let window = makeManagedWindow(
            element,
            pid: pid,
            app: app,
            cgWindowID: cgWindowID,
            messagingTimeout: messagingTimeout
        ), window.stableIdentity == expectedStableIdentity else {
            return .unknown
        }
        return .available(window)
    }

    /// Constraint learning is intentionally narrower than ordinary snap
    /// eligibility. Only a standard, currently alive content window may be
    /// used as evidence for an app-level size constraint.
    func constraintLearningEligibilityObservation(
        _ window: ManagedWindow,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> WindowInteractionCapabilityObservation {
        switch moveAndResizeCapability(
            window,
            messagingTimeout: messagingTimeout
        ) {
        case .available:
            break
        case .unavailable:
            return .unavailable
        case .unknown:
            return .unknown
        }
        guard !window.isMinimized, !window.isFullscreen else {
            return .unavailable
        }
        switch windowLiveness(
            element: window.element,
            pid: window.pid,
            messagingTimeout: messagingTimeout
        ) {
        case .alive:
            break
        case .missing:
            return .unavailable
        case .unknown:
            return .unknown
        }

        let roleObservation = attributeValueObservation(
            kAXRoleAttribute as CFString,
            on: window.element,
            messagingTimeout: messagingTimeout
        )
        switch roleObservation.error {
        case .success:
            guard let role = roleObservation.value as? String else {
                return .unknown
            }
            guard role == kAXWindowRole else { return .unavailable }
        case .attributeUnsupported, .invalidUIElement:
            return .unavailable
        default:
            return .unknown
        }

        let subroleObservation = attributeValueObservation(
            kAXSubroleAttribute as CFString,
            on: window.element,
            messagingTimeout: messagingTimeout
        )
        switch subroleObservation.error {
        case .success:
            guard let subrole = subroleObservation.value as? String else {
                return .unknown
            }
            guard subrole == kAXStandardWindowSubrole else {
                return .unavailable
            }
        case .attributeUnsupported, .invalidUIElement:
            return .unavailable
        default:
            return .unknown
        }

        let modalObservation = attributeValueObservation(
            kAXModalAttribute as CFString,
            on: window.element,
            messagingTimeout: messagingTimeout
        )
        switch modalObservation.error {
        case .success:
            guard let isModal = modalObservation.value as? Bool else {
                return .unknown
            }
            return isModal ? .unavailable : .available
        case .attributeUnsupported:
            // Preserve the existing behavior for windows that simply do not
            // expose AXModal: lack of the optional attribute is not evidence of
            // a modal window.
            return .available
        case .invalidUIElement:
            return .unavailable
        default:
            return .unknown
        }
    }

    func isEligibleForConstraintLearning(_ window: ManagedWindow) -> Bool {
        constraintLearningEligibilityObservation(window) == .available
    }

    func snapshot(_ window: ManagedWindow) -> WindowSnapshot {
        WindowSnapshot(
            element: window.element,
            pid: window.pid,
            stableIdentity: window.stableIdentity,
            frame: window.frame,
            wasFullscreen: window.isFullscreen
        )
    }

    @discardableResult
    func setFrame(_ frame: CGRect, for window: AXUIElement) -> Bool {
        let firstPositionResult = setPosition(frame.origin, targetHeight: frame.height, for: window)
        let sizeResult = setSize(frame.size, for: window)
        let finalPositionResult = setPosition(frame.origin, targetHeight: frame.height, for: window)
        return firstPositionResult && sizeResult && finalPositionResult
    }

    /// Best-effort mutation used only by the pointer-following restore
    /// animation. Its short timeout is intentionally local to derived motion;
    /// correctness-critical snap, rollback, restore and constraint mutation
    /// retain the established interactive timeout and semantic settlement.
    func setFrameForInteractiveAnimation(
        _ frame: CGRect,
        for window: AXUIElement
    ) -> Bool {
        let firstPositionResult = setPosition(
            frame.origin,
            targetHeight: frame.height,
            for: window,
            messagingTimeout: AXMessagingTimeoutPolicy.animationMutation
        )
        let sizeResult = setSize(
            frame.size,
            for: window,
            messagingTimeout: AXMessagingTimeoutPolicy.animationMutation
        )
        guard firstPositionResult, sizeResult else { return false }
        return setPosition(
            frame.origin,
            targetHeight: frame.height,
            for: window,
            messagingTimeout: AXMessagingTimeoutPolicy.animationMutation
        )
    }

    @discardableResult
    func setFrameLightweight(
        _ frame: CGRect,
        primaryScreenTop: CGFloat,
        for window: AXUIElement
    ) -> Bool {
        var position = CGPoint(
            x: frame.minX,
            y: primaryScreenTop - frame.minY - frame.height
        )
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        return withMessagingTimeout(
            window,
            timeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) {
            let firstPositionResult = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue
            ) == .success
            let sizeResult = AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                sizeValue
            ) == .success
            let finalPositionResult = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue
            ) == .success
            return firstPositionResult && sizeResult && finalPositionResult
        }
    }

    func setFrameReliably(
        _ targetFrame: CGRect,
        for window: AXUIElement,
        completion: @escaping (Bool) -> Void
    ) {
        let operation = beginFrameOperation(for: window)
        setFrameReliably(
            targetFrame,
            for: window,
            operationKey: operation.key,
            generation: operation.generation,
            completion: { [weak self] succeeded in
                self?.finishFrameOperation(
                    key: operation.key,
                    generation: operation.generation
                )
                completion(succeeded)
            }
        )
    }

    private func setFrameReliably(
        _ targetFrame: CGRect,
        for window: AXUIElement,
        operationKey: String,
        generation: Int,
        attempt: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        guard isCurrentFrameOperation(key: operationKey, generation: generation) else { return }

        if let actualFrame = frame(of: window),
           framesMatch(actualFrame, targetFrame) {
            completion(true)
            return
        }

        _ = setPosition(targetFrame.origin, targetHeight: targetFrame.height, for: window)
        let preparationDelays: [TimeInterval] = [0.05, 0.06, 0.08, 0.10]
        let settleDelays: [TimeInterval] = [0.08, 0.11, 0.16, 0.20]
        let delayIndex = Swift.min(attempt, preparationDelays.count - 1)

        DispatchQueue.main.asyncAfter(deadline: .now() + preparationDelays[delayIndex]) { [weak self] in
            guard let self,
                  self.isCurrentFrameOperation(key: operationKey, generation: generation) else { return }

            _ = self.setSize(targetFrame.size, for: window)
            _ = self.setPosition(
                targetFrame.origin,
                targetHeight: targetFrame.height,
                for: window
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelays[delayIndex]) { [weak self] in
                guard let self,
                      self.isCurrentFrameOperation(key: operationKey, generation: generation) else { return }

                if let actualFrame = self.frame(of: window),
                   self.framesMatch(actualFrame, targetFrame) {
                    completion(true)
                    return
                }

                let nextAttempt = attempt + 1
                guard nextAttempt < preparationDelays.count else {
                    completion(false)
                    return
                }
                self.setFrameReliably(
                    targetFrame,
                    for: window,
                    operationKey: operationKey,
                    generation: generation,
                    attempt: nextAttempt,
                    completion: completion
                )
            }
        }
    }

    func setFrameAnchoredReliably(
        _ targetFrame: CGRect,
        sizeConstraintAnchor: CGPoint,
        requiredOuterEdges: SnapOuterEdges = [],
        skipInitialWriteWhenVerified: Bool = false,
        for window: AXUIElement,
        afterInitialFrameAttempt: (() -> Void)? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(window, &pid)
        setFrameAnchoredObserved(
            targetFrame,
            sizeConstraintAnchor: sizeConstraintAnchor,
            requiredOuterEdges: requiredOuterEdges,
            skipInitialWriteWhenVerified: skipInitialWriteWhenVerified,
            for: window,
            pid: pid,
            afterInitialFrameAttempt: afterInitialFrameAttempt
        ) { observation in
            completion(observation.completedSuccessfully)
        }
    }

    func setFrameAnchoredObserved(
        _ targetFrame: CGRect,
        sizeConstraintAnchor: CGPoint,
        requiredOuterEdges: SnapOuterEdges = [],
        requiredCommitSizeAxes: AXFrameSizeAxes? = nil,
        skipInitialWriteWhenVerified: Bool = false,
        for window: AXUIElement,
        pid: pid_t,
        afterInitialFrameAttempt: (() -> Void)? = nil,
        settlementMode: AXFrameSettlementMode = .requireExactTarget,
        completion: @escaping (AXFrameMutationObservation) -> Void
    ) {
        let operation = beginFrameOperation(for: window)
        setFrameAnchoredAndObserved(
            targetFrame,
            sizeConstraintAnchor: sizeConstraintAnchor,
            requiredOuterEdges: requiredOuterEdges,
            requiredCommitSizeAxes: requiredCommitSizeAxes,
            skipInitialWriteWhenVerified: skipInitialWriteWhenVerified,
            for: window,
            pid: pid,
            operationKey: operation.key,
            generation: operation.generation,
            afterInitialFrameAttempt: afterInitialFrameAttempt,
            settlementMode: settlementMode,
            completion: { [weak self] observation in
                self?.finishFrameOperation(
                    key: operation.key,
                    generation: operation.generation
                )
                completion(observation)
            }
        )
    }

    private func setFrameAnchoredAndObserved(
        _ targetFrame: CGRect,
        sizeConstraintAnchor: CGPoint,
        requiredOuterEdges: SnapOuterEdges,
        requiredCommitSizeAxes: AXFrameSizeAxes?,
        skipInitialWriteWhenVerified: Bool,
        for window: AXUIElement,
        pid: pid_t,
        operationKey: String,
        generation: Int,
        afterInitialFrameAttempt: (() -> Void)?,
        settlementMode: AXFrameSettlementMode,
        completion: @escaping (AXFrameMutationObservation) -> Void
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let correctionExactAxes = AXFrameSizePolicy.historicalCorrectionAxes(
            requiredOuterEdges: requiredOuterEdges
        )
        let commitExactAxes = AXFrameSizePolicy.commitAxes(
            requiredOuterEdges: requiredOuterEdges,
            explicitCommitAxes: requiredCommitSizeAxes
        )
        let hasRequiredExactDimension = !correctionExactAxes.isEmpty
        let tracksExactCommitTarget = !commitExactAxes.isEmpty
        let settlingTimeout: TimeInterval =
            (hasRequiredExactDimension || tracksExactCommitTarget) ? 1.8 : 0.9
        let timeoutAt = startedAt + settlingTimeout
        var previousObservedSize: CGSize?
        var stableSizeTransitions = 0
        var acceptedPlacementSamples = 0
        var lastCorrectionAt = startedAt
        var finalSizeRequestAt = startedAt
        var finalSizeRequestCount = 0
        var exactCorrectionCount = 0
        var previousTargetDistance: CGFloat?
        var lastTargetProgressAt = startedAt
        var targetProgressWasObserved = false
        var placementAcceptedAt: TimeInterval?
        var completionDelivered = false
        var mutationWasSent = false
        var sizeMutationSucceeded = false
        var latestSizeMutationSucceeded = false
        var lastObservedFrame: CGRect?

        func deliver(
            successful: Bool,
            acceptedFrame: CGRect?,
            settled: Bool,
            evidence: AXFrameSettlementEvidence
        ) {
            guard !completionDelivered else { return }
            completionDelivered = true
            completion(AXFrameMutationObservation(
                requestedFrame: targetFrame,
                acceptedFrame: acceptedFrame,
                mutationWasSent: mutationWasSent,
                sizeMutationSucceeded: sizeMutationSucceeded,
                acceptedFrameIsSettled: settled,
                liveness: self.windowLiveness(
                    element: window,
                    pid: pid,
                    messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
                ),
                completedSuccessfully: successful,
                settlementEvidence: evidence
            ))
        }

        func performCorrection() {
            mutationWasSent = true
            let result = self.setFinalFrameCorrection(
                targetFrame,
                sizeConstraintAnchor: sizeConstraintAnchor,
                for: window
            )
            latestSizeMutationSucceeded = result.sizeMutationSucceeded
            sizeMutationSucceeded = sizeMutationSucceeded
                || result.sizeMutationSucceeded
        }

        let startedAtVerifiedTarget: Bool
        if skipInitialWriteWhenVerified, let initialFrame = frame(of: window) {
            startedAtVerifiedTarget = sizesMatch(
                initialFrame.size,
                targetFrame.size,
                tolerance: 1
            ) && originsMatch(
                initialFrame.origin,
                targetFrame.origin,
                tolerance: 1
            ) && requiredOuterEdgesMatch(
                initialFrame,
                targetFrame,
                requiredEdges: requiredOuterEdges,
                tolerance: 1
            )
        } else {
            startedAtVerifiedTarget = false
        }

        if startedAtVerifiedTarget {
            // The live scheduler may already have reached the final frame.
            // Keep the normal stability verification, but do not issue a
            // redundant AX write that can make a heavy app draw once more.
            finalSizeRequestCount = 2
            finalSizeRequestAt = startedAt - 0.08
        } else {
            performCorrection()
            finalSizeRequestCount = 1
        }

        if let afterInitialFrameAttempt,
           isCurrentFrameOperation(key: operationKey, generation: generation) {
            afterInitialFrameAttempt()
            if !startedAtVerifiedTarget,
               isCurrentFrameOperation(key: operationKey, generation: generation) {
                // Activation/focus is part of this original mutation phase.
                // Issue one post-activation write so an inactive app that did
                // not apply the pre-activation request cannot be mistaken for
                // a size rejection. No later settlement retry replays this
                // mutation.
                performCorrection()
                finalSizeRequestAt = ProcessInfo.processInfo.systemUptime
                finalSizeRequestCount += 1
            }
        }

        guard isCurrentFrameOperation(
            key: operationKey,
            generation: generation
        ) else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self,
                  self.isCurrentFrameOperation(key: operationKey, generation: generation) else {
                timer.invalidate()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard let actualFrame = self.frame(of: window) else {
                guard now >= timeoutAt else { return }
                timer.invalidate()
                self.frameAnimationTimers.removeValue(forKey: operationKey)
                deliver(
                    successful: false,
                    acceptedFrame: lastObservedFrame,
                    settled: false,
                    evidence: .unresolved
                )
                return
            }

            lastObservedFrame = actualFrame

            if let previousObservedSize,
               self.sizesMatch(actualFrame.size, previousObservedSize, tolerance: 2) {
                stableSizeTransitions += 1
            } else {
                stableSizeTransitions = 0
            }
            previousObservedSize = actualFrame.size

            let effectiveFrame = self.anchoredFrame(
                targetFrame,
                actualSize: actualFrame.size,
                anchor: sizeConstraintAnchor
            )
            let anchorIsCorrect = self.originsMatch(
                actualFrame.origin,
                effectiveFrame.origin,
                tolerance: 1
            )
            let exactSizeIsCorrect = self.sizesMatch(
                actualFrame.size,
                targetFrame.size,
                tolerance: 1
            )
            let correctionRequiredSizeIsCorrect = AXFrameSizePolicy
                .requiredSizeIsCorrect(
                    actual: actualFrame.size,
                    target: targetFrame.size,
                    exactAxes: correctionExactAxes
                )
            let commitRequiredSizeIsCorrect = AXFrameSizePolicy
                .requiredSizeIsCorrect(
                    actual: actualFrame.size,
                    target: targetFrame.size,
                    exactAxes: commitExactAxes
                )
            let requiredEdgesAreCorrect = self.requiredOuterEdgesMatch(
                actualFrame,
                targetFrame,
                requiredEdges: requiredOuterEdges
            )

            if hasRequiredExactDimension || tracksExactCommitTarget {
                // Progress evidence for an unknown size boundary must come
                // from the dimensions this operation owns. Position/anchor
                // movement alone must not make a stale 60% size look like
                // progress toward a requested 50% size.
                let targetDistance = AXFrameSizePolicy.targetDistance(
                    actual: actualFrame.size,
                    target: targetFrame.size,
                    exactAxes: commitExactAxes
                )
                if let previousTargetDistance,
                   previousTargetDistance - targetDistance >= 1 {
                    targetProgressWasObserved = true
                    lastTargetProgressAt = now
                }
                previousTargetDistance = targetDistance
            }

            let acceptedSizeIsStable = stableSizeTransitions >= 1
            let settledAfterFinalSizeRequest = now - finalSizeRequestAt >= 0.08
            let finalTargetWasObserved = exactSizeIsCorrect
                || (finalSizeRequestCount >= 2 && settledAfterFinalSizeRequest)
            let placementIsAcceptable = commitRequiredSizeIsCorrect
                && requiredEdgesAreCorrect
                && finalTargetWasObserved

            if placementIsAcceptable && acceptedSizeIsStable {
                acceptedPlacementSamples += 1
                if placementAcceptedAt == nil {
                    placementAcceptedAt = now
                }
            } else {
                acceptedPlacementSamples = 0
                placementAcceptedAt = nil
            }

            let verificationDuration: TimeInterval
            if startedAtVerifiedTarget {
                verificationDuration = 0.02
            } else {
                verificationDuration = (hasRequiredExactDimension
                    || tracksExactCommitTarget) ? 0.08 : 0.04
            }
            if acceptedPlacementSamples >= 2,
               let placementAcceptedAt,
               now - placementAcceptedAt >= verificationDuration {
                timer.invalidate()
                self.frameAnimationTimers.removeValue(forKey: operationKey)
                deliver(
                    successful: true,
                    acceptedFrame: actualFrame,
                    settled: true,
                    evidence: .exactTarget
                )
                return
            }

            if AXFrameSettlementPolicy.shouldReturnSettledConstraintResult(
                mode: settlementMode,
                placementIsAcceptable: placementIsAcceptable,
                mutationWasSent: mutationWasSent,
                sizeMutationSucceeded: latestSizeMutationSucceeded,
                acceptedSizeIsStable: acceptedSizeIsStable,
                settledAfterFinalSizeRequest: settledAfterFinalSizeRequest,
                targetProgressWasObserved: targetProgressWasObserved,
                secondsWithoutTargetProgress: now - lastTargetProgressAt
            ) {
                // This is a new semantic observation, not a failed retry. The
                // caller owns whether the accepted frame authorizes a replan.
                timer.invalidate()
                self.frameAnimationTimers.removeValue(forKey: operationKey)
                deliver(
                    successful: false,
                    acceptedFrame: actualFrame,
                    settled: true,
                    evidence: .operationLocalAlternative
                )
                return
            }

            guard now < timeoutAt else {
                timer.invalidate()
                self.frameAnimationTimers.removeValue(forKey: operationKey)
                let settled = stableSizeTransitions >= 1
                deliver(
                    successful: false,
                    acceptedFrame: actualFrame,
                    settled: settled,
                    evidence: settled && latestSizeMutationSucceeded
                        ? .boundedAlternative : .unresolved
                )
                return
            }

            if hasRequiredExactDimension, !placementIsAcceptable {
                let correctionIntervals: [TimeInterval] = [0.10, 0.16, 0.24, 0.32]
                let correctionInterval = correctionIntervals[
                    Swift.min(exactCorrectionCount, correctionIntervals.count - 1)
                ]
                let applicationIsStillResponding = now - lastTargetProgressAt < 0.10
                if now - lastCorrectionAt >= correctionInterval,
                   !applicationIsStillResponding {
                    var issuedCorrection = false

                    if !correctionRequiredSizeIsCorrect
                        || (!exactSizeIsCorrect && finalSizeRequestCount < 2) {
                        performCorrection()
                        finalSizeRequestAt = now
                        finalSizeRequestCount += 1
                        issuedCorrection = true
                    } else if !requiredEdgesAreCorrect {
                        _ = self.setPosition(
                            effectiveFrame.origin,
                            targetHeight: effectiveFrame.height,
                            for: window
                        )
                        issuedCorrection = true
                    }

                    if issuedCorrection {
                        exactCorrectionCount += 1
                        lastCorrectionAt = now
                        lastTargetProgressAt = now
                        previousTargetDistance = nil
                        previousObservedSize = nil
                        stableSizeTransitions = 0
                        acceptedPlacementSamples = 0
                        placementAcceptedAt = nil
                    }
                }
            } else if !hasRequiredExactDimension,
                      now - lastCorrectionAt >= 0.10 {
                if !exactSizeIsCorrect,
                   finalSizeRequestCount < 2 {
                    performCorrection()
                    finalSizeRequestAt = now
                    finalSizeRequestCount += 1
                    previousObservedSize = nil
                    stableSizeTransitions = 0
                    acceptedPlacementSamples = 0
                    placementAcceptedAt = nil
                } else if !anchorIsCorrect {
                    _ = self.setPosition(
                        effectiveFrame.origin,
                        targetHeight: effectiveFrame.height,
                        for: window
                    )
                }
                lastCorrectionAt = now
            }
        }
        frameAnimationTimers[operationKey] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private struct FrameCorrectionResult {
        let operationSucceeded: Bool
        let sizeMutationSucceeded: Bool
    }

    @discardableResult
    private func setFinalFrameCorrection(
        _ targetFrame: CGRect,
        sizeConstraintAnchor: CGPoint,
        for window: AXUIElement
    ) -> FrameCorrectionResult {
        let preparationPositionResult = setPosition(
            targetFrame.origin,
            targetHeight: targetFrame.height,
            for: window
        )
        let sizeResult = setSize(targetFrame.size, for: window)
        guard let acceptedSize = frame(of: window)?.size else {
            return FrameCorrectionResult(
                operationSucceeded: false,
                sizeMutationSucceeded: sizeResult
            )
        }
        let acceptedFrame = anchoredFrame(
            targetFrame,
            actualSize: acceptedSize,
            anchor: sizeConstraintAnchor
        )
        let finalPositionResult = setPosition(
            acceptedFrame.origin,
            targetHeight: acceptedFrame.height,
            for: window
        )
        return FrameCorrectionResult(
            operationSucceeded:
                preparationPositionResult && sizeResult && finalPositionResult,
            sizeMutationSucceeded: sizeResult
        )
    }

    func cancelFrameOperation(for window: AXUIElement) {
        let key = frameOperationKey(for: window)
        frameAnimationTimers.removeValue(forKey: key)?.invalidate()
        frameOperationGenerations.removeValue(forKey: key)
    }

    func cancelAllFrameOperations() {
        frameAnimationTimers.values.forEach { $0.invalidate() }
        frameAnimationTimers.removeAll()
        frameOperationGenerations.removeAll()
    }

    private func beginFrameOperation(for window: AXUIElement) -> (key: String, generation: Int) {
        let key = frameOperationKey(for: window)
        frameAnimationTimers.removeValue(forKey: key)?.invalidate()
        nextFrameOperationGeneration &+= 1
        let generation = nextFrameOperationGeneration
        frameOperationGenerations[key] = generation
        return (key, generation)
    }

    private func frameOperationKey(for window: AXUIElement) -> String {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(window, &pid)
        return FrameOperationOwnershipPolicy.key(
            pid: pid,
            elementHash: String(CFHash(window))
        )
    }

    private func finishFrameOperation(key: String, generation: Int) {
        guard isCurrentFrameOperation(key: key, generation: generation) else { return }
        frameAnimationTimers.removeValue(forKey: key)?.invalidate()
        frameOperationGenerations.removeValue(forKey: key)
    }

    private func isCurrentFrameOperation(key: String, generation: Int) -> Bool {
        frameOperationGenerations[key] == generation
    }

    @discardableResult
    private func setPosition(
        _ origin: CGPoint,
        targetHeight: CGFloat,
        for window: AXUIElement,
        messagingTimeout: Float = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> Bool {
        var position = cocoaPointToAX(origin, height: targetHeight)
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return withMessagingTimeout(
            window,
            timeout: messagingTimeout
        ) {
            AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                value
            ) == .success
        }
    }

    @discardableResult
    private func setSize(
        _ targetSize: CGSize,
        for window: AXUIElement,
        messagingTimeout: Float = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> Bool {
        var size = targetSize
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return withMessagingTimeout(
            window,
            timeout: messagingTimeout
        ) {
            AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                value
            ) == .success
        }
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func requiredOuterEdgesMatch(
        _ frame: CGRect,
        _ targetFrame: CGRect,
        requiredEdges: SnapOuterEdges,
        tolerance: CGFloat = 1
    ) -> Bool {
        if requiredEdges.contains(.left),
           abs(frame.minX - targetFrame.minX) > tolerance {
            return false
        }
        if requiredEdges.contains(.right),
           abs(frame.maxX - targetFrame.maxX) > tolerance {
            return false
        }
        if requiredEdges.contains(.top),
           abs(frame.maxY - targetFrame.maxY) > tolerance {
            return false
        }
        if requiredEdges.contains(.bottom),
           abs(frame.minY - targetFrame.minY) > tolerance {
            return false
        }
        return true
    }

    private func originsMatch(
        _ lhs: CGPoint,
        _ rhs: CGPoint,
        tolerance: CGFloat = 5
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
    }

    private func sizesMatch(
        _ lhs: CGSize,
        _ rhs: CGSize,
        tolerance: CGFloat = 5
    ) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    @discardableResult
    func setFullscreen(_ fullscreen: Bool, for window: AXUIElement) -> Bool {
        let value: CFBoolean = fullscreen ? kCFBooleanTrue : kCFBooleanFalse
        return withMessagingTimeout(
            window,
            timeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) {
            AXUIElementSetAttributeValue(
                window,
                "AXFullScreen" as CFString,
                value
            ) == .success
        }
    }

    func isFullscreen(_ window: AXUIElement) -> Bool {
        copyAttribute(
            window,
            "AXFullScreen" as CFString,
            messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) ?? false
    }

    @discardableResult
    func raise(_ window: ManagedWindow) -> Bool {
        withMessagingTimeout(
            window.element,
            timeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) {
            AXUIElementPerformAction(
                window.element,
                kAXRaiseAction as CFString
            ) == .success
        }
    }

    func focus(_ window: ManagedWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])
        raise(window)
    }

    /// Mission Control group selection needs application activation without
    /// prematurely selecting/raising one member. The caller observes the
    /// resulting frontmost application before authorizing any group mutation.
    @discardableResult
    func activateApplication(pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(
            processIdentifier: pid
        ) else { return false }
        return application.activate(options: [.activateIgnoringOtherApps])
    }

    func isFrontmostApplication(pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    func waitForPlacementReadiness(
        _ window: ManagedWindow,
        minimumDelay: TimeInterval = 0.06,
        timeout: TimeInterval = 0.45,
        shouldContinue: @escaping () -> Bool = { true },
        completion: @escaping (PlacementReadinessResult) -> Void
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime

        func observation(
            messagingTimeout: Float
        ) -> (ManagedWindow?, WindowInteractionCapabilityObservation) {
            guard let app = NSRunningApplication(processIdentifier: window.pid),
                  !app.isTerminated else {
                return (nil, .unavailable)
            }
            if let current = refreshed(
                window,
                messagingTimeout: messagingTimeout
            ) {
                return (
                    current,
                    moveAndResizeCapability(
                        current,
                        messagingTimeout: messagingTimeout
                    )
                )
            }
            switch windowLiveness(
                element: window.element,
                pid: window.pid,
                messagingTimeout: messagingTimeout
            ) {
            case .missing:
                return (nil, .unavailable)
            case .alive, .unknown:
                return (nil, .unknown)
            }
        }

        func finishIfSettled(
            current: ManagedWindow?,
            capability: WindowInteractionCapabilityObservation
        ) -> Bool {
            switch capability {
            case .available:
                guard let current else { return false }
                completion(.ready(current))
                return true
            case .unavailable:
                completion(.unavailable)
                return true
            case .unknown:
                return false
            }
        }

        func checkReadiness() {
            guard shouldContinue() else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let sample = observation(
                messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
            )

            if elapsed >= minimumDelay, finishIfSettled(
                current: sample.0,
                capability: sample.1
            ) {
                return
            }

            guard elapsed < timeout else {
                let finalSample = observation(
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                )
                if !finishIfSettled(
                    current: finalSample.0,
                    capability: finalSample.1
                ) {
                    completion(.indeterminate)
                }
                return
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.05,
                execute: checkReadiness
            )
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + minimumDelay,
            execute: checkReadiness
        )
    }

    func restore(_ snapshot: WindowSnapshot, completion: @escaping (Bool) -> Void) {
        if snapshot.wasFullscreen {
            guard setFullscreen(true, for: snapshot.element) else {
                completion(false)
                return
            }
            waitForFullscreenState(true, for: snapshot.element, completion: completion)
        } else {
            setFrameReliably(
                snapshot.frame,
                for: snapshot.element,
                completion: completion
            )
        }
    }

    func waitForFullscreenState(
        _ expected: Bool,
        for window: AXUIElement,
        timeout: TimeInterval = 1.2,
        completion: @escaping (Bool) -> Void
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime

        func check() {
            if isFullscreen(window) == expected {
                completion(true)
                return
            }
            guard ProcessInfo.processInfo.systemUptime - startedAt < timeout else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
        }

        check()
    }

    private func makeManagedWindow(
        _ element: AXUIElement,
        pid: pid_t,
        app: NSRunningApplication,
        cgWindowID: CGWindowID?,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> ManagedWindow? {
        withMessagingTimeout(element, timeout: messagingTimeout) {
            let role: String? = copyAttribute(
                element,
                kAXRoleAttribute as CFString
            )
            guard role == kAXWindowRole else { return nil }
            let subrole: String? = copyAttribute(
                element,
                kAXSubroleAttribute as CFString
            )
            guard subrole != kAXUnknownSubrole else { return nil }
            guard let frame = frame(of: element, messagingTimeout: nil) else {
                return nil
            }
            let title: String = copyAttribute(
                element,
                kAXTitleAttribute as CFString
            ) ?? app.localizedName ?? "ウィンドウ"
            let minimized: Bool = copyAttribute(
                element,
                kAXMinimizedAttribute as CFString
            ) ?? false
            let fullscreen: Bool = copyAttribute(
                element,
                "AXFullScreen" as CFString
            ) ?? false
            return ManagedWindow(
                element: element,
                pid: pid,
                title: title.isEmpty ? (app.localizedName ?? "ウィンドウ") : title,
                appIcon: app.icon,
                frame: frame,
                isMinimized: minimized,
                isFullscreen: fullscreen,
                cgWindowID: cgWindowID
            )
        }
    }

    private func matchedWindows(
        for app: NSRunningApplication,
        cgWindows: [CGWindowRecord],
        excludingStableIDs excludedStableIDs: Set<String> = [],
        usesFocusedWindowHint: Bool = true,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> [(window: ManagedWindow, zIndex: Int)] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let elements: [AXUIElement] = copyAttribute(
            appElement,
            kAXWindowsAttribute as CFString,
            messagingTimeout: messagingTimeout
        ) ?? []
        let focusedElement: AXUIElement? = usesFocusedWindowHint
            ? copyAttribute(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                messagingTimeout: messagingTimeout
            )
            : nil
        let baseWindows = elements.compactMap {
            makeManagedWindow(
                $0,
                pid: pid,
                app: app,
                cgWindowID: nil,
                messagingTimeout: messagingTimeout
            )
        }.filter {
            !excludedStableIDs.contains($0.stableIdentity)
        }
        let appCGWindows = cgWindows
            .filter { $0.pid == pid }
            .sorted { $0.zIndex < $1.zIndex }
        let scoreMatrix: [[CGFloat?]] = baseWindows.map { window in
            appCGWindows.map { record in
                guard visibleGeometryMatches(
                    axWindow: window,
                    cgWindow: record
                ) else { return nil }
                return matchScore(axWindow: window, cgWindow: record)
                    + (usesFocusedWindowHint && focusedElement.map {
                        CFEqual(window.element, $0)
                    } == true ? 25 : 0)
            }
        }
        let matches = WindowMatchingPolicy.mutualUniqueMatches(
            scores: scoreMatrix
        )

        return matches.map { match in
            let base = baseWindows[match.axIndex]
            let record = appCGWindows[match.cgIndex]
            let matched = makeManagedWindow(
                base.element,
                pid: pid,
                app: app,
                cgWindowID: record.id,
                messagingTimeout: messagingTimeout
            ) ?? base
            return (matched, record.zIndex)
        }
    }

    private func isModalSurface(_ element: AXUIElement) -> Bool {
        let isModal: Bool = copyAttribute(
            element,
            "AXModal" as CFString,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        ) ?? false
        if isModal { return true }
        let subrole: String? = copyAttribute(
            element,
            kAXSubroleAttribute as CFString,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        )
        return subrole == "AXDialog" || subrole == "AXSystemDialog"
    }

    private func hasAttachedSheets(_ element: AXUIElement) -> Bool {
        let sheets: [AXUIElement] = copyAttribute(
            element,
            "AXSheets" as CFString,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        ) ?? []
        return !sheets.isEmpty
    }

    private func visibleGeometryMatches(
        axWindow: ManagedWindow,
        cgWindow: CGWindowRecord
    ) -> Bool {
        let sizeDelta = abs(cgWindow.frame.width - axWindow.frame.width)
            + abs(cgWindow.frame.height - axWindow.frame.height)
        let originDelta = abs(cgWindow.frame.minX - axWindow.frame.minX)
            + abs(cgWindow.frame.minY - axWindow.frame.minY)
        let referenceLength = max(
            min(cgWindow.frame.width, cgWindow.frame.height),
            1
        )
        let allowedSizeDelta = max(24, referenceLength * 0.08)
        let allowedOriginDelta = max(48, referenceLength * 0.12)
        return sizeDelta <= allowedSizeDelta
            && originDelta <= allowedOriginDelta
    }

    private func matchScore(axWindow: ManagedWindow, cgWindow: CGWindowRecord) -> CGFloat {
        let sizeDelta = abs(cgWindow.frame.width - axWindow.frame.width)
            + abs(cgWindow.frame.height - axWindow.frame.height)
        let originDelta = abs(cgWindow.frame.minX - axWindow.frame.minX)
            + abs(cgWindow.frame.minY - axWindow.frame.minY)
        let exactTitle = !axWindow.title.isEmpty
            && !cgWindow.title.isEmpty
            && axWindow.title == cgWindow.title
        let compatibleTitle = exactTitle || axWindow.title.isEmpty || cgWindow.title.isEmpty
        let titleScore: CGFloat = exactTitle ? 300 : (compatibleTitle ? 30 : 0)
        return titleScore - sizeDelta * 6 - originDelta * 2
    }

    func windowServerFrame(
        pid: pid_t,
        windowID: CGWindowID
    ) -> CGRect? {
        // Query only the exact physical surface. Snap settlement is verification,
        // not animation, so avoid broad Window Server census work while screen
        // capture software may be querying the same subsystem.
        let requestedIDs = [NSNumber(value: windowID)] as CFArray
        let descriptions = CGWindowListCreateDescriptionFromArray(requestedIDs)
            as? [[String: Any]] ?? []
        guard let item = descriptions.first(where: { item in
            (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                == windowID
                && (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == pid
                && ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
                    == 0
        }) else { return nil }
        let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any]
            ?? [:]
        guard let bounds = CGRect(
            dictionaryRepresentation: boundsDictionary as CFDictionary
        ), bounds.width > 0, bounds.height > 0 else { return nil }
        return cgBoundsToCocoa(bounds)
    }

    private func frame(
        of element: AXUIElement,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.interactiveOperation
    ) -> CGRect? {
        withMessagingTimeout(element, timeout: messagingTimeout) {
            guard let positionValue: AXValue = copyAttribute(
                element,
                kAXPositionAttribute as CFString
            ), let sizeValue: AXValue = copyAttribute(
                element,
                kAXSizeAttribute as CFString
            ) else { return nil }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue, .cgPoint, &point),
                  AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
            return CGRect(
                origin: axPointToCocoa(point, height: size.height),
                size: size
            )
        }
    }

    func previewCGImage(
        for windowID: CGWindowID?,
        capacityWait requestedCapacityWait: TimeInterval
    ) -> CGImage? {
        guard let windowID else { return nil }
        let capacityWait = PreviewCaptureAdmissionPolicy.effectiveWait(
            requested: requestedCapacityWait,
            isMainThread: Thread.isMainThread
        )
        guard Self.beginPreviewCapture(waitingUpTo: capacityWait) else {
            return nil
        }
        defer { Self.endPreviewCapture() }
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    private static func beginPreviewCapture(
        waitingUpTo wait: TimeInterval
    ) -> Bool {
        let deadline: DispatchTime = wait > 0 ? .now() + wait : .now()
        return previewCaptureAdmission.wait(timeout: deadline) == .success
    }

    private static func endPreviewCapture() {
        previewCaptureAdmission.signal()
    }

    private func onscreenWindowRecords() -> [CGWindowRecord] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return info.enumerated().compactMap { index, item in
            guard ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0,
                  let idNumber = item[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
            guard let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            return CGWindowRecord(
                id: CGWindowID(idNumber.uint32Value),
                pid: pidNumber.int32Value,
                title: (item[kCGWindowName as String] as? String) ?? "",
                frame: cgBoundsToCocoa(bounds),
                zIndex: index
            )
        }
    }

    private func anchoredFrame(
        _ proposedFrame: CGRect,
        actualSize: CGSize,
        anchor: CGPoint
    ) -> CGRect {
        let safeAnchorX = min(max(anchor.x, 0), 1)
        let safeAnchorY = min(max(anchor.y, 0), 1)
        return CGRect(
            x: proposedFrame.minX + (proposedFrame.width - actualSize.width) * safeAnchorX,
            y: proposedFrame.minY + (proposedFrame.height - actualSize.height) * safeAnchorY,
            width: actualSize.width,
            height: actualSize.height
        )
    }

    private func cocoaPointToAX(_ point: CGPoint, height: CGFloat) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryTop - point.y - height)
    }

    private func axPointToCocoa(_ point: CGPoint, height: CGFloat) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryTop - point.y - height)
    }

    private func cgBoundsToCocoa(_ bounds: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: bounds.minX, y: primaryTop - bounds.maxY, width: bounds.width, height: bounds.height)
    }


    private func attributeValueObservation(
        _ attribute: CFString,
        on element: AXUIElement,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> (error: AXError, value: CFTypeRef?) {
        withMessagingTimeout(element, timeout: messagingTimeout) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                element,
                attribute,
                &value
            )
            return (error, value)
        }
    }

    private func attributeSettableObservation(
        _ attribute: CFString,
        on element: AXUIElement,
        messagingTimeout: Float? = AXMessagingTimeoutPolicy.passiveObservation
    ) -> WindowInteractionCapabilityObservation {
        withMessagingTimeout(element, timeout: messagingTimeout) {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(
                element,
                attribute,
                &settable
            )
            switch result {
            case .success:
                return settable.boolValue ? .available : .unavailable
            case .attributeUnsupported, .invalidUIElement:
                return .unavailable
            default:
                // cannotComplete, transport failure, disabled API, and other
                // non-semantic failures are indeterminate observations.
                return .unknown
            }
        }
    }

    private func withMessagingTimeout<T>(
        _ element: AXUIElement,
        timeout: Float?,
        perform: () -> T
    ) -> T {
        guard let timeout else { return perform() }
        _ = AXUIElementSetMessagingTimeout(element, timeout)
        defer {
            // For non-system elements, zero restores the current process-wide
            // default instead of installing a permanent short timeout.
            _ = AXUIElementSetMessagingTimeout(element, 0)
        }
        return perform()
    }

    private func copyAttribute<T>(
        _ element: AXUIElement,
        _ attribute: CFString,
        messagingTimeout: Float? = nil
    ) -> T? {
        withMessagingTimeout(element, timeout: messagingTimeout) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute,
                &value
            ) == .success else { return nil }
            return value as? T
        }
    }
}
