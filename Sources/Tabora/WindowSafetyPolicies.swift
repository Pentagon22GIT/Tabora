import CoreGraphics
import Foundation

struct WindowMatchScore: Equatable {
    let candidateIndex: Int
    let score: CGFloat
}

struct PersistedWindowBinding: Equatable {
    let stableIdentity: String
    let pid: pid_t
    let windowID: CGWindowID
}

enum WindowLiveness: Equatable {
    case alive
    case missing
    case unknown
}

/// Capability observations used by user-initiated placement readiness.
/// A transient AX transport failure is not proof that the window cannot move
/// or resize, so callers that may cancel a user transaction must preserve the
/// indeterminate state instead of collapsing it into `false`.
enum WindowInteractionCapabilityObservation: Equatable {
    case available
    case unavailable
    case unknown

    static func combining(
        _ lhs: WindowInteractionCapabilityObservation,
        _ rhs: WindowInteractionCapabilityObservation
    ) -> WindowInteractionCapabilityObservation {
        if lhs == .unavailable || rhs == .unavailable { return .unavailable }
        if lhs == .available && rhs == .available { return .available }
        return .unknown
    }
}

enum WindowDiscoveryCompleteness: Equatable {
    case complete
    case unknown
}

struct WindowIdentityCensus: Equatable {
    let identities: Set<String>
    let completeness: WindowDiscoveryCompleteness

    static let unknown = WindowIdentityCensus(
        identities: [],
        completeness: .unknown
    )
}

struct WindowServerWindowIDCensus: Equatable {
    let windowIDs: Set<CGWindowID>
    let completeness: WindowDiscoveryCompleteness

    static let unknown = WindowServerWindowIDCensus(
        windowIDs: [],
        completeness: .unknown
    )
}


enum PointerInteractionOwnershipPolicy {
    /// Recovery may clean up an orphaned Assist session only after no snap
    /// placement transaction owns the picker-hidden handoff state.
    static func recoveryMayCancelAssist(
        assistSessionActive: Bool,
        pickerVisible: Bool,
        assistPlacementPending: Bool,
        snapPlacementInProgress: Bool
    ) -> Bool {
        assistSessionActive
            && !pickerVisible
            && !assistPlacementPending
            && !snapPlacementInProgress
    }
}

enum GroupForegroundPointerObservationPolicy {
    /// A plain desktop click may passively re-observe transient foreground
    /// evidence using the controller's existing bounded resolution budget.
    /// This never authorizes a raise; all foreground safety evidence must be
    /// proven again before any mutation is issued.
    static func shouldRetry(
        isPointerOrigin: Bool,
        completedObservationAttempts: Int,
        maximumObservationAttempts: Int
    ) -> Bool {
        isPointerOrigin
            && completedObservationAttempts < maximumObservationAttempts
    }
}

enum PresentationTransactionOwnershipPolicy {
    static func preservesMissionControlPresentation(
        snapPlacementInProgress: Bool,
        assistSessionActive: Bool,
        assistPlacementPending: Bool
    ) -> Bool {
        snapPlacementInProgress || assistSessionActive || assistPlacementPending
    }
}

enum ResizeHandlePresentationOwnershipPolicy {
    /// Once an exact Mission Control group proxy has delivered selection, that
    /// foreground transaction owns desktop-handle presentation until it
    /// completes or cancels. Geometry becoming normal before foreground
    /// settlement must not re-present floating handles mid-handoff.
    static func missionControlSelectionOwnsPresentation(
        activationIsActive: Bool
    ) -> Bool {
        activationIsActive
    }
}

enum RecoveryPresentationRefreshAction: Equatable {
    case none
    case fullPresentationRefresh
    case missionControlPreviewOnly
}

enum RecoveryPresentationRefreshPolicy {
    static func action(
        hasPresentationRecoveryDebt: Bool,
        hasPreviewCacheDebt: Bool
    ) -> RecoveryPresentationRefreshAction {
        if hasPresentationRecoveryDebt { return .fullPresentationRefresh }
        if hasPreviewCacheDebt { return .missionControlPreviewOnly }
        return .none
    }
}

enum ApplicationInteractionSuppressionPolicy {
    static func isSuppressed(
        applicationUIVisible: Bool,
        constraintMeasurementActive: Bool,
        constraintPermissionPromptActive: Bool,
        restoreTransactionActive: Bool
    ) -> Bool {
        applicationUIVisible
            || constraintMeasurementActive
            || constraintPermissionPromptActive
            || restoreTransactionActive
    }
}

enum WindowStructuralPolicy {
    /// Destructive structural cleanup is authorized only by confirmed
    /// disappearance. Temporary AX failures must retain membership/state.
    static func isConfirmedMissing(_ liveness: WindowLiveness) -> Bool {
        liveness == .missing
    }
}

enum AXFrameMutationCommitPolicy {
    /// Commit from the semantic postcondition, not only from whether every AX
    /// message returned success. A captured/heavy application can time out
    /// after accepting the requested geometry; rolling that settled frame back
    /// creates the visible cancel/bounce failure. Confirmed disappearance, an
    /// unsettled frame, or required-edge mismatch still fails closed.
    static func accepts(
        _ observation: AXFrameMutationObservation,
        requiredOuterEdgesMatch: Bool
    ) -> Bool {
        guard observation.liveness != .missing,
              requiredOuterEdgesMatch,
              observation.acceptedFrame != nil else {
            return false
        }
        return observation.completedSuccessfully
            || (observation.liveness == .unknown
                && observation.acceptedFrameIsSettled)
    }
}

struct PointerDragSurfaceEvidence: Equatable {
    let selection: WindowServerSelectionSnapshot
    let frame: CGRect
    let mouseDownPoint: CGPoint
    let acquiredAt: TimeInterval
}

enum PointerDragSurfaceEvidencePolicy {
    /// Capture immutable physical pointer evidence from the original mouse
    /// event. The Window Server visual stack remains relevant, but it is not
    /// the sole input authority: screen-sharing/capture can place a
    /// non-interactive Window Server surface above the real client window.
    ///
    /// When Quartz reports the exact window that can handle this event, accept
    /// that window only if the same Window ID is presently a layer-zero
    /// physical surface containing the pointer. This follows macOS event
    /// routing without blindly skipping arbitrary overlays or popups. If the
    /// event-routing field is unavailable, preserve the historical fail-closed
    /// visual-top policy.
    static func capture(
        at point: CGPoint,
        snapshot: [WindowOcclusionSnapshot],
        eventHandlerWindowID: CGWindowID? = nil,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> PointerDragSurfaceEvidence? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let containingSurfaces = snapshot
            .filter {
                $0.frame.contains(point)
                    && $0.frame.width > 0
                    && $0.frame.height > 0
            }
            .sorted { $0.zIndex < $1.zIndex }
        guard let visualTop = containingSurfaces.first else { return nil }

        let surface: WindowOcclusionSnapshot
        if let eventHandlerWindowID {
            guard let routedSurface = containingSurfaces.first(where: {
                $0.windowID == eventHandlerWindowID && $0.layer == 0
            }) else {
                return nil
            }
            surface = routedSurface
        } else {
            guard visualTop.layer == 0 else { return nil }
            surface = visualTop
        }

        return PointerDragSurfaceEvidence(
            selection: WindowServerSelectionSnapshot(
                pid: surface.pid,
                windowID: surface.windowID
            ),
            frame: surface.frame,
            mouseDownPoint: point,
            acquiredAt: now
        )
    }

    static func stillMatches(
        _ evidence: PointerDragSurfaceEvidence,
        pid: pid_t,
        windowID: CGWindowID,
        frame: CGRect,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        maximumSizeDelta: CGFloat = 96
    ) -> Bool {
        guard evidence.selection.pid == pid,
              evidence.selection.windowID == windowID,
              now >= evidence.acquiredAt else { return false }
        // Evidence lifetime is bounded by the physical mouse gesture itself;
        // do not add a wall-clock expiry that would reject a legitimate
        // click-and-hold before dragging. Origin can legitimately move during
        // the gesture. Size is only a bounded anti-ID-reuse check and is never
        // an AX resize baseline.
        let sizeDelta = abs(evidence.frame.width - frame.width)
            + abs(evidence.frame.height - frame.height)
        return sizeDelta <= maximumSizeDelta
    }
}

enum PersistedWindowBindingResolution: Equatable {
    case unavailable
    case matched(stableIdentity: String)
    case conflicting
}

enum PersistedWindowBindingPolicy {
    /// A CGWindowID is authoritative only inside its owning process and only
    /// while exactly one live Tabora placement claims it. Geometry and title
    /// are deliberately absent: same-application windows may legitimately
    /// share both when multiple groups overlap on the desktop.
    static func resolve(
        pid: pid_t,
        windowID: CGWindowID,
        bindings: [PersistedWindowBinding]
    ) -> PersistedWindowBindingResolution {
        let identities = Set(bindings.compactMap { binding in
            binding.pid == pid && binding.windowID == windowID
                ? binding.stableIdentity
                : nil
        })
        guard !identities.isEmpty else { return .unavailable }
        guard identities.count == 1, let identity = identities.first else {
            return .conflicting
        }
        return .matched(stableIdentity: identity)
    }
}

enum WindowSnapEligibilityPolicy {
    private static let excludedBundleIdentifiers: Set<String> = [
        // System Settings still uses the historical System Preferences bundle
        // identifier on current macOS releases. Keep the renamed spelling as
        // a defensive alias so an OS-side rename cannot make it eligible.
        "com.apple.systempreferences",
        "com.apple.systemsettings"
    ]

    static func isEligible(bundleIdentifier: String?) -> Bool {
        guard let normalized = bundleIdentifier?.lowercased() else {
            return true
        }
        return !excludedBundleIdentifiers.contains(normalized)
    }
}

enum WindowMatchingPolicy {
    static let minimumScoreSeparation: CGFloat = 1

    static func uniqueBestCandidate(
        in candidates: [WindowMatchScore],
        minimumSeparation: CGFloat = minimumScoreSeparation
    ) -> Int? {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.candidateIndex < rhs.candidateIndex
            }
            return lhs.score > rhs.score
        }
        guard let best = sorted.first else { return nil }
        if sorted.count > 1,
           best.score - sorted[1].score <= minimumSeparation {
            return nil
        }
        return best.candidateIndex
    }

    /// Returns only pairs that are a unique best match in both directions.
    /// A locally attractive AX-to-CG match is not enough when the same CG
    /// surface is also an equally plausible match for another AX window.
    static func mutualUniqueMatches(
        scores: [[CGFloat?]],
        minimumSeparation: CGFloat = minimumScoreSeparation
    ) -> [(axIndex: Int, cgIndex: Int)] {
        guard let cgCount = scores.first?.count,
              scores.allSatisfy({ $0.count == cgCount }) else { return [] }

        let bestCGForAX: [Int?] = scores.map { row in
            uniqueBestCandidate(
                in: row.enumerated().compactMap { index, score in
                    score.map {
                        WindowMatchScore(candidateIndex: index, score: $0)
                    }
                },
                minimumSeparation: minimumSeparation
            )
        }
        let bestAXForCG: [Int?] = (0..<cgCount).map { cgIndex in
            uniqueBestCandidate(
                in: scores.indices.compactMap { axIndex in
                    scores[axIndex][cgIndex].map {
                        WindowMatchScore(candidateIndex: axIndex, score: $0)
                    }
                },
                minimumSeparation: minimumSeparation
            )
        }

        return bestCGForAX.enumerated().compactMap { axIndex, cgIndex in
            guard let cgIndex,
                  bestAXForCG[cgIndex] == axIndex else { return nil }
            return (axIndex, cgIndex)
        }
    }
}

enum PointerDragAcquisitionPolicy {
    /// Select exactly the frontmost surface under the pointer. Never substitute
    /// a focused window or skip a non-draggable popup to reach a window behind
    /// it; both would turn first-click races into unintended window control.
    static func draggableWindowID(
        at point: CGPoint,
        orderedSurfaces: [SplitHitTestSurface],
        draggableWindowIDs: Set<CGWindowID>
    ) -> CGWindowID? {
        guard let frontmostID = SplitLayoutGeometry.frontmostHitWindowID(
            at: point,
            orderedSurfaces: orderedSurfaces
        ), draggableWindowIDs.contains(frontmostID) else {
            return nil
        }
        return frontmostID
    }
}



enum DetachedWindowSurfaceSelectionPolicy {
    static func candidateEvidence(
        routed: PointerDragSurfaceEvidence?,
        visualFallback: PointerDragSurfaceEvidence?,
        sourcePID: pid_t,
        windowServerIDsAtDragStart: Set<CGWindowID>,
        eventHandlerWasReported: Bool
    ) -> PointerDragSurfaceEvidence? {
        func isNewSameProcess(_ evidence: PointerDragSurfaceEvidence?) -> Bool {
            guard let evidence else { return false }
            return evidence.selection.pid == sourcePID
                && !windowServerIDsAtDragStart.contains(
                    evidence.selection.windowID
                )
        }
        if isNewSameProcess(routed) { return routed }
        guard eventHandlerWasReported, isNewSameProcess(visualFallback) else {
            return nil
        }
        return visualFallback
    }
}

enum StagedGroupContinuationPolicy {
    /// A drag-stage is structural evidence for the captured member set, but it
    /// does not force those members to remain grouped after an unrelated drop.
    /// Continue the staged group only when the incoming zone and the persisted
    /// peer zones still form one connected logical split topology.
    static func canContinue(
        draggedIdentity: String,
        memberIDs: Set<String>,
        zonesByMemberID: [String: SnapZone],
        incomingZone: SnapZone,
        visibleFrame: CGRect
    ) -> Bool {
        guard memberIDs.count >= 2,
              memberIDs.contains(draggedIdentity),
              memberIDs.allSatisfy({ zonesByMemberID[$0] != nil }) else {
            return false
        }
        var proposedZones = Dictionary(
            uniqueKeysWithValues: memberIDs.compactMap { identity in
                zonesByMemberID[identity].map { (identity, $0) }
            }
        )
        proposedZones[draggedIdentity] = incomingZone
        _ = visibleFrame // retained for API compatibility with existing callers/tests
        return SplitLayoutGeometry
            .logicalSplitTopologyIsConnectedAndNonOverlapping(
                zonesByIdentity: proposedZones
            )
    }
}
enum DetachedWindowAdoptionPolicy {
    static func canAdopt(
        candidatePID: pid_t,
        sourcePID: pid_t,
        candidateIdentity: String,
        sourceIdentity: String,
        currentDragIdentity: String?,
        candidateWindowID: CGWindowID?,
        windowServerIDsAtDragStart: Set<CGWindowID>,
        dragStartCensusCompleteness: WindowDiscoveryCompleteness,
        moveAndResizeCapability: WindowInteractionCapabilityObservation,
        followsPointer: Bool
    ) -> Bool {
        guard let candidateWindowID,
              dragStartCensusCompleteness == .complete,
              moveAndResizeCapability != .unavailable else {
            return false
        }
        // Gesture ownership may migrate before AX has finished reporting the
        // new detached surface's settable attributes. Physical same-process
        // identity plus a complete pre-drag census is strong enough to retain
        // an `unknown` capability without turning it into a negative result.
        return candidatePID == sourcePID
            && candidateIdentity != sourceIdentity
            && candidateIdentity != currentDragIdentity
            && !windowServerIDsAtDragStart.contains(candidateWindowID)
            && followsPointer
    }
}

struct ForegroundSafetyEvidence {
    let selectedPID: pid_t
    let selectedIdentity: String
    let selectedWindowID: CGWindowID
    let allowedWindowServerSelections: Set<WindowServerSelectionSnapshot>
    let allowedAccessibilitySelections: [FocusedWindowIdentity]
    let windowServerSelection: WindowServerSelectionSnapshot?
    let focusedWindowServerSelection: WindowServerSelectionSnapshot?
    let accessibilitySelection: ActiveWindowIdentitySnapshot?
}

enum ForegroundSafetyPolicy {
    static func allowsAutomaticRaise(
        _ evidence: ForegroundSafetyEvidence
    ) -> Bool {
        let selectedServerSurface = WindowServerSelectionSnapshot(
            pid: evidence.selectedPID,
            windowID: evidence.selectedWindowID
        )
        let selectedAccessibilitySurface = FocusedWindowIdentity(
            pid: evidence.selectedPID,
            stableIdentity: evidence.selectedIdentity
        )
        guard evidence.allowedWindowServerSelections.contains(
                  selectedServerSurface
              ),
              evidence.allowedAccessibilitySelections.contains(
                  selectedAccessibilitySurface
              ),
              let serverSelection = evidence.windowServerSelection,
              evidence.allowedWindowServerSelections.contains(serverSelection),
              let focusedSelection = evidence.focusedWindowServerSelection,
              evidence.allowedWindowServerSelections.contains(focusedSelection),
              let accessibilitySelection = evidence.accessibilitySelection,
              !accessibilitySelection.hasBlockingModalSurface else {
            return false
        }

        let observedAccessibilitySurfaces = [
            accessibilitySelection.focusedIdentity,
            accessibilitySelection.mainIdentity
        ].compactMap { stableIdentity -> FocusedWindowIdentity? in
            guard let stableIdentity else { return nil }
            return FocusedWindowIdentity(
                pid: accessibilitySelection.pid,
                stableIdentity: stableIdentity
            )
        }
        guard !observedAccessibilitySurfaces.isEmpty,
              observedAccessibilitySurfaces.allSatisfy({
                  evidence.allowedAccessibilitySelections.contains($0)
              }) else {
            return false
        }
        return true
    }
}
