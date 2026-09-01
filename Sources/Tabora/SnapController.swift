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

private struct InitialConstraintPlannedWindow {
    let window: ManagedWindow
    let zone: SnapZone
    let originalFrame: CGRect
    let targetFrame: CGRect
    let appConstraintLimits: AppConstraintLimits
    let appConstraintIdentity: AppConstraintIdentity?
    let appConstraintDisplayName: String
}

private struct InitialConstraintSnapPlan {
    let candidateIdentity: String
    let windowsByIdentity: [String: InitialConstraintPlannedWindow]

    var candidateTargetFrame: CGRect? {
        windowsByIdentity[candidateIdentity]?.targetFrame
    }
}

private enum InitialConstraintSnapPlanResolution {
    case ready(InitialConstraintSnapPlan)
    case confirmedInfeasible
    case indeterminate
}

enum InitialSnapMutationOrderingPolicy {
    /// The user-selected incoming window establishes the first accepted
    /// geometry. Existing peers are not moved toward a provisional target
    /// until that candidate either settles at the planned frame or supplies
    /// new operation-local constraint evidence for a replan.
    static func identitiesForRound(
        candidateIdentity: String,
        plannedIdentities: Set<String>,
        candidateMustSettleFirst: Bool
    ) -> Set<String> {
        guard candidateMustSettleFirst,
              plannedIdentities.contains(candidateIdentity) else {
            return plannedIdentities
        }
        return [candidateIdentity]
    }
}

enum HandleResizeConstraintEvidencePolicy {
    static func activeAxis(
        boundaryAxis: SplitAxis,
        originalCoordinate: CGFloat,
        finalCoordinate: CGFloat,
        participantOwnsBoundary: Bool,
        epsilon: CGFloat = 0.001
    ) -> ConstraintProbeAxis? {
        guard participantOwnsBoundary,
              abs(finalCoordinate - originalCoordinate) > epsilon else {
            return nil
        }
        return boundaryAxis == .horizontal ? .width : .height
    }
}

enum InitialSnapConstraintSettlementPolicy {
    static func operationLocalAxes(
        currentFrame: CGRect,
        targetFrame: CGRect,
        limits: AppConstraintLimits,
        epsilon: CGFloat
    ) -> Set<ConstraintProbeAxis> {
        guard epsilon.isFinite, epsilon >= 0 else { return [] }
        var result = Set<ConstraintProbeAxis>()
        if targetFrame.width < currentFrame.width - epsilon,
           limits.minWidth == nil {
            result.insert(.width)
        } else if targetFrame.width > currentFrame.width + epsilon,
                  limits.maxWidth == nil {
            result.insert(.width)
        }
        if targetFrame.height < currentFrame.height - epsilon,
           limits.minHeight == nil {
            result.insert(.height)
        } else if targetFrame.height > currentFrame.height + epsilon,
                  limits.maxHeight == nil {
            result.insert(.height)
        }
        return result
    }

    static func attributableOperationLocalAxes(
        requestedFrame: CGRect,
        acceptedFrame: CGRect,
        candidateAxes: Set<ConstraintProbeAxis>,
        epsilon: CGFloat
    ) -> Set<ConstraintProbeAxis> {
        guard epsilon.isFinite, epsilon >= 0 else { return [] }
        let widthMismatch = abs(requestedFrame.width - acceptedFrame.width)
            > epsilon
        let heightMismatch = abs(requestedFrame.height - acceptedFrame.height)
            > epsilon

        if candidateAxes == [.width], heightMismatch { return [] }
        if candidateAxes == [.height], widthMismatch { return [] }
        if candidateAxes.count > 1, widthMismatch, heightMismatch { return [] }
        return candidateAxes
    }

    /// Early settled-mismatch return exists only to discover a directional
    /// bound that was unknown when this round was planned. Known axes remain
    /// solver authority even when a different axis is still being discovered.
    static func mode(
        currentFrame: CGRect,
        targetFrame: CGRect,
        limits: AppConstraintLimits,
        epsilon: CGFloat
    ) -> AXFrameSettlementMode {
        operationLocalAxes(
            currentFrame: currentFrame,
            targetFrame: targetFrame,
            limits: limits,
            epsilon: epsilon
        ).isEmpty ? .requireExactTarget : .returnSettledConstraintResult
    }
}



private struct SnapConstraintObservation {
    let identity: AppConstraintIdentity?
    let displayName: String
    let limits: AppConstraintLimits
    let eligibleForLearning: Bool
}

private final class SnapObservationScene {
    let visibleWindows: [ManagedWindow]
    let windowServerSnapshot: [WindowOcclusionSnapshot]
    let windowServerSnapshotCompleteness: WindowDiscoveryCompleteness
    var constraintObservationsByIdentity: [String: SnapConstraintObservation] = [:]

    init(
        visibleWindows: [ManagedWindow],
        windowServerSnapshot: [WindowOcclusionSnapshot],
        windowServerSnapshotCompleteness: WindowDiscoveryCompleteness
    ) {
        self.visibleWindows = visibleWindows
        self.windowServerSnapshot = windowServerSnapshot
        self.windowServerSnapshotCompleteness = windowServerSnapshotCompleteness
    }
}

struct HandleResizeParticipant {
    let window: ManagedWindow
    let zone: SnapZone
    let originalFrame: CGRect
    let appConstraintIdentity: AppConstraintIdentity?
    let appConstraintDisplayName: String
    let appConstraintLimits: AppConstraintLimits
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
    let constraintRegistryGeneration: UInt64
    let operationGeneration: Int
    let departureSnapshot: ExplicitGroupDepartureSnapshot?
    let snapshots: [WindowSnapshot]
    var participants: [String: HandleResizeParticipant]
    var boundaries: [HandleResizeBoundary]
}

struct LayoutSession {
    var groupID: SnapGroupID? = nil
    let excludedCandidateIDs: Set<String>
    let displayID: CGDirectDisplayID?
    var layoutZones: [SnapZone]
    var occupiedZones: [SnapZone: String]

    init(
        groupID: SnapGroupID? = nil,
        excludedCandidateIDs: Set<String> = [],
        displayID: CGDirectDisplayID? = nil,
        layoutZones: [SnapZone],
        occupiedZones: [SnapZone: String]
    ) {
        self.groupID = groupID
        self.excludedCandidateIDs = excludedCandidateIDs
        self.displayID = displayID
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

enum MultiMemberReplacementKind: Equatable {
    case partitionBoundary
    case fullGroupCover
}

struct MultiMemberReplacementPlan {
    let targetGroupID: SnapGroupID
    let targetZonesByMemberID: [String: SnapZone]
    let incomingZone: SnapZone
    let displacedMemberIDs: Set<String>
    let retainedMemberIDs: Set<String>
    let kind: MultiMemberReplacementKind
}

struct SnapPlacementContext {
    let targetGroupID: SnapGroupID?
    let departingGroupID: SnapGroupID?
    let memberIDs: Set<String>
    let excludedAssistCandidateIDs: Set<String>
    let displayID: CGDirectDisplayID
    let multiMemberReplacementPlan: MultiMemberReplacementPlan?

    init(
        targetGroupID: SnapGroupID?,
        departingGroupID: SnapGroupID?,
        memberIDs: Set<String>,
        excludedAssistCandidateIDs: Set<String>,
        displayID: CGDirectDisplayID,
        multiMemberReplacementPlan: MultiMemberReplacementPlan? = nil
    ) {
        self.targetGroupID = targetGroupID
        self.departingGroupID = departingGroupID
        self.memberIDs = memberIDs
        self.excludedAssistCandidateIDs = excludedAssistCandidateIDs
        self.displayID = displayID
        self.multiMemberReplacementPlan = multiMemberReplacementPlan
    }
}

enum ExplicitGroupDepartureReason: Equatable {
    case nativeResizeDeparture
    case userDragDeparture
    case explicitDetach
    case confirmedConstraintRejection
    case confirmedMemberClosure
    case confirmedSpaceSeparation
    case replacementDisplacement
    case failedSpaceMigration
}

struct StagedGroupDeparture {
    let draggedIdentity: String
    let memberIDs: Set<String>
    let retiredGroupIDs: Set<SnapGroupID>
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
    let cgWindowID: CGWindowID?
    let initialWindowServerFrame: CGRect?
    let departure: ExplicitGroupDepartureSnapshot?
}

enum SnapEntryEdge: Equatable {
    case left, right, top, bottom
}

enum DisplayTransitionPolicy {
    static func sharedEntryEdge(
        from oldFrame: CGRect,
        to newFrame: CGRect,
        at point: CGPoint,
        tolerance: CGFloat = 2
    ) -> SnapEntryEdge? {
        let verticalOverlap = min(oldFrame.maxY, newFrame.maxY)
            - max(oldFrame.minY, newFrame.minY)
        let horizontalOverlap = min(oldFrame.maxX, newFrame.maxX)
            - max(oldFrame.minX, newFrame.minX)

        if verticalOverlap > 0 {
            if abs(oldFrame.maxX - newFrame.minX) <= tolerance {
                return .left
            }
            if abs(oldFrame.minX - newFrame.maxX) <= tolerance {
                return .right
            }
        }
        if horizontalOverlap > 0 {
            if abs(oldFrame.maxY - newFrame.minY) <= tolerance {
                return .bottom
            }
            if abs(oldFrame.minY - newFrame.maxY) <= tolerance {
                return .top
            }
        }
        return nil
    }
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

    static func modeAfterSystemSelectionSupersedesAutomatic(
        _ mode: GroupForegroundMode
    ) -> GroupForegroundMode {
        mode == .automatic ? .disabled : mode
    }
}

struct OwnedForegroundMutation {
    let generation: Int
    let groupID: SnapGroupID
    let memberIdentities: Set<String>
    let memberSelections: Set<WindowServerSelectionSnapshot>
}

struct MissionControlProxyActivationState: Equatable {
    let groupID: SnapGroupID
    let generation: Int
    let memberIDs: Set<String>
    let preferredMemberID: String
}

struct MissionControlActiveSpaceCleanupDecision: Equatable {
    let preservedProxyGroupIDs: Set<SnapGroupID>
    let preservesProxyActivation: Bool
}

enum MissionControlActiveSpaceCleanupPolicy {
    static func decision(
        confirmationOwnerGroupID: SnapGroupID?,
        activationOwnerGroupID: SnapGroupID?,
        migrationPresentationIsOwned: Bool
    ) -> MissionControlActiveSpaceCleanupDecision {
        // Migration ownership is deliberately observed but does not enter the
        // preserved set. Its capture/observer/transport line survives through
        // separate ownership, while normal Active Space cleanup still retires
        // unselected Proxy presentation.
        _ = migrationPresentationIsOwned
        return MissionControlActiveSpaceCleanupDecision(
            preservedProxyGroupIDs: Set(
                [confirmationOwnerGroupID, activationOwnerGroupID]
                    .compactMap { $0 }
            ),
            preservesProxyActivation: activationOwnerGroupID != nil
        )
    }
}

struct GroupSpaceMigrationForegroundIntent: Equatable {
    let groupID: SnapGroupID
    let memberIDs: Set<String>
    let preferredMemberID: String
    let sequence: UInt64
    var migrationCompleted: Bool
}

enum GroupSpaceMigrationForegroundIntentPolicy {
    static func survivesTerminalState(
        _ state: GroupSpaceMigrationTerminalState
    ) -> Bool {
        state == .completed
    }

    static func orderedCompletedIntents(
        _ intents: [GroupSpaceMigrationForegroundIntent]
    ) -> [GroupSpaceMigrationForegroundIntent] {
        intents
            .filter(\.migrationCompleted)
            .sorted { lhs, rhs in
                if lhs.sequence == rhs.sequence {
                    return lhs.groupID.rawValue.uuidString
                        < rhs.groupID.rawValue.uuidString
                }
                return lhs.sequence < rhs.sequence
            }
    }

    static func followerRaiseOrder(
        frontToBackMemberIDs: [String],
        preferredMemberID: String
    ) -> [String] {
        Array(
            frontToBackMemberIDs
                .filter { $0 != preferredMemberID }
                .reversed()
        )
    }
}

enum MissionControlProxyActivationRetryPolicy {
    static let maximumAttempts = 20

    static func allowsAnotherPass(completedAttempts: Int) -> Bool {
        completedAttempts < maximumAttempts
    }
}

enum MissionControlVisualHandoffPolicy {
    // This is a liveness ceiling, not a fixed delay. The first whole-group
    // ordering pass has already run before any observation is deferred.
    static let maximumSuppressedRepeatOrderingObservations =
        MissionControlProxyActivationRetryPolicy.maximumAttempts
    static let maximumUnsettledDesktopVerificationDeferrals = 1

    static func shouldSuppressRepeatedOrdering(
        transformIsObserved: Bool,
        successfulOrderingPassExists: Bool,
        completedPassiveObservations: Int
    ) -> Bool {
        transformIsObserved
            && successfulOrderingPassExists
            && completedPassiveObservations
                < maximumSuppressedRepeatOrderingObservations
    }

    static func shouldDeferUnsettledDesktopVerification(
        transformIsObserved: Bool,
        successfulOrderingPassExists: Bool,
        orderingIsVerified: Bool,
        completedDeferrals: Int
    ) -> Bool {
        !transformIsObserved
            && successfulOrderingPassExists
            && !orderingIsVerified
            && completedDeferrals
                < maximumUnsettledDesktopVerificationDeferrals
    }
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
                stopAssistLayoutModifierMonitoring()
                overlay.hide()
                picker.hide()
                virtualResizeOverlay.hideAll()
                resizeHandleOverlay.hideAll()
                missionControlGroupProxyController.hideAll()
                groupSpaceMigrationReservationShadowObserver.resetAll()
                resetGroupSpaceMigrationForegroundIntents()
                groupSpaceMigrationLine.controllerStateDidChange()
                cancelHandleResize(restoreOriginalFrames: true)
                resetDragState()
                activeSession = nil
                activeWindowObserver.stop()
                foregroundSelectionMonitor.invalidateBaseline()
            } else if oldValue != isEnabled {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.foregroundSelectionMonitor.invalidateBaseline()
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
    lazy var permissionConstraintMeasurementEngine =
        ConstraintMeasurementEngine(windowService: windowService)
    let permissionConstraintMeasurementProgressPanel =
        ConstraintMeasurementProgressPanel()
    var permissionConstraintMeasurementIsActive = false
    let appConstraintRegistry = AppConstraintRegistry.shared
    let appConstraintIdentityResolver = AppConstraintIdentityResolver()
    let overlay = OverlayPanel()
    let picker = WindowPickerPanel()
    let virtualResizeOverlay = VirtualResizeOverlay()
    let resizeHandleOverlay = ResizeHandleOverlay()
    let missionControlGroupProxyController = MissionControlGroupProxyController()
    let groupSpaceMigrationReservationShadowPresenter =
        GroupSpaceMigrationReservationShadowPresenter()
    lazy var groupSpaceMigrationReservationShadowObserver =
        GroupSpaceMigrationReservationShadowObserver(
            presenter: groupSpaceMigrationReservationShadowPresenter,
            isObservationAllowed: { [weak self] in
                self?.groupSpaceMigrationReservationShadowObservationIsAllowed
                    == true
            },
            pointerButtonIsDown: {
                CGEventSource.buttonState(
                    .combinedSessionState,
                    button: .left
                )
            },
            geometrySampleProvider: { [weak self] baselines in
                self?.groupSpaceMigrationReservationShadowObservationSample(
                    baselines: baselines
                )
                    ?? GroupSpaceMigrationReservationShadowObservationSample(
                        state: .unresolved,
                        windowServerSnapshot: []
                    )
            },
            exitProbeProvider: { [weak self] baselines in
                self?.groupSpaceMigrationReservationShadowExitProbe(
                    baselines: baselines
                )
                    ?? GroupSpaceMigrationReservationShadowExitProbeSample(
                        state: .unresolved,
                        sentinelFrames: [:]
                    )
            }
        )
    let windowSpaceBackend = SkyLightWindowSpaceBackend()
    var onGroupSpaceMigrationAPIUnavailable:
        ((GroupSpaceMigrationAPIUnavailableNotice) -> Void)?
    lazy var groupSpaceMigrationLine = GroupSpaceMigrationLine(
        host: self,
        observationPort: windowSpaceBackend,
        transportPort: windowSpaceBackend
    )
    private var assistLayoutModifierMonitorTimer: Timer?
    private var observedAssistLayoutModifierIsPressed: Bool?
    let activeWindowObserver = ActiveWindowObserver()
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
    var isControllerRunning = false
    lazy var foregroundSelectionMonitor = ForegroundSelectionMonitor(
        snapshotProvider: { [weak self] in
            self?.windowService.windowServerSelectionSnapshot()
        },
        changeHandler: { [weak self] selection in
            self?.handleForegroundSelectionFallbackChange(selection)
        }
    )
    private var lastInteractionAt = Date()
    private let assistTimeout: TimeInterval = 30
    var activeTarget: SnapTarget?

    var pendingDragWindow: ManagedWindow?
    var pendingDragWindowFrame: CGRect?
    var pendingDragWindowServerFrame: CGRect?
    var pendingDragCurrentWindowServerFrame: CGRect?
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
            let affectedGroupIDs = Set(removedIDs.compactMap {
                explicitGroupStore.group(containing: $0)?.id
            })
            for groupID in affectedGroupIDs {
                missionControlGroupProxyController.hide(groupID: groupID)
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
    var groupPresentationTransitionLeasesByGroupID:
        [SnapGroupID: GroupPresentationTransitionLease] = [:]
    var groupPresentationRecoveryGeneration = 0
    var groupPresentationRecoveryChecksAreScheduled = false
    private var displayTopologyGeneration = 0
    var connectedLayoutPlacementCount: Int {
        explicitGroupStore.connectedMemberCount
    }
    var detachedConnections: Set<SplitConnectionKey> = []
    var restoreFrames: [String: CGRect] = [:]
    var activeSession: LayoutSession?
    var isAssistPlacementPending = false
    // Registration, proxy rebuilding and assist presentation must commit as a
    // single visual transaction. Otherwise observers can render the temporary
    // one-window state between those steps and produce a visible flash.
    var isSnapPlacementInProgress = false
    var isSnapRollbackActive = false
    var snapPlacementInteractionGeneration: Int?
    var activeSnapPlacementContext: SnapPlacementContext?
    var interactionGeneration = 0
    var pendingPlacementSnapshots: [String: WindowSnapshot] = [:]
    var inFlightPlacementIDs: Set<String> = []
    var handleResizeSession: HandleResizeSession?
    var isHandleResizeFinalizing = false
    var isHandleResizeRollbackActive = false
    var finalizingHandleResizeSession: HandleResizeSession?
    var baseResizeHandleDescriptors: [ResizeHandleDescriptor] = []
    var lastPresentableResizeHandleDescriptors: [ResizeHandleDescriptor] = []
    var quarantinedResizeHandleIDs = Set<String>()
    var lastHandleOcclusionRefreshAt: TimeInterval = 0
    let handleOcclusionRefreshInterval: TimeInterval = 1.0 / 20.0
    var handleOcclusionFailureCountsByDescriptorID: [String: Int] = [:]
    var handlePresentationGeneration = 0
    var scheduledHandleOcclusionRetryGeneration: Int?
    var handleGeometryRetryGeneration = 0
    var scheduledHandleGeometryRetryGeneration: Int?
    var handleGeometryFailureCountsByGroupID: [SnapGroupID: Int] = [:]
    var handleLivenessFailureCountsByGroupID: [SnapGroupID: Int] = [:]
    var handleLivenessRetryGeneration = 0
    var scheduledHandleLivenessRetryGeneration: Int?
    var hasValidatedCurrentHandleGeometry = false
    let maximumImmediateHandleOcclusionFailures = 6
    var groupRaiseGeneration = 0
    var pendingGroupRaiseWorkItem: DispatchWorkItem?
    var deferredPlainClickPoint: CGPoint?
    var deferredSelectionExpectedPID: pid_t?
    var hasDeferredSelectionSignal = false
    var activeMissionControlProxyActivation: MissionControlProxyActivationState?
    var groupSpaceMigrationForegroundIntents:
        [SnapGroupID: GroupSpaceMigrationForegroundIntent] = [:]
    var groupSpaceMigrationForegroundIntentSequence: UInt64 = 0
    var groupSpaceMigrationForegroundFlushGeneration = 0
    var pendingGroupSpaceMigrationForegroundWorkItem: DispatchWorkItem?
    var missionControlSelectionTransactionIsActive: Bool {
        activeMissionControlProxyActivation != nil
            || missionControlGroupProxyController
                .hasPendingSelectionConfirmation
            || groupSpaceMigrationLine.ownsPresentationTransaction
    }
    let groupRaiseSettleDelay: TimeInterval = 0.05
    let groupRaiseVerificationDelay: TimeInterval = 0.06
    let maximumGroupRaiseAttempts = 2
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
    var groupSpaceSeparationEvidenceByGroupID:
        [SnapGroupID: GroupDegradationEvidence] = [:]
    var directGroupSpaceSeparationEvidenceByGroupID:
        [SnapGroupID: DirectGroupSpaceSeparationEvidence] = [:]
    var groupSpaceSeparationObservationEpoch: UInt64 = 0
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
    var isConstraintMeasurementActive = false
    var isConstraintPermissionPromptActive = false
    var isRestoreTransactionActive = false

    var isApplicationInteractionSuppressed: Bool {
        ApplicationInteractionSuppressionPolicy.isSuppressed(
            applicationUIVisible: isApplicationUIVisible,
            constraintMeasurementActive: isConstraintMeasurementActive,
            constraintPermissionPromptActive: isConstraintPermissionPromptActive,
            restoreTransactionActive: isRestoreTransactionActive
        )
    }

    var canRefreshPresentationAfterAsyncTransaction: Bool {
        isEnabled && isControllerRunning && !isApplicationInteractionSuppressed
    }

    var groupSpaceMigrationFeatureIsEnabled: Bool {
        settings.missionControlGroupMigrationEnabled
    }

    var groupSpaceMigrationRuntimeStatus: GroupSpaceMigrationRuntimeStatus {
        groupSpaceMigrationLine.runtimeStatus
    }

    var groupSpaceMigrationCanMonitor: Bool {
        isEnabled
            && isControllerRunning
            && isUserSessionActive
            && settings.linkedResizeEnabled
            && !isApplicationInteractionSuppressed
            && !isSnapPlacementInProgress
            && !isAssistPlacementPending
            && activeSession == nil
            && handleResizeSession == nil
            && !isHandleResizeFinalizing
            && manualResizeWindow == nil
            && pendingDragWindow == nil
            && dragWindow == nil
            && stagedGroupDeparture == nil
    }

    var groupSpaceMigrationCanBegin: Bool {
        groupSpaceMigrationCanMonitor
            && activeMissionControlProxyActivation == nil
            && !missionControlGroupProxyController
                .hasPendingSelectionConfirmation
    }
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
            [weak self] groupID, presentedMemberIDs in
            self?.groupSpaceMigrationLine.cancelMonitoring(groupID: groupID)
            self?.activateExplicitGroupFromMissionControlProxy(
                groupID: groupID,
                presentedMemberIDs: presentedMemberIDs
            )
        }
        missionControlGroupProxyController.onSelectQueuedMigrationGroup = {
            [weak self] groupID, presentedMemberIDs in
            self?.recordGroupSpaceMigrationForegroundIntent(
                groupID: groupID,
                presentedMemberIDs: presentedMemberIDs
            )
        }
        missionControlGroupProxyController.onSelectionConfirmationTerminated = {
            [weak self] in
            guard let self else { return }
            self.discardDeferredForegroundSignals()
            self.refreshResizeHandles()
            self.scheduleGroupSpaceMigrationForegroundFlushIfReady()
        }
        missionControlGroupProxyController.currentTransitionAuthorization = {
            [weak self] groupID in
            self?.missionControlTransitionIsCurrentlyObserved(groupID: groupID)
                ?? false
        }
        missionControlGroupProxyController.selectionConfirmationIsAllowed = {
            [weak self] groupID in
            guard let self else { return false }
            return !self.groupSpaceMigrationLine
                .shouldPreferMigrationOverProxySelection(groupID: groupID)
        }
        missionControlGroupProxyController.queuedMigrationSelectionIsAllowed = {
            [weak self] groupID in
            self?.groupSpaceMigrationLine
                .presentationIsFrozenForQueuedMigration(groupID: groupID)
                ?? false
        }
        missionControlGroupProxyController.onPreviewCacheReady = { [weak self] in
            guard let self, self.canRefreshPresentationAfterAsyncTransaction else {
                return
            }
            // Apply a successful derived preview promptly on the normal desktop so
            // the first Mission Control entry does not wait for the 1 Hz watchdog.
            // refreshMissionControlGroupProxies() owns transform preservation and
            // will leave the cache debt pending if Mission Control is already moving.
            self.refreshMissionControlGroupProxies()
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
        reconcileAppConstraintLifecycle()
        startRecoveryTimer()
        updateSelectionMonitoringState()
        activeWindowObserver.observeFrontmostApplication()
        refreshResizeHandles()
    }

    func stop() {
        groupSpaceMigrationLine.shutdown()
        isControllerRunning = false
        permissionConstraintMeasurementProgressPanel.dismiss()
        if permissionConstraintMeasurementIsActive {
            permissionConstraintMeasurementIsActive = false
            permissionConstraintMeasurementEngine.cancel { [weak self] _ in
                self?.isConstraintMeasurementActive = false
            }
        }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        eventMonitorReadinessGeneration &+= 1
        eventMonitorReadinessChecksAreScheduled = false
        stopEscapeMonitoring()
        stopAssistLayoutModifierMonitoring()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        defaultObservers.forEach { NotificationCenter.default.removeObserver($0) }
        defaultObservers.removeAll()
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        foregroundSelectionMonitor.stop()
        closeAutomaticForegroundModes()
        activeWindowObserver.stop()
        invalidatePendingSelectionRaise()
        invalidatePendingOperations()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll(clearPreviewCache: true)
        groupSpaceMigrationReservationShadowObserver.resetAll()
        resetGroupSpaceMigrationForegroundIntents()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
        liveResizeScheduler.cancelAll()
        resetDragState()
        activeSession = nil
    }

    func reset() {
        guard !isConstraintMeasurementActive,
              !isConstraintPermissionPromptActive,
              !isRestoreTransactionActive else { return }
        isEnabled = true
        groupSpaceMigrationLine.resetState()
        snapshotTransactions.removeAll()
        lockedPlacements.removeAll()
        explicitGroupStore.clear()
        groupForegroundModes.removeAll()
        directGroupSpaceSeparationEvidenceByGroupID.removeAll()
        detachedConnections.removeAll()
        inFlightPlacementIDs.removeAll()
        restoreFrames.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        stopAssistLayoutModifierMonitoring()
        resetSideDwellState()
        invalidatePendingOperations()
        resetDragState()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll()
        groupSpaceMigrationReservationShadowObserver.resetAll()
        resetGroupSpaceMigrationForegroundIntents()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
        cancelHandleResize(restoreOriginalFrames: true)
    }

    func restoreLast() {
        guard !isConstraintMeasurementActive,
              !isConstraintPermissionPromptActive,
              !isRestoreTransactionActive,
              !isSnapPlacementInProgress,
              !isAssistPlacementPending,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              dragWindow == nil,
              pendingDragWindow == nil,
              stagedGroupDeparture == nil else { return }

        var target: (index: Int, transaction: SnapshotTransaction)?
        for index in snapshotTransactions.indices.reversed() {
            let transaction = snapshotTransactions[index]
            var sawUnknown = false
            var sawMissing = false
            var availableCount = 0

            for snapshot in transaction.snapshots {
                switch windowService.refreshedPersistedWindow(
                    element: snapshot.element,
                    pid: snapshot.pid,
                    expectedStableIdentity: snapshot.stableIdentity,
                    cgWindowID: nil,
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                ) {
                case .available:
                    availableCount += 1
                case .missing:
                    sawMissing = true
                case .unknown:
                    sawUnknown = true
                }
            }

            // The newest unresolved transaction remains authoritative. Do not
            // skip it and restore an older operation from incomplete evidence.
            if sawUnknown { return }

            if sawMissing {
                // A multi-window restore can no longer satisfy its complete
                // semantic postcondition when any required member is confirmed
                // missing. Retire only the impossible snapshot transaction;
                // restore does not become a structural group-departure owner.
                snapshotTransactions.remove(at: index)
                if availableCount > 0 { return }
                continue
            }

            guard availableCount == transaction.snapshots.count else { return }
            target = (index, transaction)
            break
        }

        guard let target else { return }
        invalidatePendingOperations(
            rollbackPendingPlacements: true,
            finalizeStagedDeparture: false
        )

        var resolvedWindows: [String: ManagedWindow] = [:]
        for snapshot in target.transaction.snapshots {
            switch windowService.refreshedPersistedWindow(
                element: snapshot.element,
                pid: snapshot.pid,
                expectedStableIdentity: snapshot.stableIdentity,
                cgWindowID: nil,
                messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
            ) {
            case .available(let window):
                resolvedWindows[snapshot.stableIdentity] = window
            case .missing, .unknown:
                return
            }
        }
        guard resolvedWindows.count == target.transaction.snapshots.count else {
            return
        }

        let beforeRestore = target.transaction.snapshots.compactMap { snapshot
            -> WindowSnapshot? in
            guard let window = resolvedWindows[snapshot.stableIdentity] else {
                return nil
            }
            return windowService.snapshot(window)
        }
        guard beforeRestore.count == target.transaction.snapshots.count else {
            return
        }

        isRestoreTransactionActive = true
        let generation = interactionGeneration
        var pending = target.transaction.snapshots.count
        var allSucceeded = true

        func rollbackRestoreAttempt() {
            // Restore itself is a multi-window transaction. If any member
            // fails, or another generation supersedes the command while its
            // observations are settling, return every mutated member to the
            // state that existed when this restore command began. Structural
            // state remains untouched until a complete successful commit.
            var rollbackPending = beforeRestore.count
            guard rollbackPending > 0 else {
                isRestoreTransactionActive = false
                return
            }
            for snapshot in beforeRestore {
                windowService.restore(snapshot) { [weak self] _ in
                    guard let self else { return }
                    rollbackPending -= 1
                    if rollbackPending == 0 {
                        self.isRestoreTransactionActive = false
                        if self.isEnabled,
                           self.isControllerRunning,
                           !self.isApplicationInteractionSuppressed {
                            self.refreshResizeHandles()
                        }
                    }
                }
            }
        }

        func finishRestoreAttempt() {
            guard pending == 0 else { return }
            guard interactionGeneration == generation, allSucceeded else {
                rollbackRestoreAttempt()
                return
            }

            if snapshotTransactions.indices.contains(target.index),
               snapshotTransactions[target.index].snapshots.count
                    == target.transaction.snapshots.count,
               zip(
                   snapshotTransactions[target.index].snapshots,
                   target.transaction.snapshots
               ).allSatisfy({ pair in
                   pair.0.stableIdentity == pair.1.stableIdentity
                       && pair.0.frame == pair.1.frame
                       && CFEqual(pair.0.element, pair.1.element)
               }) {
                snapshotTransactions.remove(at: target.index)
            } else if let currentIndex = snapshotTransactions.lastIndex(where: { candidate in
                candidate.snapshots.count == target.transaction.snapshots.count
                    && zip(candidate.snapshots, target.transaction.snapshots)
                        .allSatisfy { pair in
                            pair.0.stableIdentity == pair.1.stableIdentity
                                && pair.0.frame == pair.1.frame
                                && CFEqual(pair.0.element, pair.1.element)
                        }
            }) {
                snapshotTransactions.remove(at: currentIndex)
            }

            for restored in target.transaction.snapshots {
                if !dissolveExplicitGroupForUserDeparture(
                    containing: restored.stableIdentity
                ) {
                    lockedPlacements.removeValue(forKey: restored.stableIdentity)
                    removeConnections(for: restored.stableIdentity)
                }
                restoreFrames.removeValue(forKey: restored.stableIdentity)
            }
            isRestoreTransactionActive = false
            if isEnabled, isControllerRunning, !isApplicationInteractionSuppressed {
                refreshResizeHandles()
            }
        }

        for snapshot in target.transaction.snapshots {
            windowService.restore(snapshot) { [weak self] succeeded in
                guard let self, self.isRestoreTransactionActive else { return }
                // A stop/disable or other superseding transaction may advance
                // the controller generation while the AX restore observations
                // are still settling. Count every callback so the exclusive
                // restore owner can finish, but force the transaction down its
                // complete rollback path instead of stranding the active flag.
                if self.interactionGeneration != generation {
                    allSucceeded = false
                }
                allSucceeded = allSucceeded && succeeded
                pending -= 1
                finishRestoreAttempt()
            }
        }
    }

    func clearLocks() {
        guard !isConstraintMeasurementActive,
              !isConstraintPermissionPromptActive,
              !isRestoreTransactionActive else { return }
        invalidatePendingOperations()
        resetDragState()
        lockedPlacements.removeAll()
        explicitGroupStore.clear()
        groupForegroundModes.removeAll()
        detachedConnections.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        stopAssistLayoutModifierMonitoring()
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
            suppressPresentationForApplicationOwnedWindowMutation()
        } else if !isApplicationInteractionSuppressed {
            refreshResizeHandles()
        }
    }

    @discardableResult
    func beginConstraintMeasurement() -> Bool {
        guard !isConstraintMeasurementActive,
              !isConstraintPermissionPromptActive,
              !isRestoreTransactionActive,
              !isSnapPlacementInProgress,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              manualResizeWindow == nil,
              pendingDragWindow == nil,
              dragWindow == nil,
              activeSession == nil,
              !isAssistPlacementPending else {
            return false
        }
        isConstraintMeasurementActive = true
        suppressPresentationForApplicationOwnedWindowMutation()
        return true
    }

    func endConstraintMeasurement() {
        guard isConstraintMeasurementActive else { return }
        isConstraintMeasurementActive = false
        if isEnabled, isControllerRunning, !isApplicationInteractionSuppressed {
            // The measurement engine calls this only after its final restore
            // (including cancel-restore) has completed. Rebuild from current
            // evidence; any unresolved state remains ordinary Recovery debt.
            refreshResizeHandles()
        }
    }

    @discardableResult
    func beginConstraintPermissionPrompt() -> Bool {
        guard !isConstraintPermissionPromptActive,
              !isConstraintMeasurementActive,
              !isRestoreTransactionActive else { return false }
        isConstraintPermissionPromptActive = true
        // A constraint decision supersedes Assist: after the modal closes the
        // previous candidates are stale because the confirmed rejection has
        // already changed eligibility/structure. Withdraw both selectable and
        // backdrop-only panels before NSAlert enters its modal run loop.
        isAssistPlacementPending = false
        activeSession = nil
        stopEscapeMonitoring()
        stopAssistLayoutModifierMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        suppressPresentationForApplicationOwnedWindowMutation()
        return true
    }

    func endConstraintPermissionPrompt(
        refreshPresentation: Bool = true
    ) {
        guard isConstraintPermissionPromptActive else { return }
        isConstraintPermissionPromptActive = false
        if refreshPresentation,
           isEnabled,
           isControllerRunning,
           !isApplicationInteractionSuppressed,
           !isSnapPlacementInProgress,
           !isAssistPlacementPending,
           handleResizeSession == nil,
           !isHandleResizeFinalizing {
            // A snap/resize transaction that opened the modal still owns
            // presentation until its rollback/finalization completes. Do not
            // rebuild handles/proxies in the one-frame gap after runModal().
            refreshResizeHandles()
        }
    }

    private func suppressPresentationForApplicationOwnedWindowMutation() {
        invalidatePendingGroupRaise()
        invalidatePendingSelectionRaise()
        missionControlGroupProxyController.hideAll()
        if handleResizeSession != nil {
            cancelHandleResize(restoreOriginalFrames: true)
        } else {
            resizeHandleOverlay.hideAll()
        }
    }

    func snapFocusedWindow(to zone: SnapZone) {
        guard !isApplicationInteractionSuppressed,
              handleResizeSession == nil, !isHandleResizeFinalizing else { return }
        guard isEnabled, ensurePermission(),
              let focusedWindow = windowService.focusedWindow(
                  messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
              ) else { return }
        let window = windowService.resolvingWindowServerIdentity(focusedWindow)
        guard let selectedWindowID = window.cgWindowID,
              let selection = windowService.windowServerSelectionSnapshot(),
              selection.pid == window.pid,
              selection.windowID == selectedWindowID,
              windowService.canMoveAndResize(
                  window,
                  messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
              ),
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
        stopAssistLayoutModifierMonitoring()
        snap(
            window,
            to: zone,
            on: screen,
            continueAssist: true,
            frontmostGroupIDsBeforePlacement: commandPlacementBaseline
        )
    }

    private static func eventHandlerWindowID(from event: NSEvent) -> CGWindowID? {
        guard let cgEvent = event.cgEvent else { return nil }
        let rawValue = cgEvent.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        guard rawValue > 0,
              rawValue <= Int64(UInt32.max) else { return nil }
        return CGWindowID(rawValue)
    }

    private func observeReservationShadowPointerEvent(
        _ eventType: NSEvent.EventType
    ) {
        switch eventType {
        case .leftMouseDown, .leftMouseDragged:
            groupSpaceMigrationReservationShadowObserver
                .pointerInteractionDidBegin()
        case .leftMouseUp:
            groupSpaceMigrationReservationShadowObserver
                .pointerInteractionDidEnd()
        default:
            break
        }
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
                let observedEventHandlerWindowID = Self.eventHandlerWindowID(
                    from: event
                )
                if Thread.isMainThread {
                    self?.observeReservationShadowPointerEvent(event.type)
                    self?.handle(
                        event,
                        observedMouseLocation: observedMouseLocation,
                        observedEventHandlerWindowID: observedEventHandlerWindowID
                    )
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.observeReservationShadowPointerEvent(event.type)
                        self?.handle(
                            event,
                            observedMouseLocation: observedMouseLocation,
                            observedEventHandlerWindowID: observedEventHandlerWindowID
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
                self?.observeReservationShadowPointerEvent(event.type)
                if self?.resizeHandleOverlay.owns(window: event.window) == true
                    || self?.missionControlGroupProxyController.owns(
                        window: event.window
                    ) == true {
                    return event
                }
                self?.handle(
                    event,
                    observedMouseLocation: NSEvent.mouseLocation,
                    observedEventHandlerWindowID: Self.eventHandlerWindowID(
                        from: event
                    )
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
            self.groupSpaceMigrationLine.cancelForEnvironmentInvalidation()
            self.cancelAssist()
            self.missionControlGroupProxyController.hideAll()
            self.groupSpaceMigrationReservationShadowObserver.resetAll()
            self.resetGroupSpaceMigrationForegroundIntents()
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
            self.groupSpaceMigrationLine.cancelForEnvironmentInvalidation()
            self.missionControlGroupProxyController
                .setPreviewCaptureSuspended(true)
            self.updateSelectionMonitoringState()
            self.cancelAssist()
            self.missionControlGroupProxyController.hideAll()
            self.groupSpaceMigrationReservationShadowObserver.resetAll()
            self.resetGroupSpaceMigrationForegroundIntents()
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
            self.missionControlGroupProxyController
                .setPreviewCaptureSuspended(false)
            self.updateSelectionMonitoringState()
            self.missionControlGroupProxyController.hideAll()
            self.groupSpaceMigrationReservationShadowObserver.resetAll()
            self.resetGroupSpaceMigrationForegroundIntents()
            self.lastGroupWindowServerEvidenceByIdentity.removeAll()
            self.resetGroupPresentationTransitionRecovery()
            self.refreshMissionControlGroupProxies()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileAppConstraintLifecycle()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileAppConstraintLifecycle()
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
            // Activation is an early Mission Control-exit hint in many paths,
            // but it is not authoritative Mission Control state. Hide the
            // passive reservation shadow immediately and let the dedicated
            // observer re-arm it only after fresh transform evidence.
            self.groupSpaceMigrationReservationShadowObserver
                .suppressPresentationImmediately()
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
            self?.handleDisplayTopologyChange()
        })

        defaultObservers.append(defaultCenter.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Preview authorization is independent of presentation ownership.
            // Assist, Snap or settings UI may suppress the normal proxy update,
            // but OFF must still revoke every queued capture immediately.
            self.missionControlGroupProxyController.setPreviewsEnabled(
                self.settings.windowPreviewsEnabled
            )
            self.groupSpaceMigrationLine.settingsDidChange()
            self.missionControlGroupProxyController.hideAll()
            if !self.settings.missionControlGroupMigrationEnabled {
                self.groupSpaceMigrationReservationShadowObserver.resetAll()
                self.resetGroupSpaceMigrationForegroundIntents()
            } else {
                self.groupSpaceMigrationReservationShadowObserver.gateDidChange()
            }
            self.updateSelectionMonitoringState()
            self.updateAssistLayoutModifierMonitoringState()
            if !self.settings.linkedResizeEnabled,
               self.handleResizeSession != nil {
                self.cancelHandleResize(restoreOriginalFrames: true)
            } else if self.handleResizeSession == nil {
                self.refreshResizeHandles()
            }
        })
    }

    func resolveAppConstraintIdentity(
        for window: ManagedWindow
    ) -> (identity: AppConstraintIdentity, displayName: String)? {
        guard let resolved = appConstraintIdentityResolver.resolve(window) else {
            return nil
        }
        appConstraintRegistry.markObservedPresent(
            identity: resolved.identity,
            displayName: resolved.displayName
        )
        return resolved
    }

    private func reconcileAppConstraintLifecycle() {
        for record in appConstraintRegistry.records {
            switch appConstraintIdentityResolver.installationState(
                for: record.identity
            ) {
            case .matching:
                appConstraintRegistry.updateDormant(
                    false,
                    identity: record.identity
                )
            case .confirmedMissingOrReplaced:
                appConstraintRegistry.updateDormant(
                    true,
                    identity: record.identity
                )
            case .unknown:
                // "Cannot confirm" is not uninstall evidence. Preserve the
                // current lifecycle state until matching or confirmed
                // missing/replacement evidence exists.
                continue
            }
        }
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
            // Exact Window Server identity proves this notification came from
            // our own raise. Consume it so Recovery does not replay it.
            foregroundSelectionMonitor.synchronize(to: observedSelection)
            return
        }
        if initialSelection == nil, ownedForegroundMutation != nil {
            // AX focus callbacks contain only a PID and can arrive before the
            // Window Server publishes the window ID changed by our AXRaise.
            // AX identity can reject a same-process external window; when AX
            // has not settled either, let the exact-ID transaction evidence
            // or low-frequency fallback arbitrate.
            switch ForegroundMutationSelectionPolicy
                .processNotificationDisposition(
                    expectedPID: expectedPID,
                    accessibilitySelection: windowService
                        .activeWindowIdentitySnapshot(),
                    mutation: ownedForegroundMutation
                ) {
            case .ownedMutation, .awaitExactWindowIdentity:
                // Window Server may already show a same-PID external window
                // while AX focus/main still reports our old member. Do not
                // advance the fallback baseline here: if AX emits no second
                // notification, Recovery must still observe and classify the
                // exact external Window ID.
                return
            case .externalSelection:
                break
            }
        }
        // This event is now accepted as an external/system selection. Align
        // the fallback only after ownership arbitration so it cannot replay
        // the same event or erase unresolved exact-ID evidence.
        foregroundSelectionMonitor.synchronize(to: observedSelection)
        if missionControlSelectionTransactionIsActive
            || pendingGroupRaiseWorkItem != nil {
            // Application activation and focus can transiently select a
            // same-process window outside the chosen group before the exact
            // preferred surface settles. Keep the signal as observation debt;
            // the Mission Control transaction itself still fails closed unless
            // exact preferred-window identity converges within its finite pass
            // budget.
            deferredSelectionExpectedPID = expectedPID
            hasDeferredSelectionSignal = true
            return
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
        MonitoringLifecyclePolicy.foregroundSelectionLifecycleIsActive(
            controllerIsRunning: isControllerRunning,
            taboraIsEnabled: isEnabled,
            linkedResizeIsEnabled: settings.linkedResizeEnabled,
            connectedWindowRaiseIsEnabled:
                settings.raiseConnectedWindowsOnClick,
            lockedPlacementCount: connectedLayoutPlacementCount,
            userSessionIsActive: isUserSessionActive
        )
            && !isApplicationInteractionSuppressed
            && !isSnapPlacementInProgress
            && handleResizeSession == nil
            && !isHandleResizeFinalizing
            && dragWindow == nil
            && manualResizeWindow == nil
            && !isWindowMoveConfirmed
            && activeSession == nil
            && !isAssistPlacementPending
            && !missionControlSelectionTransactionIsActive
            && !groupSpaceMigrationLine.hasPendingOrActiveTransactions
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
            var selectedWindow = visibleWindows.first(where: {
                $0.pid == nextCandidate.pid
                    && $0.cgWindowID == nextCandidate.windowID
            })
            if selectedWindow == nil,
               let binding = persistedManagedWindowBindings.first(where: {
                   $0.identity.pid == nextCandidate.pid
                       && $0.identity.windowID == nextCandidate.windowID
               }),
               let placement = lockedPlacements[
                   binding.identity.stableIdentity
               ] {
                // Broad AX discovery is presentation-quality evidence only. A
                // stable Window Server selection for a persisted member gets
                // one exact AX resolution before we give up this observation.
                switch windowService.refreshedPersistedWindow(
                    element: placement.element,
                    pid: placement.pid,
                    expectedStableIdentity: placement.stableIdentity,
                    cgWindowID: placement.cgWindowID,
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                ) {
                case .available(let exactWindow):
                    selectedWindow = exactWindow
                case .missing, .unknown:
                    // Exact persisted identity proves which group the system
                    // selected even when AX cannot currently return a usable
                    // element. Close that group's automatic behavior now;
                    // a later successful retry may rearm it only after the
                    // complete-frontmost postcondition is established.
                    setSoloForegroundMode(
                        memberID: binding.identity.stableIdentity
                    )
                    break
                }
            }
            if let selectedWindow {
                var scopedWindows = visibleWindows
                if !scopedWindows.contains(where: {
                    $0.stableIdentity == selectedWindow.stableIdentity
                }) {
                    scopedWindows.append(selectedWindow)
                }
                raiseConnectedGroupForSettledSelection(
                    selectedWindow,
                    selectedWindowID: nextCandidate.windowID,
                    visibleWindows: scopedWindows,
                    generation: generation,
                    completedAttempts: completedAttempts
                )
                return
            }
            // The exact system selection is stable but is not a managed group
            // member. It therefore supersedes every previous automatic grant.
            // Keep trying bounded AX resolution in case a persisted member is
            // temporarily unavailable, but never carry old authorization
            // across the newly proven foreground context.
            closeAutomaticForegroundModes()
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
        // This exact, stable Window Server selection is a new system-level
        // foreground context. Retire every earlier automatic grant before
        // resolving it. The selected group is rearmed below only when this
        // same observation proves that all of its members are frontmost.
        // Solo locks are group-local and must survive unrelated selections.
        closeAutomaticForegroundModes()
        let groupWindows: [ManagedWindow]
        switch connectedSnapGroupResolution(
            for: selectedWindow,
            visibleWindows: visibleWindows
        ) {
        case .connected(let windows):
            groupWindows = windows
        case .indeterminate:
            guard completedAttempts < maximumSelectionSettleAttempts else {
                // Bounded observation exhausted. The exact selected member is
                // known, but complete group geometry is not; retain membership
                // and fail closed into per-member isolation.
                setSoloForegroundMode(
                    memberID: selectedWindow.stableIdentity
                )
                refreshResizeHandles(using: visibleWindows)
                replayDeferredForegroundSignalIfNeeded()
                return
            }
            // Selection is still the same exact Window Server surface, but AX
            // member/geometry evidence is incomplete. Retry observation only;
            // do not translate uncertainty into solo/group structural state.
            scheduleSelectionSettlement(
                expectedPID: selectedWindow.pid,
                candidate: currentSelection,
                stableObservationCount: requiredSelectionStableObservations,
                completedAttempts: completedAttempts + 1,
                generation: generation,
                delay: selectionSettleInterval
            )
            return
        case .confirmedDisconnected:
            // If the selected surface still belongs to a structurally known
            // group, keep that group isolated even though a complete connected
            // geometry cannot currently be resolved. For a non-member this is
            // a no-op; the stale automatic grants were still closed above.
            setSoloForegroundMode(memberID: selectedWindow.stableIdentity)
            refreshResizeHandles(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }

        let frontmostEvaluation = connectedGroupFrontmostEvaluation(groupWindows)
        // AX member resolution and Window Server occlusion capture are
        // synchronous but not atomic with the compositor. Revalidate the exact
        // selected surface immediately before changing authorization so a
        // superseded selection cannot open this group's gate.
        guard let verifiedSelection = windowService
            .windowServerSelectionSnapshot(),
              verifiedSelection.pid == selectedWindow.pid,
              verifiedSelection.windowID == selectedWindowID else {
            refreshResizeHandles(using: visibleWindows)
            replayDeferredForegroundSignalIfNeeded()
            return
        }
        let systemSelectionDisposition = GroupForegroundSelectionPolicy
            .disposition(
                frontmostEvaluation: frontmostEvaluation
            )
        if systemSelectionDisposition == .authorizeAutomaticForeground {
            // Mission Control one-by-one selection and Command-Tab can place
            // every member at the front without expressing Tabora group intent.
            // Once Window Server proves that physical result, opening the gate
            // is safe: no companion is raised by this path, and handle display
            // and future automatic foregrounding share the same postcondition.
            setAutomaticForegroundMode(
                forMemberID: selectedWindow.stableIdentity
            )
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
        // later observation proves the whole group frontmost, or an explicit
        // successful group transaction rearms it. Geometry alone never grants
        // permission.
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
        // Drag, resize, Assist, Space changes, rollback and shutdown all pass
        // through this boundary. Discard their pre-transaction selection so a
        // later 1 Hz fallback cannot reinterpret it as fresh user intent.
        foregroundSelectionMonitor.invalidateBaseline()
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
        // Keep only the Recovery core armed while the login session is
        // inactive. AX census, preview capture and presentation rebuilding are
        // derived desktop work and resume from fresh evidence on activation.
        guard isUserSessionActive else { return }
        activeWindowObserver.observeFrontmostApplication()
        // Explicit constraint measurement owns the external window mutation
        // until its restore completion. Recovery may keep its monitors armed,
        // but it must not re-observe/rebuild presentation from the deliberately
        // displaced measurement geometry in the meantime.
        guard !isConstraintMeasurementActive,
              !isConstraintPermissionPromptActive,
              !isRestoreTransactionActive else { return }

        // Normal focus/click/Mission Control changes arrive through event
        // paths. Reuse this already-existing 1 Hz watchdog only for events the
        // OS did not deliver; no independent high-frequency timer exists.
        pollForegroundSelectionFallback()

        if stagedGroupDeparture != nil,
           pendingDragWindow == nil,
           dragWindow == nil,
           !isWindowMoveConfirmed {
            _ = restoreStagedGroupDepartureIfPossible()
        }

        if handleResizeSession == nil,
           pendingDragWindow == nil,
           dragWindow == nil,
           manualResizeWindow == nil,
           pendingNativeResizeCandidates.isEmpty,
           !unresolvedNativeResizeWasActivated,
           !isWindowMoveConfirmed {
            if !isApplicationInteractionSuppressed,
               !isPreservingGroupPresentationForWindowServerTransform {
                missionControlGroupProxyController
                    .refreshStalePreviewCacheIfNeeded(
                        // The established HOT/COLD lanes retain their normal
                        // Recovery behavior. Only the new resize-settled lane
                        // yields while Assist/Snap owns the shared Window
                        // Server capture capacity.
                        allowsSettledGeometryRefresh:
                            activeSession == nil
                                && !picker.isVisible
                                && !isAssistPlacementPending
                                && !isSnapPlacementInProgress
                    )
            }
            // Liveness is a cheap presentation-only check. It does not perform
            // discovery, so the 1 Hz watchdog can detect an orderOut/cache loss
            // even when the Window Server scene itself did not change.
            if !isPreservingGroupPresentationForWindowServerTransform {
                evaluateHandlePresentationLiveness(
                    expectedDescriptors: lastPresentableResizeHandleDescriptors
                )
            }
            let snapshot = windowService.windowOcclusionSnapshot()
            let signature = SplitLayoutGeometry.recoverySceneSignature(
                for: snapshot,
                managedWindowIDs: Set(lockedPlacements.values.compactMap(\.cgWindowID)),
                interactionRegions: lastValidatedRecoveryInteractionRegions
            )
            let hasPresentationRecoveryDebt =
                signature != lastRecoverySceneSignature
                || !handleGeometryFailureCountsByGroupID.isEmpty
                || !handleOcclusionFailureCountsByDescriptorID.isEmpty
                || !handleLivenessFailureCountsByGroupID.isEmpty
                || !groupPresentationFailureCountsByGroupID.isEmpty
                || missionControlGroupProxyController
                    .hasPresentationRecoveryDebt
            let hasPreviewOnlyDebt = missionControlGroupProxyController
                .hasPendingPreviewCacheRefresh

            switch RecoveryPresentationRefreshPolicy.action(
                hasPresentationRecoveryDebt: hasPresentationRecoveryDebt,
                hasPreviewCacheDebt: hasPreviewOnlyDebt
            ) {
            case .fullPresentationRefresh:
                lastRecoverySceneSignature = signature
                refreshResizeHandles(
                    deferOcclusionRefresh: true,
                    windowServerSnapshot: snapshot
                )
                refreshResizeHandleOcclusion(
                    force: true,
                    using: snapshot
                )
            case .missionControlPreviewOnly:
                // Preview is derived presentation state. Applying a completed
                // cache entry must not rebuild resize geometry/occlusion or
                // create another broad desktop transaction.
                refreshMissionControlGroupProxies(
                    windowServerSnapshot: snapshot
                )
            case .none:
                break
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

        if PointerInteractionOwnershipPolicy.recoveryMayCancelAssist(
            assistSessionActive: activeSession != nil,
            pickerVisible: picker.isVisible,
            assistPlacementPending: isAssistPlacementPending,
            snapPlacementInProgress: isSnapPlacementInProgress
        ) {
            // A selected Assist candidate deliberately hides the picker while
            // snap() owns the atomic placement/rollback transaction. Recovery
            // may retire only an actually orphaned session after that owner is
            // gone; it must not cancel a valid in-flight placement.
            cancelAssist()
            return
        }

        if activeSession != nil,
           Date().timeIntervalSince(lastInteractionAt) >= assistTimeout {
            cancelAssist()
        }
    }

    func setMissionControlPreviewMemoryLimitMiB(_ value: Int) {
        missionControlGroupProxyController.setPreviewCacheByteLimit(
            AppSettings.missionControlPreviewMemoryByteLimit(value)
        )
    }

    func clearMissionControlPreviewCache() {
        missionControlGroupProxyController.clearPreviewCache()
    }

    private func handle(
        _ event: NSEvent,
        observedMouseLocation: CGPoint? = nil,
        observedEventHandlerWindowID: CGWindowID? = nil
    ) {
        guard isEnabled, !isApplicationInteractionSuppressed else { return }
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
            if picker.isVisible && picker.containsScreenPoint(point) {
                // The Assist panel owns this complete pointer sequence. Do not
                // leave a controller mouse-down token that turns its later
                // mouse-up into a desktop click after the panel cancels itself.
                pointerDownLocation = nil
                maximumPointerTravelSinceMouseDown = 0
                return
            }
            pointerDownLocation = point
            maximumPointerTravelSinceMouseDown = 0
            if isAssistPlacementPending {
                cancelAssist()
                return
            }
            dismissAssistPresentationForPointerDown()
            beginPendingDrag(
                at: point,
                eventHandlerWindowID: observedEventHandlerWindowID
            )

        case .leftMouseDragged:
            guard CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                cancelAssist()
                return
            }
            guard activeSession == nil else { return }

            let point = observedMouseLocation ?? NSEvent.mouseLocation
            pendingDragCurrentWindowServerFrame = nil
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
            // A real size delta is stronger evidence than the pointer's
            // approximate edge/title-bar classification. Check every snapped
            // interaction, but use the Window Server prefilter in the native
            // resize path so ordinary streamed-window drags do not AX-poll.
            if trackManualResizeIfNeeded() {
                return
            }
            if !isWindowMoveConfirmed {
                // Ordinary physical movement is much more common than tab
                // detachment. Confirm it first from the exact Window Server
                // surface; only a failed move confirmation is allowed to pay
                // the exceptional detach-resolution cost.
                if !confirmWindowMove(
                    at: point,
                    eventHandlerWindowID: observedEventHandlerWindowID
                ) {
                    guard adoptDetachedWindowIfNeeded(
                        at: point,
                        allowImmediate: false,
                        eventHandlerWindowID: observedEventHandlerWindowID
                    ) else { return }
                }
            } else if !hasWindowActuallyMoved {
                detectActualWindowMovementIfNeeded(at: point)
            }
            handleDrag(at: point)

        case .leftMouseUp:
            let hadControllerPointerDown = pointerDownLocation != nil
            defer {
                pointerDownLocation = nil
                maximumPointerTravelSinceMouseDown = 0
            }
            if isAssistPlacementPending {
                return
            }
            let mousePoint = observedMouseLocation ?? NSEvent.mouseLocation
            let wasPlainClick = hadControllerPointerDown
                && activeSession == nil
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
                handleDrop(
                    at: mousePoint,
                    eventHandlerWindowID: observedEventHandlerWindowID
                )
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

    private func beginPendingDrag(
        at point: CGPoint,
        eventHandlerWindowID: CGWindowID?
    ) {
        // Mouse-down is a Window Server observation first. AX activation can
        // settle later, but any retry must resolve this exact physical surface.
        prepareUnresolvedNativeResizeCandidates(at: point)
        let snapshot = windowService.windowOcclusionSnapshot()
        let bindings = persistedManagedWindowBindings
        guard let evidence = windowService.pointerDragSurfaceEvidence(
            at: point,
            snapshot: snapshot,
            eventHandlerWindowID: eventHandlerWindowID
        ) else {
            pendingDragWindow = nil
            pendingDragWindowFrame = nil
            pendingDragWindowServerFrame = nil
            pendingDragCurrentWindowServerFrame = nil
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
        pendingDragWindowServerFrame = nil
        pendingDragCurrentWindowServerFrame = nil
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
        // Structural native-resize confirmation remains AX-vs-AX. Keep a
        // separate Window Server baseline only for cheap physical move/size
        // prefilters so ordinary streamed-window drags do not synchronously
        // refresh AX on every mouseDragged event.
        pendingDragWindowFrame = window.frame
        pendingDragWindowServerFrame = windowService.windowServerFrame(window)
        pendingDragCurrentWindowServerFrame = nil
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
        stopAssistLayoutModifierMonitoring()
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

    func managedExplicitGroupWindows() -> [ManagedWindow] {
        let groupMemberIDs = explicitGroupStore.groups.reduce(
            into: Set<String>()
        ) { partial, group in
            partial.formUnion(group.memberIDs)
        }
        return windowService.persistedVisibleWindows(
            persistedBindings: persistedManagedWindowBindings,
            stableIDs: groupMemberIDs
        )
    }

    private func makeSnapObservationScene(
        visibleWindows providedWindows: [ManagedWindow]? = nil
    ) -> SnapObservationScene {
        let windowServerObservation = windowService
            .windowOcclusionSnapshotObservation()
        return SnapObservationScene(
            visibleWindows: providedWindows ?? managedVisibleWindows(),
            windowServerSnapshot: windowServerObservation.snapshot,
            windowServerSnapshotCompleteness: windowServerObservation.completeness
        )
    }

    func missionControlActivationWindows(
        memberIDs: Set<String>,
        snapshot: [WindowOcclusionSnapshot]? = nil
    ) -> [ManagedWindow]? {
        windowService.missionControlActivationWindows(
            persistedBindings: persistedManagedWindowBindings,
            memberIDs: memberIDs,
            snapshot: snapshot
        )
    }

    func persistedVisibleWindowsForExactGroupMembers(
        stableIDs: Set<String>
    ) -> [ManagedWindow] {
        windowService.persistedVisibleWindows(
            persistedBindings: persistedManagedWindowBindings,
            stableIDs: stableIDs
        )
    }

    private func windowServerFrontmostEvaluation(
        memberIDs: Set<String>,
        snapshot providedSnapshot: [WindowOcclusionSnapshot]? = nil
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
            snapshot: providedSnapshot ?? windowService.windowOcclusionSnapshot()
        )
    }

    private func adoptDetachedWindowIfNeeded(
        at point: CGPoint,
        allowImmediate: Bool,
        eventHandlerWindowID: CGWindowID? = nil
    ) -> Bool {
        guard let source = sourceDragWindow,
              let candidate = detachedWindowCandidate(
                  following: point,
                  source: source,
                  eventHandlerWindowID: eventHandlerWindowID
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
        pendingDragWindowServerFrame = windowService.windowServerFrame(candidate)
        pendingDragCurrentWindowServerFrame = nil
        pendingDragMousePoint = point
        pendingGrabRatio = grabRatio(at: point, in: candidate.frame)
        pendingRestoreFrame = nil
        pendingDragStartedInLikelyDragRegion = true
        pendingDragStartedNearResizeEdge = false
        dragWindow = candidate
        isWindowMoveConfirmed = true
        hasWindowActuallyMoved = true
        virtualResizeOverlay.hideAll()
        // A newly detached tab/window takes ownership of this physical drag,
        // but that gesture transfer is not evidence that the source window
        // moved, closed, or departed its structural group. The source remains
        // grouped until the normal confirmed move/resize/closure path proves
        // an actual departure. The detached child will join/create a group only
        // through the ordinary snap transaction below.
        stagedGroupDeparture = nil
        // From this point the detached surface owns the original physical
        // mouse gesture. Do not keep consulting the old tab container as the
        // source on later drag events.
        sourceDragWindow = candidate
        return true
    }

    private func detachedWindowCandidate(
        following point: CGPoint,
        source: ManagedWindow,
        eventHandlerWindowID: CGWindowID?
    ) -> ManagedWindow? {
        // Detach adoption is exceptional. Do not AX-hit-test/fetch focus on
        // every ordinary mouseDragged event: a streamed application can make
        // those synchronous messages slow enough to starve snap detection.
        // First require physical evidence for a same-process window surface
        // that did not exist at drag start. Only then resolve AX identity.
        let snapshot = windowService.windowOcclusionSnapshot()
        let routedEvidence = windowService.pointerDragSurfaceEvidence(
            at: point,
            snapshot: snapshot,
            eventHandlerWindowID: eventHandlerWindowID
        )
        let routedIsNewSameProcess = routedEvidence.map { evidence in
            evidence.selection.pid == source.pid
                && !windowServerIDsAtDragStart.contains(
                    evidence.selection.windowID
                )
        } ?? false
        // During tab detach, Quartz can continue routing the physical gesture
        // to the old container for a short period after a new same-process
        // layer-zero surface appears. Query the visual fallback only for that
        // mismatch; ordinary screen-sharing/popup acquisition retains the
        // strict routed-window policy.
        let visualFallback = !routedIsNewSameProcess
            && eventHandlerWindowID != nil
            ? windowService.pointerDragSurfaceEvidence(
                at: point,
                snapshot: snapshot,
                eventHandlerWindowID: nil
            )
            : nil
        let evidence = DetachedWindowSurfaceSelectionPolicy.candidateEvidence(
            routed: routedEvidence,
            visualFallback: visualFallback,
            sourcePID: source.pid,
            windowServerIDsAtDragStart: windowServerIDsAtDragStart,
            eventHandlerWasReported: eventHandlerWindowID != nil
        )
        guard let evidence else { return nil }

        // A detached tab is often the new frontmost Window Server surface
        // before AX promotes it to kAXFocusedWindow. Prefer the exact pointer
        // surface and keep focusedWindow only as a bounded compatibility
        // fallback after the new physical identity has already been proven.
        let candidates = [
            windowService.resolvePointerDragSurface(
                evidence,
                persistedBindings: persistedManagedWindowBindings
            ),
            windowService.focusedWindow(
                messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
            )
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
                moveAndResizeCapability: windowService.moveAndResizeCapability(
                    candidate,
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                ),
                followsPointer: isLikelyDetachedWindow(
                    candidate,
                    following: point
                )
            )
        }
    }

    private func confirmWindowMove(
        at currentMousePoint: CGPoint,
        allowEdgeFallback: Bool = false,
        eventHandlerWindowID: CGWindowID? = nil
    ) -> Bool {
        guard let originalWindow = pendingDragWindow,
              let originalAXFrame = pendingDragWindowFrame,
              let originalMousePoint = pendingDragMousePoint else {
            return false
        }

        let observation: (baseline: CGRect, window: ManagedWindow)
        if let baseline = pendingDragWindowServerFrame,
           let currentPhysicalFrame = pendingDragCurrentWindowServerFrame
                ?? windowService.windowServerFrame(originalWindow) {
            pendingDragCurrentWindowServerFrame = currentPhysicalFrame
            observation = (
                baseline,
                originalWindow.replacingFrame(currentPhysicalFrame)
            )
        } else if let refreshed = windowService.refreshed(
            originalWindow,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        ) {
            observation = (originalAXFrame, refreshed)
        } else {
            return false
        }
        let originalFrame = observation.baseline
        let currentWindow = observation.window

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
                let semanticWindow = windowService.refreshed(
                    originalWindow,
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                ) ?? originalWindow
                promoteToConfirmedDrag(
                    semanticWindow,
                    at: currentMousePoint,
                    windowActuallyMoved: true
                )
                return true
            }
        }

        if allowEdgeFallback || isNearSnapEdge(currentMousePoint),
           pendingDragStartedInLikelyDragRegion,
           mouseDistance >= 4 {
            // Edge fallback is allowed to promote an as-yet-unmoved source
            // window, but not when the pointer is already owned by a newly
            // created same-process surface (for example a detached tab).
            // Check that exceptional ambiguity only at the fallback boundary,
            // rather than paying a broad surface scan on every drag event.
            let pointerSnapshot = windowService.windowOcclusionSnapshot()
            if let pointerEvidence = windowService.pointerDragSurfaceEvidence(
                at: currentMousePoint,
                snapshot: pointerSnapshot,
                eventHandlerWindowID: eventHandlerWindowID
            ), pointerEvidence.selection.pid == originalWindow.pid,
               !windowServerIDsAtDragStart.contains(
                   pointerEvidence.selection.windowID
               ) {
                return false
            }
            let currentSurface = windowService.resolvingWindowServerIdentity(
                currentWindow
            )
            guard let currentWindowID = currentSurface.cgWindowID,
                  windowServerIDsAtDragStart.contains(currentWindowID) else {
                return false
            }
            let semanticWindow = windowService.refreshed(
                originalWindow,
                messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
            ) ?? originalWindow
            promoteToConfirmedDrag(
                semanticWindow,
                at: currentMousePoint,
                windowActuallyMoved: false
            )
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
              let originalAXFrame = pendingDragWindowFrame,
              let window = dragWindow else { return }

        let observation: (baseline: CGRect, window: ManagedWindow)
        if let baseline = pendingDragWindowServerFrame,
           let currentPhysicalFrame = pendingDragCurrentWindowServerFrame
                ?? windowService.windowServerFrame(window) {
            pendingDragCurrentWindowServerFrame = currentPhysicalFrame
            observation = (baseline, window.replacingFrame(currentPhysicalFrame))
        } else if let refreshed = windowService.refreshed(
            window,
            messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
        ) {
            observation = (originalAXFrame, refreshed)
        } else {
            return
        }
        let originalFrame = observation.baseline
        let current = observation.window

        let moved = hypot(
            current.frame.minX - originalFrame.minX,
            current.frame.minY - originalFrame.minY
        ) >= 2
        let sizeChanged = abs(current.frame.width - originalFrame.width) > 1.5
            || abs(current.frame.height - originalFrame.height) > 1.5
        guard moved, !sizeChanged else { return }
        let semanticWindow = windowService.refreshed(
            window,
            messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) ?? window
        dragWindow = semanticWindow
        beginActualWindowMovement(semanticWindow, at: mousePoint)
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

        let initialAnimationFrame = anchoredFrame(
            size: startSize,
            at: mousePoint,
            ratio: grabRatio
        )
        let initialMutationStartedAt = ProcessInfo.processInfo.systemUptime
        let initialMutationSucceeded = windowService.setFrameForInteractiveAnimation(
            initialAnimationFrame,
            for: window.element
        )
        let initialMutationElapsed = ProcessInfo.processInfo.systemUptime
            - initialMutationStartedAt
        dragWindow = window.replacingFrame(initialAnimationFrame)
        guard initialMutationSucceeded,
              initialMutationElapsed < TimeInterval(
                  AXMessagingTimeoutPolicy.animationMutation
              ) else {
            // Preserve the restore candidate, but do not start a 60 Hz AX loop
            // after a slow/failed acknowledgement. Mouse tracking and snapping
            // remain live; mouse-up can make one final best-effort correction.
            return
        }

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
            let mutationStartedAt = ProcessInfo.processInfo.systemUptime
            let frameApplied = self.windowService.setFrameForInteractiveAnimation(
                frame,
                for: window.element
            )
            let mutationElapsed = ProcessInfo.processInfo.systemUptime
                - mutationStartedAt
            self.dragWindow = window.replacingFrame(frame)

            if !frameApplied
                || mutationElapsed >= TimeInterval(
                    AXMessagingTimeoutPolicy.animationMutation
                ) {
                timer.invalidate()
                self.dragRestoreAnimationTimer = nil
                return
            }

            guard progress >= 1 else { return }
            timer.invalidate()
            self.dragRestoreAnimationTimer = nil
            self.restoreFrames.removeValue(forKey: window.stableIdentity)
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
        if windowService.setFrameForInteractiveAnimation(
            finalFrame,
            for: window.element
        ) {
            restoreFrames.removeValue(forKey: window.stableIdentity)
        }
        dragWindow = windowService.refreshed(
            window,
            messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) ?? window
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
        stopAssistLayoutModifierMonitoring()
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
        let observationScene = makeSnapObservationScene()
        if let context = expandedSideContext,
           context.displayID == target.displayID {
            let zones = ExpandedSideSelectionPolicy.candidateZones(
                isLeftEdge: context.edge == .left
            )
            let frames = zones.map { zone in
                predictedSnapFrame(
                    for: zone,
                    on: screen,
                    window: dragWindow,
                    observationScene: observationScene
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
                    window: dragWindow,
                    observationScene: observationScene
                ),
                from: point
            )
        }
    }

    private func handleDrop(
        at point: CGPoint,
        eventHandlerWindowID: CGWindowID? = nil
    ) {
        defer {
            overlay.hide()
            resetDragState()
        }

        let adoptedDetachedWindow = adoptDetachedWindowIfNeeded(
            at: point,
            allowImmediate: true,
            eventHandlerWindowID: eventHandlerWindowID
        )
        if dragWindow == nil, !adoptedDetachedWindow {
            _ = confirmWindowMove(
                at: point,
                allowEdgeFallback: true,
                eventHandlerWindowID: eventHandlerWindowID
            )
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
        let currentWindow = windowService.refreshed(
            window,
            messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
        ) ?? window
        activeSession = nil
        stopAssistLayoutModifierMonitoring()
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

    private func initialConstraintSnapPlan(
        candidate: ManagedWindow,
        desiredFrame: CGRect,
        zone: SnapZone,
        on screen: NSScreen,
        context: SnapPlacementContext,
        observationScene: SnapObservationScene? = nil,
        operationLimitsByIdentity: [String: AppConstraintLimits] = [:],
        referenceFramesByIdentity: [String: CGRect] = [:]
    ) -> InitialConstraintSnapPlanResolution {
        let contextAuthorizedConflicts = Set(context.memberIDs.compactMap { identity
            -> String? in
            guard identity != candidate.stableIdentity,
                  let placement = lockedPlacements[identity],
                  placement.displayID == context.displayID,
                  SnapPlacementLayerPolicy.conflicts(
                      existing: placement.zone,
                      incoming: zone
                  ) else { return nil }
            return identity
        })
        let displaced = (context.multiMemberReplacementPlan?
            .displacedMemberIDs ?? []).union(contextAuthorizedConflicts)
        let memberIDs = context.memberIDs.subtracting(displaced)
            .union([candidate.stableIdentity])
        let visible = observationScene?.visibleWindows
            ?? managedVisibleWindows()
        let windowsByIdentity = Dictionary(
            visible.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var zones: [String: SnapZone] = [candidate.stableIdentity: zone]
        var frames: [String: CGRect] = [candidate.stableIdentity: desiredFrame]
        var windows: [String: ManagedWindow] = [candidate.stableIdentity: candidate]
        for identity in memberIDs where identity != candidate.stableIdentity {
            guard let placement = lockedPlacements[identity],
                  placement.displayID == context.displayID else {
                return .indeterminate
            }
            let window: ManagedWindow
            if let discovered = windowsByIdentity[identity] {
                window = discovered
            } else {
                switch windowService.refreshedPersistedWindow(
                    element: placement.element,
                    pid: placement.pid,
                    expectedStableIdentity: placement.stableIdentity,
                    cgWindowID: placement.cgWindowID,
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                ) {
                case .available(let exactWindow):
                    window = exactWindow
                case .missing, .unknown:
                    // Optional/bounded AX discovery cannot authorize a
                    // different structural placement. Leave the operation
                    // unresolved rather than inventing absence/ineligibility.
                    return .indeterminate
                }
            }
            zones[identity] = placement.zone
            frames[identity] = referenceFramesByIdentity[identity] ?? window.frame
            windows[identity] = window
        }

        var learningIdentities: [String: (AppConstraintIdentity, String)] = [:]
        var limitsByIdentity: [String: AppConstraintLimits] = [:]
        for (identity, window) in windows {
            let observation: SnapConstraintObservation
            if let cached = observationScene?
                .constraintObservationsByIdentity[identity] {
                observation = cached
            } else if let resolved = resolveAppConstraintIdentity(for: window) {
                // Applying an already-known app constraint is independent from
                // whether this particular AX sample is currently good enough
                // to create new learning evidence.
                observation = SnapConstraintObservation(
                    identity: resolved.identity,
                    displayName: resolved.displayName,
                    limits: appConstraintRegistry.limits(for: resolved.identity),
                    eligibleForLearning:
                        windowService.isEligibleForConstraintLearning(window)
                )
                observationScene?.constraintObservationsByIdentity[identity] =
                    observation
            } else {
                observation = SnapConstraintObservation(
                    identity: nil,
                    displayName: L10n.text("common.app"),
                    limits: .unknown,
                    eligibleForLearning: false
                )
                observationScene?.constraintObservationsByIdentity[identity] =
                    observation
            }
            if observation.eligibleForLearning,
               let constraintIdentity = observation.identity {
                learningIdentities[identity] = (
                    constraintIdentity,
                    observation.displayName
                )
            }
            var effectiveLimits = observation.limits
            if let operationLimits = operationLimitsByIdentity[identity] {
                effectiveLimits.mergeSafetyOverride(operationLimits)
            }
            limitsByIdentity[identity] = effectiveLimits
        }

        let partitionMembers = frames.compactMap { identity, referenceFrame
            -> CanonicalSplitPartitionMember? in
            guard let memberZone = zones[identity] else { return nil }
            return CanonicalSplitPartitionMember(
                stableIdentity: identity,
                zone: memberZone,
                referenceFrame: referenceFrame,
                limits: limitsByIdentity[identity] ?? .unknown
            )
        }
        guard partitionMembers.count == frames.count else {
            return .indeterminate
        }
        switch SplitLayoutGeometry.adaptiveConstraintPartition(
            members: partitionMembers,
            incomingIdentity: candidate.stableIdentity,
            preferredIncomingFrame: desiredFrame,
            in: screen.visibleFrame
        ) {
        case .ready(let solvedFrames):
            frames = solvedFrames
        case .confirmedInfeasible:
            return .confirmedInfeasible
        case .indeterminate:
            return .indeterminate
        }

        var planned: [String: InitialConstraintPlannedWindow] = [:]
        for (identity, target) in frames {
            guard let window = windows[identity], let memberZone = zones[identity]
            else { return .indeterminate }
            let learning = learningIdentities[identity]
            planned[identity] = InitialConstraintPlannedWindow(
                window: window,
                zone: memberZone,
                originalFrame: window.frame,
                targetFrame: target,
                appConstraintLimits: limitsByIdentity[identity] ?? .unknown,
                appConstraintIdentity: learning?.0,
                appConstraintDisplayName: learning?.1 ?? L10n.text("common.app")
            )
        }
        return .ready(InitialConstraintSnapPlan(
            candidateIdentity: candidate.stableIdentity,
            windowsByIdentity: planned
        ))
    }

    private func invalidatePresentationForSnap(
        context: SnapPlacementContext
    ) {
        let affectedGroupIDs = Set([
            context.targetGroupID,
            context.departingGroupID
        ].compactMap { $0 })
        for groupID in affectedGroupIDs {
            missionControlGroupProxyController.hide(groupID: groupID)
            groupDegradationEvidenceByGroupID.removeValue(forKey: groupID)
            groupSpaceSeparationEvidenceByGroupID.removeValue(forKey: groupID)
            directGroupSpaceSeparationEvidenceByGroupID.removeValue(
                forKey: groupID
            )
            groupPresentationFailureCountsByGroupID.removeValue(forKey: groupID)
        }
        for memberID in context.memberIDs {
            lastGroupWindowServerEvidenceByIdentity.removeValue(forKey: memberID)
        }
        invalidateGroupPresentationTransitionState(for: affectedGroupIDs)
    }

    private func snap(
        _ window: ManagedWindow,
        to zone: SnapZone,
        on screen: NSScreen,
        continueAssist: Bool,
        raiseAfterInitialPlacement: Bool = false,
        frontmostGroupIDsBeforePlacement: Set<SnapGroupID>? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let operationGeneration = interactionGeneration
        let observationScene = makeSnapObservationScene()
        guard let placementContext = snapPlacementContext(
            for: window,
            zone: zone,
            on: screen,
            frontmostGroupIDsBeforePlacement:
                frontmostGroupIDsBeforePlacement,
            observationScene: observationScene
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
        invalidatePresentationForSnap(context: placementContext)
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
        let desiredTargetFrame = resolvedSnapFrame(
            for: zone,
            on: screen,
            excluding: window.stableIdentity,
            memberScope: placementContext.memberIDs,
            observationScene: observationScene
        )
        guard case .ready(let constraintPlan) = initialConstraintSnapPlan(
            candidate: window,
            desiredFrame: desiredTargetFrame,
            zone: zone,
            on: screen,
            context: placementContext,
            observationScene: observationScene
        ) else {
            pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
            finishSnapPlacementPresentation(operationGeneration: operationGeneration)
            completion?(false)
            return
        }

        let applySnap = { [weak self] in
            guard let self,
                  self.interactionGeneration == operationGeneration else { return }
            let epsilon = SystemGeometryPolicy.measurementEpsilon(
                backingScaleFactor: screen.backingScaleFactor
            )

            // Keep one immutable pre-operation geometry snapshot for the whole
            // placement. Replanning may consume newly-settled constraint
            // evidence, but it must not treat a half-mutated round as the new
            // structural baseline.
            let planningReferenceFrames = constraintPlan.windowsByIdentity
                .mapValues(\.originalFrame)
            let transactionSnapshotsByIdentity = Dictionary(
                uniqueKeysWithValues: constraintPlan.windowsByIdentity.values.map {
                    item in
                    let snapshot = item.window.stableIdentity == window.stableIdentity
                        ? pendingSnapshot
                        : self.windowService.snapshot(item.window)
                    return (item.window.stableIdentity, snapshot)
                }
            )
            var currentFramesByIdentity = planningReferenceFrames
            var currentWindowsByIdentity = Dictionary(
                uniqueKeysWithValues: constraintPlan.windowsByIdentity.values.map {
                    ($0.window.stableIdentity, $0.window)
                }
            )
            var mutatedIDs = Set<String>()
            var operationLimitsByIdentity: [String: AppConstraintLimits] = [:]
            var discoveredOperationBounds = Set<String>()
            var confirmedRejections: [ConfirmedConstraintRejection] = []
            var seenPersistentRejectionKeys = Set<String>()
            var measurementWindowIdentityByApp:
                [AppConstraintIdentity: String] = [:]
            var permissionRequests:
                [AppConstraintIdentity: ConstraintRecordingPermissionRequest] = [:]
            var terminalWasDelivered = false

            func operationBoundKey(
                identity: String,
                bound: AppConstraintBound
            ) -> String {
                "\(identity)|\(bound.rawValue)"
            }

            func transactionSnapshots() -> [WindowSnapshot] {
                mutatedIDs.compactMap { transactionSnapshotsByIdentity[$0] }
            }

            func registerLearningEvidence(
                item: InitialConstraintPlannedWindow,
                observation: AXFrameMutationObservation,
                acceptedFrame: CGRect,
                activeAxes: Set<ConstraintProbeAxis>,
                operationLocalAxes: Set<ConstraintProbeAxis>
            ) -> Bool {
                // Axis ownership belongs to the frame delta that authorized
                // this round, not to the frame observed after the mutation.
                // Using the accepted frame here can turn a stale/lagging
                // orthogonal dimension into evidence for an axis Tabora did
                // not actually mutate.
                guard !activeAxes.isEmpty else { return false }

                let screenLimitedAxes = SystemGeometryPolicy.screenLimitedAxes(
                    requestedFrame: item.targetFrame,
                    acceptedFrame: acceptedFrame,
                    activeAxes: activeAxes,
                    screenFrame: screen.visibleFrame,
                    epsilon: epsilon
                )
                let systemLimitedAxes = SystemGeometryPolicy.systemLimitedAxes(
                    requestedFrame: item.targetFrame,
                    acceptedFrame: acceptedFrame,
                    activeAxes: activeAxes,
                    epsilon: epsilon
                )

                if observation.settlementEvidence
                    .authorizesPersistentConstraintLearning,
                   let constraintIdentity = item.appConstraintIdentity {
                    let probeAnalysis = ConstraintProbe.analyze(
                        ConstraintProbeContext(
                            identity: constraintIdentity,
                            displayName: item.appConstraintDisplayName,
                            requestedFrame: item.targetFrame,
                            acceptedFrame: acceptedFrame,
                            activeAxes: activeAxes,
                            mutationWasSent: observation.mutationWasSent,
                            sizeMutationSucceeded: observation.sizeMutationSucceeded,
                            acceptedFrameIsSettled:
                                observation.acceptedFrameIsSettled,
                            liveness: observation.liveness,
                            screenLimitedAxes: screenLimitedAxes,
                            systemLimitedAxes: systemLimitedAxes,
                            peerLimitedAxes: [],
                            measurementEpsilon: epsilon,
                            operationGeneration: operationGeneration
                        )
                    )
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
                                    ?? item.window.stableIdentity,
                                item.window.stableIdentity
                            )
                        }
                    }
                    // Persistent min/max requires the full bounded settlement
                    // observation. The earlier operation-local alternative is
                    // only allowed to replan this snap and must never become a
                    // learned bound merely because a slow app paused briefly.
                }

                guard observation.mutationWasSent,
                      observation.sizeMutationSucceeded,
                      observation.acceptedFrameIsSettled,
                      observation.liveness == .alive else {
                    return false
                }
                let attributableLocalAxes =
                    InitialSnapConstraintSettlementPolicy
                        .attributableOperationLocalAxes(
                            requestedFrame: item.targetFrame,
                            acceptedFrame: acceptedFrame,
                            candidateAxes: operationLocalAxes,
                            epsilon: epsilon
                        )
                let localBounds = OperationLocalConstraintEvidencePolicy
                    .settledBounds(
                        requestedFrame: item.targetFrame,
                        acceptedFrame: acceptedFrame,
                        activeAxes: attributableLocalAxes,
                        excludedAxes: screenLimitedAxes.union(systemLimitedAxes),
                        epsilon: epsilon
                    )
                if let constraintIdentity = item.appConstraintIdentity,
                   ConstraintPermissionPromptPolicy
                    .shouldRequestFromOperationLocalEvidence(
                        hasAttributableBounds: !localBounds.isEmpty,
                        currentPermission: self.appConstraintRegistry
                            .record(for: constraintIdentity)?
                            .recordingPermission,
                        popupEnabled:
                            self.settings.constraintRecordingPromptsEnabled
                    ) {
                    // This is an early UI request only. Operation-local
                    // evidence may replan the current snap, but no value is
                    // persisted and no group is retired from this branch.
                    // Only the later user-authorized full calibration may
                    // write explicit constraints.
                    permissionRequests[constraintIdentity] = self
                        .mergedConstraintPermissionRequest(
                            existing: permissionRequests[constraintIdentity],
                            identity: constraintIdentity,
                            displayName: item.appConstraintDisplayName,
                            windowStableIdentity: item.window.stableIdentity
                        )
                }
                var addedNewEvidence = false
                for (bound, value) in localBounds {
                    let key = operationBoundKey(
                        identity: item.window.stableIdentity,
                        bound: bound
                    )
                    // One settled directional fact per bound is enough for one
                    // placement. If the same bound contradicts the new plan
                    // again, do not turn replanning into a search loop.
                    guard discoveredOperationBounds.insert(key).inserted else {
                        continue
                    }
                    var local = operationLimitsByIdentity[
                        item.window.stableIdentity
                    ] ?? .unknown
                    local.set(value, for: bound)
                    operationLimitsByIdentity[item.window.stableIdentity] = local
                    addedNewEvidence = true
                }
                return addedNewEvidence
            }

            func collectPersistentLearningDispositions() {
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
                    // Contradiction/conflict remain verification debt. Passive
                    // snap evidence alone never launches measurement; only the
                    // later explicit choice in the permission prompt may do so.
                }
            }

            func finishFailedTransaction() {
                guard !terminalWasDelivered else { return }
                terminalWasDelivered = true
                collectPersistentLearningDispositions()
                let snapshots = transactionSnapshots()
                guard !snapshots.isEmpty else {
                    self.pendingPlacementSnapshots.removeValue(
                        forKey: window.stableIdentity
                    )
                    self.presentConstraintRecordingPermissionRequests(
                        permissionRequests
                    )
                    self.finishSnapPlacementPresentation(
                        operationGeneration: operationGeneration
                    )
                    completion?(false)
                    return
                }
                self.rollbackSnapTransaction(
                    snapshots,
                    operationGeneration: operationGeneration
                ) { [weak self] _ in
                    guard let self else { return }
                    guard self.interactionGeneration == operationGeneration else {
                        self.finishSnapPlacementPresentation(
                            operationGeneration: operationGeneration
                        )
                        completion?(false)
                        return
                    }
                    self.presentConstraintRecordingPermissionRequests(
                        permissionRequests
                    )
                    self.finishSnapPlacementPresentation(
                        operationGeneration: operationGeneration
                    )
                    completion?(false)
                }
            }

            func finishSuccessfulTransaction(
                plan: InitialConstraintSnapPlan
            ) {
                guard !terminalWasDelivered else { return }
                // Resolve every value required for structural commit before
                // claiming the terminal transition. If this unexpectedly
                // fails, the ordinary rollback path must still be reachable.
                let candidateFrame = currentFramesByIdentity[window.stableIdentity]
                    ?? plan.candidateTargetFrame
                guard let candidateFrame else {
                    finishFailedTransaction()
                    return
                }
                terminalWasDelivered = true
                collectPersistentLearningDispositions()
                guard self.interactionGeneration == operationGeneration else {
                    self.finishSnapPlacementPresentation(
                        operationGeneration: operationGeneration
                    )
                    completion?(false)
                    return
                }
                let snapshots = transactionSnapshots()
                let appliedCandidate = (currentWindowsByIdentity[
                    window.stableIdentity
                ] ?? window).replacingFrame(candidateFrame)
                let acceptedFrames = Dictionary(
                    uniqueKeysWithValues: mutatedIDs.compactMap { identity
                        -> (String, CGRect)? in
                        guard let frame = currentFramesByIdentity[identity] else {
                            return nil
                        }
                        return (identity, frame)
                    }
                )
                // Permission UI is presentation owned by Tabora. Do not open
                // it while the structural snap is still provisional: the
                // register/commit (or its rollback) must finish first.
                let finalizationCompletion: (Bool) -> Void = { [weak self] result in
                    self?.presentConstraintRecordingPermissionRequests(
                        permissionRequests
                    )
                    completion?(result)
                }
                self.finalizeSuccessfulSnap(
                    appliedCandidate,
                    zone: zone,
                    on: screen,
                    snapshots: snapshots,
                    restoreFrame: pendingRestoreCandidate,
                    continueAssist: continueAssist,
                    operationGeneration: operationGeneration,
                    acceptedFramesByIdentity: acceptedFrames,
                    completion: finalizationCompletion
                )
            }

            func runRound(
                plan: InitialConstraintSnapPlan,
                candidateMustSettleFirst: Bool
            ) {
                guard !terminalWasDelivered,
                      self.interactionGeneration == operationGeneration else {
                    return
                }

                let allPlannedWindows = plan.windowsByIdentity.values.filter { item in
                    let current = currentFramesByIdentity[item.window.stableIdentity]
                        ?? item.originalFrame
                    return abs(item.targetFrame.minX - current.minX) > 0.5
                        || abs(item.targetFrame.minY - current.minY) > 0.5
                        || abs(item.targetFrame.width - current.width) > 0.5
                        || abs(item.targetFrame.height - current.height) > 0.5
                }
                let plannedIdentities = InitialSnapMutationOrderingPolicy
                    .identitiesForRound(
                        candidateIdentity: window.stableIdentity,
                        plannedIdentities: Set(allPlannedWindows.map {
                            $0.window.stableIdentity
                        }),
                        candidateMustSettleFirst: candidateMustSettleFirst
                    )
                let plannedWindows = allPlannedWindows.filter {
                    plannedIdentities.contains($0.window.stableIdentity)
                }
                guard !plannedWindows.isEmpty else {
                    finishSuccessfulTransaction(plan: plan)
                    return
                }

                var pending = plannedWindows.count
                var roundHasUnresolvedFailure = false
                var roundHasNewConstraintEvidence = false

                for item in plannedWindows {
                    let currentBeforeRound = currentFramesByIdentity[
                        item.window.stableIdentity
                    ] ?? item.originalFrame
                    var activeAxes = Set<ConstraintProbeAxis>()
                    if abs(item.targetFrame.width - currentBeforeRound.width) > epsilon {
                        activeAxes.insert(.width)
                    }
                    if abs(item.targetFrame.height - currentBeforeRound.height) > epsilon {
                        activeAxes.insert(.height)
                    }
                    let operationLocalAxes = InitialSnapConstraintSettlementPolicy
                        .operationLocalAxes(
                            currentFrame: currentBeforeRound,
                            targetFrame: item.targetFrame,
                            limits: item.appConstraintLimits,
                            epsilon: epsilon
                        )
                    var requiredCommitSizeAxes: AXFrameSizeAxes = []
                    if activeAxes.contains(.width) {
                        requiredCommitSizeAxes.insert(.width)
                    }
                    if activeAxes.contains(.height) {
                        requiredCommitSizeAxes.insert(.height)
                    }

                    mutatedIDs.insert(item.window.stableIdentity)
                    if let snapshot = transactionSnapshotsByIdentity[
                        item.window.stableIdentity
                    ] {
                        self.pendingPlacementSnapshots[
                            item.window.stableIdentity
                        ] = snapshot
                    }

                    let afterInitialFrameAttempt: (() -> Void)?
                    if raiseAfterInitialPlacement,
                       item.window.stableIdentity == window.stableIdentity,
                       currentFramesByIdentity[item.window.stableIdentity]
                            == planningReferenceFrames[item.window.stableIdentity] {
                        afterInitialFrameAttempt = { [weak self] in
                            guard let self,
                                  self.interactionGeneration == operationGeneration
                            else { return }
                            _ = self.windowService.raise(window)
                        }
                    } else {
                        afterInitialFrameAttempt = nil
                    }

                    let settlementMode = InitialSnapConstraintSettlementPolicy.mode(
                        currentFrame: currentBeforeRound,
                        targetFrame: item.targetFrame,
                        limits: item.appConstraintLimits,
                        epsilon: epsilon
                    )

                    self.windowService.setFrameAnchoredObserved(
                        item.targetFrame,
                        sizeConstraintAnchor: item.zone.sizeConstraintAnchor,
                        requiredOuterEdges: item.zone.requiredOuterEdges,
                        // Commit requires the dimensions this round actually
                        // owns, but AX correction/retry remains governed by
                        // the historical outer-edge policy. For corner snaps
                        // this prevents an old 60% size from being accepted as
                        // a successful 50% placement before the app settles.
                        requiredCommitSizeAxes: requiredCommitSizeAxes.isEmpty
                            ? nil : requiredCommitSizeAxes,
                        skipInitialWriteWhenVerified: true,
                        for: item.window.element,
                        pid: item.window.pid,
                        afterInitialFrameAttempt: afterInitialFrameAttempt,
                        settlementMode: settlementMode
                    ) { [weak self] observation in
                        guard let self,
                              !terminalWasDelivered,
                              self.interactionGeneration == operationGeneration else {
                            return
                        }

                        let acceptedFrame = observation.acceptedFrame
                            ?? self.windowService.refreshed(item.window)?.frame
                        if let acceptedFrame {
                            currentFramesByIdentity[item.window.stableIdentity] =
                                acceptedFrame
                            currentWindowsByIdentity[item.window.stableIdentity] =
                                item.window.replacingFrame(acceptedFrame)
                        }

                        let edgesMatch = acceptedFrame.map {
                            self.matchesRequiredOuterEdges(
                                $0,
                                targetFrame: item.targetFrame,
                                requiredEdges: item.zone.requiredOuterEdges
                            )
                        } ?? false
                        let requiredSizeMatch = acceptedFrame.map {
                            AXFrameSizePolicy.requiredSizeIsCorrect(
                                actual: $0.size,
                                target: item.targetFrame.size,
                                exactAxes: requiredCommitSizeAxes
                            )
                        } ?? false
                        let exactAccepted = requiredSizeMatch
                            && AXFrameMutationCommitPolicy.accepts(
                                observation,
                                requiredOuterEdgesMatch: edgesMatch
                            )

                        if !exactAccepted {
                            if let acceptedFrame,
                               registerLearningEvidence(
                                   item: item,
                                   observation: observation,
                                   acceptedFrame: acceptedFrame,
                                   activeAxes: activeAxes,
                                   operationLocalAxes: operationLocalAxes
                               ) {
                                roundHasNewConstraintEvidence = true
                            } else {
                                // Missing/unsettled/duplicate evidence cannot
                                // authorize another geometry mutation. The
                                // provisional transaction must roll back rather
                                // than search for a fit.
                                roundHasUnresolvedFailure = true
                            }
                        }

                        pending -= 1
                        guard pending == 0 else { return }

                        if roundHasUnresolvedFailure {
                            finishFailedTransaction()
                            return
                        }
                        if roundHasNewConstraintEvidence {
                            guard case .ready(let replanned) =
                                self.initialConstraintSnapPlan(
                                    candidate: window,
                                    desiredFrame: desiredTargetFrame,
                                    zone: zone,
                                    on: screen,
                                    context: placementContext,
                                    observationScene: observationScene,
                                    operationLimitsByIdentity:
                                        operationLimitsByIdentity,
                                    referenceFramesByIdentity:
                                        planningReferenceFrames
                                ) else {
                                finishFailedTransaction()
                                return
                            }
                            runRound(
                                plan: replanned,
                                candidateMustSettleFirst: false
                            )
                            return
                        }
                        if candidateMustSettleFirst {
                            runRound(
                                plan: plan,
                                candidateMustSettleFirst: false
                            )
                            return
                        }
                        finishSuccessfulTransaction(plan: plan)
                    }
                }
            }

            runRound(
                plan: constraintPlan,
                candidateMustSettleFirst: true
            )
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
        frontmostGroupIDsBeforePlacement: Set<SnapGroupID>? = nil,
        observationScene: SnapObservationScene? = nil
    ) -> SnapPlacementContext? {
        guard let currentDisplayID = displayID(for: screen) else {
            return nil
        }
        let initiallyLockedIDs = Set(lockedPlacements.compactMap {
            identity, placement in
            AssistCandidateReservationPolicy.isReserved(
                placementZone: placement.zone
            ) ? identity : nil
        })

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

        let scene = observationScene ?? makeSnapObservationScene()
        let visibleWindows = scene.visibleWindows
        let comparisonWindows = visibleWindows.filter {
            $0.stableIdentity != window.stableIdentity
        }
        if let stagedGroupDeparture,
           stagedGroupDeparture.draggedIdentity == window.stableIdentity {
            // The stage itself is the gesture-bound structural snapshot. A
            // temporary broad AX census omission or Z-order change must not
            // authorize converting that same gesture into an unrelated group.
            // Continue the captured group while every captured placement still
            // belongs to this display; exact live identity is revalidated by
            // the placement transaction immediately before mutation.
            let stagedPlacements = stagedGroupDeparture.memberIDs.compactMap {
                lockedPlacements[$0]
            }
            let stagedZones = Dictionary(
                uniqueKeysWithValues: stagedPlacements.map {
                    ($0.stableIdentity, $0.zone)
                }
            )
            if stagedPlacements.count == stagedGroupDeparture.memberIDs.count,
               stagedPlacements.allSatisfy({ $0.displayID == currentDisplayID }),
               StagedGroupContinuationPolicy.canContinue(
                   draggedIdentity: window.stableIdentity,
                   memberIDs: stagedGroupDeparture.memberIDs,
                   zonesByMemberID: stagedZones,
                   incomingZone: zone,
                   visibleFrame: screen.visibleFrame
               ) {
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
        let potentiallyRelatedGroups = explicitGroupStore.groups.filter { group in
            guard group.displayID == currentDisplayID else { return false }
            let hasConflict = group.layout.zonesByMemberID.values.contains {
                SnapPlacementLayerPolicy.conflicts(existing: $0, incoming: zone)
            }
            if hasConflict { return true }
            var proposedZones = group.layout.zonesByMemberID
            proposedZones[window.stableIdentity] = zone
            let proposedConnections = SplitLayoutGeometry
                .proposedResizeHandleGeometries(
                    zonesByIdentity: proposedZones,
                    in: screen.visibleFrame
                )
            return !SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: window.stableIdentity,
                handles: proposedConnections
            ).intersection(group.memberIDs).isEmpty
        }
        if !potentiallyRelatedGroups.isEmpty,
           scene.windowServerSnapshotCompleteness == .unknown
                || currentDraggedSurface == nil {
            // A placement that could extend/replace an existing group needs a
            // complete physical Z-order observation. Failure to obtain that
            // observation is unresolved, not authorization to manufacture an
            // independent overlapping structure.
            return nil
        }
        let currentWindowServerFrontmostGroupIDs =
            SnapGroupPlacementEligibilityPolicy
            .frontmostGroupIDs(
                groups: explicitGroupStore.groups,
                draggedSurface: currentDraggedSurface,
                bindings: persistedManagedWindowBindings.map(\.identity),
                windowServerSnapshot: scene.windowServerSnapshot
            )
        var sawUnresolvedAuthorizedGroup = false
        let eligibleGroups = explicitGroupStore.groups.compactMap { group
            -> (SnapGroup, Int, Int, MultiMemberReplacementPlan?)? in
            guard group.displayID == currentDisplayID else { return nil }
            // Structural eligibility is based on the committed group layout
            // and exact Window Server identity, not on whether every AX member
            // happened to answer a fresh broad census during this snap.
            let groupPlacements = group.memberIDs.compactMap { memberID
                -> SplitPlacementGeometry? in
                guard let placement = lockedPlacements[memberID],
                      placement.displayID == currentDisplayID,
                      let binding = persistedManagedWindowBindings.first(
                          where: { $0.identity.stableIdentity == memberID }
                      ),
                      let physicalSurface = scene.windowServerSnapshot.first(
                          where: {
                              $0.pid == binding.identity.pid
                                  && $0.windowID == binding.identity.windowID
                                  && $0.layer == 0
                          }
                      ),
                      matchesRecordedPlacement(
                          physicalSurface.frame,
                          placement.appliedFrame,
                          on: screen
                      ) else {
                    return nil
                }
                return SplitPlacementGeometry(
                    stableIdentity: memberID,
                    zone: placement.zone,
                    frame: placement.appliedFrame
                )
            }
            let geometryIsComplete = group.memberIDs.count >= 2
                && groupPlacements.count == group.memberIDs.count
            let isFrontmostNow = currentWindowServerFrontmostGroupIDs
                .contains(group.id)
            let wasFrontmostBeforeManipulation: Bool
            if let placementBaseline = frontmostGroupIDsBeforePlacement
                ?? frontmostGroupIDsAtPointerDown {
                wasFrontmostBeforeManipulation =
                    placementBaseline.contains(group.id)
            } else {
                wasFrontmostBeforeManipulation =
                    currentWindowServerFrontmostGroupIDs.contains(group.id)
            }
            let conflictingMemberIDs = Set(
                group.layout.zonesByMemberID.compactMap { memberID, memberZone
                    -> String? in
                    SnapPlacementLayerPolicy.conflicts(
                        existing: memberZone,
                        incoming: zone
                    ) ? memberID : nil
                }
            )
            let retainedMemberIDs = group.memberIDs
                .subtracting(conflictingMemberIDs)
            let placementsByIdentity = Dictionary(
                groupPlacements.map { ($0.stableIdentity, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let displacedPlacements = conflictingMemberIDs.compactMap {
                placementsByIdentity[$0]
            }
            let retainedPlacements = retainedMemberIDs.compactMap {
                placementsByIdentity[$0]
            }
            let multiMemberReplacementHasStraightBoundary: Bool
            if conflictingMemberIDs.count >= 2 {
                multiMemberReplacementHasStraightBoundary =
                    displacedPlacements.count == conflictingMemberIDs.count
                    && retainedPlacements.count == retainedMemberIDs.count
                    && SplitLayoutGeometry
                        .hasStraightSharedBoundaryBetweenPartitions(
                            displacedPlacements: displacedPlacements,
                            retainedPlacements: retainedPlacements
                        )
            } else {
                multiMemberReplacementHasStraightBoundary = false
            }
            let fullGroupReplacementIsExactCover =
                conflictingMemberIDs.count >= 2
                && conflictingMemberIDs == group.memberIDs
                && retainedMemberIDs.isEmpty
                && SnapPlacementLayerPolicy.incomingExactlyCovers(
                    existingZones: Set(group.layout.zonesByMemberID.values),
                    incoming: zone
                )
            let multiMemberReplacementPlan: MultiMemberReplacementPlan?
            if conflictingMemberIDs.count >= 2,
               multiMemberReplacementHasStraightBoundary
                    || fullGroupReplacementIsExactCover {
                multiMemberReplacementPlan = MultiMemberReplacementPlan(
                    targetGroupID: group.id,
                    targetZonesByMemberID: group.layout.zonesByMemberID,
                    incomingZone: zone,
                    displacedMemberIDs: conflictingMemberIDs,
                    retainedMemberIDs: retainedMemberIDs,
                    kind: fullGroupReplacementIsExactCover
                        ? .fullGroupCover
                        : .partitionBoundary
                )
            } else {
                multiMemberReplacementPlan = nil
            }

            var proposedZones = group.layout.zonesByMemberID
            proposedZones[window.stableIdentity] = zone
            let proposedConnections = SplitLayoutGeometry
                .proposedResizeHandleGeometries(
                    zonesByIdentity: proposedZones,
                    in: screen.visibleFrame
                )
            let canExtend = !SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: window.stableIdentity,
                handles: proposedConnections
            ).intersection(group.memberIDs).isEmpty
            let hasPotentialRelationship = !conflictingMemberIDs.isEmpty || canExtend
            if wasFrontmostBeforeManipulation,
               isFrontmostNow,
               hasPotentialRelationship,
               !geometryIsComplete {
                // The exact group is physically frontmost, but one live geometry
                // sample does not currently match its accepted placement. That is
                // settlement/observation debt, not proof that this group cannot
                // receive the placement. Do not fall through to a new structure.
                sawUnresolvedAuthorizedGroup = true
                return nil
            }
            let relationshipRank = SnapGroupPlacementEligibilityPolicy
                .relationshipRank(
                    conflictingMemberCount: conflictingMemberIDs.count,
                    multiMemberReplacementHasStraightBoundary:
                        multiMemberReplacementHasStraightBoundary,
                    fullGroupReplacementIsExactCover:
                        fullGroupReplacementIsExactCover,
                    canExtend: canExtend
                )
            guard SnapGroupPlacementEligibilityPolicy.canAbsorbPlacement(
                wasFrontmostAtPointerDown: wasFrontmostBeforeManipulation,
                isFrontmostNow: isFrontmostNow,
                isComplete: geometryIsComplete
            ),
                  let relationshipRank else { return nil }
            let firstMember = group.memberIDs.compactMap { memberID -> Int? in
                guard let binding = persistedManagedWindowBindings.first(
                    where: { $0.identity.stableIdentity == memberID }
                ) else { return nil }
                return scene.windowServerSnapshot.firstIndex { surface in
                    surface.pid == binding.identity.pid
                        && surface.windowID == binding.identity.windowID
                }
            }.min() ?? Int.max
            return (
                group,
                relationshipRank,
                firstMember,
                multiMemberReplacementPlan
            )
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.creationOrder < $1.0.creationOrder
        }

        if let target = eligibleGroups.first {
            let targetGroup = target.0
            return SnapPlacementContext(
                targetGroupID: targetGroup.id,
                departingGroupID: nil,
                memberIDs: targetGroup.memberIDs.union([window.stableIdentity]),
                excludedAssistCandidateIDs: initiallyLockedIDs,
                displayID: currentDisplayID,
                multiMemberReplacementPlan: target.3
            )
        }
        if sawUnresolvedAuthorizedGroup {
            return nil
        }


        // A previously snapped single window is not yet an explicit group,
        // but a later complementary snap must still be able to finish it.
        // Persistent locks enumerate structural candidates; Window Server owns
        // frontmost qualification; AX broad discovery is only a cache and an
        // exact persisted binding is resolved before the placement can use it.
        struct ProvisionalPlacementCandidate {
            let placement: LockedPlacement
            let zIndex: Int
        }
        var provisionalCandidates: [ProvisionalPlacementCandidate] = []
        for (identity, placement) in lockedPlacements {
            guard SnapGroupPlacementEligibilityPolicy.canUseProvisionalPeer(
                      existingIdentity: identity,
                      incomingIdentity: window.stableIdentity
                  ),
                  placement.displayID == currentDisplayID,
                  placement.zone != .maximize,
                  explicitGroupStore.group(containing: identity) == nil,
                  !(stagedGroupDeparture?.memberIDs.contains(identity) ?? false)
            else { continue }

            let conflicts = SnapPlacementLayerPolicy.conflicts(
                existing: placement.zone,
                incoming: zone
            )
            var proposedZones = [identity: placement.zone]
            proposedZones[window.stableIdentity] = zone
            let logicalHandles = SplitLayoutGeometry.proposedResizeHandleGeometries(
                zonesByIdentity: proposedZones,
                in: screen.visibleFrame
            )
            let isAdjacent = SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: window.stableIdentity,
                handles: logicalHandles
            ).contains(identity)
            guard conflicts || isAdjacent else { continue }

            switch windowServerFrontmostEvaluation(
                memberIDs: [identity],
                snapshot: scene.windowServerSnapshot
            ) {
            case .occluded:
                continue
            case .indeterminate:
                // This lock could still be the structure the user is extending.
                // Unknown frontmost evidence cannot authorize falling through
                // to a materially different independent-group result.
                return nil
            case .verifiedFrontmost:
                break
            }

            guard let binding = persistedManagedWindowBindings.first(
                where: { $0.identity.stableIdentity == identity }
            ) else {
                return nil
            }
            let zIndex = scene.windowServerSnapshot.firstIndex { surface in
                surface.pid == binding.identity.pid
                    && surface.windowID == binding.identity.windowID
            } ?? Int.max
            provisionalCandidates.append(ProvisionalPlacementCandidate(
                placement: placement,
                zIndex: zIndex
            ))
        }
        provisionalCandidates.sort { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.placement.stableIdentity < rhs.placement.stableIdentity
        }

        if let provisionalCandidate = provisionalCandidates.first {
            let placement = provisionalCandidate.placement
            if !comparisonWindows.contains(where: {
                $0.stableIdentity == placement.stableIdentity
            }) {
                switch windowService.refreshedPersistedWindow(
                    element: placement.element,
                    pid: placement.pid,
                    expectedStableIdentity: placement.stableIdentity,
                    cgWindowID: placement.cgWindowID,
                    messagingTimeout: AXMessagingTimeoutPolicy.interactiveOperation
                ) {
                case .available:
                    break
                case .missing, .unknown:
                    // Confirmed AX absence conflicts with still-frontmost Window
                    // Server evidence; unknown is likewise unresolved. Neither
                    // authorizes an unrelated structural fallback here.
                    return nil
                }
            }
            return SnapPlacementContext(
                targetGroupID: nil,
                departingGroupID: nil,
                memberIDs: [
                    placement.stableIdentity,
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

    private func finalizeSuccessfulSnap(
        _ window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen,
        snapshots: [WindowSnapshot],
        restoreFrame: CGRect,
        continueAssist: Bool,
        operationGeneration: Int,
        acceptedFramesByIdentity: [String: CGRect],
        completion: ((Bool) -> Void)?
    ) {
        for snapshot in snapshots {
            pendingPlacementSnapshots.removeValue(forKey: snapshot.stableIdentity)
        }
        guard registerLock(
            for: window,
            zone: zone,
            on: screen,
            context: activeSnapPlacementContext,
            acceptedFramesByIdentity: acceptedFramesByIdentity
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

    private func rollbackSnapTransaction(
        _ snapshots: [WindowSnapshot],
        operationGeneration: Int,
        completion: ((Bool) -> Void)?
    ) {
        guard isSnapPlacementInProgress,
              snapPlacementInteractionGeneration == operationGeneration else {
            // The structural snap owner is already gone. Do not resurrect it;
            // restore the supplied snapshots as ordinary cleanup.
            rollbackTransaction(snapshots, completion: completion)
            return
        }
        isSnapRollbackActive = true
        rollbackTransaction(snapshots) { [weak self] result in
            guard let self else {
                completion?(result)
                return
            }
            self.isSnapRollbackActive = false
            completion?(result)
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
        rollbackSnapTransaction(
            [snapshot],
            operationGeneration: operationGeneration
        ) { [weak self] _ in
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
        rollbackSnapTransaction(
            snapshots,
            operationGeneration: operationGeneration
        ) { [weak self] result in
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
        // Assist presents its next picker before the snap transaction retires.
        // The monitor correctly stays closed while that transaction owns
        // placement, then must be reconsidered at this exact recovery edge.
        // Without this handoff a visible, switchable picker can remain alive
        // with no layout-modifier observer ever started.
        updateAssistLayoutModifierMonitoringState()
        // refreshResizeHandles() either rebuilds and unsuspends validated
        // geometry, or hides everything when assist is active. Avoid manually
        // unsuspending stale descriptors between those two outcomes. A delayed
        // rollback completion must not resurrect presentation after stop/disable.
        if isEnabled,
           isControllerRunning,
           !isApplicationInteractionSuppressed {
            refreshResizeHandles()
        }
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
            updateAssistLayoutModifierMonitoringState()
            picker.hide()
            return
        }

        if activeSession == nil {
            activeSession = makeSession(startingWith: zone, window: placedWindow, screen: screen)
        } else {
            activeSession?.occupy(zone, stableIdentity: placedWindow.stableIdentity)
        }

        guard let session = activeSession else { return }
        presentAssist(session: session, on: screen)
    }

    private func presentAssist(
        session providedSession: LayoutSession,
        on screen: NSScreen
    ) {
        var session = providedSession
        var remaining = session.remainingZones
        guard !remaining.isEmpty else {
            activeSession = nil
            stopEscapeMonitoring()
            updateAssistLayoutModifierMonitoringState()
            picker.hide()
            return
        }

        let assistVisibleWindows = managedVisibleWindows()
        let candidates = assistVisibleWindows.filter { candidate in
            !session.occupiedStableIDs.contains(candidate.stableIdentity)
                &&
            // Selecting a member of another split would silently destroy or
            // merge that group. A user can still transfer it explicitly by
            // dragging it out first, which runs the normal departure path.
            // Maximize remains recorded for restore and occlusion, but it is
            // not split membership. Selecting it hands the window to the same
            // Snap transaction that clears the maximized layer on commit.
            !AssistCandidateReservationPolicy.isReserved(
                placementZone:
                    lockedPlacements[candidate.stableIdentity]?.zone
            )
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
            updateAssistLayoutModifierMonitoringState()
            picker.hide()
            return
        }
        let observationScene = makeSnapObservationScene(
            visibleWindows: assistVisibleWindows
        )
        let assistMemberScope = session.groupID.flatMap {
            explicitGroupStore.group(id: $0)?.memberIDs
        }?.union(session.occupiedStableIDs) ?? session.occupiedStableIDs
        let candidatesByZone: [SnapZone: [ManagedWindow]]
        let occupiedZones = Set(session.occupiedZones.keys)
        if settings.assistLayoutSwitchingEnabled,
           let threeWindowLayout = AssistCompletionLayoutPolicy
                .threeWindowZones(occupiedZones: occupiedZones) {
            let fourWindowRemaining = AssistCompletionLayoutPolicy
                .fourWindowZones.filter {
                    session.occupiedZones[$0] == nil
                }
            let fourWindowCandidates = assistCandidatesByZone(
                zones: fourWindowRemaining,
                candidates: candidates,
                on: screen,
                observationScene: observationScene
            )
            let fourWindowAssignmentCount = AssistCandidateAssignmentPolicy
                .maximumDistinctAssignmentCount(
                    zones: fourWindowRemaining,
                    candidateIDsByZone: fourWindowCandidates.mapValues {
                        Set($0.map(\.stableIdentity))
                    }
                )
            let threeWindowRemaining = threeWindowLayout.filter {
                session.occupiedZones[$0] == nil
            }
            let threeWindowCandidates = assistCandidatesByZone(
                zones: threeWindowRemaining,
                candidates: candidates,
                on: screen,
                observationScene: observationScene
            )
            let mergedHalfCandidateCount = Set(
                threeWindowCandidates.values.flatMap {
                    $0.map(\.stableIdentity)
                }
            ).count
            guard let completionLayout = AssistCompletionLayoutPolicy
                .completionLayout(
                    occupiedZones: occupiedZones,
                    modifierIsPressed:
                        Self.currentAssistLayoutModifierIsPressed,
                    maximumDistinctFourWindowAssignments:
                        fourWindowAssignmentCount,
                    mergedHalfCandidateCount: mergedHalfCandidateCount
            ) else {
                activeSession = nil
                stopEscapeMonitoring()
                updateAssistLayoutModifierMonitoringState()
                picker.hide()
                return
            }
            session.layoutZones = completionLayout
            remaining = session.remainingZones
            candidatesByZone = Set(completionLayout)
                    == Set(AssistCompletionLayoutPolicy.fourWindowZones)
                ? fourWindowCandidates
                : threeWindowCandidates
        } else if settings.assistLayoutSwitchingEnabled,
                  let twoWindowLayout = AssistCompletionLayoutPolicy
                    .twoWindowZones(occupiedZones: occupiedZones),
                  let threeWindowLayout = AssistCompletionLayoutPolicy
                    .threeWindowZonesStartingFromHalf(
                        occupiedZones: occupiedZones
                    ) {
            let twoWindowRemaining = twoWindowLayout.filter {
                session.occupiedZones[$0] == nil
            }
            let twoWindowCandidates = assistCandidatesByZone(
                zones: twoWindowRemaining,
                candidates: candidates,
                on: screen,
                observationScene: observationScene
            )
            let oppositeHalfCandidateCount = Set(
                twoWindowCandidates.values.flatMap {
                    $0.map(\.stableIdentity)
                }
            ).count
            let splitRemaining = threeWindowLayout.filter {
                session.occupiedZones[$0] == nil
            }
            let splitCandidates = assistCandidatesByZone(
                zones: splitRemaining,
                candidates: candidates,
                on: screen,
                observationScene: observationScene
            )
            let splitAssignmentCount = AssistCandidateAssignmentPolicy
                .maximumDistinctAssignmentCount(
                    zones: splitRemaining,
                    candidateIDsByZone: splitCandidates.mapValues {
                        Set($0.map(\.stableIdentity))
                    }
                )
            guard let completionLayout = AssistCompletionLayoutPolicy
                .completionLayoutStartingFromHalf(
                    occupiedZones: occupiedZones,
                    modifierIsPressed:
                        Self.currentAssistLayoutModifierIsPressed,
                    oppositeHalfCandidateCount: oppositeHalfCandidateCount,
                    maximumDistinctSplitAssignments: splitAssignmentCount
                ) else {
                activeSession = nil
                stopEscapeMonitoring()
                updateAssistLayoutModifierMonitoringState()
                picker.hide()
                return
            }
            session.layoutZones = completionLayout
            remaining = session.remainingZones
            candidatesByZone = Set(completionLayout) == Set(twoWindowLayout)
                ? twoWindowCandidates
                : splitCandidates
        } else {
            candidatesByZone = assistCandidatesByZone(
                zones: remaining,
                candidates: candidates,
                on: screen,
                observationScene: observationScene
            )
        }

        let eligibleCandidateCount = Set(
            candidatesByZone.values.flatMap { $0.map(\.stableIdentity) }
        ).count
        guard eligibleCandidateCount > 0 else {
            activeSession = nil
            stopEscapeMonitoring()
            updateAssistLayoutModifierMonitoringState()
            picker.hide()
            return
        }

        activeSession = session
        startEscapeMonitoring()
        // Candidate-specific constraint plans answer only whether that candidate
        // may be selected. They must not own the picker panel's bounds: using
        // the largest predicted candidate frame makes one app's minimum size
        // stretch the shared UI into neighboring zones. Both selectable zones
        // and non-selectable vacant blur use this single structural partition.
        let presentationFramesByZone: [SnapZone: CGRect] = Dictionary(
            uniqueKeysWithValues: remaining.map { remainingZone in
                let resolved = recordedSnapFrame(
                    for: remainingZone,
                    on: screen,
                    memberScope: assistMemberScope
                ).intersection(screen.visibleFrame)
                let frame = resolved.isNull
                    || resolved.width <= 1
                    || resolved.height <= 1
                    ? remainingZone.frame(in: screen)
                    : resolved
                return (remainingZone, frame)
            }
        )
        let zoneFrames: [SnapZone: CGRect] = Dictionary(
            uniqueKeysWithValues: remaining.compactMap { remainingZone -> (SnapZone, CGRect)? in
                guard let zoneCandidates = candidatesByZone[remainingZone],
                      !zoneCandidates.isEmpty,
                      let frame = presentationFramesByZone[remainingZone]
                else { return nil }
                return (remainingZone, frame)
            }
        )
        let backdropFrames = remaining.compactMap { remainingZone
            -> CGRect? in
            guard candidatesByZone[remainingZone]?.isEmpty ?? true else {
                return nil
            }
            return presentationFramesByZone[remainingZone]
        }
        let cancel: () -> Void = { [weak self] in
            guard let self else { return }
            // The picker owns cancellation while readiness is pending.
            // Clearing this flag makes the outstanding AX readiness poll stop
            // without committing a selection after the user dismissed Assist.
            self.isAssistPlacementPending = false
            self.activeSession = nil
            self.stopEscapeMonitoring()
            self.updateAssistLayoutModifierMonitoringState()
            self.refreshResizeHandles()
        }
        let select: (ManagedWindow, SnapZone) -> Void = {
            [weak self] selected, targetZone in
            guard let self else { return }

            // Keep the candidate presentation alive while AX readiness is
            // indeterminate. A transport timeout is not a negative eligibility
            // decision and must not erase the user's explicit selection.
            self.isAssistPlacementPending = true
            self.updateAssistLayoutModifierMonitoringState()
            let selectionGeneration = self.interactionGeneration
            self.windowService.waitForPlacementReadiness(
                selected,
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return self.isAssistPlacementPending
                        && self.interactionGeneration == selectionGeneration
                }
            ) { [weak self] readiness in
                guard let self,
                      self.interactionGeneration == selectionGeneration else { return }

                switch readiness {
                case .ready(let readyWindow):
                    guard readyWindow.stableIdentity == selected.stableIdentity else {
                        self.isAssistPlacementPending = false
                        self.picker.allowAnotherSelection()
                        self.updateAssistLayoutModifierMonitoringState()
                        return
                    }
                    // Readiness ownership ends here. Hand presentation to the
                    // snap transaction before retiring the picker so the final
                    // Assist placement can perform its normal post-snap rebuild.
                    self.isAssistPlacementPending = false
                    self.picker.hide()
                    self.stopEscapeMonitoring()
                    self.updateAssistLayoutModifierMonitoringState()
                    self.activeSession = session
                    self.snap(
                        readyWindow,
                        to: targetZone,
                        on: screen,
                        continueAssist: true,
                        raiseAfterInitialPlacement: true
                    ) { [weak self] succeeded in
                        guard let self else { return }
                        if !succeeded {
                            self.activeSession = nil
                            self.picker.hide()
                            self.updateAssistLayoutModifierMonitoringState()
                            self.refreshResizeHandles()
                        }
                    }

                case .unavailable:
                    // Confirmed disappearance/ineligibility invalidates only
                    // this candidate, not the entire Assist transaction. Rebuild
                    // from the still-valid occupied session so another target
                    // can be chosen.
                    self.isAssistPlacementPending = false
                    self.activeSession = session
                    self.presentAssist(session: session, on: screen)

                case .indeterminate:
                    // Preserve the user's session and current picker. A later
                    // click may retry once AX has settled; no structural or
                    // placement state is destroyed from unknown evidence.
                    self.isAssistPlacementPending = false
                    self.picker.allowAnotherSelection()
                    self.updateAssistLayoutModifierMonitoringState()
                }
            }
        }

        let updatedExistingPicker = picker.isVisible && picker.updateLayout(
            windowsByZone: candidatesByZone,
            zoneFrames: zoneFrames,
            backdropFrames: backdropFrames,
            onCancel: cancel,
            onSelect: select
        )
        if !updatedExistingPicker, activeSession != nil {
            picker.show(
                windowsByZone: candidatesByZone,
                zoneFrames: zoneFrames,
                backdropFrames: backdropFrames,
                previewCandidateBudgetCount: candidates.count,
                previewProvider: { [weak self] windowID in
                    guard let self,
                          self.settings.windowPreviewsEnabled else { return nil }
                    return self.windowService.previewCGImage(
                        for: windowID,
                        capacityWait:
                            PreviewCaptureAdmissionPolicy.assistCapacityWait,
                        shouldCapture: { [weak self] in
                            self?.settings.windowPreviewsEnabled == true
                        }
                    )
                },
                onCancel: cancel,
                onSelect: select
            )
        }
        updateAssistLayoutModifierMonitoringState()
    }

    private func assistCandidatesByZone(
        zones: [SnapZone],
        candidates: [ManagedWindow],
        on screen: NSScreen,
        observationScene: SnapObservationScene
    ) -> [SnapZone: [ManagedWindow]] {
        var result: [SnapZone: [ManagedWindow]] = [:]
        for zone in zones {
            for candidate in candidates {
                guard assistPredictedSnapFrame(
                    for: zone,
                    on: screen,
                    window: candidate,
                    observationScene: observationScene
                ) != nil else { continue }
                result[zone, default: []].append(candidate)
            }
        }
        return result
    }

    private static var currentAssistLayoutModifierIsPressed: Bool {
        AssistLayoutModifierPolicy.isPressed(
            in: CGEventSource.flagsState(.combinedSessionState)
        )
    }

    private func updateAssistLayoutModifierMonitoringState() {
        guard isEnabled,
              isControllerRunning,
              isUserSessionActive,
              !isApplicationInteractionSuppressed,
              settings.assistLayoutSwitchingEnabled,
              !isAssistPlacementPending,
              !isSnapPlacementInProgress,
              picker.isVisible,
              let session = activeSession,
              AssistCompletionLayoutPolicy.layoutForModifierState(
                  occupiedZones: Set(session.occupiedZones.keys),
                  currentLayout: session.layoutZones,
                  modifierIsPressed:
                    Self.currentAssistLayoutModifierIsPressed
              ) != nil else {
            stopAssistLayoutModifierMonitoring()
            return
        }

        if assistLayoutModifierMonitorTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
                [weak self] _ in
                self?.applyAssistLayoutModifierState(
                    SnapController.currentAssistLayoutModifierIsPressed
                )
            }
            assistLayoutModifierMonitorTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if observedAssistLayoutModifierIsPressed == nil {
            // presentAssist already resolved the initial surface from the
            // current modifier state. Seed observation without rebuilding the
            // same picker once more; only a later edge triggers a layout swap.
            observedAssistLayoutModifierIsPressed =
                Self.currentAssistLayoutModifierIsPressed
        }
    }

    private func applyAssistLayoutModifierState(_ isPressed: Bool) {
        guard observedAssistLayoutModifierIsPressed != isPressed else {
            return
        }
        guard isEnabled,
              isControllerRunning,
              isUserSessionActive,
              !isApplicationInteractionSuppressed,
              settings.assistLayoutSwitchingEnabled,
              !isAssistPlacementPending,
              !isSnapPlacementInProgress,
              picker.isVisible,
              var session = activeSession,
              let layout = AssistCompletionLayoutPolicy.layoutForModifierState(
                  occupiedZones: Set(session.occupiedZones.keys),
                  currentLayout: session.layoutZones,
                  modifierIsPressed: isPressed
              ),
              let displayID = session.displayID,
              let screen = screen(withDisplayID: displayID) else {
            stopAssistLayoutModifierMonitoring()
            return
        }
        observedAssistLayoutModifierIsPressed = isPressed
        guard Set(layout) != Set(session.layoutZones) else { return }
        session.layoutZones = layout
        activeSession = session
        presentAssist(session: session, on: screen)
    }

    /// Modifier monitoring is derived Assist presentation work. It polls the
    /// combined-session Option state only while the switchable picker is visible
    /// and is revoked by every path that supersedes or ends that session. No
    /// keyboard event is consumed and no persistent/global command is created.
    func stopAssistLayoutModifierMonitoring() {
        assistLayoutModifierMonitorTimer?.invalidate()
        assistLayoutModifierMonitorTimer = nil
        observedAssistLayoutModifierIsPressed = nil
    }

    private func currentAssistCandidateExclusions(
        from capturedIDs: Set<String>
    ) -> Set<String> {
        // A placement-start snapshot is not authoritative after replacement.
        // Keep excluding only windows that are still structurally reserved now;
        // displaced members whose lock/group was committed away must become
        // eligible Assist candidates immediately.
        let groupedIDs = explicitGroupStore.groups.reduce(into: Set<String>()) {
            result, group in
            result.formUnion(group.memberIDs)
        }
        return AssistCandidateExclusionPolicy.currentExclusions(
            capturedIDs: capturedIDs,
            lockedIDs: Set(lockedPlacements.compactMap {
                identity, placement in
                AssistCandidateReservationPolicy.isReserved(
                    placementZone: placement.zone
                ) ? identity : nil
            }),
            groupedIDs: groupedIDs
        )
    }

    private func makeSession(startingWith zone: SnapZone, window: ManagedWindow, screen: NSScreen) -> LayoutSession {
        let group = explicitGroupStore.group(
            containing: window.stableIdentity
        )
        let memberScope = group?.memberIDs
            ?? activeSnapPlacementContext?.memberIDs
            ?? [window.stableIdentity]
        // Preserve the existing confirmed-closure cleanup path, but do not
        // let optional AX discovery decide which structurally locked cells are
        // occupied for Assist. Unknown/mismatched presentation remains an
        // occupied logical slot until its dedicated lifecycle owner confirms
        // departure.
        _ = activeLocks(
            for: screen,
            validZones: SnapZone.allCases,
            memberScope: memberScope
        )
        guard let currentDisplayID = displayID(for: screen) else {
            return LayoutSession(
                groupID: group?.id,
                excludedCandidateIDs: currentAssistCandidateExclusions(
                    from: activeSnapPlacementContext?
                        .excludedAssistCandidateIDs ?? []
                ),
                displayID: nil,
                layoutZones: [],
                occupiedZones: [:]
            )
        }
        let currentLocks = lockedPlacements.values.filter { placement in
            placement.displayID == currentDisplayID
                && memberScope.contains(placement.stableIdentity)
                && placement.zone != .maximize
        }
        let layoutZones = layoutZones(startingWith: zone, activeLocks: currentLocks)
        guard !layoutZones.isEmpty else {
            return LayoutSession(
                groupID: group?.id,
                excludedCandidateIDs: currentAssistCandidateExclusions(
                    from: activeSnapPlacementContext?
                        .excludedAssistCandidateIDs ?? []
                ),
                displayID: currentDisplayID,
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
            excludedCandidateIDs: currentAssistCandidateExclusions(
                from: activeSnapPlacementContext?
                    .excludedAssistCandidateIDs ?? []
            ),
            displayID: currentDisplayID,
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
        memberScope: Set<String>? = nil,
        observationScene: SnapObservationScene? = nil
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
        let visibleWindows = observationScene?.visibleWindows
            ?? managedVisibleWindows()
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
        window: ManagedWindow?,
        observationScene: SnapObservationScene? = nil
    ) -> CGRect {
        let context: SnapPlacementContext?
        let memberScope: Set<String>?
        if let window {
            context = snapPlacementContext(
                for: window,
                zone: zone,
                on: screen,
                observationScene: observationScene
            )
            memberScope = context?.memberIDs
        } else if let session = activeSession {
            context = nil
            memberScope = session.groupID.flatMap {
                explicitGroupStore.group(id: $0)?.memberIDs
            }?.union(session.occupiedStableIDs)
                ?? session.occupiedStableIDs
        } else {
            context = nil
            memberScope = nil
        }
        let resolved = recordedSnapFrame(
            for: zone,
            on: screen,
            excluding: window?.stableIdentity,
            memberScope: memberScope
        )
        guard let window, let context else { return resolved }
        switch initialConstraintSnapPlan(
            candidate: window,
            desiredFrame: resolved,
            zone: zone,
            on: screen,
            context: context,
            observationScene: observationScene
        ) {
        case .ready(let plan):
            return plan.candidateTargetFrame ?? resolved
        case .confirmedInfeasible, .indeterminate:
            // Drag guides remain available for unknown/new constraints so the
            // first confirmed rejection can still trigger learning. Assist uses
            // the stricter zone-specific helper below for already-known
            // infeasible candidates.
            return resolved
        }
    }

    private func assistPredictedSnapFrame(
        for zone: SnapZone,
        on screen: NSScreen,
        window: ManagedWindow,
        observationScene: SnapObservationScene
    ) -> CGRect? {
        let context = snapPlacementContext(
            for: window,
            zone: zone,
            on: screen,
            observationScene: observationScene
        )
        let memberScope = context?.memberIDs
        let resolved = recordedSnapFrame(
            for: zone,
            on: screen,
            excluding: window.stableIdentity,
            memberScope: memberScope
        )
        guard let context else { return resolved }
        switch initialConstraintSnapPlan(
            candidate: window,
            desiredFrame: resolved,
            zone: zone,
            on: screen,
            context: context,
            observationScene: observationScene
        ) {
        case .ready(let plan):
            return plan.candidateTargetFrame ?? resolved
        case .confirmedInfeasible:
            return nil
        case .indeterminate:
            // Unknown AX/discovery evidence is not ineligibility. Keep the
            // candidate selectable and revalidate when the user acts.
            return resolved
        }
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
                    pid: placement.pid,
                    messagingTimeout: AXMessagingTimeoutPolicy.passiveObservation
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

    private func revalidateMultiMemberReplacementPlan(
        _ plan: MultiMemberReplacementPlan,
        zone: SnapZone,
        displayID: CGDirectDisplayID
    ) -> Bool {
        let expectedMemberIDs = plan.displacedMemberIDs
            .union(plan.retainedMemberIDs)
        guard plan.incomingZone == zone,
              let group = explicitGroupStore.group(id: plan.targetGroupID),
              group.displayID == displayID,
              MultiMemberReplacementStructuralPolicy.matchesCapturedStructure(
                  expectedMemberIDs: expectedMemberIDs,
                  expectedZonesByMemberID: plan.targetZonesByMemberID,
                  currentMemberIDs: group.memberIDs,
                  currentZonesByMemberID: group.layout.zonesByMemberID
              ),
              plan.displacedMemberIDs.count >= 2 else {
            return false
        }

        var placementsByIdentity: [String: SplitPlacementGeometry] = [:]
        for memberID in group.memberIDs {
            guard let locked = lockedPlacements[memberID],
                  locked.displayID == displayID,
                  let groupZone = group.layout.zonesByMemberID[memberID],
                  locked.zone == groupZone else {
                return false
            }
            // Revalidation protects the captured pre-mutation structure.
            // Retained members may already have accepted a new canonical
            // divider by the time registration runs; comparing those new
            // frames with displaced members that intentionally stay at their
            // old desktop frames would reject a valid constraint-driven
            // replacement. The authoritative lock is the pre-operation
            // geometry that the placement context already qualified.
            placementsByIdentity[memberID] = SplitPlacementGeometry(
                stableIdentity: memberID,
                zone: groupZone,
                frame: locked.appliedFrame
            )
        }

        let displacedPlacements = plan.displacedMemberIDs.compactMap {
            placementsByIdentity[$0]
        }
        let retainedPlacements = plan.retainedMemberIDs.compactMap {
            placementsByIdentity[$0]
        }
        guard displacedPlacements.count == plan.displacedMemberIDs.count,
              retainedPlacements.count == plan.retainedMemberIDs.count else {
            return false
        }

        switch plan.kind {
        case .partitionBoundary:
            guard !plan.retainedMemberIDs.isEmpty else { return false }
            return SplitLayoutGeometry.hasStraightSharedBoundaryBetweenPartitions(
                displacedPlacements: displacedPlacements,
                retainedPlacements: retainedPlacements
            )
        case .fullGroupCover:
            return plan.retainedMemberIDs.isEmpty
                && plan.displacedMemberIDs == group.memberIDs
                && SnapPlacementLayerPolicy.incomingExactlyCovers(
                    existingZones: Set(group.layout.zonesByMemberID.values),
                    incoming: plan.incomingZone
                )
        }
    }

    private func registerLock(
        for window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen,
        context: SnapPlacementContext?,
        acceptedFramesByIdentity: [String: CGRect]
    ) -> Bool {
        guard let currentDisplayID = displayID(for: screen) else {
            return false
        }
        if let context, context.displayID != currentDisplayID {
            return false
        }
        if let plan = context?.multiMemberReplacementPlan,
           !revalidateMultiMemberReplacementPlan(
               plan,
               zone: zone,
               displayID: currentDisplayID
           ) {
            return false
        }
        let fullGroupReplacementPlan = context?.multiMemberReplacementPlan
            .flatMap { plan in
                plan.kind == .fullGroupCover ? plan : nil
            }
        let previousLockedPlacements = lockedPlacements
        let previousGroupStore = explicitGroupStore
        let previousDetachedConnections = detachedConnections
        let previousInFlightPlacementIDs = inFlightPlacementIDs
        let previousPendingPlacementSnapshots = pendingPlacementSnapshots
        let previousRestoreFrames = restoreFrames
        let previousForegroundModes = groupForegroundModes
        let previousStagedDeparture = stagedGroupDeparture
        let previousPendingNativeResizeDeparture = pendingNativeResizeDeparture
        let previousActiveSession = activeSession
        let previousAssistPlacementPending = isAssistPlacementPending
        var registrationSucceeded = false
        isReconcilingPlacementMutation = true
        defer {
            if !registrationSucceeded {
                lockedPlacements = previousLockedPlacements
                explicitGroupStore = previousGroupStore
                detachedConnections = previousDetachedConnections
                inFlightPlacementIDs = previousInFlightPlacementIDs
                pendingPlacementSnapshots = previousPendingPlacementSnapshots
                restoreFrames = previousRestoreFrames
                groupForegroundModes = previousForegroundModes
                stagedGroupDeparture = previousStagedDeparture
                pendingNativeResizeDeparture = previousPendingNativeResizeDeparture
                activeSession = previousActiveSession
                isAssistPlacementPending = previousAssistPlacementPending
                updateSelectionMonitoringState()
            }
            isReconcilingPlacementMutation = false
        }

        // Existing members may already have accepted new geometry from the AX
        // mutation phase. Keep those frames provisional until this structural
        // registration transaction commits; any failure restores the captured
        // controller state before the outer physical rollback completes.
        for (identity, frame) in acceptedFramesByIdentity
            where identity != window.stableIdentity {
            if var placement = lockedPlacements[identity] {
                placement.appliedFrame = frame
                lockedPlacements[identity] = placement
            }
        }
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
        let targetMemberIDs = context?.targetGroupID.flatMap {
            explicitGroupStore.group(id: $0)?.memberIDs
        } ?? []
        let conflictingIDs = Set(lockedPlacements.compactMap { identity, placement -> String? in
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
            // The snap context already authorized the target/provisional
            // structural scope from exact identity evidence. Do not ask a new
            // broad AX census to decide whether that committed lock conflicts.
            // Maximized-layer conflicts are structurally explicit as well.
            return identity
        })
        if let plan = fullGroupReplacementPlan {
            guard conflictingIDs == plan.displacedMemberIDs,
                  let group = explicitGroupStore.group(id: plan.targetGroupID),
                  group.memberIDs == plan.displacedMemberIDs else {
                return false
            }
            let departure = ExplicitGroupDepartureSnapshot(
                groupID: group.id,
                memberIDs: group.memberIDs
            )
            guard retireExplicitGroup(
                departure,
                reason: .replacementDisplacement
            ) else {
                return false
            }
        } else {
            conflictingIDs.forEach { identity in
                // Replacing one occupied zone is a layout mutation, not
                // evidence that every peer left the desktop. Preserve the
                // unaffected locks; reconciliation after inserting the
                // incoming placement builds the new complete group atomically.
                let displacedZone = lockedPlacements[identity]?.zone
                lockedPlacements.removeValue(forKey: identity)
                if displacedZone == .maximize {
                    explicitGroupStore.clearMaximizedLayer(windowID: identity)
                }
                removeConnections(for: identity)
                restoreFrames.removeValue(forKey: identity)
            }
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
        if fullGroupReplacementPlan != nil {
            successorMemberScope = [window.stableIdentity]
        } else if let context {
            successorMemberScope = context.memberIDs
                .subtracting(conflictingIDs)
                .union([window.stableIdentity])
        } else {
            successorMemberScope = nil
        }
        let reconciled: Bool
        if fullGroupReplacementPlan != nil {
            // The exact-cover replacement intentionally leaves the incoming
            // window as a provisional single placement. The retired members are
            // immediately eligible for Assist, which may build the successor
            // group without preserving a one-member phantom group.
            reconciled = true
        } else {
            reconciled = reconcileExplicitGroupAfterLayoutMutation(
                preferredMemberID: window.stableIdentity,
                targetGroupID: context?.targetGroupID,
                memberScope: successorMemberScope
            )
        }
        guard reconciled else {
            // The deferred state rollback restores every authoritative value.
            // Presentation stays owned by the active snap until the outer AX
            // snapshot rollback settles; only then is it rebuilt once.
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
        registrationSucceeded = true
        updateSelectionMonitoringState()
        return true
    }

    func removeConnections(for stableIdentity: String) {
        detachedConnections = Set(
            detachedConnections.filter { !$0.contains(stableIdentity) }
        )
    }

    private func handleDisplayTopologyChange() {
        // Display attachment/removal/reconfiguration is an environment
        // transition, not a user-requested group departure. Quiesce geometry
        // derived from the old topology immediately, but do not run a broad AX
        // census from the notification callback and do not finalize a staged
        // drag departure merely because NSScreen changed.
        displayTopologyGeneration &+= 1
        groupSpaceMigrationLine.cancelForEnvironmentInvalidation()
        groupSpaceMigrationReservationShadowObserver
            .displayTopologyDidChange()
        // A queued post-migration foreground request is presentation-only and
        // is valid only for the display topology under which the migration
        // completed. Cancel both stored intents and any main-queue flush
        // before rebuilding display-derived geometry. Never let an old
        // explicit Proxy click raise windows after a display reconfiguration.
        resetGroupSpaceMigrationForegroundIntents()
        let topologyGeneration = displayTopologyGeneration

        resetSideDwellState()
        stopEscapeMonitoring()
        stopAssistLayoutModifierMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.hideAll()
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()

        let hadInFlightPlacement = isSnapPlacementInProgress
            || isAssistPlacementPending
            || !pendingPlacementSnapshots.isEmpty
        let hadHandleInteraction = handleResizeSession != nil
            || isHandleResizeFinalizing
        if hadInFlightPlacement || hadHandleInteraction {
            invalidatePendingOperations(
                rollbackPendingPlacements: true,
                finalizeStagedDeparture: false
            )
        }

        // Display reconfiguration invalidates gesture geometry, not structural
        // membership. Never finalize or discard a staged departure from this
        // environment signal. The post-transition recovery below reconstructs
        // the captured group from its still-authoritative placement locks.
        activeSession = nil
        activeTarget = nil
        dragDisplayID = nil
        dragScreenFrame = nil
        suppressedEntryEdge = nil
        suppressedDisplayID = nil
        // The physical gesture cannot safely retain old display geometry, but
        // resetting it must not dissolve the source group.
        resetDragState()

        // One bounded post-transition rebuild is enough. If AX or Window
        // Server state is still settling, refreshResizeHandles records liveness
        // debt and the existing 1 Hz Recovery owns later attempts. Repeating a
        // whole-group AX rebuild several times during Sidecar/display attach can
        // otherwise monopolize the main run loop exactly when clients are slow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.displayTopologyGeneration == topologyGeneration else {
                return
            }
            _ = self.restoreStagedGroupDepartureIfPossible()
            self.refreshResizeHandles()
        }

        activeWindowObserver.observeFrontmostApplication()
        scheduleSelectionDrivenGroupRaise(expectedPID: nil)
    }

    private func handleActiveSpaceChange() {
        // Active Space changes occur both on true Mission Control exit and
        // while the accepted destination is changing. Hide immediately, but
        // do not terminate the reservation-owned observer scene. Its frozen
        // capture baseline can independently prove either continued Mission
        // Control geometry or the normal desktop on subsequent 10 Hz probes.
        // Snapshot the narrow Proxy-selection owner before any environment
        // cleanup mutates presentation. Migration presentation ownership is
        // intentionally excluded: it owns its own observer/transport line but
        // must not preserve unrelated Proxy surfaces or ordinary raises.
        let selectedActivation = activeMissionControlProxyActivation
        let cleanupDecision = MissionControlActiveSpaceCleanupPolicy.decision(
            confirmationOwnerGroupID: missionControlGroupProxyController
                .selectionConfirmationOwnerGroupID,
            activationOwnerGroupID: selectedActivation?.groupID,
            migrationPresentationIsOwned:
                groupSpaceMigrationLine.ownsPresentationTransaction
        )

        groupSpaceMigrationReservationShadowObserver
            .suppressPresentationImmediately()
        groupSpaceMigrationLine.noteActiveSpaceChanged()
        if handleResizeSession != nil {
            cancelHandleResize(restoreOriginalFrames: true)
        }
        resizeHandleOverlay.hideAll()
        missionControlGroupProxyController.retireUnownedProxies(
            preservingGroupIDs: cleanupDecision.preservedProxyGroupIDs
        )
        lastGroupWindowServerEvidenceByIdentity.removeAll()
        resetGroupPresentationTransitionRecovery()
        explicitGroupStore.suspendForSpaceTransition()
        // A Space transition is an environment event, not proof that the
        // staged member left its group. Quiesce pending work without converting
        // the gesture snapshot into a destructive departure commit. A restore
        // transaction is already exclusive and owns its own success/rollback;
        // do not invalidate its generation from an environment notification.
        if !isRestoreTransactionActive {
            invalidatePendingOperations(
                finalizeStagedDeparture: false,
                preserveMissionControlProxyActivation:
                    cleanupDecision.preservesProxyActivation
            )
        }
        resetSideDwellState()
        stopEscapeMonitoring()
        stopAssistLayoutModifierMonitoring()
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
                _ = self.restoreStagedGroupDepartureIfPossible()
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

    func invalidatePendingOperations(
        rollbackPendingPlacements: Bool = true,
        finalizeStagedDeparture: Bool = true,
        preserveMissionControlProxyActivation: Bool = false
    ) {
        if finalizeStagedDeparture {
            finalizeStagedGroupDepartureIfNeeded()
        }
        interactionGeneration &+= 1
        deferredPlainClickPoint = nil
        deferredSelectionExpectedPID = nil
        hasDeferredSelectionSignal = false
        handlePresentationRevalidationGeneration &+= 1
        resetMissionControlPresentationRetryDebt()
        invalidatePendingGroupRaise(
            preservingMissionControlProxyActivation:
                preserveMissionControlProxyActivation
        )
        invalidatePendingSelectionRaise()
        resetIncompleteHandleGeometryRecovery()
        isAssistPlacementPending = false
        stopAssistLayoutModifierMonitoring()
        if !isSnapRollbackActive {
            isSnapPlacementInProgress = false
            snapPlacementInteractionGeneration = nil
            activeSnapPlacementContext = nil
        }
        if !isConstraintMeasurementActive
            && !isRestoreTransactionActive
            && !isSnapRollbackActive
            && !isHandleResizeRollbackActive
            && !groupSpaceMigrationLine.ownsWindowMutationTransaction {
            // Constraint measurement, explicit Restore, snap rollback, and a
            // shared-resize rollback or dispatched Space migration each owns an
            // atomic external-window transaction while its flag/phase is set.
            // Let bounded
            // settlement/rollback complete; canceling the shared AX frame
            // operation here could strand a partial layout with no remaining
            // authoritative restore owner. Active Space changes are expected
            // during migration and must not cancel its destination frame batch.
            windowService.cancelAllFrameOperations()
        }
        let invalidatedHandleSession = handleResizeSession
            ?? (isHandleResizeRollbackActive ? nil : finalizingHandleResizeSession)
        handleResizeSession = nil
        if !isHandleResizeRollbackActive {
            finalizingHandleResizeSession = nil
        }
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
        } else if !isHandleResizeRollbackActive {
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
        if isConstraintMeasurementActive
            || isConstraintPermissionPromptActive
            || isRestoreTransactionActive {
            stopEscapeMonitoring()
            stopAssistLayoutModifierMonitoring()
            overlay.hide()
            picker.hide()
            virtualResizeOverlay.hideAll()
            return
        }
        if handleResizeSession != nil {
            cancelHandleResize(restoreOriginalFrames: true)
            return
        }
        invalidatePendingOperations()
        stopEscapeMonitoring()
        stopAssistLayoutModifierMonitoring()
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
        pendingDragWindowServerFrame = nil
        pendingDragCurrentWindowServerFrame = nil
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

        // Mouse-up is also authoritative for display ownership. A fast throw
        // can cross a shared display edge after the final drag callback. Apply
        // the same entry-band suppression here so a one-pixel excursion onto
        // a bottom/side-attached display cannot silently choose that display's
        // visibleFrame and commit a placement there.
        updateDisplayTransition(
            to: screen,
            displayID: displayID,
            point: point
        )

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
           let entryEdge = DisplayTransitionPolicy.sharedEntryEdge(
               from: previousFrame,
               to: screen.frame,
               at: point
           ) {
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

    func screen(containing point: CGPoint) -> NSScreen? {
        screenOwning(point)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
