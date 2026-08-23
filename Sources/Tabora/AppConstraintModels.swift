import Foundation
import CoreGraphics

// Persistent App Constraint state is deliberately independent from runtime
// window identity. PID / CGWindowID / AX element hashes never enter these keys.
enum AppConstraintBound: String, Codable, CaseIterable, Hashable {
    case minWidth
    case minHeight
    case maxWidth
    case maxHeight

    var isMinimum: Bool {
        self == .minWidth || self == .minHeight
    }

    var isWidth: Bool {
        self == .minWidth || self == .maxWidth
    }
}

enum RecordingPermission: String, Codable, CaseIterable, Equatable {
    case undecided
    case allowed
    case denied
}

enum ConstraintKnownSource: String, Codable, Equatable {
    case learnedRejection
    case permissionCalibration
    case explicitMeasurement
    case userEdited
}

enum RejectionEvidence: String, Codable, Equatable {
    case pending
    case confirmedAppRejection
    case screenLimit
    case systemLimit
    case peerConstraintLimit
    case axFailure
    case ambiguous
}

struct ConstraintCandidate: Codable, Equatable {
    var value: Double
    var observations: Int
    var firstObservedAt: Date
    var lastObservedAt: Date

    init(value: CGFloat, now: Date = Date()) {
        self.value = Double(value)
        observations = 1
        firstObservedAt = now
        lastObservedAt = now
    }
}

struct KnownConstraintValue: Codable, Equatable {
    var value: Double
    var source: ConstraintKnownSource
    var confirmedAt: Date

    init(value: CGFloat, source: ConstraintKnownSource, now: Date = Date()) {
        self.value = Double(value)
        self.source = source
        confirmedAt = now
    }
}

enum ConstraintBoundState: Codable, Equatable {
    case unknown
    case candidate(ConstraintCandidate)
    case known(KnownConstraintValue)

    var knownValue: CGFloat? {
        guard case .known(let known) = self else { return nil }
        return CGFloat(known.value)
    }

    var candidateValue: CGFloat? {
        guard case .candidate(let candidate) = self else { return nil }
        return CGFloat(candidate.value)
    }
}

enum AppConstraintIdentityKind: String, Codable, Hashable {
    case nativeApplication
    case chromeWebApp
}

struct AppConstraintIdentity: Codable, Hashable {
    let kind: AppConstraintIdentityKind
    let bundleIdentifier: String
    let signingRequirement: String
    let parentBundleIdentifier: String?
    let webAppID: String?

    init(
        kind: AppConstraintIdentityKind,
        bundleIdentifier: String,
        signingRequirement: String,
        parentBundleIdentifier: String? = nil,
        webAppID: String? = nil
    ) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.signingRequirement = signingRequirement
        self.parentBundleIdentifier = parentBundleIdentifier
        self.webAppID = webAppID
    }

    /// Stable textual key used only inside Tabora's local constraint store.
    /// Version, path, PID and window identity are intentionally absent.
    var storageKey: String {
        [
            kind.rawValue,
            parentBundleIdentifier ?? "-",
            webAppID ?? "-",
            bundleIdentifier,
            signingRequirement
        ].joined(separator: "\u{1F}")
    }
}

struct AppConstraintRecord: Codable, Equatable {
    let identity: AppConstraintIdentity
    var displayName: String
    var recordingPermission: RecordingPermission
    var bounds: [AppConstraintBound: ConstraintBoundState]
    var candidateConflictBounds: Set<AppConstraintBound>
    var verificationRequiredBounds: Set<AppConstraintBound>
    var dormant: Bool
    var updatedAt: Date

    init(
        identity: AppConstraintIdentity,
        displayName: String,
        recordingPermission: RecordingPermission = .undecided,
        bounds: [AppConstraintBound: ConstraintBoundState] = [:],
        candidateConflictBounds: Set<AppConstraintBound> = [],
        verificationRequiredBounds: Set<AppConstraintBound> = [],
        dormant: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.displayName = displayName
        self.recordingPermission = recordingPermission
        var normalized = bounds
        for bound in AppConstraintBound.allCases where normalized[bound] == nil {
            normalized[bound] = .unknown
        }
        self.bounds = normalized
        self.candidateConflictBounds = candidateConflictBounds
        self.verificationRequiredBounds = verificationRequiredBounds
        self.dormant = dormant
        self.updatedAt = updatedAt
    }

    func state(for bound: AppConstraintBound) -> ConstraintBoundState {
        bounds[bound] ?? .unknown
    }

    func knownValue(for bound: AppConstraintBound) -> CGFloat? {
        state(for: bound).knownValue
    }

    var candidateConflict: Bool {
        !candidateConflictBounds.isEmpty
    }

    var needsVerification: Bool {
        !verificationRequiredBounds.isEmpty
    }

    var hasValidKnownRanges: Bool {
        if let minimum = knownValue(for: .minWidth),
           let maximum = knownValue(for: .maxWidth),
           minimum > maximum {
            return false
        }
        if let minimum = knownValue(for: .minHeight),
           let maximum = knownValue(for: .maxHeight),
           minimum > maximum {
            return false
        }
        return true
    }
}

struct AppConstraintLimits: Equatable {
    var minWidth: CGFloat?
    var minHeight: CGFloat?
    var maxWidth: CGFloat?
    var maxHeight: CGFloat?

    static let unknown = AppConstraintLimits()

    func value(for bound: AppConstraintBound) -> CGFloat? {
        switch bound {
        case .minWidth: return minWidth
        case .minHeight: return minHeight
        case .maxWidth: return maxWidth
        case .maxHeight: return maxHeight
        }
    }

    mutating func set(_ value: CGFloat?, for bound: AppConstraintBound) {
        switch bound {
        case .minWidth: minWidth = value
        case .minHeight: minHeight = value
        case .maxWidth: maxWidth = value
        case .maxHeight: maxHeight = value
        }
    }

    mutating func mergeSafetyOverride(_ other: AppConstraintLimits) {
        if let value = other.minWidth { minWidth = max(minWidth ?? value, value) }
        if let value = other.minHeight { minHeight = max(minHeight ?? value, value) }
        if let value = other.maxWidth { maxWidth = min(maxWidth ?? value, value) }
        if let value = other.maxHeight { maxHeight = min(maxHeight ?? value, value) }
    }

    var isEmpty: Bool {
        minWidth == nil && minHeight == nil
            && maxWidth == nil && maxHeight == nil
    }
}


/// A settled frame mismatch may be used as temporary geometry evidence for
/// the exact placement transaction that produced it. This never becomes a
/// persistent App Constraint by itself; persistent learning remains owned by
/// ConstraintProbe/ConstraintStore and keeps axis-attribution rules intact.
enum OperationLocalConstraintEvidencePolicy {
    static func settledBounds(
        requestedFrame: CGRect,
        acceptedFrame: CGRect,
        activeAxes: Set<ConstraintProbeAxis>,
        excludedAxes: Set<ConstraintProbeAxis>,
        epsilon: CGFloat
    ) -> [AppConstraintBound: CGFloat] {
        guard epsilon.isFinite, epsilon >= 0 else { return [:] }
        var result: [AppConstraintBound: CGFloat] = [:]

        if activeAxes.contains(.width), !excludedAxes.contains(.width) {
            let requested = requestedFrame.width
            let accepted = acceptedFrame.width
            if requested.isFinite, accepted.isFinite, accepted > 0 {
                if accepted > requested + epsilon {
                    result[.minWidth] = accepted
                } else if accepted < requested - epsilon {
                    result[.maxWidth] = accepted
                }
            }
        }

        if activeAxes.contains(.height), !excludedAxes.contains(.height) {
            let requested = requestedFrame.height
            let accepted = acceptedFrame.height
            if requested.isFinite, accepted.isFinite, accepted > 0 {
                if accepted > requested + epsilon {
                    result[.minHeight] = accepted
                } else if accepted < requested - epsilon {
                    result[.maxHeight] = accepted
                }
            }
        }
        return result
    }
}

struct ConstraintRecordingPermissionRequest {
    let identity: AppConstraintIdentity
    let displayName: String
    /// Exact window that produced the confirmed rejection. Persistent
    /// permission remains app-scoped, but an optional explicit calibration
    /// must never fall through to another window from the same application.
    let windowStableIdentity: String?
}

enum ConstraintPermissionPromptPolicy {
    static func shouldRequestFromOperationLocalEvidence(
        hasAttributableBounds: Bool,
        currentPermission: RecordingPermission?,
        popupEnabled: Bool
    ) -> Bool {
        popupEnabled
            && hasAttributableBounds
            && (currentPermission ?? .undecided) == .undecided
    }
}

struct ConfirmedConstraintRejection: Equatable {
    let identity: AppConstraintIdentity
    let displayName: String
    let bound: AppConstraintBound
    let acceptedValue: CGFloat
    let measurementEpsilon: CGFloat
    let operationGeneration: Int
}

enum ConstraintLearningDisposition: Equatable {
    case ignored
    case pendingCandidate
    case requestPermission
    case learnedKnown
    case contradiction
    case conflict
}
