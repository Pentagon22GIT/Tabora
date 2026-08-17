import AppKit
import ApplicationServices

struct LockedPlacement {
    let element: AXUIElement
    let pid: pid_t
    let stableIdentity: String
    let cgWindowID: CGWindowID?
    let zone: SnapZone
    let displayID: CGDirectDisplayID
    var appliedFrame: CGRect
}

private struct SnapshotTransaction {
    let snapshots: [WindowSnapshot]
}

private struct DeferredPointerDragResolution {
    let evidence: PointerDragSurfaceEvidence
    var attempts: Int
}

private struct InitialReflowFollower {
    let window: ManagedWindow
    let zone: SnapZone
    let axis: SplitAxis
    let side: SplitBoundarySide
    let originalFrame: CGRect
    let targetFrame: CGRect
    let constraintReference: CGSize
}

private struct InitialReflowPlan {
    let axes: Set<SplitAxis>
    let candidateStartFrame: CGRect
    let candidateTarget: CGRect
}

private enum InitialSplitDisposition {
    case accept
    case reflow(InitialReflowPlan)
    case reject
}

struct HandleResizeParticipant {
    let window: ManagedWindow
    let zone: SnapZone
    let originalFrame: CGRect
    let constraintReference: CGSize
    var targetFrame: CGRect
}

struct HandleResizeBoundary {
    let descriptor: ResizeHandleDescriptor
    let allowedBoundary: ClosedRange<CGFloat>
    let sides: [String: SplitBoundarySide]
    var coordinate: CGFloat
}

struct HandleResizeSession {
    let interactionID: String
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let mainIdentity: String
    let liveIdentities: Set<String>
    let virtualIdentities: Set<String>
    let schedulerGeneration: Int
    let snapshots: [WindowSnapshot]
    var participants: [String: HandleResizeParticipant]
    var boundaries: [HandleResizeBoundary]
}

struct LayoutSession {
    var groupID: SnapGroupID? = nil
    let excludedCandidateIDs: Set<String>
    let layoutZones: [SnapZone]
    var occupiedZones: [SnapZone: String]

    init(
        groupID: SnapGroupID? = nil,
        excludedCandidateIDs: Set<String> = [],
        layoutZones: [SnapZone],
        occupiedZones: [SnapZone: String]
    ) {
        self.groupID = groupID
        self.excludedCandidateIDs = excludedCandidateIDs
        self.layoutZones = layoutZones
        self.occupiedZones = occupiedZones
    }

    mutating func occupy(_ zone: SnapZone, stableIdentity: String) {
        occupiedZones[zone] = stableIdentity
    }

    var remainingZones: [SnapZone] {
        layoutZones.filter { occupiedZones[$0] == nil }
    }

    var occupiedStableIDs: Set<String> {
        Set(occupiedZones.values)
    }
}

struct SnapPlacementContext {
    let targetGroupID: SnapGroupID?
    let departingGroupID: SnapGroupID?
    let memberIDs: Set<String>
    let excludedAssistCandidateIDs: Set<String>
    let displayID: CGDirectDisplayID
}

struct StagedGroupDeparture {
    let draggedIdentity: String
    let memberIDs: Set<String>
}

struct ExplicitGroupDepartureSnapshot: Equatable {
    let groupID: SnapGroupID
    let memberIDs: Set<String>
}

struct PendingNativeResizeCandidate {
    let element: AXUIElement
    let pid: pid_t
    let stableIdentity: String
    let initialFrame: CGRect
    let departure: ExplicitGroupDepartureSnapshot?
}

private enum SnapEntryEdge {
    case left, right, top, bottom
}

struct SnapTarget: Equatable {
    let displayID: CGDirectDisplayID
    let zone: SnapZone
}

private enum SideSnapEdge: Equatable {
    case left
    case right
}

enum ConnectedGroupRaiseOrigin: Equatable {
    case pointer
    case focus
}

enum GroupForegroundMode: Equatable {
    case disabled
    case automatic
    case soloPresented(memberID: String)

    static let defaultMode: GroupForegroundMode = .disabled
}

enum GroupForegroundClickDisposition: Equatable {
    case evaluateExplicitGroupRaise
    case preserveSystemIsolation
}

enum GroupForegroundAuthorizationPolicy {
    static func directClickDisposition(
        for mode: GroupForegroundMode
    ) -> GroupForegroundClickDisposition {
        if case .soloPresented = mode {
            return .preserveSystemIsolation
        }
        return .evaluateExplicitGroupRaise
    }
}

struct OwnedForegroundMutation {
    let generation: Int
    let groupID: SnapGroupID
    let memberIdentities: Set<String>
    let memberSelections: Set<WindowServerSelectionSnapshot>
}

enum ForegroundMutationProcessDisposition: Equatable {
    case ownedMutation
    case externalSelection
    case awaitExactWindowIdentity
}

enum ForegroundMutationSelectionPolicy {
    static func isOwnedSelection(
        _ selection: WindowServerSelectionSnapshot?,
        mutation: OwnedForegroundMutation?
    ) -> Bool {
        guard let selection, let mutation else { return false }
        return mutation.memberSelections.contains(selection)
    }

    static func processNotificationDisposition(
        expectedPID: pid_t?,
        accessibilitySelection: ActiveWindowIdentitySnapshot?,
        mutation: OwnedForegroundMutation?
    ) -> ForegroundMutationProcessDisposition {
        guard let mutation else { return .externalSelection }
        guard let expectedPID else { return .awaitExactWindowIdentity }
        guard mutation.memberSelections.contains(where: {
            $0.pid == expectedPID
        }) else {
            return .externalSelection
        }
        guard let accessibilitySelection,
              accessibilitySelection.pid == expectedPID else {
            return .awaitExactWindowIdentity
        }
        let identities = Set([
            accessibilitySelection.focusedIdentity,
            accessibilitySelection.mainIdentity
        ].compactMap { $0 })
        guard !identities.isEmpty else { return .awaitExactWindowIdentity }
        return identities.isSubset(of: mutation.memberIdentities)
            ? .ownedMutation
            : .externalSelection
    }
}

private struct SideDwellContext: Equatable {
    let displayID: CGDirectDisplayID
    let edge: SideSnapEdge
}

final class SnapController {
    var isEnabled = true {
        didSet {
            if !isEnabled {
                updateSelectionMonitoringState()
                invalidatePendingOperations()
                stopEscapeMonitoring()
                overlay.hide()
                picker.hide()
                virtualResizeOverlay.hideAll()
                resizeHandleOverlay.hideAll()
                missionControlGroupProxyController.hideAll()
                cancelHandleResize(restoreOriginalFrames: true)
                resetDragState()
                activeSession = nil
                activeWindowObserver.stop()
                windowServerSelectionPollState.reset()
            } else if oldValue != isEnabled {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.windowServerSelectionPollState.reset()
                    if !self.installEventMonitors() {
                        self.scheduleEventMonitorReadinessChecksIfNeeded()
                    }
                    self.updateSelectionMonitoringState()
                    self.activeWindowObserver.observeFrontmostApplication()
                    self.refreshResizeHandles()
                }
            }
        }
    }

    let windowService = AXWindowService()
    let overlay = OverlayPanel()
    let picker = WindowPickerPanel()
    let virtualResizeOverlay = VirtualResizeOverlay()
    let resizeHandleOverlay = ResizeHandleOverlay()
    let missionControlGroupProxyController = MissionControlGroupProxyController()
    private let activeWindowObserver = ActiveWindowObserver()
    lazy var liveResizeScheduler = LiveResizeScheduler(windowService: windowService)
    let settings = AppSettings.shared
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventMonitorReadinessGeneration = 0
    private var eventMonitorReadinessChecksAreScheduled = false
    private var globalEscapeMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var recoveryTimer: Timer?
    private var focusedWindowPollTimer: Timer?
    private var isControllerRunning = false
    var windowServerSelectionPollState = WindowServerSelectionPollState()
    private let focusedWindowPollInterval: TimeInterval = 0.10
    private var lastInteractionAt = Date()
    private let assistTimeout: TimeInterval = 30
    var activeTarget: SnapTarget?

    var pendingDragWindow: ManagedWindow?
    var pendingDragWindowFrame: CGRect?
    private var pendingDragMousePoint: CGPoint?
    private var pendingDragStartedInLikelyDragRegion = false
    var pendingDragStartedNearResizeEdge = false
    private var frontmostGroupIDsAtPointerDown: Set<SnapGroupID>?
    var isWindowMoveConfirmed = false
    var sourceDragWindow: ManagedWindow?
    private var deferredPointerDragResolution: DeferredPointerDragResolution?
    private var windowServerIDsAtDragStart: Set<CGWindowID> = []
    private var detachedWindowServerCensusAtDragStart =
        WindowServerWindowIDCensus.unknown
    private var pendingRestoreFrame: CGRect?
    private var dragRestoreFrameCandidate: CGRect?
    private var pendingGrabRatio: CGPoint?
    private var dragRestoreAnimationTimer: Timer?
    var hasWindowActuallyMoved = false
    var didStartDragRestore = false
    private var detachedCandidateID: String?
    private var detachedCandidateHitCount = 0
    var manualResizeWindow: ManagedWindow?
    var pendingNativeResizeDeparture: ExplicitGroupDepartureSnapshot?
    var pendingNativeResizeCandidates: [PendingNativeResizeCandidate] = []
    var unresolvedNativeResizeWasActivated = false
    var lastManualResizeRefreshAt: TimeInterval = 0
    let manualResizeRefreshInterval: TimeInterval = 1.0 / 60.0
    let manualResizeDetectionTolerance: CGFloat = 0.5
    private var sideDwellTimer: Timer?
    private var sideDwellPulseTimer: Timer?
    private var sideDwellContext: SideDwellContext?
    private var expandedSideContext: SideDwellContext?

    var dragWindow: ManagedWindow?
    private var dragDisplayID: CGDirectDisplayID?
    private var dragScreenFrame: CGRect?
    private var suppressedEntryEdge: SnapEntryEdge?
    private var suppressedDisplayID: CGDirectDisplayID?
    private var snapshotTransactions: [SnapshotTransaction] = []
    var isReconcilingPlacementMutation = false
    var lockedPlacements: [String: LockedPlacement] = [:] {
        didSet {
            guard !isReconcilingPlacementMutation else { return }
            let removedIDs = Set(oldValue.keys).subtracting(lockedPlacements.keys)
            if !removedIDs.isEmpty {
                missionControlGroupProxyController.hideAll()
            }
            updateSelectionMonitoringState()
        }
    }
    var explicitGroupStore = SnapGroupStore()
    let missionControlGroupPresentationIsEnabled = true
    var isUserSessionActive = true
    var lastGroupWindowServerEvidenceByIdentity:
        [String: GroupWindowServerEvidence] = [:]
    var isPreservingGroupPresentationForWindowServerTransform = false
    var groupPresentationRecoveryDeadline: TimeInterval?
    var groupPresentationRecoveryGeneration = 0
    var groupPresentationRecoveryChecksAreScheduled = false
    var connectedLayoutPlacementCount: Int {
        explicitGroupStore.connectedMemberCount
    }
    var detachedConnections: Set<SplitConnectionKey> = []
    var constraintHints: [String: WindowConstraintHint] = [:]
    var restoreFrames: [String: CGRect] = [:]
    var activeSession: LayoutSession?
    var isAssistPlacementPending = false
    // Registration, proxy rebuilding and assist presentation must commit as a
    // single visual transaction. Otherwise observers can render the temporary
    // one-window state between those steps and produce a visible flash.
    var isSnapPlacementInProgress = false
    var snapPlacementInteractionGeneration: Int?
    var activeSnapPlacementContext: SnapPlacementContext?
    var interactionGeneration = 0
    var pendingPlacementSnapshots: [String: WindowSnapshot] = [:]
    var inFlightPlacementIDs: Set<String> = []
    var handleResizeSession: HandleResizeSession?
    var isHandleResizeFinalizing = false
    var finalizingHandleResizeSession: HandleResizeSession?
    var baseResizeHandleDescriptors: [ResizeHandleDescriptor] = []
    var quarantinedResizeHandleIDs = Set<String>()
    var lastHandleOcclusionRefreshAt: TimeInterval = 0
    let handleOcclusionRefreshInterval: TimeInterval = 1.0 / 20.0
    var handleOcclusionFailureCountsByDescriptorID: [String: Int] = [:]
    var handlePresentationGeneration = 0
    var scheduledHandleOcclusionRetryGeneration: Int?
    var handleGeometryRetryGeneration = 0
    var scheduledHandleGeometryRetryGeneration: Int?
    var handleGeometryFailureCountsByGroupID: [SnapGroupID: Int] = [:]
    var hasValidatedCurrentHandleGeometry = false
    let maximumImmediateHandleOcclusionFailures = 6
    var groupRaiseGeneration = 0
    var pendingGroupRaiseWorkItem: DispatchWorkItem?
    var deferredPlainClickPoint: CGPoint?
    var deferredSelectionExpectedPID: pid_t?
    var hasDeferredSelectionSignal = false
    var activeMissionControlProxyActivationGeneration: Int?
    var missionControlProxyFocusRequestedGeneration: Int?
    let groupRaiseSettleDelay: TimeInterval = 0.05
    let groupRaiseVerificationDelay: TimeInterval = 0.06
    let maximumGroupRaiseAttempts = 2
    let maximumMissionControlProxyActivationSettleAttempts = 12
    let maximumPlainClickResolutionAttempts = 2
    private var selectionRaiseGeneration = 0
    var pendingSelectionRaiseWorkItem: DispatchWorkItem?
    private let selectionSettleInterval: TimeInterval = 0.06
    // Two identical Window Server observations are enough to reject the
    // transient selection seen during app switching. The final per-window
    // safety check still runs immediately before every AXRaise, so a third
    // observation only added visible latency without widening the trust set.
    private let requiredSelectionStableObservations = 2
    private let maximumSelectionSettleAttempts = 16
    var handlePresentationRevalidationGeneration = 0
    var stagedGroupDeparture: StagedGroupDeparture?
    var groupDegradationEvidenceByGroupID:
        [SnapGroupID: GroupDegradationEvidence] = [:]
    var groupDegradationObservationEpoch: UInt64 = 0
    var groupDegradationRetryGeneration = 0
    var scheduledGroupPresentationRetryGeneration: Int?
    var groupPresentationFailureCountsByGroupID: [SnapGroupID: Int] = [:]
    var groupForegroundModes: [SnapGroupID: GroupForegroundMode] = [:]
    var ownedForegroundMutation: OwnedForegroundMutation?
    var lastRecoverySceneSignature: [RecoveryWindowSceneItem]?
    var lastValidatedRecoveryInteractionRegions: [CGRect] = []
    private var shouldRestoreHandlesAfterPointerInteraction = false
    var isApplicationUIVisible = false
    private var pointerDownLocation: CGPoint?
    private var maximumPointerTravelSinceMouseDown: CGFloat = 0

    func establishLiveWindowAboveVirtualOverlay(
        _ window: ManagedWindow,
        while isCurrent: @escaping (SnapController) -> Bool
    ) {
        _ = windowService.raise(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, isCurrent(self) else { return }
            _ = self.windowService.raise(window)
        }
    }

    init() {
        activeWindowObserver.onFocusedWindowChange = { [weak self] pid in
            self?.handleResizeHandlePresentationSignal(
                .accessibilityFocusChanged
            )
            self?.scheduleSelectionDrivenGroupRaise(expectedPID: pid)
        }
        resizeHandleOverlay.onBegin = { [weak self] interaction, point in
            self?.beginHandleResize(interaction: interaction, at: point)
        }
        resizeHandleOverlay.onChange = { [weak self] interaction, point in
            self?.updateHandleResize(interaction: interaction, at: point)
        }
        resizeHandleOverlay.onEnd = { [weak self] interaction, point in
            self?.finishHandleResize(interaction: interaction, at: point)
        }
        resizeHandleOverlay.onCancel = { [weak self] _ in
            self?.cancelHandleResize(restoreOriginalFrames: true)
        }
        missionControlGroupProxyController.onSelectGroup = {
            [weak self] groupID, revision in
            self?.activateExplicitGroupFromMissionControlProxy(
                groupID: groupID,
                revision: revision
            )
        }
        missionControlGroupProxyController.currentTransitionAuthorization = {
            [weak self] groupID in
            self?.missionControlTransitionIsCurrentlyObserved(groupID: groupID)
                ?? false
        }
    }

    func start() {
        guard !isControllerRunning else { return }
        isControllerRunning = true
        _ = windowService.requestPermissionIfNeeded()
        if !installEventMonitors() {
            scheduleEventMonitorReadinessChecksIfNeeded()
        }
        installRecoveryObservers()
        startRecoveryTimer()
        updateSelectionMonitoringState()
        activeWindowObserver.observeFrontmostApplication()
        refreshResizeHandles()
    }

    func stop() {
        isControllerRunning = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        eventMonitorReadinessGeneration &+= 1
        eventMonitorReadinessChecksAreScheduled = false
        stopEscapeMonitoring()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        defaultObservers.forEach { NotificationCenter.default.removeObserver($0) }
        defaultObservers.removeAll()
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        stopFocusedWindowPolling()
        activeWindowObserver.stop()
        invalidatePendingSelectionRaise()
        invalidatePendingOperations()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
        liveResizeScheduler.cancelAll()
        resetDragState()
        activeSession = nil
    }

    func reset() {
        isEnabled = true
        snapshotTransactions.removeAll()
        lockedPlacements.removeAll()
        explicitGroupStore.clear()
        groupForegroundModes.removeAll()
        detachedConnections.removeAll()
        constraintHints.removeAll()
        inFlightPlacementIDs.removeAll()
        restoreFrames.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        resetSideDwellState()
        invalidatePendingOperations()
        resetDragState()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
        cancelHandleResize(restoreOriginalFrames: true)
    }

    func restoreLast() {
        guard handleResizeSession == nil, !isHandleResizeFinalizing else { return }
        let visibleIDs = Set(managedVisibleWindows().map(\.stableIdentity))
        var targetIndex: Int?
        var staleIndices: [Int] = []

        for index in snapshotTransactions.indices.reversed() {
            let transaction = snapshotTransactions[index]
            if transaction.snapshots.contains(where: { visibleIDs.contains($0.stableIdentity) }) {
                targetIndex = index
                break
            }
            if transaction.snapshots.allSatisfy({ snapshot in
                WindowStructuralPolicy.isConfirmedMissing(
                    windowService.windowLiveness(
                        element: snapshot.element,
                        pid: snapshot.pid
                    )
                )
            }) {
                staleIndices.append(index)
                for snapshot in transaction.snapshots {
                    if !dissolveExplicitGroupForUserDeparture(
                        containing: snapshot.stableIdentity
                    ) {
                        lockedPlacements.removeValue(forKey: snapshot.stableIdentity)
                        removeConnections(for: snapshot.stableIdentity)
                    }
                    restoreFrames.removeValue(forKey: snapshot.stableIdentity)
                    constraintHints.removeValue(forKey: snapshot.stableIdentity)
                }
            }
        }

        staleIndices.sorted(by: >).forEach { snapshotTransactions.remove(at: $0) }
        guard let targetIndex, snapshotTransactions.indices.contains(targetIndex) else { return }
        let transaction = snapshotTransactions[targetIndex]
        let restorable = transaction.snapshots.filter {
            visibleIDs.contains($0.stableIdentity)
                && windowService.isWindowAlive(element: $0.element, pid: $0.pid)
        }
        guard !restorable.isEmpty else { return }
        invalidatePendingOperations()
        let generation = interactionGeneration
        var pending = restorable.count
        var allSucceeded = true

        for snapshot in restorable {
            windowService.restore(snapshot) { [weak self] succeeded in
                guard let self else { return }
                allSucceeded = allSucceeded && succeeded
                pending -= 1
                guard pending == 0,
                      allSucceeded,
                      self.interactionGeneration == generation else { return }

                if let currentIndex = self.snapshotTransactions.lastIndex(where: { candidate in
                    candidate.snapshots.count == transaction.snapshots.count
                        && zip(candidate.snapshots, transaction.snapshots).allSatisfy { pair in
                            pair.0.stableIdentity == pair.1.stableIdentity
                                && pair.0.frame == pair.1.frame
                                && CFEqual(pair.0.element, pair.1.element)
                        }
                }) {
                    self.snapshotTransactions.remove(at: currentIndex)
                }
                for restored in restorable {
                    if !self.dissolveExplicitGroupForUserDeparture(
                        containing: restored.stableIdentity
                    ) {
                        self.lockedPlacements.removeValue(forKey: restored.stableIdentity)
                        self.removeConnections(for: restored.stableIdentity)
                    }
                    self.restoreFrames.removeValue(forKey: restored.stableIdentity)
                }
            }
        }
    }

    func clearLocks() {
        invalidatePendingOperations()
        resetDragState()
        lockedPlacements.removeAll()
        explicitGroupStore.clear()
        groupForegroundModes.removeAll()
        detachedConnections.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
    }

    func setApplicationUIVisible(_ isVisible: Bool) {
        isApplicationUIVisible = isVisible
        if isVisible {
            invalidatePendingGroupRaise()
            invalidatePendingSelectionRaise()
            missionControlGroupProxyController.hideAll()
            if handleResizeSession != nil {
                cancelHandleResize(restoreOriginalFrames: true)
            } else {
                resizeHandleOverlay.hideAll()
            }
        } else {
            refreshResizeHandles()
        }
    }

    func snapFocusedWindow(to zone: SnapZone) {
        guard handleResizeSession == nil, !isHandleResizeFinalizing else { return }
        guard isEnabled, ensurePermission(),
              let focusedWindow = windowService.focusedWindow() else { return }
        let window = windowService.resolvingWindowServerIdentity(focusedWindow)
        guard let selectedWindowID = window.cgWindowID,
              let selection = windowService.windowServerSelectionSnapshot(),
              selection.pid == window.pid,
              selection.windowID == selectedWindowID,
              windowService.canMoveAndResize(window),
              let screen = screen(containing: window.frame.center) ?? NSScreen.main else { return }
        let commandScene = windowService.windowOcclusionSnapshot()
        guard windowService.windowServerSelectionSnapshot() == selection else {
            return
        }
        let commandPlacementBaseline = SnapGroupPlacementEligibilityPolicy
            .frontmostGroupIDs(
                groups: explicitGroupStore.groups,
                draggedSurface: selection,
                bindings: persistedManagedWindowBindings.map(\.identity),
                windowServerSnapshot: commandScene
            )
        invalidatePendingOperations()
        activeSession = nil
        snap(
            window,
            to: zone,
            on: screen,
            continueAssist: true,
            frontmostGroupIDsBeforePlacement: commandPlacementBaseline
        )
    }

    @discardableResult
    private func installEventMonitors() -> Bool {
        let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp
        ]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: mouseMask
            ) { [weak self] event in
                // Preserve the pointer sample from the monitor callback. The
                // controller may be busy during cold launch, and rereading
                // NSEvent.mouseLocation after an async hop can bind the first
                // drag to a different physical surface.
                let observedMouseLocation = NSEvent.mouseLocation
                if Thread.isMainThread {
                    self?.handle(
                        event,
                        observedMouseLocation: observedMouseLocation
                    )
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.handle(
                            event,
                            observedMouseLocation: observedMouseLocation
                        )
                    }
                }
            }
        }

        let localMask: NSEvent.EventTypeMask = [mouseMask, .keyDown]
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: localMask
            ) { [weak self] event in
                if self?.resizeHandleOverlay.owns(window: event.window) == true
                    || self?.missionControlGroupProxyController.owns(
                        window: event.window
                    ) == true {
                    return event
                }
                self?.handle(
                    event,
                    observedMouseLocation: NSEvent.mouseLocation
                )
                return event
            }
        }
        return globalMonitor != nil && localMonitor != nil
    }

    private func scheduleEventMonitorReadinessChecksIfNeeded() {
        guard isControllerRunning,
              !eventMonitorReadinessChecksAreScheduled,
              globalMonitor == nil || localMonitor == nil else { return }
        eventMonitorReadinessChecksAreScheduled = true
        eventMonitorReadinessGeneration &+= 1
        let generation = eventMonitorReadinessGeneration
        let delays: [TimeInterval] = [0.05, 0.15, 0.35, 0.75]
        let lastIndex = delays.index(before: delays.endIndex)
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.isControllerRunning,
                      self.eventMonitorReadinessGeneration == generation else {
                    return
                }
                if self.installEventMonitors() {
                    self.eventMonitorReadinessGeneration &+= 1
                    self.eventMonitorReadinessChecksAreScheduled = false
                    return
                }
                if index == lastIndex {
                    // Fast startup retries are intentionally bounded. The
                    // existing 1 Hz Recovery watchdog remains the long-term
                    // rearm path for a transient registration failure.
                    self.eventMonitorReadinessChecksAreScheduled = false
                }
            }
        }
    }

    func startEscapeMonitoring() {
        guard globalEscapeMonitor == nil else { return }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.handleResizeSession != nil {
                    self.cancelHandleResize(restoreOriginalFrames: true)
                } else {
                    self.cancelAssist()
                }
            }
        }
    }

    func stopEscapeMonitoring() {
        guard let globalEscapeMonitor else { return }
        NSEvent.removeMonitor(globalEscapeMonitor)
        self.globalEscapeMonitor = nil
    }


    private func installRecoveryObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.handleActiveSpaceChange()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cancelAssist()
            self.missionControlGroupProxyController.hideAll()
            self.lastGroupWindowServerEvidenceByIdentity.removeAll()
            self.resetGroupPresentationTransitionRecovery()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isUserSessionActive = false
            self.cancelAssist()
            self.missionControlGroupProxyController.hideAll()
            self.lastGroupWindowServerEvidenceByIdentity.removeAll()
            self.resetGroupPresentationTransitionRecovery()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isUserSessionActive = true
            self.missionControlGroupProxyController.hideAll()
            self.lastGroupWindowServerEvidenceByIdentity.removeAll()
            self.resetGroupPresentationTransitionRecovery()
            self.refreshMissionControlGroupProxies()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            // A real application transition is the lifecycle boundary where
            // an old handle must disappear immediately. AX focused/main
            // notifications are intentionally excluded: many applications
            // emit them for ordinary tab and document changes.
            self?.handleResizeHandlePresentationSignal(.applicationDeactivated)
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            self.handleResizeHandlePresentationSignal(.applicationActivated)
            self.activeWindowObserver.observe(application)
            // Keep controls suspended until the settled selection has been
            // classified as a desktop group click or a system-level single
            // window activation. Showing controls from this early lifecycle
            // notification causes a one-frame flash on Command-Tab and
            // Mission Control exits.
            self.scheduleSelectionDrivenGroupRaise(
                expectedPID: application?.processIdentifier
            )
        })

        defaultObservers.append(defaultCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cancelAssist()
        })

        defaultObservers.append(defaultCenter.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.missionControlGroupProxyController.hideAll()
            self.updateSelectionMonitoringState()
            if !self.settings.linkedResizeEnabled,
               self.handleResizeSession != nil {
                self.cancelHandleResize(restoreOriginalFrames: true)
            } else if self.handleResizeSession == nil {
                self.refreshResizeHandles()
            }
        })
    }

    func updateSelectionMonitoringState() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateSelectionMonitoringState()
            }
            return
        }

        pruneForegroundStateForActiveGroups()

        let shouldRun = MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: isControllerRunning,
            taboraIsEnabled: isEnabled,
            linkedResizeIsEnabled: settings.linkedResizeEnabled,
            connectedWindowRaiseIsEnabled: settings.raiseConnectedWindowsOnClick,
            lockedPlacementCount: connectedLayoutPlacementCount
        )
        if shouldRun {
            startFocusedWindowPolling()
        } else {
            stopFocusedWindowPolling()
        }
    }

    private func startFocusedWindowPolling() {
        guard focusedWindowPollTimer == nil else { return }
        windowServerSelectionPollState.reset()
        pollFocusedWindowIdentity()
        let timer = Timer(timeInterval: focusedWindowPollInterval, repeats: true) {
            [weak self] _ in
            self?.pollFocusedWindowIdentity()
        }
        focusedWindowPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFocusedWindowPolling() {
        guard focusedWindowPollTimer != nil
                || windowServerSelectionPollState.hasBaseline
                || windowServerSelectionPollState.lastSnapshot != nil
                || pendingSelectionRaiseWorkItem != nil else { return }
        focusedWindowPollTimer?.invalidate()
        focusedWindowPollTimer = nil
        windowServerSelectionPollState.reset()
        invalidatePendingSelectionRaise()
    }

    private func pollFocusedWindowIdentity() {
        guard isEnabled,
              settings.linkedResizeEnabled,
              settings.raiseConnectedWindowsOnClick,
              connectedLayoutPlacementCount >= 2,
              !isApplicationUIVisible,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              dragWindow == nil,
              manualResizeWindow == nil,
              !isWindowMoveConfirmed,
              activeSession == nil,
              !isAssistPlacementPending else {
            windowServerSelectionPollState.reset()
            return
        }

        let currentSelection = windowService.windowServerSelectionSnapshot()
        guard let changedSelection = windowServerSelectionPollState.observe(
            currentSelection
        ) else { return }
        if ForegroundMutationSelectionPolicy.isOwnedSelection(
            changedSelection,
            mutation: ownedForegroundMutation
        ) {
            return
        }
        handleResizeHandlePresentationSignal(.windowServerSelectionChanged)
        activeWindowObserver.observeFrontmostApplication()
        // Rebuild safe handles now; foreground settlement may intentionally
        // take longer and must not own handle creation timing.
        refreshResizeHandles()
        scheduleSelectionDrivenGroupRaise(
            expectedPID: changedSelection.pid,
            initialSelection: changedSelection
        )
    }

    func scheduleSelectionDrivenGroupRaise(
        expectedPID: pid_t?,
        initialSelection: WindowServerSelectionSnapshot? = nil
    ) {
        guard selectionDrivenRaiseIsAllowed else { return }
        let observedSelection = initialSelection
            ?? windowService.windowServerSelectionSnapshot()
        if ForegroundMutationSelectionPolicy.isOwnedSelection(
            observedSelection,
            mutation: ownedForegroundMutation
        ) {
            return
        }
        if initialSelection == nil, ownedForegroundMutation != nil {
            // AX focus callbacks contain only a PID and can arrive before the
            // Window Server publishes the window ID changed by our AXRaise.
            // AX identity can reject a same-process external window; when AX
            // has not settled either, let the exact-ID poller arbitrate.
            switch ForegroundMutationSelectionPolicy
                .processNotificationDisposition(
                    expectedPID: expectedPID,
                    accessibilitySelection: windowService
                        .activeWindowIdentitySnapshot(),
                    mutation: ownedForegroundMutation
                ) {
            case .ownedMutation, .awaitExactWindowIdentity:
                return
            case .externalSelection:
                break
            }
        }
        if ownedForegroundMutation != nil {
            // A selection outside the exact member set is new user/system
            // intent. Abort our outstanding foreground mutation and process
            // that selection normally; suppression must never be PID-wide.
            invalidatePendingGroupRaise()
            endOwnedForegroundMutation()
        }
        // A desktop click has a stronger and more specific meaning than a
        // generic application/focus notification: clicking a visible member
        // asks for that member's complete group. Let mouse-up resolve the
        // authoritative surface instead of briefly entering solo mode here.
        if pointerDownLocation != nil
            || CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            ) {
            deferredSelectionExpectedPID = expectedPID
            hasDeferredSelectionSignal = true
            return
        }
        if activeMissionControlProxyActivationGeneration != nil
            || pendingGroupRaiseWorkItem != nil {
            deferredSelectionExpectedPID = expectedPID
            hasDeferredSelectionSignal = true
            return
        }
        // AX focus/main changes are newer and more authoritative than a
        // pointer fallback that may have been queued before a sheet appeared.
        invalidatePendingGroupRaise()
        selectionRaiseGeneration &+= 1
        pendingSelectionRaiseWorkItem?.cancel()
        pendingSelectionRaiseWorkItem = nil
        scheduleSelectionSettlement(
            expectedPID: expectedPID,
            candidate: initialSelection,
            stableObservationCount: initialSelection == nil ? 0 : 1,
            completedAttempts: 0,
            generation: selectionRaiseGeneration,
            delay: selectionSettleInterval
        )
    }

    var selectionDrivenRaiseIsAllowed: Bool {
        isEnabled
            && settings.linkedResizeEnabled
            && settings.raiseConnectedWindowsOnClick
            && connectedLayoutPlacementCount >= 2
            && !isApplicationUIVisible
            && !isSnapPlacementInProgress
            && handleResizeSession == nil
            && !isHandleResizeFinalizing
            && dragWindow == nil
            && manualResizeWindow == nil
            && !isWindowMoveConfirmed
            && activeSession == nil
            && !isAssistPlacementPending
            && !PointerInteractionPolicy.isDrag(
                maximumDistance: maximumPointerTravelSinceMouseDown
            )
    }

    private func scheduleSelectionSettlement(
        expectedPID: pid_t?,
        candidate: WindowServerSelectionSnapshot?,
        stableObservationCount: Int,
        completedAttempts: Int,
        generation: Int,
        delay: TimeInterval
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.selectionRaiseGeneration == generation else { return }
            self.pendingSelectionRaiseWorkItem = nil
            self.settleWindowServerSelection(
                expectedPID: expectedPID,
                candidate: candidate,
                stableObservationCount: stableObservationCount,
                completedAttempts: completedAttempts,
                generation: generation
            )
        }
        pendingSelectionRaiseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func settleWindowServerSelection(
        expectedPID: pid_t?,
        candidate: WindowServerSelectionSnapshot?,
        stableObservationCount: Int,
        completedAttempts: Int,
        generation: Int
    ) {
        guard selectionRaiseGeneration == generation,
              selectionDrivenRaiseIsAllowed else { return }

        let current = windowService.windowServerSelectionSnapshot()
        let matchesExpectedPID = expectedPID == nil || current?.pid == expectedPID
        let nextCandidate = matchesExpectedPID ? current : nil
        let nextStableCount: Int
        if let nextCandidate, nextCandidate == candidate {
            nextStableCount = stableObservationCount + 1
        } else if nextCandidate != nil {
            nextStableCount = 1
        } else {
            nextStableCount = 0
        }

        if let nextCandidate,
           nextStableCount >= requiredSelectionStableObservations {
            let visibleWindows = managedVisibleWindows()
            if let selectedWindow = visibleWindows.first(where: {
                $0.pid == nextCandidate.pid
                    && $0.cgWindowID == nextCandidate.windowID
            }) {
                raiseConnectedGroupForSettledSelection(
                    selectedWindow,
                    selectedWindowID: nextCandidate.windowID,
                    visibleWindows: visibleWindows,
                    generation: generation,
                    completedAttempts: 0
                )
                return
            }
        }

        guard completedAttempts < maximumSelectionSettleAttempts else {
            refreshResizeHandles()
            replayDeferredForegroundSignalIfNeeded()
            return
        }
        scheduleSelectionSettlement(
            expectedPID: expectedPID,
            candidate: nextCandidate,
            stableObservationCount: nextStableCount,
            completedAttempts: completedAttempts + 1,
            generation: generation,
            delay: selectionSettleInterval
        )
    }

    private func raiseConnectedGroupForSettledSelection(
        _ selectedWindow: ManagedWindow,
        selectedWindowID: CGWindowID,
        visibleWindows: [ManagedWindow],
        generation: Int,
        completedAttempts: Int
    ) {
        guard selectionRaiseGeneration == generation,
              selectionDrivenRaiseIsAllowed else {
            return
        }
        guard let currentSelection = windowService.windowServerSelectionSnapshot(),
              currentSelection.pid == selectedWindow.pid,
              currentSelection.windowID == selectedWindowID else {
            refreshResizeHandles(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }
        guard let groupWindows = connectedSnapGroupWindows(
            for: selectedWindow,
            visibleWindows: visibleWindows
        ) else {
            refreshResizeHandles(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }

        let frontmostEvaluation = connectedGroupFrontmostEvaluation(groupWindows)
        let systemSelectionDisposition = GroupForegroundSelectionPolicy
            .disposition(
                groupIsAlreadyFrontmost: frontmostEvaluation == .verifiedFrontmost
            )
        if systemSelectionDisposition == .preserveCurrentAuthorization {
            explicitGroupStore.setPreferredMember(
                selectedWindow.stableIdentity
            )
            refreshResizeHandles(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }
        // Mission Control, Command-Tab, Dock, App Expose and other system
        // activation paths select a window/application, not a Tabora group.
        // Never expand that ambiguous selection into AXRaise calls. Preserve
        // structural membership and suppress automatic foregrounding until a
        // an explicit group proxy selection or a later successful group
        // mutation rearms the group. Geometry alone never grants permission.
        setSoloForegroundMode(
            memberID: selectedWindow.stableIdentity
        )
        explicitGroupStore.setPreferredMember(
            selectedWindow.stableIdentity
        )
        refreshResizeHandles(using: visibleWindows)
        replayDeferredForegroundSignalIfNeeded()
        _ = completedAttempts
    }

    func invalidatePendingSelectionRaise() {
        selectionRaiseGeneration &+= 1
        pendingSelectionRaiseWorkItem?.cancel()
        pendingSelectionRaiseWorkItem = nil
    }

    private func startRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recoverIfNeeded()
        }
        if let recoveryTimer {
            RunLoop.main.add(recoveryTimer, forMode: .common)
        }
    }

    private func recoverIfNeeded() {
        updateSelectionMonitoringState()
        guard isEnabled else { return }
        // Recovery is deliberately low-frequency. Startup/re-enable paths own
        // the bounded fast registration burst; the watchdog performs only one
        // rearm attempt per tick after that burst is exhausted.
        _ = installEventMonitors()
        activeWindowObserver.observeFrontmostApplication()

        if handleResizeSession == nil,
           pendingDragWindow == nil,
           dragWindow == nil,
           manualResizeWindow == nil,
           pendingNativeResizeCandidates.isEmpty,
           !unresolvedNativeResizeWasActivated,
           !isWindowMoveConfirmed {
            let snapshot = windowService.windowOcclusionSnapshot()
            let signature = SplitLayoutGeometry.recoverySceneSignature(
                for: snapshot,
                managedWindowIDs: Set(lockedPlacements.values.compactMap(\.cgWindowID)),
                interactionRegions: lastValidatedRecoveryInteractionRegions
            )
            if signature != lastRecoverySceneSignature
                || !handleGeometryFailureCountsByGroupID.isEmpty
                || !handleOcclusionFailureCountsByDescriptorID.isEmpty
                || !groupPresentationFailureCountsByGroupID.isEmpty
                || missionControlGroupProxyController
                    .hasPresentationRecoveryDebt {
                lastRecoverySceneSignature = signature
                refreshResizeHandles(
                    deferOcclusionRefresh: true,
                    windowServerSnapshot: snapshot
                )
                refreshResizeHandleOcclusion(
                    force: true,
                    using: snapshot
                )
            }
        }

        if (dragWindow != nil
                || pendingDragWindow != nil
                || !pendingNativeResizeCandidates.isEmpty
                || unresolvedNativeResizeWasActivated),
           !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            let isManualResizeBeingFinished =
                finishUnresolvedNativeResizeIfNeeded()
                || finishManualResizeIfNeeded()
            if !isManualResizeBeingFinished {
                // The global mouse-up is forwarded to the main queue. Under
                // load, this recovery tick can observe the physical button-up
                // first. Treat that as a lost mouse-up and run the normal drop
                // transaction; clearing state here silently discarded a valid
                // edge target in every direction.
                handleDrop(at: NSEvent.mouseLocation)
            }
            overlay.hide()
        }

        if activeSession != nil, !picker.isVisible, !isAssistPlacementPending {
            cancelAssist()
            return
        }

        if activeSession != nil,
           Date().timeIntervalSince(lastInteractionAt) >= assistTimeout {
            cancelAssist()
        }
    }

    private func handle(
        _ event: NSEvent,
        observedMouseLocation: CGPoint? = nil
    ) {
        guard isEnabled else { return }
        lastInteractionAt = Date()

        if event.type == .leftMouseDragged,
           handleResizeSession == nil,
           pendingDragStartedNearResizeEdge,
           let pendingDragWindow,
           let resizingGroup = explicitGroupStore.group(
               containing: pendingDragWindow.stableIdentity
           ) {
            // Hide the shared control on the first native resize event, before
            // frame polling has observed a >0.5pt size delta. Otherwise the
            // overlay can remain above the native edge for one or more frames
            // and briefly recapture the user's recovery drag.
            resizeHandleOverlay.setPresentationSuspended(true)
            missionControlGroupProxyController.hide(
                groupID: resizingGroup.id
            )
        }

        if handleResizeSession == nil,
           manualResizeWindow == nil,
           event.type == .leftMouseDragged,
           !pendingDragStartedNearResizeEdge {
            refreshResizeHandleOcclusion()
        }

        if handleResizeSession != nil {
            if event.type == .keyDown, event.keyCode == 53 {
                cancelHandleResize(restoreOriginalFrames: true)
            }
            return
        }
        if isHandleResizeFinalizing {
            return
        }

        if event.type == .keyDown, event.keyCode == 53 {
            cancelAssist()
            return
        }
        guard ensurePermission() else { return }

        switch event.type {
        case .leftMouseDown:
            let point = observedMouseLocation ?? NSEvent.mouseLocation
            pointerDownLocation = point
            maximumPointerTravelSinceMouseDown = 0

            if picker.isVisible && picker.containsScreenPoint(point) {
                return
            }
            if isAssistPlacementPending {
                cancelAssist()
                return
            }
            dismissAssistPresentationForPointerDown()
            beginPendingDrag(at: point)

        case .leftMouseDragged:
            guard CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                cancelAssist()
                return
            }
            guard activeSession == nil else { return }

            let point = observedMouseLocation ?? NSEvent.mouseLocation
            if let pointerDownLocation {
                let previousWasDrag = PointerInteractionPolicy.isDrag(
                    maximumDistance: maximumPointerTravelSinceMouseDown
                )
                maximumPointerTravelSinceMouseDown = max(
                    maximumPointerTravelSinceMouseDown,
                    hypot(
                        point.x - pointerDownLocation.x,
                        point.y - pointerDownLocation.y
                    )
                )
                if !previousWasDrag,
                   PointerInteractionPolicy.isDrag(
                       maximumDistance: maximumPointerTravelSinceMouseDown
                   ) {
                    invalidatePendingGroupRaise()
                    invalidatePendingSelectionRaise()
                }
            }
            if trackUnresolvedNativeResizeIfNeeded() {
                return
            }
            if pendingDragWindow == nil, deferredPointerDragResolution != nil {
                guard resolveDeferredPointerDragIfNeeded() else { return }
            }
            let adoptedDetachedWindow = adoptDetachedWindowIfNeeded(at: point, allowImmediate: false)
            if !adoptedDetachedWindow {
                // A real size delta is stronger evidence than the pointer's
                // approximate edge/title-bar classification. Check every
                // snapped interaction so top-corner resizes cannot slip into
                // the move path and leave a stale explicit group behind.
                if trackManualResizeIfNeeded() {
                    return
                }
                if !isWindowMoveConfirmed {
                    guard confirmWindowMove(at: point) else { return }
                } else if !hasWindowActuallyMoved {
                    detectActualWindowMovementIfNeeded(at: point)
                }
            }
            handleDrag(at: point)

        case .leftMouseUp:
            defer {
                pointerDownLocation = nil
                maximumPointerTravelSinceMouseDown = 0
            }
            if isAssistPlacementPending {
                return
            }
            let mousePoint = observedMouseLocation ?? NSEvent.mouseLocation
            let wasPlainClick = activeSession == nil
                && manualResizeWindow == nil
                && !isWindowMoveConfirmed
                && !hasWindowActuallyMoved
                && !didStartDragRestore
                && !PointerInteractionPolicy.isDrag(
                    maximumDistance: maximumPointerTravelSinceMouseDown
                )
            if finishUnresolvedNativeResizeIfNeeded()
                || finishManualResizeIfNeeded() {
                shouldRestoreHandlesAfterPointerInteraction = false
                overlay.hide()
                return
            }
            if wasPlainClick {
                scheduleConnectedGroupRaiseForPlainClick(at: mousePoint)
            }
            if activeSession == nil {
                handleDrop(at: mousePoint)
            } else if !picker.isVisible {
                cancelAssist()
            }
            if !wasPlainClick {
                refreshResizeHandleOcclusion(force: true)
            } else if shouldRestoreHandlesAfterPointerInteraction {
                refreshResizeHandles()
            }
            shouldRestoreHandlesAfterPointerInteraction = false

        default:
            break
        }
    }

    private func beginPendingDrag(at point: CGPoint) {
        // Mouse-down is a Window Server observation first. AX activation can
        // settle later, but any retry must resolve this exact physical surface.
        prepareUnresolvedNativeResizeCandidates(at: point)
        let snapshot = windowService.windowOcclusionSnapshot()
        let bindings = persistedManagedWindowBindings
        guard let evidence = windowService.pointerDragSurfaceEvidence(
            at: point,
            snapshot: snapshot
        ) else {
            pendingDragWindow = nil
            pendingDragWindowFrame = nil
            pendingDragMousePoint = nil
            deferredPointerDragResolution = nil
            windowServerIDsAtDragStart.removeAll()
            detachedWindowServerCensusAtDragStart = .unknown
            return
        }

        windowServerIDsAtDragStart = Set(snapshot.compactMap { surface in
            surface.pid == evidence.selection.pid && surface.layer == 0
                ? surface.windowID
                : nil
        })
        detachedWindowServerCensusAtDragStart =
            windowService.windowServerWindowIDCensus(
                forPID: evidence.selection.pid
            )
        frontmostGroupIDsAtPointerDown =
            SnapGroupPlacementEligibilityPolicy.frontmostGroupIDs(
                groups: explicitGroupStore.groups,
                draggedSurface: evidence.selection,
                bindings: bindings.map(\.identity),
                windowServerSnapshot: snapshot
            )

        if let window = windowService.resolvePointerDragSurface(
            evidence,
            persistedBindings: bindings
        ) {
            configurePendingDrag(window: window, mouseDownPoint: point)
            return
        }

        deferredPointerDragResolution = DeferredPointerDragResolution(
            evidence: evidence,
            attempts: 0
        )
        pendingDragWindow = nil
        pendingDragWindowFrame = nil
        pendingDragMousePoint = nil
    }

    private func resolveDeferredPointerDragIfNeeded() -> Bool {
        guard var deferred = deferredPointerDragResolution else { return true }
        deferred.attempts += 1
        deferredPointerDragResolution = deferred
        if let window = windowService.resolvePointerDragSurface(
            deferred.evidence,
            persistedBindings: persistedManagedWindowBindings
        ) {
            deferredPointerDragResolution = nil
            configurePendingDrag(
                window: window,
                mouseDownPoint: deferred.evidence.mouseDownPoint
            )
            return true
        }
        // Event-driven bounded retry: failure never substitutes stale focus or
        // performs unbounded broad discovery on every drag event.
        if deferred.attempts >= 12 {
            deferredPointerDragResolution = nil
        }
        return false
    }

    private func configurePendingDrag(
        window: ManagedWindow,
        mouseDownPoint point: CGPoint
    ) {
        sourceDragWindow = window
        pendingDragWindow = window
        // Native resize/move detection is AX-vs-AX only. Never put the CG
        // evidence frame into this baseline.
        pendingDragWindowFrame = window.frame
        pendingDragMousePoint = point
        pendingDragStartedInLikelyDragRegion = isLikelyWindowDragRegion(
            point,
            window: window
        )
        pendingDragStartedNearResizeEdge = isNearWindowResizeEdge(
            point,
            frame: window.frame
        )
        pendingGrabRatio = grabRatio(at: point, in: window.frame)
        let storedRestoreFrame = restoreFrames[window.stableIdentity]
        pendingRestoreFrame = storedRestoreFrame
        dragRestoreFrameCandidate = storedRestoreFrame ?? window.frame
        isWindowMoveConfirmed = false
        hasWindowActuallyMoved = false
        didStartDragRestore = false
        detachedCandidateID = nil
        detachedCandidateHitCount = 0
        manualResizeWindow = nil
        pendingNativeResizeDeparture = explicitGroupDepartureSnapshot(
            containing: window.stableIdentity
        )
        lastManualResizeRefreshAt = 0
        virtualResizeOverlay.hideAll()
    }

    private func dismissAssistPresentationForPointerDown() {
        shouldRestoreHandlesAfterPointerInteraction = activeSession != nil
            || picker.isVisible
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resetDragState()
        activeSession = nil
    }

    private var persistedManagedWindowBindings: [ManagedWindowBinding] {
        lockedPlacements.values.compactMap { placement in
            guard let windowID = placement.cgWindowID else { return nil }
            return ManagedWindowBinding(
                element: placement.element,
                identity: PersistedWindowBinding(
                    stableIdentity: placement.stableIdentity,
                    pid: placement.pid,
                    windowID: windowID
                )
            )
        }
    }

    func managedVisibleWindows(
        excludingStableIDs excludedStableIDs: Set<String> = []
    ) -> [ManagedWindow] {
        windowService.visibleWindows(
            excludingStableIDs: excludedStableIDs,
            persistedBindings: persistedManagedWindowBindings
        )
    }

    private func windowServerFrontmostEvaluation(
        memberIDs: Set<String>
    ) -> GroupFrontmostEvaluation {
        guard !memberIDs.isEmpty else { return .indeterminate }
        let bindings = persistedManagedWindowBindings.map(\.identity)
        let selections = Set(bindings.compactMap { binding
            -> WindowServerSelectionSnapshot? in
            guard memberIDs.contains(binding.stableIdentity) else { return nil }
            return WindowServerSelectionSnapshot(
                pid: binding.pid,
                windowID: binding.windowID
            )
        })
        guard selections.count == memberIDs.count else { return .indeterminate }
        return GroupFrontmostEvaluationPolicy.evaluate(
            memberSelections: selections,
            snapshot: windowService.windowOcclusionSnapshot()
        )
    }

    private func adoptDetachedWindowIfNeeded(at point: CGPoint, allowImmediate: Bool) -> Bool {
        guard let source = sourceDragWindow,
              let candidate = detachedWindowCandidate(
                  following: point,
                  source: source
              ) else {
            detachedCandidateID = nil
            detachedCandidateHitCount = 0
            return false
        }

        if detachedCandidateID == candidate.stableIdentity {
            detachedCandidateHitCount += 1
        } else {
            detachedCandidateID = candidate.stableIdentity
            detachedCandidateHitCount = 1
        }
        guard allowImmediate || detachedCandidateHitCount >= 2 else { return false }

        invalidatePendingGroupRaise()
        invalidatePendingSelectionRaise()
        dragRestoreFrameCandidate = restoreFrames[source.stableIdentity] ?? source.frame
        pendingDragWindow = candidate
        pendingDragWindowFrame = candidate.frame
        pendingDragMousePoint = point
        pendingGrabRatio = grabRatio(at: point, in: candidate.frame)
        pendingRestoreFrame = nil
        pendingDragStartedInLikelyDragRegion = true
        pendingDragStartedNearResizeEdge = false
        dragWindow = candidate
        isWindowMoveConfirmed = true
        hasWindowActuallyMoved = true
        virtualResizeOverlay.hideAll()
        if stageExplicitGroupDepartureForDrag(
            containing: source.stableIdentity
        ), let staged = stagedGroupDeparture {
            // A detached tab receives a new stable window identity. Treat it
            // as the moving replacement for the old member so a subsequent
            // snap can retain the untouched peers.
            stagedGroupDeparture = StagedGroupDeparture(
                draggedIdentity: candidate.stableIdentity,
                memberIDs: staged.memberIDs
            )
        }
        // From this point the detached surface owns the original physical
        // mouse gesture. Do not keep consulting the old tab container as the
        // source on later drag events.
        sourceDragWindow = candidate
        return true
    }

    private func detachedWindowCandidate(
        following point: CGPoint,
        source: ManagedWindow
    ) -> ManagedWindow? {
        // A detached Chrome tab is often the frontmost Window Server surface
        // under the pointer before AX promotes it to kAXFocusedWindow. Looking
        // only at focusedWindow creates a deadlock: ordinary drag confirmation
        // rejects the newly-created identity while adoption waits for focus.
        // Prefer the exact pointer surface, retaining focusedWindow solely as
        // a compatibility fallback for applications with delayed CG matching.
        let candidates = [
            windowService.pointerHitTestWindow(
                at: point,
                persistedBindings: persistedManagedWindowBindings
            ),
            windowService.focusedWindow()
        ]
        var seen = Set<String>()
        return candidates.compactMap { $0 }.first { rawCandidate in
            let candidate = windowService.resolvingWindowServerIdentity(
                rawCandidate
            )
            guard seen.insert(candidate.stableIdentity).inserted else {
                return false
            }
            return DetachedWindowAdoptionPolicy.canAdopt(
                candidatePID: candidate.pid,
                sourcePID: source.pid,
                candidateIdentity: candidate.stableIdentity,
                sourceIdentity: source.stableIdentity,
                currentDragIdentity: dragWindow?.stableIdentity,
                candidateWindowID: candidate.cgWindowID,
                windowServerIDsAtDragStart:
                    detachedWindowServerCensusAtDragStart.windowIDs,
                dragStartCensusCompleteness:
                    detachedWindowServerCensusAtDragStart.completeness,
                canMoveAndResize: windowService.canMoveAndResize(candidate),
                followsPointer: isLikelyDetachedWindow(
                    candidate,
                    following: point
                )
            )
        }
    }

    private func confirmWindowMove(at currentMousePoint: CGPoint, allowEdgeFallback: Bool = false) -> Bool {
        guard let originalWindow = pendingDragWindow,
              let originalFrame = pendingDragWindowFrame,
              let originalMousePoint = pendingDragMousePoint,
              let currentWindow = windowService.refreshed(originalWindow) else {
            return false
        }

        let windowDelta = CGPoint(
            x: currentWindow.frame.minX - originalFrame.minX,
            y: currentWindow.frame.minY - originalFrame.minY
        )
        let mouseDelta = CGPoint(
            x: currentMousePoint.x - originalMousePoint.x,
            y: currentMousePoint.y - originalMousePoint.y
        )

        let mouseDistance = hypot(mouseDelta.x, mouseDelta.y)
        let windowDistance = hypot(windowDelta.x, windowDelta.y)

        let sizeTolerance: CGFloat = 1.5
        let sizeChanged = abs(currentWindow.frame.width - originalFrame.width) > sizeTolerance
            || abs(currentWindow.frame.height - originalFrame.height) > sizeTolerance
        guard !sizeChanged else { return false }

        if windowDistance >= 2, mouseDistance >= 2 {
            let dot = windowDelta.x * mouseDelta.x + windowDelta.y * mouseDelta.y
            let directionMatches = dot > 0
            let followTolerance = max(18, min(72, mouseDistance * 0.55))
            let closelyFollows = abs(windowDelta.x - mouseDelta.x) <= followTolerance
                && abs(windowDelta.y - mouseDelta.y) <= followTolerance

            if closelyFollows || directionMatches {
                promoteToConfirmedDrag(currentWindow, at: currentMousePoint, windowActuallyMoved: true)
                return true
            }
        }

        if allowEdgeFallback || isNearSnapEdge(currentMousePoint),
           pendingDragStartedInLikelyDragRegion,
           mouseDistance >= 4 {
            let currentSurface = windowService.resolvingWindowServerIdentity(
                currentWindow
            )
            guard let currentWindowID = currentSurface.cgWindowID,
                  windowServerIDsAtDragStart.contains(currentWindowID) else {
                return false
            }
            promoteToConfirmedDrag(currentWindow, at: currentMousePoint, windowActuallyMoved: false)
            return true
        }

        return false
    }

    private func promoteToConfirmedDrag(
        _ window: ManagedWindow,
        at mousePoint: CGPoint,
        windowActuallyMoved: Bool
    ) {
        invalidatePendingGroupRaise()
        invalidatePendingSelectionRaise()
        virtualResizeOverlay.hideAll()
        dragWindow = window
        isWindowMoveConfirmed = true
        guard windowActuallyMoved else { return }
        beginActualWindowMovement(window, at: mousePoint)
    }

    private func detectActualWindowMovementIfNeeded(at mousePoint: CGPoint) {
        guard !hasWindowActuallyMoved,
              let originalFrame = pendingDragWindowFrame,
              let window = dragWindow,
              let current = windowService.refreshed(window) else { return }

        let moved = hypot(
            current.frame.minX - originalFrame.minX,
            current.frame.minY - originalFrame.minY
        ) >= 2
        let sizeChanged = abs(current.frame.width - originalFrame.width) > 1.5
            || abs(current.frame.height - originalFrame.height) > 1.5
        guard moved, !sizeChanged else { return }
        dragWindow = current
        beginActualWindowMovement(current, at: mousePoint)
    }

    private func beginActualWindowMovement(_ window: ManagedWindow, at mousePoint: CGPoint) {
        guard !hasWindowActuallyMoved else { return }
        hasWindowActuallyMoved = true
        if !stageExplicitGroupDepartureForDrag(
            containing: window.stableIdentity
        ) {
            lockedPlacements.removeValue(forKey: window.stableIdentity)
            removeConnections(for: window.stableIdentity)
        }

        guard let restoreFrame = pendingRestoreFrame,
              let ratio = pendingGrabRatio else { return }

        let alreadyUsesRestoreSize = abs(window.frame.width - restoreFrame.width) <= 1.5
            && abs(window.frame.height - restoreFrame.height) <= 1.5
        guard settings.restoreSnappedWindowSizeOnMove, !alreadyUsesRestoreSize else {
            restoreFrames.removeValue(forKey: window.stableIdentity)
            pendingRestoreFrame = nil
            dragRestoreFrameCandidate = window.frame
            return
        }

        startSmoothDragRestore(
            window: window,
            targetFrame: restoreFrame,
            grabRatio: ratio,
            mousePoint: mousePoint
        )
    }

    private func startSmoothDragRestore(
        window: ManagedWindow,
        targetFrame: CGRect,
        grabRatio: CGPoint,
        mousePoint: CGPoint
    ) {
        cancelSmoothDragRestore()
        windowService.cancelFrameOperation(for: window.element)
        didStartDragRestore = true
        let startSize = window.frame.size
        let targetSize = targetFrame.size
        let duration: TimeInterval = 0.16
        let startedAt = ProcessInfo.processInfo.systemUptime

        _ = windowService.setFrame(
            anchoredFrame(size: startSize, at: mousePoint, ratio: grabRatio),
            for: window.element
        )

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let progress = min(max(elapsed / duration, 0), 1)
            let eased = CGFloat(1 - pow(1 - progress, 3))
            let size = CGSize(
                width: startSize.width + (targetSize.width - startSize.width) * eased,
                height: startSize.height + (targetSize.height - startSize.height) * eased
            )
            let cursor = NSEvent.mouseLocation
            let frame = self.anchoredFrame(size: size, at: cursor, ratio: grabRatio)
            let frameApplied = self.windowService.setFrame(frame, for: window.element)

            if let refreshed = self.windowService.refreshed(window) {
                self.dragWindow = refreshed
            }

            guard progress >= 1 else { return }
            timer.invalidate()
            self.dragRestoreAnimationTimer = nil
            if frameApplied {
                self.restoreFrames.removeValue(forKey: window.stableIdentity)
            }
        }
        dragRestoreAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishSmoothDragRestore(at mousePoint: CGPoint) {
        guard let window = dragWindow,
              let restoreFrame = dragRestoreFrameCandidate,
              let ratio = pendingGrabRatio,
              didStartDragRestore else {
            cancelSmoothDragRestore()
            return
        }

        cancelSmoothDragRestore()
        let finalFrame = anchoredFrame(size: restoreFrame.size, at: mousePoint, ratio: ratio)
        if windowService.setFrame(finalFrame, for: window.element) {
            restoreFrames.removeValue(forKey: window.stableIdentity)
        }
        dragWindow = windowService.refreshed(window) ?? window
    }

    private func cancelSmoothDragRestore() {
        dragRestoreAnimationTimer?.invalidate()
        dragRestoreAnimationTimer = nil
    }

    private func anchoredFrame(size: CGSize, at mousePoint: CGPoint, ratio: CGPoint) -> CGRect {
        var frame = CGRect(
            x: mousePoint.x - size.width * ratio.x,
            y: mousePoint.y - size.height * ratio.y,
            width: size.width,
            height: size.height
        )
        guard let visibleFrame = screenOwning(mousePoint)?.visibleFrame else { return frame }

        let minimumVisibleWidth = min(max(frame.width * 0.15, 96), 160)
        if frame.maxX < visibleFrame.minX + minimumVisibleWidth {
            frame.origin.x += visibleFrame.minX + minimumVisibleWidth - frame.maxX
        } else if frame.minX > visibleFrame.maxX - minimumVisibleWidth {
            frame.origin.x -= frame.minX - (visibleFrame.maxX - minimumVisibleWidth)
        }

        let titleBarTop = min(max(frame.maxY, visibleFrame.minY + 36), visibleFrame.maxY)
        frame.origin.y += titleBarTop - frame.maxY
        return frame
    }

    private func grabRatio(at point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 1) }
        return CGPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1)
        )
    }

    private func isLikelyDetachedWindow(_ window: ManagedWindow, following point: CGPoint) -> Bool {
        let horizontalMargin: CGFloat = 28
        let topBandHeight = min(120, max(48, window.frame.height * 0.18))
        let titleBand = CGRect(
            x: window.frame.minX - horizontalMargin,
            y: window.frame.maxY - topBandHeight - 20,
            width: window.frame.width + horizontalMargin * 2,
            height: topBandHeight + 40
        )
        return titleBand.contains(point)
    }

    private func handleDrag(at point: CGPoint) {
        picker.hide()
        guard dragWindow != nil, isWindowMoveConfirmed else { return }

        guard let target = snapTarget(at: point, shouldUpdateDisplayTransition: true),
              let screen = screen(withDisplayID: target.displayID) else {
            resetSideDwellState()
            if activeTarget != nil {
                activeTarget = nil
                overlay.hide()
            }
            return
        }

        updateSideDwell(for: target, at: point, on: screen)

        guard activeTarget != target else { return }
        activeTarget = target
        if let context = expandedSideContext,
           context.displayID == target.displayID {
            let zones = ExpandedSideSelectionPolicy.candidateZones(
                isLeftEdge: context.edge == .left
            )
            let frames = zones.map { zone in
                predictedSnapFrame(
                    for: zone,
                    on: screen,
                    window: dragWindow
                )
            }
            overlay.showSideCandidates(
                frames: frames,
                activeIndex: zones.firstIndex(of: target.zone) ?? 0,
                from: point
            )
        } else {
            overlay.show(
                frame: predictedSnapFrame(
                    for: target.zone,
                    on: screen,
                    window: dragWindow
                ),
                from: point
            )
        }
    }

    private func handleDrop(at point: CGPoint) {
        defer {
            overlay.hide()
            resetDragState()
        }

        let adoptedDetachedWindow = adoptDetachedWindowIfNeeded(at: point, allowImmediate: true)
        if dragWindow == nil, !adoptedDetachedWindow {
            _ = confirmWindowMove(at: point, allowEdgeFallback: true)
        }
        guard let window = dragWindow else { return }

        let target = snapTargetForDrop(at: point)

        guard let target,
              let screen = screen(withDisplayID: target.displayID) else {
            finishSmoothDragRestore(at: point)
            finalizeStagedGroupDepartureIfNeeded()
            return
        }

        cancelSmoothDragRestore()
        let currentWindow = windowService.refreshed(window) ?? window
        activeSession = nil
        snap(
            currentWindow,
            to: target.zone,
            on: screen,
            continueAssist: true
        ) { [weak self] succeeded in
            guard let self else { return }
            if !succeeded {
                self.finalizeStagedGroupDepartureIfNeeded()
            }
        }
    }

    private func snap(
        _ window: ManagedWindow,
        to zone: SnapZone,
        on screen: NSScreen,
        continueAssist: Bool,
        activateAfterInitialPlacement: Bool = false,
        frontmostGroupIDsBeforePlacement: Set<SnapGroupID>? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let operationGeneration = interactionGeneration
        guard let placementContext = snapPlacementContext(
            for: window,
            zone: zone,
            on: screen,
            frontmostGroupIDsBeforePlacement:
                frontmostGroupIDsBeforePlacement
        ) else {
            completion?(false)
            return
        }
        if let stagedGroupDeparture,
           stagedGroupDeparture.draggedIdentity == window.stableIdentity,
           !stagedGroupDeparture.memberIDs.isSubset(
                of: placementContext.memberIDs
           ) {
            // This drop is creating an independent group rather than
            // reconstructing the staged original. Retire every old lock now;
            // otherwise former peers can survive as hidden provisional state.
            finalizeStagedGroupDepartureIfNeeded()
        }
        activeSnapPlacementContext = placementContext
        isSnapPlacementInProgress = true
        snapPlacementInteractionGeneration = operationGeneration
        resizeHandleOverlay.setPresentationSuspended(true)
        missionControlGroupProxyController.hideAll()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
        let pendingSnapshot = windowService.snapshot(window)
        let wasKnownSnappedWindow = restoreFrames[window.stableIdentity] != nil
        let pendingRestoreCandidate: CGRect
        if let dragRestoreFrameCandidate,
           dragWindow?.stableIdentity == window.stableIdentity {
            pendingRestoreCandidate = dragRestoreFrameCandidate
        } else if wasKnownSnappedWindow,
                  let stored = restoreFrames[window.stableIdentity] {
            pendingRestoreCandidate = stored
        } else {
            pendingRestoreCandidate = pendingSnapshot.frame
        }
        pendingPlacementSnapshots[window.stableIdentity] = pendingSnapshot
        let targetFrame = resolvedSnapFrame(
            for: zone,
            on: screen,
            excluding: window.stableIdentity,
            memberScope: placementContext.memberIDs
        )

        let applySnap = { [weak self] in
            guard let self,
                  self.interactionGeneration == operationGeneration else { return }
            let afterInitialFrameAttempt: (() -> Void)?
            if activateAfterInitialPlacement {
                afterInitialFrameAttempt = { [weak self] in
                    guard let self,
                          self.interactionGeneration == operationGeneration else { return }
                    self.windowService.focus(window)
                }
            } else {
                afterInitialFrameAttempt = nil
            }

            self.windowService.setFrameAnchoredReliably(
                targetFrame,
                sizeConstraintAnchor: zone.sizeConstraintAnchor,
                requiredOuterEdges: zone.requiredOuterEdges,
                skipInitialWriteWhenVerified: true,
                for: window.element,
                afterInitialFrameAttempt: afterInitialFrameAttempt
            ) { [weak self] succeeded in
                guard let self,
                      self.interactionGeneration == operationGeneration else { return }

                let appliedWindow = self.windowService.refreshed(window)
                let requiredEdgesAreCorrect = appliedWindow.map {
                    self.matchesRequiredOuterEdges(
                        $0.frame,
                        targetFrame: targetFrame,
                        requiredEdges: zone.requiredOuterEdges
                    )
                } ?? false
                guard succeeded && requiredEdgesAreCorrect else {
                    self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                    self.rollbackFailedPlacement(
                        pendingSnapshot,
                        operationGeneration: operationGeneration
                    ) {
                        completion?(false)
                    }
                    return
                }
                let refreshedWindow = appliedWindow ?? window
                self.observeConstraint(for: refreshedWindow, requestedSize: targetFrame.size)
                switch self.initialSplitDisposition(
                    for: refreshedWindow,
                    requestedFrame: targetFrame,
                    zone: zone,
                    on: screen
                ) {
                case .accept:
                    self.finalizeSuccessfulSnap(
                        refreshedWindow,
                        zone: zone,
                        on: screen,
                        snapshots: [pendingSnapshot],
                        restoreFrame: pendingRestoreCandidate,
                        continueAssist: continueAssist,
                        operationGeneration: operationGeneration,
                        completion: completion
                    )

                case .reflow(let plan):
                    self.performInitialReflow(
                        plan,
                        candidate: refreshedWindow,
                        candidateSnapshot: pendingSnapshot,
                        restoreFrame: pendingRestoreCandidate,
                        zone: zone,
                        on: screen,
                        continueAssist: continueAssist,
                        operationGeneration: operationGeneration,
                        completion: completion
                    )

                case .reject:
                    self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                    self.rollbackFailedPlacement(
                        pendingSnapshot,
                        operationGeneration: operationGeneration
                    ) {
                        completion?(false)
                    }
                }
            }
        }

        if window.isFullscreen {
            guard windowService.setFullscreen(false, for: window.element) else {
                pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                overlay.hide()
                finishSnapPlacementPresentation(
                    operationGeneration: operationGeneration
                )
                completion?(false)
                return
            }
            windowService.waitForFullscreenState(false, for: window.element) { [weak self] succeeded in
                guard let self,
                      self.interactionGeneration == operationGeneration else { return }
                if succeeded {
                    applySnap()
                } else {
                    self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                    _ = self.windowService.setFullscreen(true, for: window.element)
                    self.overlay.hide()
                    self.finishSnapPlacementPresentation(
                        operationGeneration: operationGeneration
                    )
                    completion?(false)
                }
            }
        } else {
            applySnap()
        }
    }

    private func snapPlacementContext(
        for window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen,
        frontmostGroupIDsBeforePlacement: Set<SnapGroupID>? = nil
    ) -> SnapPlacementContext? {
        guard let currentDisplayID = displayID(for: screen) else {
            return nil
        }
        let initiallyLockedIDs = Set(lockedPlacements.keys)

        if let session = activeSession {
            let groupMembers = session.groupID.flatMap {
                explicitGroupStore.group(id: $0)?.memberIDs
            } ?? []
            return SnapPlacementContext(
                targetGroupID: session.groupID,
                departingGroupID: nil,
                memberIDs: groupMembers
                    .union(session.occupiedStableIDs)
                    .union([window.stableIdentity]),
                excludedAssistCandidateIDs:
                    session.excludedCandidateIDs,
                displayID: currentDisplayID
            )
        }

        if let existing = explicitGroupStore.group(
            containing: window.stableIdentity
        ) {
            return SnapPlacementContext(
                targetGroupID: existing.id,
                departingGroupID: nil,
                memberIDs: existing.memberIDs.union([window.stableIdentity]),
                excludedAssistCandidateIDs: initiallyLockedIDs,
                displayID: currentDisplayID
            )
        }

        let visibleWindows = managedVisibleWindows()
        let comparisonWindows = visibleWindows.filter {
            $0.stableIdentity != window.stableIdentity
        }
        let orderedIDs = comparisonWindows.map(\.stableIdentity)
        let incomingGeometry = SplitPlacementGeometry(
            stableIdentity: window.stableIdentity,
            zone: zone,
            frame: zone.frame(in: screen)
        )

        if let stagedGroupDeparture,
           stagedGroupDeparture.draggedIdentity == window.stableIdentity {
            let peerIDs = stagedGroupDeparture.memberIDs.subtracting([
                window.stableIdentity
            ])
            let visiblePeerIDs = Set(comparisonWindows.compactMap { item in
                peerIDs.contains(item.stableIdentity)
                    ? item.stableIdentity
                    : nil
            })
            if visiblePeerIDs == peerIDs,
               windowServerFrontmostEvaluation(memberIDs: peerIDs)
                    == .verifiedFrontmost {
                return SnapPlacementContext(
                    targetGroupID: nil,
                    departingGroupID: nil,
                    memberIDs: stagedGroupDeparture.memberIDs,
                    excludedAssistCandidateIDs: initiallyLockedIDs,
                    displayID: currentDisplayID
                )
            }
        }
        let currentDraggedSurface = window.cgWindowID.map {
            WindowServerSelectionSnapshot(pid: window.pid, windowID: $0)
        }
        let currentWindowServerFrontmostGroupIDs =
            SnapGroupPlacementEligibilityPolicy
            .frontmostGroupIDs(
                groups: explicitGroupStore.groups,
                draggedSurface: currentDraggedSurface,
                bindings: persistedManagedWindowBindings.map(\.identity),
                windowServerSnapshot: windowService.windowOcclusionSnapshot()
            )
        let eligibleGroups = explicitGroupStore.groups.compactMap { group
            -> (SnapGroup, Int, Int)? in
            guard group.displayID == currentDisplayID else { return nil }
            let groupWindows = comparisonWindows.filter {
                group.memberIDs.contains($0.stableIdentity)
            }
            let geometryIsComplete: Bool
            if group.memberIDs.count >= 2,
               groupWindows.count == group.memberIDs.count,
               let main = groupWindows.first,
               let validatedMembers = connectedSnapGroupWindows(
                for: main,
                visibleWindows: comparisonWindows
               ) {
                geometryIsComplete = Set(
                    validatedMembers.map(\.stableIdentity)
                ) == group.memberIDs
            } else {
                geometryIsComplete = false
            }
            let isFrontmostNow = geometryIsComplete
                && currentWindowServerFrontmostGroupIDs.contains(group.id)
            let wasFrontmostBeforeManipulation: Bool
            if let placementBaseline = frontmostGroupIDsBeforePlacement
                ?? frontmostGroupIDsAtPointerDown {
                wasFrontmostBeforeManipulation =
                    placementBaseline.contains(group.id)
            } else {
                wasFrontmostBeforeManipulation =
                    currentWindowServerFrontmostGroupIDs.contains(group.id)
            }
            let groupPlacements = groupWindows.compactMap { member
                -> SplitPlacementGeometry? in
                guard let placement = lockedPlacements[
                    member.stableIdentity
                ] else { return nil }
                return SplitPlacementGeometry(
                    stableIdentity: member.stableIdentity,
                    zone: placement.zone,
                    frame: member.frame
                )
            }
            let hasLogicalConflict = group.layout.zonesByMemberID.values
                .contains {
                    SnapPlacementLayerPolicy.conflicts(
                        existing: $0,
                        incoming: zone
                    )
                }
            let incomingConnections = SplitLayoutGeometry
                .resizeHandleGeometries(
                    placements: groupPlacements + [incomingGeometry],
                    detachedConnections: detachedConnections
                )
            let canExtend = !SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: window.stableIdentity,
                handles: incomingConnections
            ).intersection(group.memberIDs).isEmpty
            let relationshipRank = SnapGroupPlacementEligibilityPolicy
                .relationshipRank(
                    hasLogicalConflict: hasLogicalConflict,
                    canExtend: canExtend
                )
            guard SnapGroupPlacementEligibilityPolicy.canAbsorbPlacement(
                wasFrontmostAtPointerDown: wasFrontmostBeforeManipulation,
                isFrontmostNow: isFrontmostNow,
                isComplete: geometryIsComplete
            ),
                  let relationshipRank,
                  let firstMember = group.memberIDs.compactMap({ memberID in
                      orderedIDs.firstIndex(of: memberID)
                  }).min() else { return nil }
            return (group, relationshipRank, firstMember)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }

        if let targetGroup = eligibleGroups.first?.0 {
            return SnapPlacementContext(
                targetGroupID: targetGroup.id,
                departingGroupID: nil,
                memberIDs: targetGroup.memberIDs.union([window.stableIdentity]),
                excludedAssistCandidateIDs: initiallyLockedIDs,
                displayID: currentDisplayID
            )
        }


        // A previously snapped single window is not yet an explicit group,
        // but a later manual complementary snap must still be able to finish
        // it. Consider only the frontmost ungrouped placement; never use
        // geometry from an already registered group as implicit membership.
        let windowsByIdentity = Dictionary(
            comparisonWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let provisionalPlacements = lockedPlacements.compactMap {
            identity, placement -> SplitPlacementGeometry? in
            guard placement.displayID == currentDisplayID,
                  placement.zone != .maximize,
                  explicitGroupStore.group(containing: identity) == nil,
                  !(stagedGroupDeparture?.memberIDs.contains(identity)
                    ?? false),
                  let current = windowsByIdentity[identity] else {
                return nil
            }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: current.frame
            )
        }.sorted { lhs, rhs in
            let lhsIndex = orderedIDs.firstIndex(of: lhs.stableIdentity)
                ?? Int.max
            let rhsIndex = orderedIDs.firstIndex(of: rhs.stableIdentity)
                ?? Int.max
            return lhsIndex < rhsIndex
        }
        if let provisional = provisionalPlacements.first(where: { item in
            guard windowServerFrontmostEvaluation(
                memberIDs: [item.stableIdentity]
            ) == .verifiedFrontmost else { return false }
            if SnapPlacementLayerPolicy.conflicts(
                existing: item.zone,
                incoming: zone
            ) {
                return true
            }
            let handles = SplitLayoutGeometry.resizeHandleGeometries(
                placements: [item, incomingGeometry],
                detachedConnections: detachedConnections
            )
            return SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: window.stableIdentity,
                handles: handles
            ).contains(item.stableIdentity)
        }) {
            return SnapPlacementContext(
                targetGroupID: nil,
                departingGroupID: nil,
                memberIDs: [
                    provisional.stableIdentity,
                    window.stableIdentity
                ],
                excludedAssistCandidateIDs: initiallyLockedIDs,
                displayID: currentDisplayID
            )
        }

        // No complete frontmost group can absorb this placement. Leave every
        // existing group untouched and begin an independent split.
        return SnapPlacementContext(
            targetGroupID: nil,
            departingGroupID: nil,
            memberIDs: [window.stableIdentity],
            excludedAssistCandidateIDs: initiallyLockedIDs,
            displayID: currentDisplayID
        )
    }

    private func initialSplitDisposition(
        for candidate: ManagedWindow,
        requestedFrame: CGRect,
        zone: SnapZone,
        on screen: NSScreen
    ) -> InitialSplitDisposition {
        let axes = SplitLayoutGeometry.splitAxes(for: zone)
        guard !axes.isEmpty else { return .accept }

        let reference = constraintReference(
            stableIdentity: candidate.stableIdentity,
            currentSize: candidate.frame.size,
            zone: zone,
            on: screen
        )
        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        var failingAxes: Set<SplitAxis> = []

        if axes.contains(.horizontal),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: requestedFrame.width,
               acceptedLength: candidate.frame.width,
               referenceLength: reference.width
           ) > tolerance {
            failingAxes.insert(.horizontal)
        }
        if axes.contains(.vertical),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: requestedFrame.height,
               acceptedLength: candidate.frame.height,
               referenceLength: reference.height
           ) > tolerance {
            failingAxes.insert(.vertical)
        }
        guard !failingAxes.isEmpty else { return .accept }
        // A two-axis initial reflow would need to reshape the diagonal window in
        // both dimensions at once. Keep the existing grid intact unless the
        // operation can be represented by one complete boundary transaction.
        guard failingAxes.count == 1 else { return .reject }

        var desiredSize = candidate.frame.size
        if failingAxes.contains(.horizontal) {
            desiredSize.width = max(desiredSize.width, reference.width)
        }
        if failingAxes.contains(.vertical) {
            desiredSize.height = max(desiredSize.height, reference.height)
        }
        guard desiredSize.width <= screen.visibleFrame.width + 1,
              desiredSize.height <= screen.visibleFrame.height + 1 else {
            return .reject
        }

        let candidateTarget = SplitLayoutGeometry.anchoredFrame(
            around: requestedFrame,
            size: desiredSize,
            anchor: zone.sizeConstraintAnchor
        )
        guard let followers = makeInitialReflowFollowers(
            candidateIdentity: candidate.stableIdentity,
            candidateZone: zone,
            candidateStartFrame: requestedFrame,
            candidateFrame: candidateTarget,
            axes: failingAxes,
            on: screen
        ) else {
            return .reject
        }
        guard !followers.isEmpty else {
            return .accept
        }
        return .reflow(InitialReflowPlan(
            axes: failingAxes,
            candidateStartFrame: requestedFrame,
            candidateTarget: candidateTarget
        ))
    }

    private func makeInitialReflowFollowers(
        candidateIdentity: String,
        candidateZone: SnapZone,
        candidateStartFrame: CGRect,
        candidateFrame: CGRect,
        axes: Set<SplitAxis>,
        on screen: NSScreen
    ) -> [InitialReflowFollower]? {
        guard let currentDisplayID = displayID(for: screen) else { return nil }
        let windows = managedVisibleWindows()
        let windowsByIdentity = Dictionary(
            windows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        var followersByIdentity: [String: InitialReflowFollower] = [:]

        for axis in axes {
            guard let candidateSide = SplitLayoutGeometry.boundarySide(
                for: candidateZone,
                axis: axis
            ) else { return nil }
            let candidateBands = SplitLayoutGeometry.perpendicularBands(
                for: candidateZone,
                axis: axis
            )
            let initialCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: candidateStartFrame,
                side: candidateSide,
                axis: axis
            )
            let currentCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: candidateFrame,
                side: candidateSide,
                axis: axis
            )

            for band in [SplitPerpendicularBand.first, .second] {
                let members = lockedPlacements.compactMap { identity, placement
                    -> (String, LockedPlacement, ManagedWindow, SplitBoundarySide)? in
                    guard identity != candidateIdentity,
                          activeSnapPlacementContext?.memberIDs.contains(identity)
                            ?? false,
                          placement.displayID == currentDisplayID,
                          SplitLayoutGeometry.perpendicularBands(
                              for: placement.zone,
                              axis: axis
                          ).contains(band),
                          let side = SplitLayoutGeometry.boundarySide(
                              for: placement.zone,
                              axis: axis
                          ),
                          let window = windowsByIdentity[identity] else { return nil }
                    return (identity, placement, window, side)
                }
                guard !members.isEmpty else { continue }

                var occupiedSides = Set(members.map { $0.3 })
                if candidateBands.contains(band) {
                    occupiedSides.insert(candidateSide)
                }
                guard occupiedSides.count == 2 else { continue }
                let coordinates = members.map {
                    SplitLayoutGeometry.boundaryCoordinate(
                        of: $0.2.frame,
                        side: $0.3,
                        axis: axis
                    )
                }
                guard SplitLayoutGeometry.hasReachedBoundary(
                    initialCoordinate: initialCoordinate,
                    currentCoordinate: currentCoordinate,
                    participantCoordinates: coordinates
                ) else { continue }

                for (identity, placement, follower, side) in members {
                    let target = SplitLayoutGeometry.frame(
                        follower.frame,
                        meetingBoundary: currentCoordinate,
                        side: side,
                        axis: axis
                    )
                    let reference = constraintReference(
                        for: follower,
                        zone: placement.zone,
                        on: screen
                    )
                    let targetLength = axis == .horizontal ? target.width : target.height
                    let referenceLength = axis == .horizontal ? reference.width : reference.height
                    guard target.width > 0,
                          target.height > 0,
                          SplitLayoutGeometry.compressionRatio(
                              targetLength: targetLength,
                              referenceLength: referenceLength
                          ) <= tolerance else {
                        return nil
                    }
                    followersByIdentity[identity] = InitialReflowFollower(
                        window: follower,
                        zone: placement.zone,
                        axis: axis,
                        side: side,
                        originalFrame: follower.frame,
                        targetFrame: target,
                        constraintReference: reference
                    )
                }
            }
        }
        return Array(followersByIdentity.values)
    }

    private func performInitialReflow(
        _ plan: InitialReflowPlan,
        candidate: ManagedWindow,
        candidateSnapshot: WindowSnapshot,
        restoreFrame: CGRect,
        zone: SnapZone,
        on screen: NSScreen,
        continueAssist: Bool,
        operationGeneration: Int,
        completion: ((Bool) -> Void)?
    ) {
        windowService.setFrameAnchoredReliably(
            plan.candidateTarget,
            sizeConstraintAnchor: zone.sizeConstraintAnchor,
            requiredOuterEdges: zone.requiredOuterEdges,
            skipInitialWriteWhenVerified: true,
            for: candidate.element
        ) { [weak self] _ in
            guard let self,
                  self.interactionGeneration == operationGeneration else { return }
            guard let appliedCandidate = self.windowService.refreshed(candidate),
                  self.matchesRequiredOuterEdges(
                      appliedCandidate.frame,
                      targetFrame: plan.candidateTarget,
                      requiredEdges: zone.requiredOuterEdges
                  ) else {
                self.rollbackFailedSnapTransaction(
                    [candidateSnapshot],
                    operationGeneration: operationGeneration,
                    completion: completion
                )
                return
            }
            self.observeConstraint(for: appliedCandidate, requestedSize: plan.candidateTarget.size)

            guard let followers = self.makeInitialReflowFollowers(
                candidateIdentity: appliedCandidate.stableIdentity,
                candidateZone: zone,
                candidateStartFrame: plan.candidateStartFrame,
                candidateFrame: appliedCandidate.frame,
                axes: plan.axes,
                on: screen
            ), !followers.isEmpty else {
                self.rollbackFailedSnapTransaction(
                    [candidateSnapshot],
                    operationGeneration: operationGeneration,
                    completion: completion
                )
                return
            }

            let followerSnapshots = followers.map { self.windowService.snapshot($0.window) }
            for snapshot in followerSnapshots {
                self.pendingPlacementSnapshots[snapshot.stableIdentity] = snapshot
            }
            let needsFallbackRaise = self.virtualResizeOverlay.update(
                items: followers.map { follower in
                    VirtualResizeItem(
                        stableIdentity: follower.window.stableIdentity,
                        originalFrame: follower.originalFrame,
                        targetFrame: follower.targetFrame,
                        appIcon: follower.window.appIcon
                    )
                },
                liveFrames: [appliedCandidate.frame],
                liveWindowID: appliedCandidate.cgWindowID,
                screenFrame: screen.visibleFrame,
                layering: VirtualResizePresentationPolicy.layering(
                    liveWindowCount: 1,
                    virtualWindowCount: followers.count
                )
            )
            if needsFallbackRaise {
                self.establishLiveWindowAboveVirtualOverlay(
                    appliedCandidate
                ) { controller in
                    controller.interactionGeneration == operationGeneration
                }
            }

            var pending = followers.count
            var allAccepted = true
            var acceptedFollowers: [String: ManagedWindow] = [:]
            let tolerance = CGFloat(self.settings.layoutIntrusionTolerance)

            for follower in followers {
                self.windowService.setFrameAnchoredReliably(
                    follower.targetFrame,
                    sizeConstraintAnchor: SplitLayoutGeometry.boundaryAnchor(
                        sides: [follower.axis: follower.side],
                        activeAxes: [follower.axis]
                    ),
                    requiredOuterEdges: follower.zone.requiredOuterEdges,
                    skipInitialWriteWhenVerified: true,
                    for: follower.window.element
                ) { [weak self] _ in
                    guard let self else { return }
                    defer {
                        pending -= 1
                        if pending == 0 {
                            self.virtualResizeOverlay.hideAll()
                            if self.interactionGeneration == operationGeneration,
                               allAccepted {
                                for accepted in acceptedFollowers.values {
                                    if var placement = self.lockedPlacements[accepted.stableIdentity] {
                                        placement.appliedFrame = accepted.frame
                                        self.lockedPlacements[accepted.stableIdentity] = placement
                                    }
                                }
                                self.finalizeSuccessfulSnap(
                                    appliedCandidate,
                                    zone: zone,
                                    on: screen,
                                    snapshots: [candidateSnapshot] + followerSnapshots,
                                    restoreFrame: restoreFrame,
                                    continueAssist: continueAssist,
                                    operationGeneration: operationGeneration,
                                    completion: completion
                                )
                            } else {
                                self.rollbackFailedSnapTransaction(
                                    [candidateSnapshot] + followerSnapshots,
                                    operationGeneration: operationGeneration,
                                    completion: completion
                                )
                            }
                        }
                    }

                    guard self.interactionGeneration == operationGeneration else {
                        allAccepted = false
                        return
                    }
                    let actual = self.windowService.refreshed(follower.window) ?? follower.window
                    self.observeConstraint(for: actual, requestedSize: follower.targetFrame.size)
                    guard let candidateSide = SplitLayoutGeometry.boundarySide(
                        for: zone,
                        axis: follower.axis
                    ) else {
                        allAccepted = false
                        return
                    }
                    let candidateCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                        of: appliedCandidate.frame,
                        side: candidateSide,
                        axis: follower.axis
                    )
                    let followerCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                        of: actual.frame,
                        side: follower.side,
                        axis: follower.axis
                    )
                    let referenceLength = follower.axis == .horizontal
                        ? follower.constraintReference.width
                        : follower.constraintReference.height
                    let degree = abs(candidateCoordinate - followerCoordinate)
                        / max(referenceLength, 1)
                    let outerEdgesMatch = self.matchesRequiredOuterEdges(
                        actual.frame,
                        targetFrame: follower.targetFrame,
                        requiredEdges: follower.zone.requiredOuterEdges
                    )
                    allAccepted = allAccepted && degree <= tolerance && outerEdgesMatch
                    acceptedFollowers[actual.stableIdentity] = actual
                }
            }
        }
    }

    private func finalizeSuccessfulSnap(
        _ window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen,
        snapshots: [WindowSnapshot],
        restoreFrame: CGRect,
        continueAssist: Bool,
        operationGeneration: Int,
        completion: ((Bool) -> Void)?
    ) {
        for snapshot in snapshots {
            pendingPlacementSnapshots.removeValue(forKey: snapshot.stableIdentity)
        }
        guard registerLock(
            for: window,
            zone: zone,
            on: screen,
            context: activeSnapPlacementContext
        ) else {
            rollbackFailedSnapTransaction(
                snapshots,
                operationGeneration: operationGeneration,
                completion: completion
            )
            return
        }
        commitSnapshots(snapshots)
        restoreFrames[window.stableIdentity] = restoreFrame
        setAutomaticForegroundMode(forMemberID: window.stableIdentity)
        raiseSnapGroup(withMainWindow: window, on: screen)
        advanceAssist(
            with: window,
            justPlacedZone: zone,
            on: screen,
            continueAssist: continueAssist
        )
        finishSnapPlacementPresentation(
            operationGeneration: operationGeneration
        )
        completion?(true)
    }

    func resolvedUserWindowAtMouseUp(
        at point: CGPoint,
        visibleWindows: [ManagedWindow]
    ) -> ManagedWindow? {
        // Re-resolve the authoritative mouse-up surface for click-driven group
        // foregrounding. Do not skip a non-actionable popup and reach a snapped
        // window behind it.
        resolvedUserWindow(at: point, visibleWindows: visibleWindows)
    }

    func resolvedUserWindow(
        at point: CGPoint,
        visibleWindows: [ManagedWindow]
    ) -> ManagedWindow? {
        let orderedSurfaces = windowService.windowOcclusionSnapshot().map {
            SplitHitTestSurface(windowID: $0.windowID, frame: $0.frame)
        }
        let draggableWindowIDs = Set(visibleWindows.compactMap(\.cgWindowID))
        guard let clickedWindowID = PointerDragAcquisitionPolicy
            .draggableWindowID(
                at: point,
                orderedSurfaces: orderedSurfaces,
                draggableWindowIDs: draggableWindowIDs
            ) else { return nil }
        return visibleWindows.first {
            $0.cgWindowID == clickedWindowID
                && windowService.canMoveAndResize($0)
        }
    }

    func rollbackTransaction(
        _ snapshots: [WindowSnapshot],
        completion: ((Bool) -> Void)?
    ) {
        virtualResizeOverlay.hideAll()
        guard !snapshots.isEmpty else {
            completion?(false)
            return
        }
        for snapshot in snapshots {
            pendingPlacementSnapshots.removeValue(forKey: snapshot.stableIdentity)
        }
        var pending = snapshots.count
        for snapshot in snapshots {
            windowService.restore(snapshot) { _ in
                pending -= 1
                if pending == 0 {
                    completion?(false)
                }
            }
        }
    }

    func matchesRequiredOuterEdges(
        _ frame: CGRect,
        targetFrame: CGRect,
        requiredEdges: SnapOuterEdges
    ) -> Bool {
        let tolerance: CGFloat = 1

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

    private func rollbackFailedPlacement(
        _ snapshot: WindowSnapshot,
        operationGeneration: Int,
        completion: (() -> Void)? = nil
    ) {
        pendingPlacementSnapshots.removeValue(forKey: snapshot.stableIdentity)
        windowService.restore(snapshot) { [weak self] _ in
            self?.finishSnapPlacementPresentation(
                operationGeneration: operationGeneration
            )
            completion?()
        }
    }

    private func rollbackFailedSnapTransaction(
        _ snapshots: [WindowSnapshot],
        operationGeneration: Int,
        completion: ((Bool) -> Void)?
    ) {
        rollbackTransaction(snapshots) { [weak self] result in
            self?.finishSnapPlacementPresentation(
                operationGeneration: operationGeneration
            )
            completion?(result)
        }
    }

    private func finishSnapPlacementPresentation(
        operationGeneration: Int
    ) {
        guard isSnapPlacementInProgress,
              snapPlacementInteractionGeneration == operationGeneration else {
            return
        }
        isSnapPlacementInProgress = false
        snapPlacementInteractionGeneration = nil
        activeSnapPlacementContext = nil
        // refreshResizeHandles() either rebuilds and unsuspends validated
        // geometry, or hides everything when assist is active. Avoid manually
        // unsuspending stale descriptors between those two outcomes.
        refreshResizeHandles()
    }

    private func commitSnapshots(_ snapshots: [WindowSnapshot]) {
        guard !snapshots.isEmpty else { return }
        snapshotTransactions.append(SnapshotTransaction(snapshots: snapshots))
        if snapshotTransactions.count > 30 {
            snapshotTransactions.removeFirst(snapshotTransactions.count - 30)
        }
    }

    private func advanceAssist(with placedWindow: ManagedWindow, justPlacedZone zone: SnapZone, on screen: NSScreen, continueAssist: Bool) {
        guard continueAssist, zone != .maximize else {
            activeSession = nil
            stopEscapeMonitoring()
            picker.hide()
            return
        }

        if activeSession == nil {
            activeSession = makeSession(startingWith: zone, window: placedWindow, screen: screen)
        } else {
            activeSession?.occupy(zone, stableIdentity: placedWindow.stableIdentity)
        }

        guard let session = activeSession else { return }
        let remaining = session.remainingZones
        guard !remaining.isEmpty else {
            activeSession = nil
            stopEscapeMonitoring()
            picker.hide()
            return
        }

        let candidates = managedVisibleWindows(
            excludingStableIDs: session.occupiedStableIDs
        ).filter { candidate in
            // Selecting a member of another split would silently destroy or
            // merge that group. A user can still transfer it explicitly by
            // dragging it out first, which runs the normal departure path.
            lockedPlacements[candidate.stableIdentity] == nil
                && !session.excludedCandidateIDs.contains(
                    candidate.stableIdentity
                )
                && explicitGroupStore.group(
                    containing: candidate.stableIdentity
                ) == nil
        }
        guard !candidates.isEmpty else {
            activeSession = nil
            stopEscapeMonitoring()
            picker.hide()
            return
        }
        startEscapeMonitoring()
        let zoneFrames = Dictionary(
            uniqueKeysWithValues: remaining.map { remainingZone in
                let presentationFrame = candidates
                    .map { predictedSnapFrame(for: remainingZone, on: screen, window: $0) }
                    .max { lhs, rhs in
                        lhs.width * lhs.height < rhs.width * rhs.height
                    } ?? resolvedSnapFrame(for: remainingZone, on: screen)
                let nominalFrame = remainingZone.frame(in: screen)
                let clippedPresentation = presentationFrame.intersection(nominalFrame)
                return (
                    remainingZone,
                    clippedPresentation.isNull ? nominalFrame : clippedPresentation
                )
            }
        )
        picker.show(
            windows: candidates,
            zoneFrames: zoneFrames,
            previewProvider: { [weak self] windowID in
                guard let self, self.settings.windowPreviewsEnabled else { return nil }
                return self.windowService.previewCGImage(for: windowID)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.activeSession = nil
                self.stopEscapeMonitoring()
                self.refreshResizeHandles()
            }
        ) { [weak self] selected, targetZone in
            guard let self else { return }
            self.stopEscapeMonitoring()
            guard let current = self.windowService.refreshed(selected),
                  current.stableIdentity == selected.stableIdentity,
                  self.windowService.canMoveAndResize(current) else {
                self.cancelAssist()
                return
            }

            self.isAssistPlacementPending = true
            let selectionGeneration = self.interactionGeneration
            self.windowService.waitForPlacementReadiness(
                current,
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return self.isAssistPlacementPending
                        && self.interactionGeneration == selectionGeneration
                }
            ) { [weak self] readyWindow in
                guard let self,
                      self.interactionGeneration == selectionGeneration else { return }
                guard let readyWindow,
                      readyWindow.stableIdentity == selected.stableIdentity else {
                    self.isAssistPlacementPending = false
                    self.activeSession = nil
                    self.picker.hide()
                    self.refreshResizeHandles()
                    return
                }

                self.activeSession = session
                self.snap(
                    readyWindow,
                    to: targetZone,
                    on: screen,
                    continueAssist: true,
                    activateAfterInitialPlacement: true
                ) { [weak self] succeeded in
                    guard let self else { return }
                    self.isAssistPlacementPending = false
                    if !succeeded {
                        self.activeSession = nil
                        self.picker.hide()
                        self.refreshResizeHandles()
                    }
                }
            }
        }
    }

    private func makeSession(startingWith zone: SnapZone, window: ManagedWindow, screen: NSScreen) -> LayoutSession {
        let group = explicitGroupStore.group(
            containing: window.stableIdentity
        )
        let memberScope = group?.memberIDs
            ?? activeSnapPlacementContext?.memberIDs
            ?? [window.stableIdentity]
        let currentLocks = activeLocks(
            for: screen,
            validZones: SnapZone.allCases,
            memberScope: memberScope
        )
        let layoutZones = layoutZones(startingWith: zone, activeLocks: currentLocks)
        guard !layoutZones.isEmpty else {
            return LayoutSession(
                groupID: group?.id,
                excludedCandidateIDs: activeSnapPlacementContext?
                    .excludedAssistCandidateIDs ?? [],
                layoutZones: [],
                occupiedZones: [:]
            )
        }

        var occupied: [SnapZone: String] = [:]
        for placement in currentLocks where layoutZones.contains(placement.zone) {
            occupied[placement.zone] = placement.stableIdentity
        }

        occupied[zone] = window.stableIdentity
        return LayoutSession(
            groupID: group?.id,
            excludedCandidateIDs: activeSnapPlacementContext?
                .excludedAssistCandidateIDs ?? [],
            layoutZones: layoutZones,
            occupiedZones: occupied
        )
    }

    private func layoutZones(
        startingWith zone: SnapZone,
        activeLocks: [LockedPlacement]
    ) -> [SnapZone] {
        AssistLayoutPolicy.layoutZones(
            startingWith: zone,
            occupiedZones: Set(activeLocks.map(\.zone))
        )
    }

    private func resolvedSnapFrame(
        for zone: SnapZone,
        on screen: NSScreen,
        excluding excludedIdentity: String? = nil,
        memberScope: Set<String>? = nil
    ) -> CGRect {
        guard let currentDisplayID = displayID(for: screen) else {
            return zone.frame(in: screen)
        }
        let effectiveMemberScope = memberScope
            ?? activeSnapPlacementContext?.memberIDs
            ?? activeSession.map { session in
                let groupMembers = session.groupID.flatMap {
                    explicitGroupStore.group(id: $0)?.memberIDs
                } ?? []
                return groupMembers.union(session.occupiedStableIDs)
            }
        let visibleWindows = managedVisibleWindows()
        let framesByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        let geometries = lockedPlacements.compactMap { identity, placement -> SplitPlacementGeometry? in
            guard placement.displayID == currentDisplayID,
                  effectiveMemberScope?.contains(identity) ?? true,
                  let frame = framesByIdentity[identity] else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: frame
            )
        }
        return SplitLayoutGeometry.resolvedFrame(
            for: zone,
            in: screen.visibleFrame,
            placements: geometries,
            excluding: excludedIdentity
        )
    }

    private func predictedSnapFrame(
        for zone: SnapZone,
        on screen: NSScreen,
        window: ManagedWindow?
    ) -> CGRect {
        let memberScope: Set<String>?
        if let window {
            memberScope = snapPlacementContext(
                for: window,
                zone: zone,
                on: screen
            )?.memberIDs
        } else if let session = activeSession {
            memberScope = session.groupID.flatMap {
                explicitGroupStore.group(id: $0)?.memberIDs
            }?.union(session.occupiedStableIDs)
                ?? session.occupiedStableIDs
        } else {
            memberScope = nil
        }
        let resolved = recordedSnapFrame(
            for: zone,
            on: screen,
            excluding: window?.stableIdentity,
            memberScope: memberScope
        )
        guard let window else { return resolved }
        let axes = SplitLayoutGeometry.splitAxes(for: zone)
        guard !axes.isEmpty else { return resolved }

        let reference = constraintReference(
            for: window,
            zone: zone,
            on: screen
        )
        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        var size = resolved.size
        if axes.contains(.horizontal),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: resolved.width,
               acceptedLength: resolved.width,
               referenceLength: reference.width
           ) > tolerance {
            size.width = min(max(size.width, reference.width), screen.visibleFrame.width)
        }
        if axes.contains(.vertical),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: resolved.height,
               acceptedLength: resolved.height,
               referenceLength: reference.height
           ) > tolerance {
            size.height = min(max(size.height, reference.height), screen.visibleFrame.height)
        }
        return SplitLayoutGeometry.anchoredFrame(
            around: resolved,
            size: size,
            anchor: zone.sizeConstraintAnchor
        )
    }

    private func recordedSnapFrame(
        for zone: SnapZone,
        on screen: NSScreen,
        excluding excludedIdentity: String? = nil,
        memberScope: Set<String>? = nil
    ) -> CGRect {
        guard let currentDisplayID = displayID(for: screen) else {
            return zone.frame(in: screen)
        }
        let geometries = lockedPlacements.compactMap { identity, placement
            -> SplitPlacementGeometry? in
            guard placement.displayID == currentDisplayID,
                  memberScope?.contains(identity) ?? true,
                  identity != excludedIdentity else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: placement.appliedFrame
            )
        }
        return SplitLayoutGeometry.resolvedFrame(
            for: zone,
            in: screen.visibleFrame,
            placements: geometries,
            excluding: excludedIdentity
        )
    }

    func constraintReference(
        for window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen
    ) -> CGSize {
        constraintReference(
            stableIdentity: window.stableIdentity,
            currentSize: window.frame.size,
            zone: zone,
            on: screen
        )
    }

    func constraintReference(
        stableIdentity: String,
        currentSize: CGSize,
        zone: SnapZone,
        on screen: NSScreen
    ) -> CGSize {
        let nominal = zone.frame(in: screen).size
        return constraintHints[stableIdentity, default: WindowConstraintHint()]
            .referenceSize(current: currentSize, nominal: nominal)
    }

    func observeConstraint(for window: ManagedWindow, requestedSize: CGSize) {
        var hint = constraintHints[window.stableIdentity] ?? WindowConstraintHint()
        hint.observe(requested: requestedSize, accepted: window.frame.size)
        constraintHints[window.stableIdentity] = hint
    }

    private func activeLocks(
        for screen: NSScreen,
        validZones: [SnapZone],
        memberScope: Set<String>? = nil
    ) -> [LockedPlacement] {
        guard let currentDisplayID = displayID(for: screen) else { return [] }
        let windows = managedVisibleWindows()
        var windowByID: [String: ManagedWindow] = [:]
        for window in windows { windowByID[window.stableIdentity] = window }

        var matches: [LockedPlacement] = []
        var closedWindows: [String] = []

        for (identity, placement) in lockedPlacements {
            guard placement.displayID == currentDisplayID,
                  memberScope?.contains(identity) ?? true else { continue }

            if let window = windowByID[identity] {
                if inFlightPlacementIDs.contains(identity) {
                    if validZones.contains(placement.zone) { matches.append(placement) }
                    continue
                }
                guard matchesRecordedPlacement(
                    window.frame,
                    placement.appliedFrame,
                    on: screen
                ) else {
                    // AX and Window Server frames can briefly disagree while
                    // the next snap is being constructed. Exclude this lock
                    // from the layout suggestion, but keep its persistent
                    // state. Confirmed move/resize paths own dissolution.
                    continue
                }
                if validZones.contains(placement.zone) { matches.append(placement) }
                continue
            }

            if WindowStructuralPolicy.isConfirmedMissing(
                windowService.windowLiveness(
                    element: placement.element,
                    pid: placement.pid
                )
            ) {
                closedWindows.append(identity)
            }
        }

        closedWindows.forEach { identity in
            if !dissolveExplicitGroupForUserDeparture(containing: identity) {
                lockedPlacements.removeValue(forKey: identity)
                removeConnections(for: identity)
                restoreFrames.removeValue(forKey: identity)
            }
            constraintHints.removeValue(forKey: identity)
        }
        return matches.filter { lockedPlacements[$0.stableIdentity] != nil }
    }

    private func matchesRecordedPlacement(
        _ current: CGRect,
        _ recorded: CGRect,
        on screen: NSScreen
    ) -> Bool {
        let tolerance = max(8, min(screen.visibleFrame.width, screen.visibleFrame.height) * 0.008)
        return abs(current.minX - recorded.minX) <= tolerance
            && abs(current.minY - recorded.minY) <= tolerance
            && abs(current.width - recorded.width) <= tolerance
            && abs(current.height - recorded.height) <= tolerance
    }

    private func registerLock(
        for window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen,
        context: SnapPlacementContext?
    ) -> Bool {
        guard let currentDisplayID = displayID(for: screen) else {
            return false
        }
        if let context, context.displayID != currentDisplayID {
            return false
        }
        let previousLockedPlacements = lockedPlacements
        let previousGroupStore = explicitGroupStore
        let previousDetachedConnections = detachedConnections
        let previousInFlightPlacementIDs = inFlightPlacementIDs
        let previousPendingPlacementSnapshots = pendingPlacementSnapshots
        let previousRestoreFrames = restoreFrames
        let previousConstraintHints = constraintHints
        let previousForegroundModes = groupForegroundModes
        let previousStagedDeparture = stagedGroupDeparture
        isReconcilingPlacementMutation = true
        defer { isReconcilingPlacementMutation = false }
        if let departingGroupID = context?.departingGroupID {
            guard explicitGroupStore.group(
                containing: window.stableIdentity
            )?.id == departingGroupID,
                  dissolveExplicitGroupForUserDeparture(
                    containing: window.stableIdentity
                  ) else {
                return false
            }
        }
        if zone == .maximize,
           stagedGroupDeparture?.draggedIdentity == window.stableIdentity {
            finalizeStagedGroupDepartureIfNeeded()
        }
        if zone == .maximize,
           explicitGroupStore.group(
            containing: window.stableIdentity
           ) != nil {
            let incomingRestoreFrame = restoreFrames[window.stableIdentity]
            _ = dissolveExplicitGroupForUserDeparture(
                containing: window.stableIdentity
            )
            if let incomingRestoreFrame {
                restoreFrames[window.stableIdentity] = incomingRestoreFrame
            }
        }
        if context?.departingGroupID == nil {
            removeConnections(for: window.stableIdentity)
        }
        if zone != .maximize {
            explicitGroupStore.clearMaximizedLayer(
                windowID: window.stableIdentity
            )
        }
        let visibleIDs = Set(managedVisibleWindows().map(\.stableIdentity))
        let targetMemberIDs = context?.targetGroupID.flatMap {
            explicitGroupStore.group(id: $0)?.memberIDs
        } ?? []
        let conflictingIDs = lockedPlacements.compactMap { identity, placement -> String? in
            let belongsToTargetGroup = context?.targetGroupID != nil
                && targetMemberIDs.contains(identity)
            let belongsToProvisionalScope = context?.targetGroupID == nil
                && (context?.memberIDs.contains(identity) ?? false)
            let isMaximizedLayerConflict = placement.zone == .maximize
            guard identity != window.stableIdentity,
                  belongsToTargetGroup
                    || belongsToProvisionalScope
                    || isMaximizedLayerConflict,
                  placement.displayID == currentDisplayID,
                  SnapPlacementLayerPolicy.conflicts(
                      existing: placement.zone,
                      incoming: zone
                  ) else { return nil }
            let crossesMaximizedLayer = placement.zone == .maximize
                || zone == .maximize
            guard crossesMaximizedLayer || visibleIDs.contains(identity) else {
                return nil
            }
            return identity
        }
        conflictingIDs.forEach { identity in
            // Replacing one occupied zone is a layout mutation, not evidence
            // that every peer left the desktop. Preserve the unaffected locks;
            // the reconciliation after inserting the incoming placement will
            // build the new complete group atomically.
            let displacedZone = lockedPlacements[identity]?.zone
            lockedPlacements.removeValue(forKey: identity)
            if displacedZone == .maximize {
                explicitGroupStore.clearMaximizedLayer(windowID: identity)
            }
            removeConnections(for: identity)
            restoreFrames.removeValue(forKey: identity)
        }

        let persistedWindowID = window.cgWindowID
            ?? windowService.resolvingWindowServerIdentity(window).cgWindowID
        lockedPlacements[window.stableIdentity] = LockedPlacement(
            element: window.element,
            pid: window.pid,
            stableIdentity: window.stableIdentity,
            cgWindowID: persistedWindowID,
            zone: zone,
            displayID: currentDisplayID,
            appliedFrame: window.frame
        )
        let successorMemberScope: Set<String>?
        if let context {
            successorMemberScope = context.memberIDs
                .subtracting(conflictingIDs)
                .union([window.stableIdentity])
        } else {
            successorMemberScope = nil
        }
        let reconciled = reconcileExplicitGroupAfterLayoutMutation(
            preferredMemberID: window.stableIdentity,
            targetGroupID: context?.targetGroupID,
            memberScope: successorMemberScope
        )
        guard reconciled else {
            lockedPlacements = previousLockedPlacements
            explicitGroupStore = previousGroupStore
            detachedConnections = previousDetachedConnections
            inFlightPlacementIDs = previousInFlightPlacementIDs
            pendingPlacementSnapshots = previousPendingPlacementSnapshots
            restoreFrames = previousRestoreFrames
            constraintHints = previousConstraintHints
            groupForegroundModes = previousForegroundModes
            stagedGroupDeparture = previousStagedDeparture
            // Authoritative placement/group state rolls back, but temporal
            // observation evidence must be reacquired after the rollback.
            groupDegradationEvidenceByGroupID.removeAll()
            lastGroupWindowServerEvidenceByIdentity.removeAll()
            resetGroupPresentationTransitionRecovery()
            updateSelectionMonitoringState()
            refreshMissionControlGroupProxies()
            return false
        }
        if let group = explicitGroupStore.group(
            containing: window.stableIdentity
        ) {
            activeSession?.groupID = group.id
        }
        if zone != .maximize,
           stagedGroupDeparture?.draggedIdentity == window.stableIdentity,
           explicitGroupStore.group(containing: window.stableIdentity) != nil {
            stagedGroupDeparture = nil
        }
        return true
    }

    func removeConnections(for stableIdentity: String) {
        detachedConnections = Set(
            detachedConnections.filter { !$0.contains(stableIdentity) }
        )
    }

    private func handleActiveSpaceChange() {
        if handleResizeSession != nil {
            cancelHandleResize(restoreOriginalFrames: true)
        }
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
        explicitGroupStore.suspendForSpaceTransition()
        invalidatePendingOperations()
        resetSideDwellState()
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        activeSession = nil
        activeTarget = nil
        dragDisplayID = nil
        dragScreenFrame = nil
        suppressedEntryEdge = nil
        suppressedDisplayID = nil

        let recoveryGeneration = interactionGeneration
        for delay in [0.15, 0.35, 0.75, 1.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.interactionGeneration == recoveryGeneration else {
                    return
                }
                self.refreshResizeHandles()
            }
        }

        guard CGEventSource.buttonState(.combinedSessionState, button: .left),
              pendingDragWindow != nil || dragWindow != nil else {
            resetDragState()
            activeWindowObserver.observeFrontmostApplication()
            scheduleSelectionDrivenGroupRaise(expectedPID: nil)
            return
        }
    }

    func invalidatePendingOperations(rollbackPendingPlacements: Bool = true) {
        finalizeStagedGroupDepartureIfNeeded()
        interactionGeneration &+= 1
        deferredPlainClickPoint = nil
        deferredSelectionExpectedPID = nil
        hasDeferredSelectionSignal = false
        handlePresentationRevalidationGeneration &+= 1
        resetMissionControlPresentationRetryDebt()
        invalidatePendingGroupRaise()
        invalidatePendingSelectionRaise()
        resetIncompleteHandleGeometryRecovery()
        isAssistPlacementPending = false
        isSnapPlacementInProgress = false
        snapPlacementInteractionGeneration = nil
        activeSnapPlacementContext = nil
        windowService.cancelAllFrameOperations()
        let invalidatedHandleSession = handleResizeSession
            ?? finalizingHandleResizeSession
        handleResizeSession = nil
        finalizingHandleResizeSession = nil
        if let invalidatedHandleSession {
            resizeHandleOverlay.setPresentationSuspended(true)
            updateHandleSettlementOverlay(
                invalidatedHandleSession,
                restoreOriginalFrames: true
            )
            isHandleResizeFinalizing = true
            stopEscapeMonitoring()
            let identities = Set(invalidatedHandleSession.participants.keys)
            liveResizeScheduler.stop(
                generation: invalidatedHandleSession.schedulerGeneration
            ) { [weak self] in
                guard let self else { return }
                for snapshot in invalidatedHandleSession.snapshots {
                    if snapshot.wasFullscreen {
                        _ = self.windowService.setFullscreen(
                            true,
                            for: snapshot.element
                        )
                    } else {
                        _ = self.windowService.setFrame(
                            snapshot.frame,
                            for: snapshot.element
                        )
                    }
                }
                self.isHandleResizeFinalizing = false
                self.inFlightPlacementIDs.subtract(identities)
                self.virtualResizeOverlay.hideAll()
                self.resizeHandleOverlay.endInteraction()
                self.refreshResizeHandles()
            }
        } else {
            liveResizeScheduler.cancelAll()
        }
        let pending = Array(pendingPlacementSnapshots.values)
        pendingPlacementSnapshots.removeAll()
        inFlightPlacementIDs.removeAll()
        guard rollbackPendingPlacements else { return }

        for snapshot in pending {
            if snapshot.wasFullscreen {
                _ = windowService.setFullscreen(true, for: snapshot.element)
            } else {
                _ = windowService.setFrame(snapshot.frame, for: snapshot.element)
            }
        }
    }

    private func cancelAssist() {
        if handleResizeSession != nil {
            cancelHandleResize(restoreOriginalFrames: true)
            return
        }
        invalidatePendingOperations()
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        finalizeStagedGroupDepartureIfNeeded()
        resetDragState()
        activeSession = nil

        // A normal click is also routed through this cancellation path before
        // drag detection begins. Rebuilding in place avoids destroying and
        // recreating the handle panels on every tab/title-bar click.
        refreshResizeHandles()
    }

    func resetDragState() {
        cancelSmoothDragRestore()
        resetSideDwellState()
        activeTarget = nil
        pendingDragWindow = nil
        pendingDragWindowFrame = nil
        pendingDragMousePoint = nil
        pendingDragStartedInLikelyDragRegion = false
        pendingDragStartedNearResizeEdge = false
        isWindowMoveConfirmed = false
        sourceDragWindow = nil
        frontmostGroupIDsAtPointerDown = nil
        deferredPointerDragResolution = nil
        windowServerIDsAtDragStart.removeAll()
        detachedWindowServerCensusAtDragStart = .unknown
        pendingRestoreFrame = nil
        dragRestoreFrameCandidate = nil
        pendingGrabRatio = nil
        hasWindowActuallyMoved = false
        didStartDragRestore = false
        detachedCandidateID = nil
        detachedCandidateHitCount = 0
        manualResizeWindow = nil
        pendingNativeResizeDeparture = nil
        pendingNativeResizeCandidates.removeAll()
        unresolvedNativeResizeWasActivated = false
        dragWindow = nil
        dragDisplayID = nil
        dragScreenFrame = nil
        suppressedEntryEdge = nil
        suppressedDisplayID = nil
    }


    private func isLikelyWindowDragRegion(_ point: CGPoint, window: ManagedWindow) -> Bool {
        guard window.frame.contains(point) else { return false }

        let bandHeight = min(88, max(36, window.frame.height * 0.14))
        return point.y >= window.frame.maxY - bandHeight
    }

    func isNearWindowResizeEdge(_ point: CGPoint, frame: CGRect) -> Bool {
        NativeWindowResizePolicy.isNearResizeEdge(point, frame: frame)
    }

    private var currentEdgeThreshold: CGFloat {
        CGFloat(settings.edgeThreshold)
    }

    private var currentCornerBand: CGFloat {
        CGFloat(settings.cornerBand)
    }

    private func updateSideDwell(for target: SnapTarget, at point: CGPoint, on screen: NSScreen) {
        if let expandedSideContext {
            if expandedSideContext.displayID == target.displayID,
               isAtSideEdge(point, edge: expandedSideContext.edge, on: screen) {
                return
            }
            resetSideDwellState()
        }

        guard settings.sideDwellExpansionEnabled,
              let edge = sideEdge(for: target.zone),
              isAtSideEdge(point, edge: edge, on: screen) else {
            resetSideDwellState()
            return
        }

        let context = SideDwellContext(displayID: target.displayID, edge: edge)
        guard sideDwellContext != context else { return }
        resetSideDwellState()
        sideDwellContext = context

        let totalDuration = settings.sideDwellDuration
        let pulseDuration = min(OverlayPanel.sideExpansionPulseDuration, totalDuration)
        let pulseDelay = max(totalDuration - pulseDuration, 0)

        let pulseTimer = Timer(timeInterval: pulseDelay, repeats: false) { [weak self] _ in
            self?.beginSideDwellPulse(context, duration: pulseDuration)
        }
        sideDwellPulseTimer = pulseTimer
        RunLoop.main.add(pulseTimer, forMode: .common)
    }

    private func beginSideDwellPulse(_ context: SideDwellContext, duration: TimeInterval) {
        sideDwellPulseTimer = nil
        guard settings.sideDwellExpansionEnabled,
              sideDwellContext == context,
              CGEventSource.buttonState(.combinedSessionState, button: .left),
              let screen = screen(withDisplayID: context.displayID) else {
            resetSideDwellState()
            return
        }

        let point = NSEvent.mouseLocation
        guard let currentScreen = screenOwning(point),
              displayID(for: currentScreen) == context.displayID,
              isAtSideEdge(point, edge: context.edge, on: screen) else {
            resetSideDwellState()
            return
        }

        overlay.pulse(times: 3, duration: duration)
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.activateExpandedSideSelection(context)
        }
        sideDwellTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func activateExpandedSideSelection(_ context: SideDwellContext) {
        guard settings.sideDwellExpansionEnabled,
              sideDwellContext == context,
              CGEventSource.buttonState(.combinedSessionState, button: .left),
              let screen = screen(withDisplayID: context.displayID) else {
            resetSideDwellState()
            return
        }

        let point = NSEvent.mouseLocation
        guard let currentScreen = screenOwning(point),
              displayID(for: currentScreen) == context.displayID,
              isAtSideEdge(point, edge: context.edge, on: screen) else {
            resetSideDwellState()
            return
        }

        sideDwellTimer = nil
        sideDwellPulseTimer = nil
        overlay.finishPulse()
        expandedSideContext = context
        activeTarget = nil
        handleDrag(at: point)
    }

    private func expandedSideZone(at point: CGPoint, edge: SideSnapEdge, on screen: NSScreen) -> SnapZone {
        let frame = screen.frame
        let relativeY = min(max((point.y - frame.minY) / max(frame.height, 1), 0), 1)
        return ExpandedSideSelectionPolicy.zone(
            relativeY: relativeY,
            isLeftEdge: edge == .left
        )
    }

    private func sideEdge(for zone: SnapZone) -> SideSnapEdge? {
        switch zone {
        case .leftHalf, .topLeft, .bottomLeft:
            return .left
        case .rightHalf, .topRight, .bottomRight:
            return .right
        default:
            return nil
        }
    }

    private func isAtSideEdge(_ point: CGPoint, edge: SideSnapEdge, on screen: NSScreen) -> Bool {
        let threshold = max(currentEdgeThreshold + 8, currentEdgeThreshold * 1.25)
        switch edge {
        case .left:
            return point.x <= screen.frame.minX + threshold
        case .right:
            return point.x >= screen.frame.maxX - threshold
        }
    }

    private func resetSideDwellState() {
        sideDwellTimer?.invalidate()
        sideDwellTimer = nil
        sideDwellPulseTimer?.invalidate()
        sideDwellPulseTimer = nil
        overlay.finishPulse()
        sideDwellContext = nil
        expandedSideContext = nil
    }

    private func detectSnapZone(at point: CGPoint, on screen: NSScreen) -> SnapZone? {
        SnapZone.detect(
            at: point,
            on: screen,
            edgeThreshold: currentEdgeThreshold,
            cornerBand: currentCornerBand
        )
    }

    private func isNearSnapEdge(_ point: CGPoint) -> Bool {
        guard let screen = screenOwning(point) else { return false }
        return detectSnapZone(at: point, on: screen) != nil
    }

    func ensurePermission() -> Bool {
        if windowService.isTrusted { return true }
        return windowService.requestPermissionIfNeeded()
    }

    private func snapTarget(at point: CGPoint, shouldUpdateDisplayTransition: Bool) -> SnapTarget? {
        guard let screen = screenOwning(point),
              let displayID = displayID(for: screen) else { return nil }

        if shouldUpdateDisplayTransition {
            updateDisplayTransition(to: screen, displayID: displayID, point: point)
        }

        if suppressedDisplayID == displayID,
           let edge = suppressedEntryEdge {
            if isInsideEntryBand(point, edge: edge, screen: screen) {
                return nil
            }
            suppressedEntryEdge = nil
            suppressedDisplayID = nil
        }

        if let context = expandedSideContext {
            if context.displayID == displayID,
               isAtSideEdge(point, edge: context.edge, on: screen) {
                return SnapTarget(
                    displayID: displayID,
                    zone: expandedSideZone(at: point, edge: context.edge, on: screen)
                )
            }
            resetSideDwellState()
        }

        let detectedZone = detectSnapZone(at: point, on: screen)

        if let activeTarget,
           activeTarget.displayID == displayID,
           let detectedZone,
           shouldPreferDetectedCorner(
               detectedZone,
               over: activeTarget.zone
           ) {
            return SnapTarget(displayID: displayID, zone: detectedZone)
        }

        if let activeTarget,
           activeTarget.displayID == displayID,
           shouldKeepActiveTarget(activeTarget, at: point, on: screen) {
            return activeTarget
        }

        guard let detectedZone else { return nil }
        return SnapTarget(displayID: displayID, zone: detectedZone)
    }

    /// Mouse-up is the authoritative edge sample. During a fast throw the
    /// preview path may not receive another drag event after entering the top
    /// band, and its sticky target can also describe the preceding edge. Keep
    /// cross-display suppression, but prefer the zone physically under the
    /// pointer before falling back to a still-valid preview target.
    private func snapTargetForDrop(at point: CGPoint) -> SnapTarget? {
        guard let screen = screenOwning(point),
              let displayID = displayID(for: screen) else { return nil }

        if suppressedDisplayID == displayID,
           let edge = suppressedEntryEdge {
            if isInsideEntryBand(point, edge: edge, screen: screen) {
                return nil
            }
            suppressedEntryEdge = nil
            suppressedDisplayID = nil
        }

        if let context = expandedSideContext {
            if context.displayID == displayID,
               isAtSideEdge(point, edge: context.edge, on: screen) {
                return SnapTarget(
                    displayID: displayID,
                    zone: expandedSideZone(
                        at: point,
                        edge: context.edge,
                        on: screen
                    )
                )
            }
            resetSideDwellState()
        }

        let activeZone = activeTarget?.displayID == displayID
            ? activeTarget?.zone
            : nil
        let activeZoneIsStillValid = activeTarget.map {
            $0.displayID == displayID
                && shouldKeepActiveTarget($0, at: point, on: screen)
        } ?? false
        guard let zone = SnapDropTargetPolicy.preferredZone(
            detectedZone: detectSnapZone(at: point, on: screen),
            activeZone: activeZone,
            activeZoneIsStillValid: activeZoneIsStillValid
        ) else { return nil }
        return SnapTarget(displayID: displayID, zone: zone)
    }

    private func shouldPreferDetectedCorner(
        _ detectedZone: SnapZone,
        over activeZone: SnapZone
    ) -> Bool {
        switch (activeZone, detectedZone) {
        case (.leftHalf, .topLeft),
             (.leftHalf, .bottomLeft),
             (.rightHalf, .topRight),
             (.rightHalf, .bottomRight),
             (.maximize, .topLeft),
             (.maximize, .topRight):
            return true
        default:
            return false
        }
    }

    private func shouldKeepActiveTarget(_ target: SnapTarget, at point: CGPoint, on screen: NSScreen) -> Bool {
        let frame = screen.frame
        let exitThreshold = max(currentEdgeThreshold + 8, currentEdgeThreshold * 1.25)
        let cornerBand = currentCornerBand + 20

        switch target.zone {
        case .leftHalf:
            return point.x <= frame.minX + exitThreshold
        case .rightHalf:
            return point.x >= frame.maxX - exitThreshold
        case .topHalf, .bottomHalf:
            return false
        case .maximize:
            return point.y >= frame.maxY - exitThreshold
        case .topLeft:
            return point.x <= frame.minX + exitThreshold && point.y >= frame.maxY - cornerBand
        case .topRight:
            return point.x >= frame.maxX - exitThreshold && point.y >= frame.maxY - cornerBand
        case .bottomLeft:
            return point.x <= frame.minX + exitThreshold && point.y <= frame.minY + cornerBand
        case .bottomRight:
            return point.x >= frame.maxX - exitThreshold && point.y <= frame.minY + cornerBand
        }
    }

    private func updateDisplayTransition(to screen: NSScreen, displayID: CGDirectDisplayID, point: CGPoint) {
        guard dragDisplayID != displayID else { return }

        if let previousFrame = dragScreenFrame,
           let entryEdge = sharedEntryEdge(from: previousFrame, to: screen.frame, at: point) {
            suppressedEntryEdge = entryEdge
            suppressedDisplayID = displayID
        } else {
            suppressedEntryEdge = nil
            suppressedDisplayID = nil
        }

        dragDisplayID = displayID
        dragScreenFrame = screen.frame
        resetSideDwellState()
        activeTarget = nil
        overlay.hide()
    }

    private func sharedEntryEdge(from oldFrame: CGRect, to newFrame: CGRect, at point: CGPoint) -> SnapEntryEdge? {
        let tolerance: CGFloat = 2
        let verticalOverlap = min(oldFrame.maxY, newFrame.maxY) - max(oldFrame.minY, newFrame.minY)
        let horizontalOverlap = min(oldFrame.maxX, newFrame.maxX) - max(oldFrame.minX, newFrame.minX)

        if verticalOverlap > 0 {
            if abs(oldFrame.maxX - newFrame.minX) <= tolerance { return .left }
            if abs(oldFrame.minX - newFrame.maxX) <= tolerance { return .right }
        }
        if horizontalOverlap > 0 {
            if abs(oldFrame.maxY - newFrame.minY) <= tolerance { return .bottom }
            if abs(oldFrame.minY - newFrame.maxY) <= tolerance { return .top }
        }
        return nil
    }

    private func isInsideEntryBand(_ point: CGPoint, edge: SnapEntryEdge, screen: NSScreen) -> Bool {
        let threshold: CGFloat = 18
        let frame = screen.frame
        switch edge {
        case .left:
            return point.x < frame.minX + threshold
        case .right:
            return point.x >= frame.maxX - threshold
        case .top:
            return point.y >= frame.maxY - threshold
        case .bottom:
            return point.y < frame.minY + threshold
        }
    }

    private func screenOwning(_ point: CGPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x < frame.maxX
                && point.y >= frame.minY && point.y < frame.maxY
        }) {
            return exact
        }

        return NSScreen.screens.min { distanceSquared(from: point, to: $0.frame) < distanceSquared(from: point, to: $1.frame) }
    }

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    func screen(withDisplayID targetDisplayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(for: $0) == targetDisplayID }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        screenOwning(point)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
