import Foundation

private struct ConstraintStoreEnvelope: Codable {
    let schemaVersion: Int
    let records: [AppConstraintRecord]
}

final class ConstraintStore {
    static let schemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
            let bundleDomain = Bundle.main.bundleIdentifier ?? "unbundled"
            self.fileURL = base
                .appendingPathComponent("Tabora", isDirectory: true)
                .appendingPathComponent(bundleDomain, isDirectory: true)
                .appendingPathComponent("constraints-v1.json", isDirectory: false)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadRecords() -> [AppConstraintRecord] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return []
        }

        // Decode records independently so a single corrupt record cannot make
        // every learned application constraint disappear.
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              (object["schemaVersion"] as? Int) == Self.schemaVersion,
              let rawRecords = object["records"] as? [Any] else {
            return []
        }

        return rawRecords.compactMap { raw -> AppConstraintRecord? in
            guard JSONSerialization.isValidJSONObject(raw),
                  let recordData = try? JSONSerialization.data(withJSONObject: raw),
                  let record = try? decoder.decode(
                      AppConstraintRecord.self,
                      from: recordData
                  ), Self.isValid(record) else {
                return nil
            }
            return record
        }
    }

    func saveRecords(_ records: [AppConstraintRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let envelope = ConstraintStoreEnvelope(
            schemaVersion: Self.schemaVersion,
            records: records.sorted {
                $0.identity.storageKey < $1.identity.storageKey
            }
        )
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func isValid(_ record: AppConstraintRecord) -> Bool {
        guard !record.identity.bundleIdentifier.isEmpty,
              !record.identity.signingRequirement.isEmpty else { return false }
        for bound in AppConstraintBound.allCases {
            switch record.state(for: bound) {
            case .unknown:
                continue
            case .candidate(let candidate):
                guard candidate.value.isFinite, candidate.value > 0,
                      candidate.observations > 0 else { return false }
            case .known(let known):
                guard known.value.isFinite, known.value > 0 else { return false }
            }
        }
        return record.hasValidKnownRanges
    }
}

final class AppConstraintRegistry {
    static let shared = AppConstraintRegistry(store: ConstraintStore())

    private let store: ConstraintStore
    private var recordsByKey: [String: AppConstraintRecord]
    private(set) var generation: UInt64 = 0

    init(store: ConstraintStore) {
        self.store = store
        recordsByKey = Dictionary(
            store.loadRecords().map { ($0.identity.storageKey, $0) },
            uniquingKeysWith: { newer, _ in newer }
        )
    }

    var records: [AppConstraintRecord] {
        recordsByKey.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
    }

    func record(for identity: AppConstraintIdentity) -> AppConstraintRecord? {
        recordsByKey[identity.storageKey]
    }

    func limits(for identity: AppConstraintIdentity) -> AppConstraintLimits {
        var limits = AppConstraintLimits.unknown
        if let record = record(for: identity) {
            for bound in AppConstraintBound.allCases {
                limits.set(record.knownValue(for: bound), for: bound)
            }
        }
        return limits
    }

    @discardableResult
    func ensureRecord(
        identity: AppConstraintIdentity,
        displayName: String
    ) -> AppConstraintRecord {
        if var existing = recordsByKey[identity.storageKey] {
            if existing.displayName != displayName || existing.dormant {
                existing.displayName = displayName
                existing.dormant = false
                existing.updatedAt = Date()
                commit(existing)
            }
            return existing
        }
        let record = AppConstraintRecord(
            identity: identity,
            displayName: displayName
        )
        commit(record)
        return record
    }

    func setPermission(
        _ permission: RecordingPermission,
        for identity: AppConstraintIdentity
    ) {
        guard var record = recordsByKey[identity.storageKey] else { return }
        guard record.recordingPermission != permission else { return }
        record.recordingPermission = permission
        if permission == .denied {
            for bound in AppConstraintBound.allCases {
                if case .candidate = record.state(for: bound) {
                    record.bounds[bound] = .unknown
                    record.candidateConflictBounds.remove(bound)
                    record.verificationRequiredBounds.remove(bound)
                }
            }
        } else if permission == .allowed {
            // The candidate already came from confirmed app rejection. This
            // store transition only promotes that evidence. A controller may
            // separately run explicit, user-authorized calibration, but the
            // permission write itself never mutates an external window.
            // Promote only non-conflicting candidates and keep impossible
            // ranges inactive.
            let dimensions: [[AppConstraintBound]] = [
                [.minWidth, .maxWidth],
                [.minHeight, .maxHeight]
            ]
            for dimension in dimensions {
                var trial = record
                var promotable = Set<AppConstraintBound>()
                for bound in dimension {
                    guard case .candidate(let candidate) = record.state(for: bound),
                          !record.candidateConflictBounds.contains(bound),
                          !record.verificationRequiredBounds.contains(bound) else {
                        continue
                    }
                    trial.bounds[bound] = .known(KnownConstraintValue(
                        value: CGFloat(candidate.value),
                        source: .learnedRejection
                    ))
                    promotable.insert(bound)
                }
                guard !promotable.isEmpty else { continue }
                guard trial.hasValidKnownRanges else {
                    record.candidateConflictBounds.formUnion(promotable)
                    record.verificationRequiredBounds.formUnion(promotable)
                    continue
                }
                record = trial
                for bound in promotable {
                    record.candidateConflictBounds.remove(bound)
                    record.verificationRequiredBounds.remove(bound)
                }
            }
        }
        record.updatedAt = Date()
        commit(record)
    }

    @discardableResult
    func setKnownValue(
        _ value: CGFloat,
        for bound: AppConstraintBound,
        identity: AppConstraintIdentity,
        source: ConstraintKnownSource
    ) -> Bool {
        applyKnownValues(
            [bound: value],
            identity: identity,
            source: source
        )
    }

    @discardableResult
    func applyKnownValues(
        _ values: [AppConstraintBound: CGFloat],
        clearing clearedBounds: Set<AppConstraintBound> = [],
        identity: AppConstraintIdentity,
        source: ConstraintKnownSource
    ) -> Bool {
        guard var record = recordsByKey[identity.storageKey] else { return false }
        let validValues = values.filter { $0.value.isFinite && $0.value > 0 }
        guard validValues.count == values.count,
              Set(validValues.keys).isDisjoint(with: clearedBounds),
              !validValues.isEmpty || !clearedBounds.isEmpty else {
            return false
        }
        for bound in clearedBounds {
            record.bounds[bound] = .unknown
        }
        for (bound, value) in validValues {
            record.bounds[bound] = .known(KnownConstraintValue(
                value: value,
                source: source
            ))
        }
        guard record.hasValidKnownRanges else { return false }
        let affectedBounds = Set(validValues.keys).union(clearedBounds)
        for bound in affectedBounds {
            record.candidateConflictBounds.remove(bound)
            record.verificationRequiredBounds.remove(bound)
        }
        record.updatedAt = Date()
        commit(record)
        return true
    }

    func setBoundUnknown(
        _ bound: AppConstraintBound,
        identity: AppConstraintIdentity
    ) {
        guard var record = recordsByKey[identity.storageKey] else { return }
        record.bounds[bound] = .unknown
        record.candidateConflictBounds.remove(bound)
        record.verificationRequiredBounds.remove(bound)
        record.updatedAt = Date()
        commit(record)
    }

    func deleteRecord(identity: AppConstraintIdentity) {
        recordsByKey.removeValue(forKey: identity.storageKey)
        generation &+= 1
        persist()
    }

    func updateDormant(
        _ dormant: Bool,
        identity: AppConstraintIdentity
    ) {
        guard var record = recordsByKey[identity.storageKey],
              record.dormant != dormant else { return }
        record.dormant = dormant
        record.updatedAt = Date()
        commit(record)
    }

    /// Runtime observation of the exact persistent identity silently
    /// reactivates an existing record, but never creates a record merely
    /// because an application window was seen.
    func markObservedPresent(
        identity: AppConstraintIdentity,
        displayName: String
    ) {
        guard var record = recordsByKey[identity.storageKey] else { return }
        guard record.dormant || record.displayName != displayName else { return }
        record.dormant = false
        record.displayName = displayName
        record.updatedAt = Date()
        commit(record)
    }

    @discardableResult
    func observeConfirmedRejection(
        _ rejection: ConfirmedConstraintRejection,
        popupEnabled: Bool
    ) -> ConstraintLearningDisposition {
        var record = ensureRecord(
            identity: rejection.identity,
            displayName: rejection.displayName
        )
        let bound = rejection.bound
        let accepted = rejection.acceptedValue

        switch record.state(for: bound) {
        case .known(let known):
            let oldValue = CGFloat(known.value)
            let isStricter = bound.isMinimum
                ? accepted > oldValue + rejection.measurementEpsilon
                : accepted < oldValue - rejection.measurementEpsilon
            guard isStricter else { return .ignored }
            record.verificationRequiredBounds.insert(bound)
            record.updatedAt = Date()
            commit(record)
            return .contradiction

        case .unknown:
            switch record.recordingPermission {
            case .allowed:
                var trial = record
                trial.bounds[bound] = .known(KnownConstraintValue(
                    value: accepted,
                    source: .learnedRejection
                ))
                guard trial.hasValidKnownRanges else {
                    // A newly discovered opposite bound can contradict an
                    // older known value. Keep the fresh evidence inactive
                    // instead of persisting an impossible active range.
                    record.bounds[bound] = .candidate(ConstraintCandidate(
                        value: accepted
                    ))
                    record.candidateConflictBounds.insert(bound)
                    record.verificationRequiredBounds.insert(bound)
                    record.updatedAt = Date()
                    commit(record)
                    return .conflict
                }
                trial.updatedAt = Date()
                commit(trial)
                return .learnedKnown
            case .denied:
                return .ignored
            case .undecided:
                record.bounds[bound] = .candidate(ConstraintCandidate(
                    value: accepted
                ))
                record.updatedAt = Date()
                commit(record)
                return popupEnabled ? .requestPermission : .pendingCandidate
            }

        case .candidate(var candidate):
            let candidateValue = CGFloat(candidate.value)
            if abs(candidateValue - accepted) <= rejection.measurementEpsilon {
                candidate.observations += 1
                candidate.lastObservedAt = Date()
                candidate.value = Double(bound.isMinimum
                    ? max(candidateValue, accepted)
                    : min(candidateValue, accepted))
                record.bounds[bound] = .candidate(candidate)
                if record.recordingPermission == .allowed,
                   candidate.observations >= 2 {
                    var trial = record
                    trial.bounds[bound] = .known(KnownConstraintValue(
                        value: CGFloat(candidate.value),
                        source: .learnedRejection
                    ))
                    if trial.hasValidKnownRanges {
                        trial.candidateConflictBounds.remove(bound)
                        trial.verificationRequiredBounds.remove(bound)
                        trial.updatedAt = Date()
                        commit(trial)
                        return .learnedKnown
                    }
                    record.candidateConflictBounds.insert(bound)
                    record.verificationRequiredBounds.insert(bound)
                }
                record.updatedAt = Date()
                commit(record)
                return record.recordingPermission == .undecided && popupEnabled
                    ? .requestPermission
                    : .pendingCandidate
            }

            record.candidateConflictBounds.insert(bound)
            record.verificationRequiredBounds.insert(bound)
            record.updatedAt = Date()
            commit(record)
            return .conflict
        }
    }

    @discardableResult
    func applyExplicitMeasurement(
        _ values: [AppConstraintBound: CGFloat],
        identity: AppConstraintIdentity,
        displayName: String
    ) -> Set<AppConstraintBound> {
        var record = ensureRecord(identity: identity, displayName: displayName)
        var applied = Set<AppConstraintBound>()

        // Width and height are independent. Validate each dimension as one
        // atomic unit so an inconsistent measurement cannot invalidate the
        // whole persistent record, while a confirmed orthogonal dimension can
        // still be retained safely.
        let dimensions: [[AppConstraintBound]] = [
            [.minWidth, .maxWidth],
            [.minHeight, .maxHeight]
        ]
        for dimension in dimensions {
            let updates = dimension.compactMap { bound -> (AppConstraintBound, CGFloat)? in
                guard let value = values[bound], value.isFinite, value > 0 else {
                    return nil
                }
                return (bound, value)
            }
            guard !updates.isEmpty else { continue }
            var trial = record
            for (bound, value) in updates {
                trial.bounds[bound] = .known(KnownConstraintValue(
                    value: value,
                    source: .explicitMeasurement
                ))
            }
            guard trial.hasValidKnownRanges else {
                record.verificationRequiredBounds.formUnion(updates.map(\.0))
                continue
            }
            record = trial
            for (bound, _) in updates {
                applied.insert(bound)
                record.candidateConflictBounds.remove(bound)
                record.verificationRequiredBounds.remove(bound)
            }
        }
        record.updatedAt = Date()
        commit(record)
        return applied
    }

    private func commit(_ record: AppConstraintRecord) {
        recordsByKey[record.identity.storageKey] = record
        generation &+= 1
        persist()
    }

    private func persist() {
        do {
            try store.saveRecords(Array(recordsByKey.values))
        } catch {
            // Persistence failure must never change active geometry correctness.
            // Keep the validated in-memory state for this session; the next
            // meaningful state transition retries the atomic save.
        }
    }
}
