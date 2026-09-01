import AppKit
import CoreGraphics
import Foundation

private struct GroupSpaceProxyObservationSession {
    let groupID: SnapGroupID
    let presentedMemberIDs: Set<String>
    let proxyWindowID: CGWindowID
    let sourceSpace: TaboraSpaceID
    var candidateSpace: TaboraSpaceID?
    var candidateFirstObservedAt: TimeInterval?
    var candidateObservationCount: Int
    var completedPreflightRetryCount: Int
    let startedAt: TimeInterval
}

private struct GroupSpaceProxySourceBaseline {
    let presentedMemberIDs: Set<String>
    let proxyWindowID: CGWindowID
    let sourceSpace: TaboraSpaceID
}

private struct PendingGroupSpaceProxyBaseline {
    let presentedMemberIDs: Set<String>
    let proxyWindowID: CGWindowID
    var completedRetryCount: Int
}

final class GroupSpaceMigrationLine {
    private weak var host: GroupSpaceMigrationHost?
    private let observationPort: WindowSpaceObservationPort
    private let transportPort: WindowSpaceTransportPort
    private var monitorTimer: Timer?
    private var proxySessions:
        [SnapGroupID: GroupSpaceProxyObservationSession] = [:]
    private var proxyBaselines:
        [SnapGroupID: GroupSpaceProxySourceBaseline] = [:]
    private var pendingProxyBaselines:
        [SnapGroupID: PendingGroupSpaceProxyBaseline] = [:]
    private var rearmPendingGroupIDs = Set<SnapGroupID>()
    private var presentationRearmEvidenceByGroupID:
        [SnapGroupID: GroupSpacePresentationRearmEvidence] = [:]
    private var pendingAPIUnavailableNotice:
        (groupID: SnapGroupID, notice: GroupSpaceMigrationAPIUnavailableNotice)?
    private var reportedAPIFailureKeys = Set<String>()
    private var missionControlTransformIsObserved = false
    private(set) var activeTransaction: GroupSpaceMigrationTransaction?
    private var queuedTransactions: [GroupSpaceMigrationTransaction] = []

    private let observationInterval: TimeInterval = 0.10
    private let moveVerificationTimeout: TimeInterval = 2.50
    private let rollbackVerificationTimeout: TimeInterval = 2.50

    init(
        host: GroupSpaceMigrationHost,
        observationPort: WindowSpaceObservationPort,
        transportPort: WindowSpaceTransportPort
    ) {
        self.host = host
        self.observationPort = observationPort
        self.transportPort = transportPort
    }

    var hasActiveTransaction: Bool {
        activeTransaction != nil || !queuedTransactions.isEmpty
    }

    var hasPendingOrActiveTransactions: Bool {
        hasActiveTransaction
    }

    var ownsWindowMutationTransaction: Bool {
        guard let phase = activeTransaction?.phase else { return false }
        return GroupSpaceMigrationFrameOperationOwnershipPolicy
            .ownsFrameOperations(for: phase)
    }

    /// A captured destination does not own normal desktop presentation while
    /// it waits for Mission Control's transform to finish. The existing
    /// geometry observer must remain able to deliver that boundary.
    var ownsPresentationTransaction: Bool {
        guard let phase = activeTransaction?.phase else { return false }
        return phase != .awaitingNormalDesktopDispatch
    }

    var hasPendingPresentationRearmEvidence: Bool {
        !presentationRearmEvidenceByGroupID.isEmpty
    }

    var awaitsNormalDesktopDispatch: Bool {
        transactions.contains {
            $0.phase == .awaitingNormalDesktopDispatch
        }
    }

    func presentationIsQuarantined(groupID: SnapGroupID) -> Bool {
        if rearmPendingGroupIDs.contains(groupID) { return true }
        guard let transaction = transaction(for: groupID) else { return false }
        return transaction.phase != .awaitingNormalDesktopDispatch
    }

    func presentationIsFrozenForQueuedMigration(
        groupID: SnapGroupID
    ) -> Bool {
        guard let phase = transaction(for: groupID)?.phase else { return false }
        return GroupSpaceMigrationQueuedPresentationPolicy
            .preservesMovedProxy(for: phase)
    }

    var runtimeStatus: GroupSpaceMigrationRuntimeStatus {
        let capabilities = observationPort.capabilities
        return GroupSpaceMigrationRuntimeStatus(
            isAvailable: capabilities.contains(.migrationMinimum),
            detail: capabilities.missingMigrationComponentDescription
        )
    }

    func owns(groupID: SnapGroupID) -> Bool {
        transaction(for: groupID) != nil
    }

    private var transactions: [GroupSpaceMigrationTransaction] {
        [activeTransaction].compactMap { $0 } + queuedTransactions
    }

    private func transaction(
        for groupID: SnapGroupID
    ) -> GroupSpaceMigrationTransaction? {
        transactions.first {
            $0.capture.structuralSnapshot.groupID == groupID
        }
    }

    private var acceptsAdditionalMissionControlCaptures: Bool {
        activeTransaction == nil
            || transactions.allSatisfy {
                $0.phase == .awaitingNormalDesktopDispatch
            }
    }

    func noteProxyPresentedNormally(groupID: SnapGroupID) {
        guard let host,
              acceptsAdditionalMissionControlCaptures,
              !owns(groupID: groupID),
              proxySessions[groupID] == nil,
              !rearmPendingGroupIDs.contains(groupID),
              host.groupSpaceMigrationFeatureIsEnabled else {
            return
        }
        guard observationPort.capabilities.contains(
            .proxyObservationMinimum
        ) else {
            proxyBaselines.removeValue(forKey: groupID)
            pendingProxyBaselines.removeValue(forKey: groupID)
            deliverAPIUnavailableNoticeIfNeeded(
                GroupSpaceMigrationAPIUnavailableNotice(
                    kind: .runtimeUnavailable,
                    detail: observationPort.capabilities
                        .missingMigrationComponentDescription
                        + " / "
                        + transportPort.moveRuntimeDiagnosticDescription
                )
            )
            return
        }
        guard let descriptor = host.groupSpaceProxyDescriptor(
            groupID: groupID
        ) else {
            proxyBaselines.removeValue(forKey: groupID)
            pendingProxyBaselines.removeValue(forKey: groupID)
            return
        }
        if establishProxyBaseline(groupID: groupID, descriptor: descriptor) {
            pendingProxyBaselines.removeValue(forKey: groupID)
        } else {
            let existing = pendingProxyBaselines[groupID]
            pendingProxyBaselines[groupID] = PendingGroupSpaceProxyBaseline(
                presentedMemberIDs: descriptor.memberIDs,
                proxyWindowID: descriptor.windowID,
                completedRetryCount:
                    existing?.presentedMemberIDs == descriptor.memberIDs
                        && existing?.proxyWindowID == descriptor.windowID
                    ? existing?.completedRetryCount ?? 0
                    : 0
            )
            ensureMonitorTimer()
        }
    }

    func noteMissionControlTransformObserved(groupID: SnapGroupID) {
        guard let host,
              host.groupSpaceMigrationFeatureIsEnabled else { return }
        missionControlTransformIsObserved = true
        for transaction in transactions where
            transaction.phase == .awaitingNormalDesktopDispatch {
            transaction.dispatchReadinessEvidence = nil
            transaction.normalDesktopDispatchIsReady = false
        }
        // After a terminal failure the proxy is deliberately retired. Ignore
        // residual Mission Control transform callbacks until normal desktop
        // observation rearms this exact group.
        if rearmPendingGroupIDs.contains(groupID) {
            presentationRearmEvidenceByGroupID.removeValue(forKey: groupID)
            return
        }
        // Baseline acquisition is valid only on the normal desktop. Once a
        // transform is observed, never mistake the moved proxy's destination
        // membership for its source.
        pendingProxyBaselines.removeValue(forKey: groupID)
        guard acceptsAdditionalMissionControlCaptures,
              !owns(groupID: groupID),
              host.groupSpaceMigrationCanMonitor else { return }
        guard observationPort.capabilities.contains(
            .proxyObservationMinimum
        ) else { return }
        guard let descriptor = host.groupSpaceProxyDescriptor(
            groupID: groupID
        ) else { return }
        guard let baseline = proxyBaselines[groupID] else { return }
        guard baseline.presentedMemberIDs == descriptor.memberIDs,
              baseline.proxyWindowID == descriptor.windowID else { return }
        if let existing = proxySessions[groupID],
           existing.presentedMemberIDs == descriptor.memberIDs,
           existing.proxyWindowID == descriptor.windowID {
            ensureMonitorTimer()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        proxySessions[groupID] = GroupSpaceProxyObservationSession(
            groupID: groupID,
            presentedMemberIDs: descriptor.memberIDs,
            proxyWindowID: descriptor.windowID,
            sourceSpace: baseline.sourceSpace,
            candidateSpace: nil,
            candidateFirstObservedAt: nil,
            candidateObservationCount: 0,
            completedPreflightRetryCount: 0,
            startedAt: now
        )
        ensureMonitorTimer()
    }

    func cancelMonitoring(groupID: SnapGroupID) {
        // A genuine Mission Control selection cancels only the uncommitted
        // observation session. No private move was dispatched, so quarantining
        // and retiring the next proxy would create an unnecessary blank entry.
        proxySessions.removeValue(forKey: groupID)
        proxyBaselines.removeValue(forKey: groupID)
        pendingProxyBaselines.removeValue(forKey: groupID)
        stopTimerIfIdle()
    }

    func shouldPreferMigrationOverProxySelection(
        groupID: SnapGroupID
    ) -> Bool {
        guard let session = proxySessions[groupID] else { return false }
        let observed = observationPort.membership(
            forWindowID: session.proxyWindowID
        ).singleUserCandidate
        let observedUserSpace = observed.flatMap {
            observationPort.isUserSpace($0) == true ? $0 : nil
        }
        let shouldPrefer = GroupSpaceProxySelectionArbitrationPolicy
            .shouldPreferMigration(
                sourceSpace: session.sourceSpace,
                observedSpace: observedUserSpace,
                existingCandidateSpace: session.candidateSpace
            )
        if shouldPrefer { ensureMonitorTimer() }
        return shouldPrefer
    }

    func groupDidRetire(groupID: SnapGroupID) {
        proxySessions.removeValue(forKey: groupID)
        proxyBaselines.removeValue(forKey: groupID)
        pendingProxyBaselines.removeValue(forKey: groupID)
        rearmPendingGroupIDs.remove(groupID)
        presentationRearmEvidenceByGroupID.removeValue(forKey: groupID)
        if pendingAPIUnavailableNotice?.groupID == groupID {
            pendingAPIUnavailableNotice = nil
        }
        stopTimerIfIdle()
    }

    func noteNormalDesktopObserved(
        groupIDs: Set<SnapGroupID>,
        groupsWithNormalMembers: Set<SnapGroupID>
    ) {
        missionControlTransformIsObserved = false
        let now = ProcessInfo.processInfo.systemUptime
        var activeBecameReady = false
        for transaction in transactions where
            transaction.phase == .awaitingNormalDesktopDispatch {
            let migratingGroupID = transaction.capture
                .structuralSnapshot.groupID
            if GroupSpaceMigrationDispatchReadinessPolicy
                .acceptsNormalDesktopObservation(
                    migratingGroupIsNormal:
                        groupIDs.contains(migratingGroupID),
                    migratingGroupHasNormalMember:
                        groupsWithNormalMembers.contains(migratingGroupID),
                    activeSpaceChangeWasObserved:
                        transaction.activeSpaceChangeObservedAt != nil
                ) {
                let observation = GroupSpaceMigrationDispatchReadinessPolicy
                    .observe(
                        previous: transaction.dispatchReadinessEvidence,
                        now: now
                    )
                transaction.dispatchReadinessEvidence = observation.evidence
                if observation.isConfirmed {
                    transaction.normalDesktopDispatchIsReady = true
                    activeBecameReady = activeTransaction === transaction
                }
            } else {
                transaction.dispatchReadinessEvidence = nil
                transaction.normalDesktopDispatchIsReady = false
            }
        }
        if activeBecameReady, let activeTransaction {
            dispatchCapturedMove(activeTransaction)
        }
        var rearmedGroupIDs = Set<SnapGroupID>()
        for groupID in groupIDs {
            proxySessions.removeValue(forKey: groupID)
            guard rearmPendingGroupIDs.contains(groupID) else { continue }
            let observation = GroupSpacePresentationRearmPolicy.observe(
                previous: presentationRearmEvidenceByGroupID[groupID],
                now: now
            )
            presentationRearmEvidenceByGroupID[groupID] = observation.evidence
            if observation.isConfirmed {
                rearmPendingGroupIDs.remove(groupID)
                presentationRearmEvidenceByGroupID.removeValue(forKey: groupID)
                rearmedGroupIDs.insert(groupID)
            }
        }
        if let pending = pendingAPIUnavailableNotice,
           GroupSpaceMigrationAPIFailurePolicy
            .shouldDeliverAfterNormalDesktop(
                pendingGroupID: pending.groupID,
                observedNormalGroupIDs: rearmedGroupIDs
            ) {
                pendingAPIUnavailableNotice = nil
                deliverAPIUnavailableNoticeIfNeeded(pending.notice)
        }
        stopTimerIfIdle()
    }

    func noteNonNormalDesktopObserved(groupIDs: Set<SnapGroupID>) {
        for groupID in groupIDs {
            pendingProxyBaselines.removeValue(forKey: groupID)
            if rearmPendingGroupIDs.contains(groupID) {
                presentationRearmEvidenceByGroupID.removeValue(forKey: groupID)
            }
        }
    }

    func settingsDidChange() {
        guard host?.groupSpaceMigrationFeatureIsEnabled == true else {
            proxySessions.removeAll()
            proxyBaselines.removeAll()
            pendingProxyBaselines.removeAll()
            rearmPendingGroupIDs.removeAll()
            presentationRearmEvidenceByGroupID.removeAll()
            pendingAPIUnavailableNotice = nil
            cancelQueuedTransactionsBeforeDispatch()
            driveActiveTransaction()
            stopTimerIfIdle()
            return
        }
        ensureMonitorTimerIfNeeded()
    }

    func controllerStateDidChange() {
        guard host?.groupSpaceMigrationCanMonitor == true else {
            proxySessions.removeAll()
            proxyBaselines.removeAll()
            pendingProxyBaselines.removeAll()
            cancelQueuedTransactionsBeforeDispatch()
            driveActiveTransaction()
            stopTimerIfIdle()
            return
        }
        ensureMonitorTimerIfNeeded()
    }

    func cancelForEnvironmentInvalidation() {
        proxySessions.removeAll()
        proxyBaselines.removeAll()
        pendingProxyBaselines.removeAll()
        cancelQueuedTransactionsBeforeDispatch()
        guard let transaction = activeTransaction,
              let host else {
            stopTimerIfIdle()
            return
        }
        switch GroupSpaceMigrationInterruptionPolicy.disposition(
            for: transaction.phase
        ) {
        case .cancelBeforeDispatch:
            finish(transaction, terminalState: .cancelledBeforeStart)
        case .rollbackDispatchedMove:
            beginRollback(transaction)
        case .continueRollback:
            ensureMonitorTimer()
        case .dissolveAtDestination:
            host.dissolveGroupSpaceMigration(transaction.capture)
            finish(transaction, terminalState: .dissolvedAtDestination)
        }
    }

    func noteActiveSpaceChanged() {
        if activeTransaction != nil {
            driveActiveTransaction()
        }
        if acceptsAdditionalMissionControlCaptures {
            observeProxySessions(activeSpaceSettlementWasObserved: true)
        }
        for transaction in transactions where
            transaction.phase == .awaitingNormalDesktopDispatch {
            transaction.activeSpaceChangeObservedAt =
                ProcessInfo.processInfo.systemUptime
        }
        if missionControlTransformIsObserved {
            observeQueuedProxyDestinations(
                activeSpaceSettlementWasObserved: true
            )
        }
    }

    /// App termination cannot wait for an asynchronous WindowServer operation.
    /// An undispatched capture emits no transport command. After destination
    /// dispatch but before physical commit, make identity-checked best-effort
    /// moves to each recorded origin; afterward never move Spaces again.
    func shutdown() {
        if let transaction = activeTransaction {
            switch GroupSpaceMigrationInterruptionPolicy.disposition(
                for: transaction.phase
            ) {
            case .cancelBeforeDispatch:
                break
            case .rollbackDispatchedMove, .continueRollback:
                bestEffortRollbackOnShutdown(transaction)
            case .dissolveAtDestination:
                host?.dissolveGroupSpaceMigration(transaction.capture)
                host?.retireGroupSpaceMigrationProxy(
                    groupID: transaction.capture.structuralSnapshot.groupID
                )
            }
        }
        activeTransaction = nil
        queuedTransactions.removeAll()
        proxySessions.removeAll()
        proxyBaselines.removeAll()
        pendingProxyBaselines.removeAll()
        rearmPendingGroupIDs.removeAll()
        presentationRearmEvidenceByGroupID.removeAll()
        pendingAPIUnavailableNotice = nil
        missionControlTransformIsObserved = false
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func bestEffortRollbackOnShutdown(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        let observation = observeMembers(of: transaction.capture)
        var windowIDsByOrigin: [TaboraSpaceID: [CGWindowID]] = [:]
        for member in transaction.capture.members {
            guard let origin = transaction.dispatchOriginsByMemberID[
                member.stableIdentity
            ], let observed = observation.member(member.stableIdentity),
                  observed.windowID == member.windowID,
                  let current = observed.membership.singleUserCandidate,
                  observationPort.isUserSpace(current) == true,
                  current != origin else { continue }
            windowIDsByOrigin[origin, default: []].append(member.windowID)
        }
        for origin in windowIDsByOrigin.keys.sorted(
            by: { $0.rawValue < $1.rawValue }
        ) {
            _ = transportPort.move(
                windowIDs: windowIDsByOrigin[origin] ?? [],
                to: origin
            )
        }
    }

    func resetState() {
        shutdown()
        reportedAPIFailureKeys.removeAll()
    }

    private func ensureMonitorTimerIfNeeded() {
        guard hasActiveTransaction || !proxySessions.isEmpty
                || !pendingProxyBaselines.isEmpty else {
            return
        }
        ensureMonitorTimer()
    }

    private func ensureMonitorTimer() {
        guard monitorTimer == nil else { return }
        let timer = Timer(timeInterval: observationInterval, repeats: true) {
            [weak self] _ in
            self?.tick()
        }
        monitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        refreshPendingProxyBaselines()
        if missionControlTransformIsObserved {
            observeQueuedProxyDestinations(
                activeSpaceSettlementWasObserved: false
            )
        }
        if activeTransaction != nil {
            driveActiveTransaction()
        }
        if acceptsAdditionalMissionControlCaptures {
            observeProxySessions(activeSpaceSettlementWasObserved: false)
        }
        stopTimerIfIdle()
    }

    private func refreshPendingProxyBaselines() {
        guard let host,
              acceptsAdditionalMissionControlCaptures,
              host.groupSpaceMigrationFeatureIsEnabled,
              host.groupSpaceMigrationCanMonitor else { return }
        for groupID in Array(pendingProxyBaselines.keys) {
            guard var pending = pendingProxyBaselines[groupID],
                  proxySessions[groupID] == nil,
                  !owns(groupID: groupID),
                  !rearmPendingGroupIDs.contains(groupID),
                  let descriptor = host.groupSpaceProxyDescriptor(
                      groupID: groupID
                  ),
                  descriptor.memberIDs == pending.presentedMemberIDs,
                  descriptor.windowID == pending.proxyWindowID else {
                pendingProxyBaselines.removeValue(forKey: groupID)
                continue
            }
            if establishProxyBaseline(
                groupID: groupID,
                descriptor: descriptor
            ) {
                pendingProxyBaselines.removeValue(forKey: groupID)
                continue
            }
            guard GroupSpaceProxyBaselineRetryPolicy.shouldRetry(
                completedRetryCount: pending.completedRetryCount
            ) else {
                pendingProxyBaselines.removeValue(forKey: groupID)
                continue
            }
            pending.completedRetryCount += 1
            pendingProxyBaselines[groupID] = pending
        }
    }

    private func establishProxyBaseline(
        groupID: SnapGroupID,
        descriptor: GroupSpaceProxyDescriptor
    ) -> Bool {
        let sourceMembership = observationPort.membership(
            forWindowID: descriptor.windowID
        )
        guard let sourceSpace = sourceMembership.singleUserCandidate,
              observationPort.isUserSpace(sourceSpace) == true else {
            proxyBaselines.removeValue(forKey: groupID)
            return false
        }
        proxyBaselines[groupID] = GroupSpaceProxySourceBaseline(
            presentedMemberIDs: descriptor.memberIDs,
            proxyWindowID: descriptor.windowID,
            sourceSpace: sourceSpace
        )
        return true
    }

    private func observeProxySessions(
        activeSpaceSettlementWasObserved: Bool
    ) {
        guard let host,
              host.groupSpaceMigrationFeatureIsEnabled,
              host.groupSpaceMigrationCanMonitor else {
            proxySessions.removeAll()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let buttonIsDown = CGEventSource.buttonState(
            .combinedSessionState,
            button: .left
        )
        var readySessions: [GroupSpaceProxyObservationSession] = []

        for groupID in Array(proxySessions.keys) {
            guard var session = proxySessions[groupID] else { continue }
            guard GroupSpaceProxyMonitoringPolicy.isWithinLifetime(
                startedAt: session.startedAt,
                now: now
            ) else {
                requireNormalDesktopRearm(groupID: groupID)
                proxySessions.removeValue(forKey: groupID)
                continue
            }
            guard let currentDescriptor = host.groupSpaceProxyDescriptor(
                groupID: groupID
            ),
                  currentDescriptor.memberIDs == session.presentedMemberIDs,
                  currentDescriptor.windowID == session.proxyWindowID else {
                requireNormalDesktopRearm(groupID: groupID)
                proxySessions.removeValue(forKey: groupID)
                continue
            }

            let observedSpace = observationPort.membership(
                forWindowID: session.proxyWindowID
            ).singleUserCandidate
            guard let observedSpace,
                  observationPort.isUserSpace(observedSpace) == true else {
                session.candidateSpace = nil
                session.candidateFirstObservedAt = nil
                session.candidateObservationCount = 0
                session.completedPreflightRetryCount = 0
                proxySessions[groupID] = session
                continue
            }
            if observedSpace == session.sourceSpace {
                session.candidateSpace = nil
                session.candidateFirstObservedAt = nil
                session.candidateObservationCount = 0
                session.completedPreflightRetryCount = 0
                proxySessions[groupID] = session
                continue
            }
            if session.candidateSpace == observedSpace {
                session.candidateObservationCount += 1
            } else {
                session.candidateSpace = observedSpace
                session.candidateFirstObservedAt = now
                session.candidateObservationCount = 1
                session.completedPreflightRetryCount = 0
            }
            proxySessions[groupID] = session
            if GroupSpaceProxyMonitoringPolicy.destinationIsSettled(
                observationCount: session.candidateObservationCount,
                firstObservedAt: session.candidateFirstObservedAt,
                now: now,
                buttonIsDown: buttonIsDown,
                activeSpaceSettlementWasObserved:
                    activeSpaceSettlementWasObserved
            ) {
                readySessions.append(session)
            }
        }

        let orderedSessions = readySessions.sorted(by: {
            let leftObservedAt = $0.candidateFirstObservedAt
                ?? $0.startedAt
            let rightObservedAt = $1.candidateFirstObservedAt
                ?? $1.startedAt
            if leftObservedAt != rightObservedAt {
                return leftObservedAt < rightObservedAt
            }
            return $0.groupID.rawValue.uuidString
                < $1.groupID.rawValue.uuidString
        })
        for selected in orderedSessions {
            guard proxySessions[selected.groupID] != nil,
                  let destination = selected.candidateSpace else { continue }
            beginMigration(from: selected, destination: destination)
        }
    }

    private func beginMigration(
        from session: GroupSpaceProxyObservationSession,
        destination: TaboraSpaceID
    ) {
        guard let host else { return }
        guard GroupSpaceMigrationQueuePolicy.acceptsCapture(
            groupID: session.groupID,
            capturedGroupIDs: Set(transactions.map {
                $0.capture.structuralSnapshot.groupID
            })
        ) else {
            proxySessions.removeValue(forKey: session.groupID)
            return
        }
        // Proxy key-state can briefly start the existing selection confirmation
        // while Mission Control settles a drop. Keep the exact observation
        // session alive; only the confirmed selection callback cancels it.
        guard host.groupSpaceMigrationCanBegin else { return }
        guard observationPort.capabilities.contains(.migrationMinimum) else {
            queueAPIUnavailableNotice(
                groupID: session.groupID,
                kind: .runtimeUnavailable,
                detail: observationPort.capabilities
                    .missingMigrationComponentDescription
                    + " / " + transportPort.moveRuntimeDiagnosticDescription
            )
            rejectCandidate(groupID: session.groupID)
            return
        }
        guard let subjects = host.groupSpaceMigrationSubjects(
            groupID: session.groupID,
            presentedMemberIDs: session.presentedMemberIDs
        ) else {
            rejectCandidate(groupID: session.groupID)
            return
        }
        let observation = observationPort.observe(subjects: subjects)
        let relationship = GroupSpaceMembershipPolicy.relationship(
            memberIDs: session.presentedMemberIDs,
            observation: observation
        )
        switch GroupSpaceMigrationPreflightPolicy.disposition(
            relationship: relationship,
            expectedSourceSpace: session.sourceSpace
        ) {
        case .retry:
            retryPreflight(for: session)
            return
        case .reject:
            rejectCandidate(groupID: session.groupID)
            return
        case .proceed:
            break
        }
        let memberSourceSpace = session.sourceSpace
        guard destination != memberSourceSpace else {
            rejectCandidate(groupID: session.groupID)
            return
        }
        guard let displayIdentifier = observationPort
            .managedDisplayIdentifier(for: destination) else {
            retryPreflight(for: session)
            return
        }
        let captureResolution = host.captureGroupSpaceMigration(
            groupID: session.groupID,
            presentedMemberIDs: session.presentedMemberIDs,
            proxyWindowID: session.proxyWindowID,
            sourceSpace: memberSourceSpace,
            destinationSpace: destination,
            destinationManagedDisplayIdentifier: displayIdentifier,
            observedMembers: observation
        )
        let capture: GroupSpaceMigrationCapture
        switch captureResolution {
        case .ready(let resolvedCapture):
            capture = resolvedCapture
        case .retryableObservation:
            retryPreflight(for: session)
            return
        case .rejected:
            rejectCandidate(groupID: session.groupID)
            return
        }
        guard queueAccepts(capture) else {
            rejectCandidate(groupID: session.groupID)
            return
        }

        proxySessions.removeValue(forKey: session.groupID)
        proxyBaselines.removeValue(forKey: session.groupID)
        pendingProxyBaselines.removeValue(forKey: session.groupID)
        let transaction = GroupSpaceMigrationTransaction(capture: capture)
        transaction.phase = .awaitingNormalDesktopDispatch
        if activeTransaction == nil {
            activeTransaction = transaction
        } else {
            queuedTransactions.append(transaction)
        }
        host.groupSpaceMigrationDidBegin(capture)
        refreshQueuedProxyPresentation()
        ensureMonitorTimer()
    }

    private func observeQueuedProxyDestinations(
        activeSpaceSettlementWasObserved: Bool
    ) {
        guard let host,
              host.groupSpaceMigrationFeatureIsEnabled,
              host.groupSpaceMigrationCanMonitor else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let buttonIsDown = CGEventSource.buttonState(
            .combinedSessionState,
            button: .left
        )
        for transaction in Array(transactions) where
            transaction.phase == .awaitingNormalDesktopDispatch {
            let capture = transaction.capture
            let groupID = capture.structuralSnapshot.groupID
            guard let descriptor = host.groupSpaceProxyDescriptor(
                groupID: groupID
            ),
                  descriptor.memberIDs == capture.structuralSnapshot.memberIDs,
                  descriptor.windowID == capture.proxyWindowID else {
                resetQueuedProxyCandidate(transaction)
                continue
            }
            guard let observedSpace = observationPort.membership(
                forWindowID: capture.proxyWindowID
            ).singleUserCandidate,
                  observationPort.isUserSpace(observedSpace) == true else {
                resetQueuedProxyCandidate(transaction)
                continue
            }
            let destinationDisposition =
                GroupSpaceMigrationQueuedDestinationPolicy.disposition(
                    observedSpace: observedSpace,
                    sourceSpace: capture.sourceSpace,
                    currentDestinationSpace: capture.destinationSpace
                )
            if destinationDisposition == .unchanged {
                resetQueuedProxyCandidate(transaction)
                continue
            }
            if transaction.queuedProxyCandidateSpace == observedSpace {
                transaction.queuedProxyCandidateObservationCount += 1
            } else {
                transaction.queuedProxyCandidateSpace = observedSpace
                transaction.queuedProxyCandidateFirstObservedAt = now
                transaction.queuedProxyCandidateObservationCount = 1
                transaction.completedRetargetRetryCount = 0
            }
            guard GroupSpaceProxyMonitoringPolicy.destinationIsSettled(
                observationCount:
                    transaction.queuedProxyCandidateObservationCount,
                firstObservedAt:
                    transaction.queuedProxyCandidateFirstObservedAt,
                now: now,
                buttonIsDown: buttonIsDown,
                activeSpaceSettlementWasObserved:
                    activeSpaceSettlementWasObserved
            ) else { continue }

            if destinationDisposition == .cancelAtSource {
                cancelReservationAtSource(transaction)
            } else {
                retargetQueuedTransaction(
                    transaction,
                    destination: observedSpace
                )
            }
        }
    }

    private func retargetQueuedTransaction(
        _ transaction: GroupSpaceMigrationTransaction,
        destination: TaboraSpaceID
    ) {
        guard let host else { return }
        let capture = transaction.capture
        let groupID = capture.structuralSnapshot.groupID
        guard let subjects = host.groupSpaceMigrationSubjects(
            groupID: groupID,
            presentedMemberIDs: capture.structuralSnapshot.memberIDs
        ) else {
            cancelBeforeDispatch(transaction)
            return
        }
        let observation = observationPort.observe(subjects: subjects)
        let relationship = GroupSpaceMembershipPolicy.relationship(
            memberIDs: capture.structuralSnapshot.memberIDs,
            observation: observation
        )
        switch GroupSpaceMigrationPreflightPolicy.disposition(
            relationship: relationship,
            expectedSourceSpace: capture.sourceSpace
        ) {
        case .retry:
            guard GroupSpaceMigrationPreflightPolicy.shouldRetry(
                completedRetryCount: transaction.completedRetargetRetryCount
            ) else {
                cancelBeforeDispatch(transaction)
                return
            }
            transaction.completedRetargetRetryCount += 1
            ensureMonitorTimer()
            return
        case .reject:
            cancelBeforeDispatch(transaction)
            return
        case .proceed:
            break
        }
        guard let displayIdentifier = observationPort
            .managedDisplayIdentifier(for: destination) else {
            transaction.completedRetargetRetryCount += 1
            if !GroupSpaceMigrationPreflightPolicy.shouldRetry(
                completedRetryCount: transaction.completedRetargetRetryCount
            ) {
                cancelBeforeDispatch(transaction)
            }
            return
        }
        switch host.captureGroupSpaceMigration(
            groupID: groupID,
            presentedMemberIDs: capture.structuralSnapshot.memberIDs,
            proxyWindowID: capture.proxyWindowID,
            sourceSpace: capture.sourceSpace,
            destinationSpace: destination,
            destinationManagedDisplayIdentifier: displayIdentifier,
            observedMembers: observation
        ) {
        case .ready(let replacement):
            guard queueAccepts(replacement, excluding: transaction) else {
                cancelBeforeDispatch(transaction)
                return
            }
            transaction.capture = replacement
            host.groupSpaceMigrationDidRefreshCapture(replacement)
            transaction.dispatchReadinessEvidence = nil
            transaction.normalDesktopDispatchIsReady = false
            transaction.completedDispatchPreflightRetryCount = 0
            transaction.activeSpaceChangeObservedAt = nil
            resetQueuedProxyCandidate(transaction)
            refreshQueuedProxyPresentation()
        case .retryableObservation:
            transaction.completedRetargetRetryCount += 1
            if !GroupSpaceMigrationPreflightPolicy.shouldRetry(
                completedRetryCount: transaction.completedRetargetRetryCount
            ) {
                cancelBeforeDispatch(transaction)
            }
        case .rejected:
            cancelBeforeDispatch(transaction)
        }
    }

    private func queueAccepts(
        _ capture: GroupSpaceMigrationCapture,
        excluding excludedTransaction: GroupSpaceMigrationTransaction? = nil
    ) -> Bool {
        let otherTransactions = excludedTransaction.map { excluded in
            transactions.filter { $0 !== excluded }
        } ?? transactions
        let capturedMemberIDs = otherTransactions.reduce(
            into: Set<String>()
        ) {
            $0.formUnion($1.capture.structuralSnapshot.memberIDs)
        }
        let capturedWindowIDs = otherTransactions.reduce(
            into: Set<CGWindowID>()
        ) {
            $0.formUnion($1.capture.members.map(\.windowID))
        }
        return GroupSpaceMigrationQueuePolicy.acceptsPhysicalMembers(
            memberIDs: capture.structuralSnapshot.memberIDs,
            windowIDs: Set(capture.members.map(\.windowID)),
            capturedMemberIDs: capturedMemberIDs,
            capturedWindowIDs: capturedWindowIDs
        )
    }

    private func resetQueuedProxyCandidate(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        transaction.queuedProxyCandidateSpace = nil
        transaction.queuedProxyCandidateFirstObservedAt = nil
        transaction.queuedProxyCandidateObservationCount = 0
        transaction.completedRetargetRetryCount = 0
    }

    private func cancelBeforeDispatch(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        guard transaction.phase == .awaitingNormalDesktopDispatch else {
            return
        }
        if activeTransaction === transaction {
            finish(transaction, terminalState: .cancelledBeforeStart)
            return
        }
        guard let index = queuedTransactions.firstIndex(where: {
            $0 === transaction
        }) else { return }
        queuedTransactions.remove(at: index)
        let groupID = transaction.capture.structuralSnapshot.groupID
        requireNormalDesktopRearm(groupID: groupID)
        host?.retireGroupSpaceMigrationProxy(groupID: groupID)
        host?.groupSpaceMigrationDidFinish(
            transaction.capture,
            terminalState: .cancelledBeforeStart
        )
        refreshQueuedProxyPresentation()
    }

    private func cancelReservationAtSource(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        guard transaction.phase == .awaitingNormalDesktopDispatch else {
            return
        }
        if activeTransaction === transaction {
            finish(transaction, terminalState: .cancelledAtSource)
            return
        }
        guard let index = queuedTransactions.firstIndex(where: {
            $0 === transaction
        }) else { return }
        queuedTransactions.remove(at: index)
        let capture = transaction.capture
        let groupID = capture.structuralSnapshot.groupID
        rearmPendingGroupIDs.remove(groupID)
        presentationRearmEvidenceByGroupID.removeValue(forKey: groupID)
        proxyBaselines[groupID] = GroupSpaceProxySourceBaseline(
            presentedMemberIDs: capture.structuralSnapshot.memberIDs,
            proxyWindowID: capture.proxyWindowID,
            sourceSpace: capture.sourceSpace
        )
        host?.restoreGroupSpaceMigrationProxyAfterSourceCancellation(
            groupID: groupID
        )
        host?.groupSpaceMigrationDidFinish(
            capture,
            terminalState: .cancelledAtSource
        )
        refreshQueuedProxyPresentation()
        stopTimerIfIdle()
    }

    private func refreshQueuedProxyPresentation() {
        let ordered = transactions.filter {
            $0.phase == .awaitingNormalDesktopDispatch
        }
        for (index, transaction) in ordered.enumerated() {
            guard let host else { continue }
            host.updateGroupSpaceMigrationQueuePresentation(
                groupID: transaction.capture.structuralSnapshot.groupID,
                position: index + 1,
                total: ordered.count
            )
        }
    }

    private func dispatchCapturedMove(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        guard activeTransaction === transaction,
              transaction.phase == .awaitingNormalDesktopDispatch else {
            return
        }
        let capture = transaction.capture
        let memberObservation = observeMembers(of: capture)
        let expectedWindowIDsByMemberID = Dictionary(
            uniqueKeysWithValues: capture.members.map {
                ($0.stableIdentity, $0.windowID)
            }
        )
        switch GroupSpaceMigrationDispatchMembershipPolicy.disposition(
            expectedWindowIDsByMemberID: expectedWindowIDsByMemberID,
            observation: memberObservation,
            destinationSpace: capture.destinationSpace,
            isUserSpace: { [observationPort] in
                observationPort.isUserSpace($0)
            }
        ) {
        case .dispatchRequired:
            transaction.completedDispatchPreflightRetryCount = 0
            guard let origins = exactMemberSpaces(
                of: capture,
                observation: memberObservation
            ) else {
                retryDispatchPreflight(transaction)
                return
            }
            transaction.dispatchOriginsByMemberID = origins
        case .alreadyAtDestination:
            // The exact captured set was moved together by an external action
            // after capture. Do not issue a duplicate private move; adopt the
            // observed destination and continue through the same layout/commit
            // boundary.
            transaction.completedDispatchPreflightRetryCount = 0
            host?.retireGroupSpaceMigrationProxy(
                groupID: capture.structuralSnapshot.groupID
            )
            transaction.phase = .verifyingMove
            physicalCommit(transaction)
            return
        case .retryUnknown:
            retryDispatchPreflight(transaction)
            return
        case .cancelForIdentityMutation:
            // A different Window ID or a non-user Space is not the captured
            // physical surface. Never send a private move to a guessed target.
            finish(transaction, terminalState: .cancelledBeforeStart)
            return
        }
        // Mission Control has completed its managed-window transform. Retire
        // the consumed proxy before beginning a separate operation for real
        // application surfaces; these operations must never share one scene.
        host?.retireGroupSpaceMigrationProxy(
            groupID: capture.structuralSnapshot.groupID
        )
        transaction.phase = .dispatchingMove
        let windowIDsToMove = capture.members.compactMap { member in
            transaction.dispatchOriginsByMemberID[member.stableIdentity]
                == capture.destinationSpace ? nil : member.windowID
        }
        guard !windowIDsToMove.isEmpty else {
            transaction.phase = .verifyingMove
            physicalCommit(transaction)
            return
        }
        switch transportPort.move(
            windowIDs: windowIDsToMove,
            to: capture.destinationSpace
        ) {
        case .dispatched:
            transaction.phase = .verifyingMove
            transaction.phaseDeadline = ProcessInfo.processInfo.systemUptime
                + moveVerificationTimeout
            ensureMonitorTimer()
        case .unavailable:
            queueAPIUnavailableNotice(
                groupID: capture.structuralSnapshot.groupID,
                kind: .runtimeUnavailable,
                detail: transportPort.lastMoveDispatchDiagnosticDescription
            )
            finish(
                transaction,
                terminalState: .cancelledBeforeStart
            )
        case .rejected:
            queueAPIUnavailableNotice(
                groupID: capture.structuralSnapshot.groupID,
                kind: .dispatchRejected,
                detail: transportPort.lastMoveDispatchDiagnosticDescription
            )
            finish(
                transaction,
                terminalState: .cancelledBeforeStart
            )
        }
    }

    private func retryDispatchPreflight(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        guard GroupSpaceMigrationDispatchMembershipPolicy.shouldRetryUnknown(
            completedRetryCount:
                transaction.completedDispatchPreflightRetryCount
        ) else {
            finish(transaction, terminalState: .cancelledBeforeStart)
            return
        }
        transaction.completedDispatchPreflightRetryCount += 1
        ensureMonitorTimer()
    }

    private func retryPreflight(
        for session: GroupSpaceProxyObservationSession
    ) {
        guard var current = proxySessions[session.groupID],
              current.presentedMemberIDs == session.presentedMemberIDs,
              current.proxyWindowID == session.proxyWindowID,
              current.candidateSpace == session.candidateSpace else {
            return
        }
        guard GroupSpaceMigrationPreflightPolicy.shouldRetry(
            completedRetryCount: current.completedPreflightRetryCount
        ) else {
            rejectCandidate(groupID: session.groupID)
            return
        }
        current.completedPreflightRetryCount += 1
        proxySessions[session.groupID] = current
        ensureMonitorTimer()
    }

    private func rejectCandidate(groupID: SnapGroupID) {
        requireNormalDesktopRearm(groupID: groupID)
        proxySessions.removeValue(forKey: groupID)
        proxyBaselines.removeValue(forKey: groupID)
        host?.retireGroupSpaceMigrationProxy(groupID: groupID)
    }

    private func driveActiveTransaction() {
        guard let transaction = activeTransaction,
              let host else { return }
        let capture = transaction.capture

        let featureIsEnabled = host.groupSpaceMigrationFeatureIsEnabled
        // Once capture has succeeded, transient proxy key/selection state is
        // no longer an independent interaction that may cancel transport.
        // Structural and controller readiness still remain mandatory.
        let controllerAllowsContinuation = host.groupSpaceMigrationCanMonitor
        let structureMatches = host.groupSpaceMigrationStructureMatches(
            capture.structuralSnapshot
        )
        if transaction.phase != .rollingBack
            && (!featureIsEnabled
                || !controllerAllowsContinuation
                || !structureMatches) {
            switch GroupSpaceMigrationInterruptionPolicy.disposition(
                for: transaction.phase
            ) {
            case .cancelBeforeDispatch:
                finish(transaction, terminalState: .cancelledBeforeStart)
            case .rollbackDispatchedMove:
                beginRollback(transaction)
            case .continueRollback:
                ensureMonitorTimer()
            case .dissolveAtDestination:
                host.dissolveGroupSpaceMigration(capture)
                finish(transaction, terminalState: .dissolvedAtDestination)
            }
            return
        }

        switch transaction.phase {
        case .awaitingNormalDesktopDispatch:
            if transaction.normalDesktopDispatchIsReady {
                dispatchCapturedMove(transaction)
            }

        case .verifyingMove:
            let observation = observeMembers(of: capture)
            if allMembers(
                capture,
                areIn: capture.destinationSpace,
                observation: observation
            ) {
                physicalCommit(transaction)
            } else if ProcessInfo.processInfo.systemUptime
                        >= transaction.phaseDeadline {
                beginRollback(transaction)
            }

        case .rollingBack:
            driveRollback(transaction)

        case .captured, .dispatchingMove,
             .physicalCommitted,
             .applyingLayout, .rebuildingGroup:
            break
        }
    }

    private func beginRollback(_ transaction: GroupSpaceMigrationTransaction) {
        guard transaction.phase == .verifyingMove else { return }
        transaction.phase = .rollingBack
        transaction.rollbackBatches = rollbackBatches(for: transaction)
        transaction.rollbackBatchIndex = 0
        transaction.rollbackBatchWasDispatched = false
        transaction.phaseDeadline = ProcessInfo.processInfo.systemUptime
            + rollbackVerificationTimeout
        ensureMonitorTimer()
    }

    private func driveRollback(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        guard let host else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard transaction.rollbackBatches.indices.contains(
            transaction.rollbackBatchIndex
        ) else {
            let observation = observeMembers(of: transaction.capture)
            guard exactMemberSpaces(
                of: transaction.capture,
                observation: observation
            ) == transaction.dispatchOriginsByMemberID else {
                if now >= transaction.phaseDeadline {
                    host.dissolveGroupSpaceMigration(transaction.capture)
                    finish(
                        transaction,
                        terminalState: .dissolvedAfterIncompleteRollback
                    )
                } else {
                    ensureMonitorTimer()
                }
                return
            }
            let restoredToCapturedSource = GroupSpaceMigrationRollbackPolicy
                .canPreserveStructuralGroup(
                    originsByMemberID:
                        transaction.dispatchOriginsByMemberID,
                    capturedSource: transaction.capture.sourceSpace,
                    expectedMemberCount: transaction.capture.members.count
                )
            if restoredToCapturedSource {
                finish(transaction, terminalState: .rolledBack)
            } else {
                // Restore only Tabora's own move. A pre-existing user Space
                // split remains untouched and cannot keep structural grouping.
                host.dissolveGroupSpaceMigration(transaction.capture)
                finish(
                    transaction,
                    terminalState: .dissolvedAfterOriginRestore
                )
            }
            return
        }

        let batch = transaction.rollbackBatches[
            transaction.rollbackBatchIndex
        ]
        let observation = observeMembers(of: transaction.capture)
        if members(
            batch.memberIDs,
            of: transaction.capture,
            areIn: batch.destinationSpace,
            observation: observation
        ) {
            transaction.rollbackBatchIndex += 1
            transaction.rollbackBatchWasDispatched = false
            transaction.phaseDeadline = now + rollbackVerificationTimeout
            driveRollback(transaction)
            return
        }
        if !transaction.rollbackBatchWasDispatched,
           rollbackBatchIdentityIsExact(
            batch,
            capture: transaction.capture,
            observation: observation
        ) {
            let windowIDs = transaction.capture.members.compactMap { member in
                batch.memberIDs.contains(member.stableIdentity)
                    ? member.windowID : nil
            }
            let result = transportPort.move(
                windowIDs: windowIDs,
                to: batch.destinationSpace
            )
            if let failureKind = GroupSpaceMigrationAPIFailurePolicy.kind(
                for: result
            ) {
                queueAPIUnavailableNotice(
                    groupID:
                        transaction.capture.structuralSnapshot.groupID,
                    kind: failureKind,
                    detail:
                        transportPort.lastMoveDispatchDiagnosticDescription
                )
                host.dissolveGroupSpaceMigration(transaction.capture)
                finish(
                    transaction,
                    terminalState: .dissolvedAfterIncompleteRollback
                )
                return
            } else {
                transaction.rollbackBatchWasDispatched = true
                transaction.phaseDeadline = now + rollbackVerificationTimeout
            }
        }

        if now >= transaction.phaseDeadline {
            host.dissolveGroupSpaceMigration(transaction.capture)
            finish(
                transaction,
                terminalState: .dissolvedAfterIncompleteRollback
            )
        }
    }

    private func rollbackBatches(
        for transaction: GroupSpaceMigrationTransaction
    ) -> [GroupSpaceMigrationRollbackBatch] {
        GroupSpaceMigrationRollbackPolicy.batches(
            originsByMemberID: transaction.dispatchOriginsByMemberID,
            dispatchedDestination: transaction.capture.destinationSpace
        )
    }

    private func rollbackBatchIdentityIsExact(
        _ batch: GroupSpaceMigrationRollbackBatch,
        capture: GroupSpaceMigrationCapture,
        observation: WindowSpaceObservation
    ) -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: capture.members.map {
            ($0.stableIdentity, $0.windowID)
        })
        return batch.memberIDs.allSatisfy { memberID in
            guard let member = observation.member(memberID),
                  member.windowID == expected[memberID],
                  let space = member.membership.singleUserCandidate else {
                return false
            }
            return observationPort.isUserSpace(space) == true
        }
    }

    private func physicalCommit(
        _ transaction: GroupSpaceMigrationTransaction
    ) {
        guard let host,
              activeTransaction === transaction else { return }
        let capture = transaction.capture
        transaction.phase = .physicalCommitted
        guard let entryFrames = host
            .groupSpaceMigrationDestinationEntryFrames(capture),
              entryFrames.count == capture.members.count,
              let plannedFrames = capture.plannedLayout.frames else {
            host.dissolveGroupSpaceMigration(capture)
            finish(transaction, terminalState: .dissolvedAtDestination)
            return
        }
        transaction.destinationEntryFrames = entryFrames
        transaction.phase = .applyingLayout
        let transactionID = capture.transactionID
        host.applyGroupSpaceMigrationLayout(
            capture,
            frames: plannedFrames
        ) { [weak self] succeeded, acceptedFrames in
            guard let self,
                  let current = self.activeTransaction,
                  current.capture.transactionID == transactionID,
                  current.phase == .applyingLayout else { return }
            if succeeded,
               acceptedFrames.count == capture.members.count {
                current.phase = .rebuildingGroup
                if host.commitGroupSpaceMigration(
                    capture,
                    acceptedFrames: acceptedFrames
                ) {
                    self.finish(current, terminalState: .completed)
                } else {
                    host.dissolveGroupSpaceMigration(capture)
                    self.finish(
                        current,
                        terminalState: .dissolvedAtDestination
                    )
                }
            } else {
                host.restoreGroupSpaceMigrationEntryFrames(
                    capture,
                    frames: current.destinationEntryFrames
                ) { [weak self] in
                    guard let self,
                          let latest = self.activeTransaction,
                          latest.capture.transactionID == transactionID else {
                        return
                    }
                    host.dissolveGroupSpaceMigration(capture)
                    self.finish(
                        latest,
                        terminalState: .dissolvedAtDestination
                    )
                }
            }
        }
    }

    private func observeMembers(
        of capture: GroupSpaceMigrationCapture
    ) -> WindowSpaceObservation {
        observationPort.observe(subjects: capture.members.map {
            WindowSpaceSubject(
                stableIdentity: $0.stableIdentity,
                element: $0.element,
                pid: $0.pid,
                cachedWindowID: $0.windowID
            )
        })
    }

    private func allMembers(
        _ capture: GroupSpaceMigrationCapture,
        areIn space: TaboraSpaceID,
        observation: WindowSpaceObservation
    ) -> Bool {
        members(
            capture.structuralSnapshot.memberIDs,
            of: capture,
            areIn: space,
            observation: observation
        )
    }

    private func members(
        _ memberIDs: Set<String>,
        of capture: GroupSpaceMigrationCapture,
        areIn space: TaboraSpaceID,
        observation: WindowSpaceObservation
    ) -> Bool {
        let selectedMembers = capture.members.filter {
            memberIDs.contains($0.stableIdentity)
        }
        guard selectedMembers.count == memberIDs.count else { return false }
        return selectedMembers.allSatisfy { member in
            guard let observed = observation.member(member.stableIdentity)
            else { return false }
            return observed.windowID == member.windowID
                && observed.membership.singleUserCandidate == space
        }
    }

    private func exactMemberSpaces(
        of capture: GroupSpaceMigrationCapture,
        observation: WindowSpaceObservation
    ) -> [String: TaboraSpaceID]? {
        var spaces: [String: TaboraSpaceID] = [:]
        for member in capture.members {
            guard let observed = observation.member(member.stableIdentity),
                  observed.windowID == member.windowID,
                  let space = observed.membership.singleUserCandidate,
                  observationPort.isUserSpace(space) == true else {
                return nil
            }
            spaces[member.stableIdentity] = space
        }
        return spaces.count == capture.members.count ? spaces : nil
    }

    private func finish(
        _ transaction: GroupSpaceMigrationTransaction,
        terminalState: GroupSpaceMigrationTerminalState
    ) {
        guard activeTransaction === transaction else { return }
        let groupID = transaction.capture.structuralSnapshot.groupID
        if GroupSpaceMigrationTerminalPolicy.requiresNormalDesktopRearm(
            terminalState
        ) {
            requireNormalDesktopRearm(groupID: groupID)
        } else {
            rearmPendingGroupIDs.remove(groupID)
            presentationRearmEvidenceByGroupID.removeValue(forKey: groupID)
        }
        if GroupSpaceMigrationTerminalPolicy.preservesQueuedProxy(
            terminalState
        ) {
            proxyBaselines[groupID] = GroupSpaceProxySourceBaseline(
                presentedMemberIDs:
                    transaction.capture.structuralSnapshot.memberIDs,
                proxyWindowID: transaction.capture.proxyWindowID,
                sourceSpace: transaction.capture.sourceSpace
            )
            host?.restoreGroupSpaceMigrationProxyAfterSourceCancellation(
                groupID: groupID
            )
        } else {
            proxyBaselines.removeValue(forKey: groupID)
            // A migrated/failed Proxy must not remain as a managed Mission
            // Control participant in the same transform. Rebuilding it before
            // normal desktop evidence returns can leave WindowServer with a
            // stale Space participant when another ordinary window is moved.
            host?.retireGroupSpaceMigrationProxy(groupID: groupID)
        }
        activeTransaction = queuedTransactions.isEmpty
            ? nil
            : queuedTransactions.removeFirst()
        host?.groupSpaceMigrationDidFinish(
            transaction.capture,
            terminalState: terminalState
        )
        refreshQueuedProxyPresentation()
        if let next = activeTransaction,
           next.phase == .awaitingNormalDesktopDispatch,
           next.normalDesktopDispatchIsReady {
            dispatchCapturedMove(next)
        }
        stopTimerIfIdle()
    }

    private func queueAPIUnavailableNotice(
        groupID: SnapGroupID,
        kind: GroupSpaceMigrationAPIFailureKind,
        detail: String
    ) {
        let notice = GroupSpaceMigrationAPIUnavailableNotice(
            kind: kind,
            detail: detail
        )
        guard !reportedAPIFailureKeys.contains(
            notice.sessionDeduplicationKey
        ) else { return }
        pendingAPIUnavailableNotice = (groupID, notice)
    }

    private func requireNormalDesktopRearm(groupID: SnapGroupID) {
        rearmPendingGroupIDs.insert(groupID)
        presentationRearmEvidenceByGroupID.removeValue(forKey: groupID)
    }

    private func cancelQueuedTransactionsBeforeDispatch() {
        guard !queuedTransactions.isEmpty else { return }
        let cancelled = queuedTransactions
        queuedTransactions.removeAll()
        for transaction in cancelled {
            let groupID = transaction.capture.structuralSnapshot.groupID
            requireNormalDesktopRearm(groupID: groupID)
            host?.retireGroupSpaceMigrationProxy(groupID: groupID)
            host?.groupSpaceMigrationDidFinish(
                transaction.capture,
                terminalState: .cancelledBeforeStart
            )
        }
        refreshQueuedProxyPresentation()
    }

    private func deliverAPIUnavailableNoticeIfNeeded(
        _ notice: GroupSpaceMigrationAPIUnavailableNotice
    ) {
        guard reportedAPIFailureKeys.insert(
            notice.sessionDeduplicationKey
        ).inserted else { return }
        host?.groupSpaceMigrationDidDetectUnavailableAPI(notice)
    }

    private func stopTimerIfIdle() {
        guard !hasActiveTransaction, proxySessions.isEmpty,
              pendingProxyBaselines.isEmpty else { return }
        monitorTimer?.invalidate()
        monitorTimer = nil
    }
}
