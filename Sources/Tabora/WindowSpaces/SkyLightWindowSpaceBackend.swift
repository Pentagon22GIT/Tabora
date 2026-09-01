import ApplicationServices
import CoreGraphics
import Foundation
import TaboraSkyLightBridge

final class SkyLightWindowSpaceBackend:
    WindowSpaceObservationPort,
    WindowSpaceTransportPort {
    private(set) var lastMoveDispatchDiagnosticDescription = L10n.text(
        "migration.diagnostic.not_dispatched"
    )
    private let windowIDResolver = RuntimeWindowIDResolver()

    var capabilities: SpaceRuntimeCapabilities {
        let bridge = TSLBridgeCopyCapabilities()
        var resolved: SpaceRuntimeCapabilities = []
        if bridge.contains(.resolveWindowID) {
            resolved.insert(.resolveWindowID)
        }
        if bridge.contains(.readWindowSpaces) {
            resolved.insert(.readWindowSpaces)
        }
        if bridge.contains(.readSpaceType) {
            resolved.insert(.readSpaceType)
        }
        if bridge.contains(.readSpaceDisplay) {
            resolved.insert(.readSpaceDisplay)
        }
        if bridge.contains(.dispatchBridgedMove) {
            resolved.insert(.dispatchBridgedMove)
        }
        return resolved
    }

    var moveRuntimeDiagnosticDescription: String {
        TSLBridgeCopyMoveRuntimeDiagnosticDescription() as String
    }

    init() {}

    func observe(subjects: [WindowSpaceSubject]) -> WindowSpaceObservation {
        var members: [String: WindowSpaceMemberObservation] = [:]
        for subject in subjects {
            let currentStableIdentity = ManagedWindow.stableIdentity(
                for: subject.element,
                pid: subject.pid
            )
            guard currentStableIdentity == subject.stableIdentity else {
                members[subject.stableIdentity] = WindowSpaceMemberObservation(
                    stableIdentity: subject.stableIdentity,
                    windowID: nil,
                    membership: .unknown
                )
                continue
            }

            let windowID: CGWindowID?
            if windowIDResolver.isAvailable {
                windowID = windowIDResolver.resolve(subject.element)
            } else {
                windowID = subject.cachedWindowID
            }
            let membership = windowID.map(membership(forWindowID:)) ?? .unknown
            members[subject.stableIdentity] = WindowSpaceMemberObservation(
                stableIdentity: subject.stableIdentity,
                windowID: windowID,
                membership: membership
            )
        }
        return WindowSpaceObservation(membersByStableIdentity: members)
    }

    func membership(forWindowID windowID: CGWindowID)
        -> WindowSpaceMembership {
        guard capabilities.contains(.readWindowSpaces),
              windowID != 0,
              let values = TSLBridgeCopySpacesForWindowID(windowID) else {
            return .unknown
        }
        let spaces = Set(values.compactMap {
            TaboraSpaceID($0.uint64Value)
        })
        return spaces.isEmpty ? .unknown : .known(spaces)
    }

    func isUserSpace(_ spaceID: TaboraSpaceID) -> Bool? {
        guard capabilities.contains(.readSpaceType) else { return nil }
        var spaceType = 0
        guard TSLBridgeCopySpaceType(spaceID.rawValue, &spaceType) else {
            return nil
        }
        return spaceType == 0
    }

    func managedDisplayIdentifier(for spaceID: TaboraSpaceID) -> String? {
        guard capabilities.contains(.readSpaceDisplay) else { return nil }
        return TSLBridgeCopyManagedDisplayForSpace(spaceID.rawValue)
    }

    func move(
        windowIDs: [CGWindowID],
        to destination: TaboraSpaceID
    ) -> SpaceTransportDispatchResult {
        guard capabilities.contains(.dispatchBridgedMove) else {
            lastMoveDispatchDiagnosticDescription = L10n.format(
                "migration.diagnostic.runtime_unavailable",
                moveRuntimeDiagnosticDescription
            )
            return .unavailable
        }
        let uniqueWindowIDs = Array(Set(windowIDs)).sorted()
        guard !uniqueWindowIDs.isEmpty,
              uniqueWindowIDs.allSatisfy({ $0 != 0 }) else {
            lastMoveDispatchDiagnosticDescription = L10n.text(
                "migration.diagnostic.invalid_window_ids"
            )
            return .rejected
        }
        var detail: NSString?
        let dispatched = TSLBridgeDispatchMoveWindowsDetailed(
            uniqueWindowIDs.map { NSNumber(value: $0) },
            destination.rawValue,
            &detail
        )
        lastMoveDispatchDiagnosticDescription = detail.map { $0 as String }
            ?? L10n.text("migration.diagnostic.bridge_unavailable")
        return dispatched ? .dispatched : .rejected
    }
}
