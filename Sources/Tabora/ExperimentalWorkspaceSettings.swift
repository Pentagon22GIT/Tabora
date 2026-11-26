import Foundation

enum WorkspaceEdgeDelayError: LocalizedError {
    case commandFailed(String)
    case invalidStoredValue
    case verificationFailed
    case rollbackFailed(primary: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed:
            return L10n.text("workspace.error.command_failed")
        case .invalidStoredValue:
            return L10n.text("workspace.error.invalid_readback")
        case .verificationFailed:
            return L10n.text("workspace.error.verification_failed")
        case .rollbackFailed(let primary, let rollback):
            return L10n.format(
                "workspace.error.rollback_failed",
                primary,
                rollback
            )
        }
    }
}

private enum WorkspaceEdgeDelayMutation {
    case set(Double)
    case remove
}

final class ExperimentalWorkspaceSettings {
    static let shared = ExperimentalWorkspaceSettings()
    static let delayedValue: Double = 60

    private let queue = DispatchQueue(
        label: "dev.pent.Tabora.experimental-workspace-settings",
        qos: .userInitiated
    )

    func readEdgeDelay(
        completion: @escaping (Result<Double?, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<Double?, Error> = Result {
                try self.readEdgeDelaySynchronously()
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func applyDelayedEdgeSwitching(
        completion: @escaping (Result<Double?, Error>) -> Void
    ) {
        mutate(
            mutation: .set(Self.delayedValue),
            completion: completion
        )
    }

    func restoreDefaultEdgeSwitching(
        completion: @escaping (Result<Double?, Error>) -> Void
    ) {
        mutate(mutation: .remove, completion: completion)
    }

    private func mutate(
        mutation: WorkspaceEdgeDelayMutation,
        completion: @escaping (Result<Double?, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<Double?, Error>
            do {
                let original = try self.storedValue()
                let originalValue = try self.delay(from: original)
                let expectedValue = self.expectedValue(for: mutation)
                if self.valuesMatch(originalValue, expectedValue) {
                    result = .success(originalValue)
                } else {
                    do {
                        try self.write(expectedValue.map(NSNumber.init(value:)))
                        try self.restartDock()
                        let verified = try self.readEdgeDelaySynchronously()
                        guard self.valuesMatch(verified, expectedValue) else {
                            throw WorkspaceEdgeDelayError.verificationFailed
                        }
                        result = .success(verified)
                    } catch {
                        let primaryError = error
                        do {
                            try self.write(original)
                            try self.restartDock()
                            let rolledBack = try self.readEdgeDelaySynchronously()
                            guard self.valuesMatch(rolledBack, originalValue) else {
                                throw WorkspaceEdgeDelayError.verificationFailed
                            }
                            result = .failure(primaryError)
                        } catch {
                            result = .failure(
                                WorkspaceEdgeDelayError.rollbackFailed(
                                    primary: primaryError.localizedDescription,
                                    rollback: error.localizedDescription
                                )
                            )
                        }
                    }
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func expectedValue(
        for mutation: WorkspaceEdgeDelayMutation
    ) -> Double? {
        switch mutation {
        case .set(let value): return value
        case .remove: return nil
        }
    }

    private func valuesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs - rhs) <= 0.000_001
        default: return false
        }
    }

    private let dockDomain: CFString
    private let restartDock: () throws -> Void

    init(domain: String = "com.apple.dock", restartDock: @escaping () throws -> Void = ExperimentalWorkspaceSettings.restartSystemDock) {
        self.dockDomain = domain as CFString
        self.restartDock = restartDock
    }

    private let delayKey = "workspaces-edge-delay" as CFString

    private func synchronize() throws {
        guard CFPreferencesSynchronize(dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw WorkspaceEdgeDelayError.commandFailed("")
        }
    }

    private func write(_ value: CFPropertyList?) throws {
        CFPreferencesSetValue(delayKey, value, dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try synchronize()
    }

    private func readEdgeDelaySynchronously() throws -> Double? {
        try delay(from: storedValue())
    }

    private func storedValue() throws -> CFPropertyList? {
        try synchronize()
        return CFPreferencesCopyValue(delayKey, dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func delay(from stored: CFPropertyList?) throws -> Double? {
        guard let value = stored else { return nil }
        // Older defaults writes may have stored a numeric string.
        let parsed: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            parsed = number.doubleValue
        } else {
            parsed = (value as? String).flatMap(Double.init)
        }
        guard let parsed, parsed.isFinite, parsed >= 0 else {
            throw WorkspaceEdgeDelayError.invalidStoredValue
        }
        return parsed
    }

    private static func restartSystemDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 3) == .success else {
            if process.isRunning { process.terminate() }
            throw WorkspaceEdgeDelayError.commandFailed("")
        }
        guard process.terminationStatus == 0 else { throw WorkspaceEdgeDelayError.commandFailed("") }
    }
}
