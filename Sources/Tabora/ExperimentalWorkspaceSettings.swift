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
                let originalValue = try self.readEdgeDelaySynchronously()
                let expectedValue = self.expectedValue(for: mutation)
                if self.valuesMatch(originalValue, expectedValue) {
                    result = .success(originalValue)
                } else {
                    do {
                        try self.apply(mutation)
                        try self.restartDock()
                        let verified = try self.readEdgeDelaySynchronously()
                        guard self.valuesMatch(verified, expectedValue) else {
                            throw WorkspaceEdgeDelayError.verificationFailed
                        }
                        result = .success(verified)
                    } catch {
                        let primaryError = error
                        do {
                            try self.apply(self.mutation(for: originalValue))
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

    private func mutation(for value: Double?) -> WorkspaceEdgeDelayMutation {
        value.map(WorkspaceEdgeDelayMutation.set) ?? .remove
    }

    private func valuesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs - rhs) <= 0.000_001
        default: return false
        }
    }

    private func apply(_ mutation: WorkspaceEdgeDelayMutation) throws {
        let arguments: [String]
        switch mutation {
        case .set(let value):
            arguments = [
                "write",
                "com.apple.dock",
                "workspaces-edge-delay",
                "-float",
                String(value)
            ]
        case .remove:
            arguments = [
                "delete",
                "com.apple.dock",
                "workspaces-edge-delay"
            ]
        }
        _ = try run(
            executable: "/usr/bin/defaults",
            arguments: arguments,
            acceptsFailure: mutation.isRemoval
        )
    }

    private func readEdgeDelaySynchronously() throws -> Double? {
        let result = try run(
            executable: "/usr/bin/defaults",
            arguments: [
                "read",
                "com.apple.dock",
                "workspaces-edge-delay"
            ],
            acceptsFailure: true
        )
        guard result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Double(value), number.isFinite, number >= 0 else {
            throw WorkspaceEdgeDelayError.invalidStoredValue
        }
        return number
    }

    private func restartDock() throws {
        _ = try run(
            executable: "/usr/bin/killall",
            arguments: ["Dock"]
        )
    }

    private func run(
        executable: String,
        arguments: [String],
        acceptsFailure: Bool = false
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            throw WorkspaceEdgeDelayError.commandFailed("")
        }
        // Drain the pipe while the child can still make progress. Waiting for
        // exit first can deadlock if a future command fills the pipe buffer.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if !acceptsFailure, process.terminationStatus != 0 {
            throw WorkspaceEdgeDelayError.commandFailed(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (process.terminationStatus, output)
    }
}

private extension WorkspaceEdgeDelayMutation {
    var isRemoval: Bool {
        if case .remove = self { return true }
        return false
    }
}
