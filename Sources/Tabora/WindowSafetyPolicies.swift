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

enum WindowStructuralPolicy {
    /// Destructive structural cleanup is authorized only by confirmed
    /// disappearance. Temporary AX failures must retain membership/state.
    static func isConfirmedMissing(_ liveness: WindowLiveness) -> Bool {
        liveness == .missing
    }
}

struct PointerDragSurfaceEvidence: Equatable {
    let selection: WindowServerSelectionSnapshot
    let frame: CGRect
    let mouseDownPoint: CGPoint
    let acquiredAt: TimeInterval
}

enum PointerDragSurfaceEvidencePolicy {
    /// Capture immutable Window Server evidence at physical mouse-down. The
    /// first surface in the ordered snapshot owns the point; a popup/nonzero
    /// layer fails closed rather than exposing a window behind it.
    static func capture(
        at point: CGPoint,
        snapshot: [WindowOcclusionSnapshot],
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> PointerDragSurfaceEvidence? {
        guard point.x.isFinite, point.y.isFinite,
              let surface = snapshot.first(where: { $0.frame.contains(point) }),
              surface.layer == 0,
              surface.frame.width > 0, surface.frame.height > 0 else {
            return nil
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
        canMoveAndResize: Bool,
        followsPointer: Bool
    ) -> Bool {
        guard let candidateWindowID, dragStartCensusCompleteness == .complete else {
            return false
        }
        return candidatePID == sourcePID
            && candidateIdentity != sourceIdentity
            && candidateIdentity != currentDragIdentity
            && !windowServerIDsAtDragStart.contains(candidateWindowID)
            && canMoveAndResize
            && followsPointer
    }
}

struct ForegroundSafetyEvidence {
    let selectedPID: pid_t
    let selectedIdentity: String
    let selectedWindowID: CGWindowID
    let allowedWindowServerIDs: Set<CGWindowID>
    let windowServerSelection: WindowServerSelectionSnapshot?
    let focusedWindowServerSelection: WindowServerSelectionSnapshot?
    let accessibilitySelection: ActiveWindowIdentitySnapshot?
}

enum ForegroundSafetyPolicy {
    static func allowsAutomaticRaise(
        _ evidence: ForegroundSafetyEvidence
    ) -> Bool {
        guard let serverSelection = evidence.windowServerSelection,
              serverSelection.pid == evidence.selectedPID,
              evidence.allowedWindowServerIDs.contains(
                  serverSelection.windowID
              ),
              let focusedSelection = evidence.focusedWindowServerSelection,
              focusedSelection.pid == evidence.selectedPID,
              focusedSelection.windowID == evidence.selectedWindowID,
              let accessibilitySelection = evidence.accessibilitySelection,
              accessibilitySelection.pid == evidence.selectedPID,
              accessibilitySelection.contains(evidence.selectedIdentity),
              !accessibilitySelection.hasDistinctFocusedSurface,
              !accessibilitySelection.hasBlockingModalSurface else {
            return false
        }
        return true
    }
}
