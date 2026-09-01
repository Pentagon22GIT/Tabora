import CoreGraphics
import Foundation

/// Read-only presentation observation result. This state is deliberately
/// narrower than the migration transaction state: it can only decide whether
/// reservation shadow presentation is safe to show, should be hidden, or has
/// returned to the normal desktop.
enum GroupSpaceMigrationReservationShadowObservationState: Equatable {
    case transformed
    case normal
    case unresolved
}

struct GroupSpaceMigrationReservationShadowObservationSample {
    let state: GroupSpaceMigrationReservationShadowObservationState
    let windowServerSnapshot: [WindowOcclusionSnapshot]
}

struct GroupSpaceMigrationReservationShadowExitProbeSample {
    let state: GroupSpaceMigrationReservationShadowObservationState
    let sentinelFrames: [GroupSpaceMigrationReservationShadowIdentity: CGRect]
}

/// Immutable presentation-only desktop baseline captured at the same accepted
/// migration boundary as the reservation. The dedicated observer must not
/// depend on `lastGroupWindowServerEvidenceByIdentity`: that controller cache
/// is intentionally cleared by ordinary Space-transition recovery and is not
/// reservation lifetime state.
struct GroupSpaceMigrationReservationShadowBaselineMember: Equatable {
    let stableIdentity: String
    let identity: GroupSpaceMigrationReservationShadowIdentity
    let expectedFrame: CGRect
}

struct GroupSpaceMigrationReservationShadowBaseline: Equatable {
    let groupID: SnapGroupID
    let members: [GroupSpaceMigrationReservationShadowBaselineMember]

    init?(capture: GroupSpaceMigrationCapture) {
        let capturedMembers = capture.members.map { member in
            GroupSpaceMigrationReservationShadowBaselineMember(
                stableIdentity: member.stableIdentity,
                identity: GroupSpaceMigrationReservationShadowIdentity(
                    pid: member.pid,
                    windowID: member.windowID
                ),
                expectedFrame: member.sourceFrame
            )
        }.sorted { $0.stableIdentity < $1.stableIdentity }
        guard capturedMembers.count >= 2,
              Set(capturedMembers.map(\.stableIdentity)).count
                == capturedMembers.count,
              Set(capturedMembers.map(\.identity)).count
                == capturedMembers.count,
              capturedMembers.allSatisfy({
                  $0.expectedFrame.width > 1 && $0.expectedFrame.height > 1
              }) else { return nil }
        groupID = capture.structuralSnapshot.groupID
        members = capturedMembers
    }

    init(
        groupID: SnapGroupID,
        members: [GroupSpaceMigrationReservationShadowBaselineMember]
    ) {
        self.groupID = groupID
        self.members = members.sorted { $0.stableIdentity < $1.stableIdentity }
    }
}

enum GroupSpaceMigrationReservationShadowObservationPolicy {
    static func observe(
        baseline: GroupSpaceMigrationReservationShadowBaseline,
        snapshot: [WindowOcclusionSnapshot]
    ) -> GroupPresentationTransitionObservation {
        let evidence = baseline.members.map { member in
            GroupWindowServerEvidence(
                stableIdentity: member.stableIdentity,
                pid: member.identity.pid,
                windowID: member.identity.windowID,
                expectedFrame: member.expectedFrame
            )
        }
        let normalGeometryMemberIDs = Set(baseline.members.compactMap {
            member -> String? in
            guard let surface = snapshot.first(where: {
                $0.pid == member.identity.pid
                    && $0.windowID == member.identity.windowID
                    && $0.layer == 0
            }), GroupWindowServerEvidenceBaselinePolicy
                .framesRepresentTheSameDesktopGeometry(
                    accessibilityFrame: member.expectedFrame,
                    windowServerFrame: surface.frame
                ) else { return nil }
            return member.stableIdentity
        })
        return GroupPresentationTransitionPolicy.observe(
            evidence: evidence,
            expectedMemberCount: baseline.members.count,
            visibleMemberIDs: normalGeometryMemberIDs,
            snapshot: snapshot
        )
    }

    static func aggregate(
        _ observations: [GroupPresentationTransitionObservation]
    ) -> GroupSpaceMigrationReservationShadowObservationState {
        guard !observations.isEmpty else { return .normal }
        if observations.contains(.transformed) { return .transformed }
        if observations.allSatisfy({ $0 == .normal }) { return .normal }
        return .unresolved
    }
}

enum GroupSpaceMigrationReservationShadowProbePolicy {
    static func classify(
        expectedFrame: CGRect,
        currentFrame: CGRect?
    ) -> GroupSpaceMigrationReservationShadowObservationState {
        guard let currentFrame,
              expectedFrame.width > 1,
              expectedFrame.height > 1,
              currentFrame.width > 1,
              currentFrame.height > 1 else {
            return .unresolved
        }
        if GroupWindowServerEvidenceBaselinePolicy.framesRepresentTheSameDesktopGeometry(
            accessibilityFrame: expectedFrame,
            windowServerFrame: currentFrame
        ) {
            return .normal
        }
        let widthScale = currentFrame.width / expectedFrame.width
        let heightScale = currentFrame.height / expectedFrame.height
        let hasMaterialScaleDelta = abs(widthScale - 1)
                >= GroupPresentationTransitionPolicy.defaultMinimumScaleDelta
            || abs(heightScale - 1)
                >= GroupPresentationTransitionPolicy.defaultMinimumScaleDelta
        guard hasMaterialScaleDelta,
              abs(widthScale - heightScale)
                <= GroupPresentationTransitionPolicy.defaultMaximumScaleAnisotropy
        else { return .unresolved }
        return .transformed
    }

    static func aggregate(
        _ observations: [GroupSpaceMigrationReservationShadowObservationState]
    ) -> GroupSpaceMigrationReservationShadowObservationState {
        guard !observations.isEmpty else { return .normal }
        if observations.contains(.transformed) { return .transformed }
        if observations.allSatisfy({ $0 == .normal }) { return .normal }
        return .unresolved
    }
}

enum GroupSpaceMigrationReservationShadowRearmPolicy {
    static func allowsRefreshOneShot(
        lifecycleRearmIsRequired: Bool
    ) -> Bool {
        !lifecycleRearmIsRequired
    }
}

enum GroupSpaceMigrationReservationShadowObservationDisposition: Equatable {
    case ignore
    case showCandidate
    case hide
    case hideAndEndScene
}

struct GroupSpaceMigrationReservationShadowObservationGate: Equatable {
    private(set) var sceneIsActive = false
    private(set) var consecutiveNormalSamples = 0

    mutating func beginScene() {
        sceneIsActive = true
        consecutiveNormalSamples = 0
    }

    mutating func consume(
        _ state: GroupSpaceMigrationReservationShadowObservationState
    ) -> GroupSpaceMigrationReservationShadowObservationDisposition {
        guard sceneIsActive else { return .ignore }
        switch state {
        case .transformed:
            consecutiveNormalSamples = 0
            return .showCandidate
        case .unresolved:
            consecutiveNormalSamples = 0
            return .hide
        case .normal:
            consecutiveNormalSamples += 1
            guard consecutiveNormalSamples >=
                    GroupSpaceMigrationReservationShadowObserver
                        .normalSamplesRequiredToEndScene else {
                return .hide
            }
            sceneIsActive = false
            consecutiveNormalSamples = 0
            return .hideAndEndScene
        }
    }

    mutating func endScene() {
        sceneIsActive = false
        consecutiveNormalSamples = 0
    }
}

enum GroupSpaceMigrationReservationShadowGeometryRecoveryReason: Equatable {
    case reservation
    case pointer
    case lifecycleHint
    case geometryChange

    var requiredStableSampleCount: Int {
        switch self {
        case .reservation:
            return 2
        case .pointer, .lifecycleHint, .geometryChange:
            return 3
        }
    }

    var minimumStableDuration: TimeInterval {
        switch self {
        case .reservation:
            return 0.08
        case .pointer, .geometryChange:
            return 0.18
        case .lifecycleHint:
            return 0.22
        }
    }
}

/// A transform sample proves Mission Control, but not that WindowManager has
/// finished retiling the thumbnails. Presentation is rebuilt only after the
/// exact tracked surfaces stop changing for a bounded number of 10 Hz samples.
struct GroupSpaceMigrationReservationShadowGeometrySettleGate: Equatable {
    static let frameTolerance: CGFloat = 1.5

    private(set) var previousFrames:
        [GroupSpaceMigrationReservationShadowIdentity: CGRect] = [:]
    private(set) var stableSampleCount = 0
    private(set) var stableSince: TimeInterval?
    private(set) var isSettled = false

    mutating func reset() {
        previousFrames.removeAll()
        stableSampleCount = 0
        stableSince = nil
        isSettled = false
    }

    mutating func observe(
        frames: [GroupSpaceMigrationReservationShadowIdentity: CGRect],
        now: TimeInterval,
        reason: GroupSpaceMigrationReservationShadowGeometryRecoveryReason
    ) -> Bool {
        guard !frames.isEmpty else {
            reset()
            return false
        }
        guard sameGeometry(previousFrames, frames) else {
            previousFrames = frames
            stableSampleCount = 1
            stableSince = now
            isSettled = false
            return false
        }
        stableSampleCount += 1
        guard let stableSince,
              stableSampleCount >= reason.requiredStableSampleCount,
              now - stableSince >= reason.minimumStableDuration else {
            return false
        }
        isSettled = true
        return true
    }

    static func frames(
        from snapshot: [WindowOcclusionSnapshot]
    ) -> [GroupSpaceMigrationReservationShadowIdentity: CGRect] {
        Dictionary(
            snapshot.compactMap { surface in
                guard surface.layer == 0 else { return nil }
                return (
                    GroupSpaceMigrationReservationShadowIdentity(
                        pid: surface.pid,
                        windowID: surface.windowID
                    ),
                    surface.frame
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func probeMatchesSettledGeometry(
        _ probeFrames: [GroupSpaceMigrationReservationShadowIdentity: CGRect],
        settledFrames: [GroupSpaceMigrationReservationShadowIdentity: CGRect]
    ) -> Bool {
        guard !probeFrames.isEmpty else { return false }
        return probeFrames.allSatisfy { identity, probeFrame in
            guard let settledFrame = settledFrames[identity] else { return false }
            return framesMatch(settledFrame, probeFrame)
        }
    }

    private func sameGeometry(
        _ lhs: [GroupSpaceMigrationReservationShadowIdentity: CGRect],
        _ rhs: [GroupSpaceMigrationReservationShadowIdentity: CGRect]
    ) -> Bool {
        guard !lhs.isEmpty,
              lhs.count == rhs.count,
              Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { identity, frame in
            guard let other = rhs[identity] else { return false }
            return Self.framesMatch(frame, other)
        }
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= frameTolerance
            && abs(lhs.minY - rhs.minY) <= frameTolerance
            && abs(lhs.width - rhs.width) <= frameTolerance
            && abs(lhs.height - rhs.height) <= frameTolerance
    }
}

/// Session-scoped observer used only while an accepted Mission Control group
/// migration reservation exists. It intentionally owns one independent 10 Hz
/// read-only timer instead of attaching shadow refresh work to the controller's
/// broader resize/group refresh path.
///
/// The timer has two modes:
/// - acquiring: read the exact reserved surfaces until their Mission Control
///   geometry settles, then render once;
/// - settled: stop refreshing presentation geometry. Poll only one exact
///   sentinel surface per reserved group so Mission Control exit/unexpected
///   retiling can fail closed without a whole-desktop census.
///
/// The dependency is one-way:
/// migration truth -> reservation shadow observer -> presenter.
/// No observer or presenter state is exposed back to FIFO, dispatch, rollback,
/// Space writes, AX mutation, foreground authorization, or group membership.
final class GroupSpaceMigrationReservationShadowObserver {
    static let observationInterval: TimeInterval = 0.10
    static let normalSamplesRequiredToEndScene = 2

    static func shouldProcessSnapshot(
        pointerInteractionIsActive: Bool
    ) -> Bool {
        !pointerInteractionIsActive
    }

    private let presenter: GroupSpaceMigrationReservationShadowPresenter
    private let isObservationAllowed: () -> Bool
    private let pointerButtonIsDown: () -> Bool
    private let geometrySampleProvider:
        ([GroupSpaceMigrationReservationShadowBaseline]) ->
            GroupSpaceMigrationReservationShadowObservationSample
    private let exitProbeProvider:
        ([GroupSpaceMigrationReservationShadowBaseline]) ->
            GroupSpaceMigrationReservationShadowExitProbeSample

    private var baselinesByGroupID:
        [SnapGroupID: GroupSpaceMigrationReservationShadowBaseline] = [:]
    private var monitorTimer: Timer?
    private var oneShotGeneration: UInt64 = 0
    private var oneShotIsScheduled = false
    private var pointerInteractionIsActive = false
    private var observationGate =
        GroupSpaceMigrationReservationShadowObservationGate()
    private var geometrySettleGate =
        GroupSpaceMigrationReservationShadowGeometrySettleGate()
    private var geometryRecoveryReason:
        GroupSpaceMigrationReservationShadowGeometryRecoveryReason = .reservation
    private var geometryAcquisitionIsRequired = true
    private var lifecycleRearmIsRequired = false
    private var settledFrames:
        [GroupSpaceMigrationReservationShadowIdentity: CGRect] = [:]

    init(
        presenter: GroupSpaceMigrationReservationShadowPresenter,
        isObservationAllowed: @escaping () -> Bool,
        pointerButtonIsDown: @escaping () -> Bool,
        geometrySampleProvider: @escaping (
            [GroupSpaceMigrationReservationShadowBaseline]
        ) -> GroupSpaceMigrationReservationShadowObservationSample,
        exitProbeProvider: @escaping (
            [GroupSpaceMigrationReservationShadowBaseline]
        ) -> GroupSpaceMigrationReservationShadowExitProbeSample
    ) {
        self.presenter = presenter
        self.isObservationAllowed = isObservationAllowed
        self.pointerButtonIsDown = pointerButtonIsDown
        self.geometrySampleProvider = geometrySampleProvider
        self.exitProbeProvider = exitProbeProvider
    }

    var isMonitoring: Bool { monitorTimer != nil }
    var activeReservationCount: Int { baselinesByGroupID.count }
    var isGeometryAcquisitionActive: Bool { geometryAcquisitionIsRequired }

    deinit {
        monitorTimer?.invalidate()
    }

    func reservationDidBegin(_ capture: GroupSpaceMigrationCapture) {
        guard let baseline = GroupSpaceMigrationReservationShadowBaseline(
            capture: capture
        ) else { return }
        let wasEmpty = baselinesByGroupID.isEmpty
        if wasEmpty {
            lifecycleRearmIsRequired = false
        }
        baselinesByGroupID[baseline.groupID] = baseline
        if wasEmpty || !observationGate.sceneIsActive {
            observationGate.beginScene()
        }
        requestReservationGeometryRefresh(hidesPresentation: false)
    }

    func reservationDidRefresh(_ capture: GroupSpaceMigrationCapture) {
        let groupID = capture.structuralSnapshot.groupID
        guard baselinesByGroupID[groupID] != nil,
              observationGate.sceneIsActive,
              let baseline = GroupSpaceMigrationReservationShadowBaseline(
                  capture: capture
              ) else { return }
        baselinesByGroupID[groupID] = baseline
        requestReservationGeometryRefresh(hidesPresentation: true)
    }

    func reservationDidEnd(groupID: SnapGroupID) {
        baselinesByGroupID.removeValue(forKey: groupID)
        guard !baselinesByGroupID.isEmpty else {
            observationGate.endScene()
            stopObservationWork()
            resetGeometryObservation()
            presenter.missionControlDidBecomeAbsent()
            return
        }
        guard observationGate.sceneIsActive else { return }
        requestReservationGeometryRefresh(hidesPresentation: true)
    }

    /// Existing controller mouse monitors call this. No new event monitor is
    /// installed here. Presentation is hidden immediately; the transport line
    /// is never consulted or modified. The 10 Hz timer remains owned by the
    /// short-lived reservation scene, but its Window Server reads are skipped
    /// completely until mouse-up.
    func pointerInteractionDidBegin() {
        guard observationGate.sceneIsActive, !baselinesByGroupID.isEmpty else { return }
        guard !pointerInteractionIsActive else { return }
        pointerInteractionIsActive = true
        cancelPendingOneShot()
        beginGeometryAcquisition(reason: .pointer, hidesPresentation: false)
        presenter.pointerInteractionDidBegin()
    }

    func pointerInteractionDidEnd() {
        guard observationGate.sceneIsActive, !baselinesByGroupID.isEmpty else { return }
        pointerInteractionIsActive = false
        lifecycleRearmIsRequired = false
        beginGeometryAcquisition(reason: .pointer, hidesPresentation: false)
        presenter.pointerInteractionDidEnd()
        guard openGateIfAllowed() else { return }
        // Mouse-up starts recovery; it does not reopen presentation. A next-turn
        // sample becomes the first geometry baseline, then 10 Hz samples must
        // prove that WindowManager's post-drag animation has actually settled.
        scheduleOneShotObservation()
    }

    /// Early lifecycle hints improve exit UX without becoming migration truth.
    /// Cancel any queued one-shot so a stale transformed snapshot cannot flash
    /// the shadow back on during Mission Control's closing animation. If the
    /// hint was a false positive, the independent 10 Hz observer can recover
    /// only after transformed geometry becomes stably settled again.
    func suppressPresentationImmediately() {
        guard observationGate.sceneIsActive, !baselinesByGroupID.isEmpty else { return }
        lifecycleRearmIsRequired = true
        cancelPendingOneShot()
        beginGeometryAcquisition(reason: .lifecycleHint, hidesPresentation: false)
        presenter.suppressPresentationImmediately()
    }

    /// Call whenever the feature/controller environment gate may have changed.
    /// A closed gate invalidates the timer and hides presentation immediately.
    /// It never mutates migration truth.
    func gateDidChange() {
        guard !baselinesByGroupID.isEmpty else {
            stopObservationWork()
            resetGeometryObservation()
            presenter.missionControlDidBecomeAbsent()
            return
        }
        guard isObservationAllowed() else {
            closeGate()
            return
        }
        if !observationGate.sceneIsActive {
            observationGate.beginScene()
            beginGeometryAcquisition(reason: .reservation, hidesPresentation: true)
        }
        ensureTimer()
        if GroupSpaceMigrationReservationShadowRearmPolicy
            .allowsRefreshOneShot(
                lifecycleRearmIsRequired: lifecycleRearmIsRequired
            ) {
            scheduleOneShotObservation()
        }
    }

    func displayTopologyDidChange() {
        stopObservationWork()
        observationGate.endScene()
        resetGeometryObservation()
        baselinesByGroupID.removeAll()
        presenter.displayTopologyDidChange()
    }

    func resetAll() {
        stopObservationWork()
        observationGate.endScene()
        resetGeometryObservation()
        baselinesByGroupID.removeAll()
        presenter.resetAll()
    }

    private var currentBaselines: [GroupSpaceMigrationReservationShadowBaseline] {
        Array(baselinesByGroupID.values)
    }

    private func requestReservationGeometryRefresh(
        hidesPresentation: Bool
    ) {
        let allowsOneShot = GroupSpaceMigrationReservationShadowRearmPolicy
            .allowsRefreshOneShot(
                lifecycleRearmIsRequired: lifecycleRearmIsRequired
            )
        beginGeometryAcquisition(
            reason: allowsOneShot ? .reservation : .lifecycleHint,
            hidesPresentation: hidesPresentation
        )
        guard openGateIfAllowed(), allowsOneShot else { return }
        // Do not wait for the first 100 ms timer turn. An accepted reservation
        // or retarget can start settlement on the next run-loop turn, except
        // while an exit hint owns re-arm debt. In that state only the ordinary
        // 10 Hz observer may prove a stable Mission Control continuation.
        scheduleOneShotObservation()
    }

    private func openGateIfAllowed() -> Bool {
        guard isObservationAllowed() else {
            closeGate()
            return false
        }
        ensureTimer()
        return true
    }

    private func closeGate() {
        stopObservationWork()
        observationGate.endScene()
        resetGeometryObservation()
        presenter.missionControlDidBecomeAbsent()
    }

    private func ensureTimer() {
        guard monitorTimer == nil,
              observationGate.sceneIsActive,
              !baselinesByGroupID.isEmpty,
              isObservationAllowed() else { return }
        let timer = Timer(
            fire: Date().addingTimeInterval(Self.observationInterval),
            interval: Self.observationInterval,
            repeats: true
        ) { [weak self] _ in
            self?.observeNow()
        }
        monitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func stopObservationWork() {
        stopTimer()
        cancelPendingOneShot()
        pointerInteractionIsActive = false
    }

    private func cancelPendingOneShot() {
        oneShotGeneration &+= 1
        oneShotIsScheduled = false
    }

    private func scheduleOneShotObservation() {
        guard observationGate.sceneIsActive,
              !baselinesByGroupID.isEmpty,
              Self.shouldProcessSnapshot(
                  pointerInteractionIsActive: pointerInteractionIsActive
              ),
              isObservationAllowed(),
              !oneShotIsScheduled else { return }
        oneShotGeneration &+= 1
        let generation = oneShotGeneration
        oneShotIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.oneShotIsScheduled,
                  self.oneShotGeneration == generation else { return }
            self.oneShotIsScheduled = false
            self.observeNow(forceGeometrySample: true)
        }
    }

    private func observeNow(forceGeometrySample: Bool = false) {
        guard observationGate.sceneIsActive,
              !baselinesByGroupID.isEmpty else {
            stopObservationWork()
            return
        }
        guard isObservationAllowed() else {
            closeGate()
            return
        }

        // This is a cheap fail-safe for missed asynchronous mouse monitor
        // callbacks. It never posts or consumes input. While down, keep the
        // timer alive but perform zero Window Server reads.
        let buttonIsDown = pointerButtonIsDown()
        if buttonIsDown {
            if !pointerInteractionIsActive {
                pointerInteractionDidBegin()
            }
            return
        }
        if pointerInteractionIsActive {
            pointerInteractionDidEnd()
            return
        }

        guard Self.shouldProcessSnapshot(
            pointerInteractionIsActive: pointerInteractionIsActive
        ) else { return }

        if forceGeometrySample || geometryAcquisitionIsRequired {
            consumeGeometrySample(geometrySampleProvider(currentBaselines))
        } else {
            consumeExitProbe(exitProbeProvider(currentBaselines))
        }
    }

    private func consumeGeometrySample(
        _ sample: GroupSpaceMigrationReservationShadowObservationSample
    ) {
        let disposition = observationGate.consume(sample.state)
        switch disposition {
        case .ignore:
            return
        case .hideAndEndScene:
            stopObservationWork()
            resetGeometryObservation()
            presenter.missionControlDidBecomeAbsent()
        case .hide:
            geometrySettleGate.reset()
            settledFrames.removeAll()
            geometryAcquisitionIsRequired = true
            presenter.suppressPresentationImmediately()
        case .showCandidate:
            let frames = GroupSpaceMigrationReservationShadowGeometrySettleGate
                .frames(from: sample.windowServerSnapshot)
            let now = ProcessInfo.processInfo.systemUptime
            guard geometrySettleGate.observe(
                frames: frames,
                now: now,
                reason: geometryRecoveryReason
            ) else {
                presenter.suppressPresentationImmediately()
                return
            }
            geometryAcquisitionIsRequired = false
            lifecycleRearmIsRequired = false
            settledFrames = frames
            presenter.missionControlDidBecomePresent()
            presenter.sync(
                windowServerSnapshot: sample.windowServerSnapshot,
                transformIsProven: true
            )
        }
    }

    private func consumeExitProbe(
        _ probe: GroupSpaceMigrationReservationShadowExitProbeSample
    ) {
        let disposition = observationGate.consume(probe.state)
        switch disposition {
        case .ignore:
            return
        case .hideAndEndScene:
            stopObservationWork()
            resetGeometryObservation()
            presenter.missionControlDidBecomeAbsent()
        case .hide:
            beginGeometryAcquisition(reason: .geometryChange, hidesPresentation: true)
        case .showCandidate:
            // Settled mode deliberately does not update panel geometry. The probe
            // watches only one exact member per reserved group. If even that
            // sentinel moved, hide now and reacquire the complete reserved set on
            // the next observation tick instead of following the animation.
            guard GroupSpaceMigrationReservationShadowGeometrySettleGate
                .probeMatchesSettledGeometry(
                    probe.sentinelFrames,
                    settledFrames: settledFrames
                ) else {
                beginGeometryAcquisition(
                    reason: .geometryChange,
                    hidesPresentation: true
                )
                return
            }
        }
    }

    private func beginGeometryAcquisition(
        reason: GroupSpaceMigrationReservationShadowGeometryRecoveryReason,
        hidesPresentation: Bool
    ) {
        geometryRecoveryReason = reason
        geometryAcquisitionIsRequired = true
        geometrySettleGate.reset()
        settledFrames.removeAll()
        if hidesPresentation {
            presenter.suppressPresentationImmediately()
        }
    }

    private func resetGeometryObservation() {
        geometryRecoveryReason = .reservation
        geometryAcquisitionIsRequired = true
        lifecycleRearmIsRequired = false
        geometrySettleGate.reset()
        settledFrames.removeAll()
    }
}
