import AppKit
import XCTest
@testable import Tabora

final class AppConstraintTests: XCTestCase {
    private func identity(_ suffix: String = "app") -> AppConstraintIdentity {
        AppConstraintIdentity(
            kind: .nativeApplication,
            bundleIdentifier: "com.tabora.tests.\(suffix)",
            signingRequirement: "identifier com.tabora.tests.\(suffix)"
        )
    }

    private func registry(_ suffix: String = UUID().uuidString) -> AppConstraintRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaboraConstraintTests-\(suffix)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        return AppConstraintRegistry(store: ConstraintStore(
            fileURL: directory.appendingPathComponent("constraints.json")
        ))
    }

    private func rejection(
        identity: AppConstraintIdentity,
        bound: AppConstraintBound,
        accepted: CGFloat,
        epsilon: CGFloat = 1
    ) -> ConfirmedConstraintRejection {
        ConfirmedConstraintRejection(
            identity: identity,
            displayName: "Test App",
            bound: bound,
            acceptedValue: accepted,
            measurementEpsilon: epsilon,
            operationGeneration: 1
        )
    }

    func testConstraintMeasurementProgressIsBoundedAndMonotonic() {
        let samples = [
            ConstraintMeasurementProgressPolicy.boundFraction(
                index: 0, boundCount: 4, fractionWithinBound: 0
            ),
            ConstraintMeasurementProgressPolicy.boundFraction(
                index: 0, boundCount: 4, fractionWithinBound: 0.5
            ),
            ConstraintMeasurementProgressPolicy.boundFraction(
                index: 1, boundCount: 4, fractionWithinBound: 0
            ),
            ConstraintMeasurementProgressPolicy.boundFraction(
                index: 4, boundCount: 4, fractionWithinBound: 1
            )
        ]
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertGreaterThanOrEqual(samples.first ?? -1, 0)
        XCTAssertLessThanOrEqual(samples.last ?? 2, 0.94)
    }

    func testConstraintMeasurementProgressAggregatesMultipleApps() {
        XCTAssertEqual(
            ConstraintMeasurementProgressPolicy.aggregateFraction(
                itemIndex: 1,
                itemCount: 2,
                itemFraction: 0.5
            ),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ConstraintMeasurementProgressPolicy.aggregateFraction(
                itemIndex: 0,
                itemCount: 0,
                itemFraction: 0
            ),
            1,
            accuracy: 0.0001
        )
    }

    func testOperationLocalPermissionPromptDoesNotBypassUserChoice() {
        XCTAssertTrue(
            ConstraintPermissionPromptPolicy
                .shouldRequestFromOperationLocalEvidence(
                    hasAttributableBounds: true,
                    currentPermission: nil,
                    popupEnabled: true
                )
        )
        for permission in [RecordingPermission.allowed, .denied] {
            XCTAssertFalse(
                ConstraintPermissionPromptPolicy
                    .shouldRequestFromOperationLocalEvidence(
                        hasAttributableBounds: true,
                        currentPermission: permission,
                        popupEnabled: true
                    )
            )
        }
        XCTAssertFalse(
            ConstraintPermissionPromptPolicy
                .shouldRequestFromOperationLocalEvidence(
                    hasAttributableBounds: false,
                    currentPermission: nil,
                    popupEnabled: true
                )
        )
        XCTAssertFalse(
            ConstraintPermissionPromptPolicy
                .shouldRequestFromOperationLocalEvidence(
                    hasAttributableBounds: true,
                    currentPermission: nil,
                    popupEnabled: false
                )
        )
    }

    func testConstraintStoreRoundTripsPermissionKnownAndDormantState() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaboraConstraintRoundTrip-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("constraints.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = identity("roundtrip")
        let first = AppConstraintRegistry(store: ConstraintStore(fileURL: fileURL))
        _ = first.ensureRecord(identity: identity, displayName: "Round Trip")
        first.setPermission(.allowed, for: identity)
        XCTAssertTrue(first.setKnownValue(
            500,
            for: .minWidth,
            identity: identity,
            source: .explicitMeasurement
        ))
        first.updateDormant(true, identity: identity)

        let second = AppConstraintRegistry(store: ConstraintStore(fileURL: fileURL))
        let record = second.record(for: identity)
        XCTAssertEqual(record?.recordingPermission, .allowed)
        XCTAssertEqual(record?.knownValue(for: .minWidth) ?? -1, 500, accuracy: 0.001)
        XCTAssertEqual(record?.dormant, true)
    }

    func testObservedMatchingIdentityReactivatesDormantRecordWithoutCreatingOne() {
        let registry = registry()
        let identity = identity("observed-present")

        registry.markObservedPresent(
            identity: identity,
            displayName: "Unrecorded"
        )
        XCTAssertNil(registry.record(for: identity))

        _ = registry.ensureRecord(identity: identity, displayName: "Old Name")
        registry.updateDormant(true, identity: identity)
        XCTAssertEqual(registry.record(for: identity)?.dormant, true)

        registry.markObservedPresent(
            identity: identity,
            displayName: "Current Name"
        )
        XCTAssertEqual(registry.record(for: identity)?.dormant, false)
        XCTAssertEqual(registry.record(for: identity)?.displayName, "Current Name")
    }

    func testConstraintStoreIsolatesOneInvalidRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaboraConstraintCorrupt-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("constraints.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppConstraintRegistry(store: ConstraintStore(fileURL: fileURL))
        let good = identity("good")
        let bad = identity("bad")
        _ = first.ensureRecord(identity: good, displayName: "Good")
        _ = first.ensureRecord(identity: bad, displayName: "Bad")

        let data = try Data(contentsOf: fileURL)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let badIndex = try XCTUnwrap(records.firstIndex(where: { record in
            guard let identity = record["identity"] as? [String: Any] else { return false }
            return identity["bundleIdentifier"] as? String == bad.bundleIdentifier
        }))
        var invalidIdentity = try XCTUnwrap(records[badIndex]["identity"] as? [String: Any])
        invalidIdentity["bundleIdentifier"] = ""
        records[badIndex]["identity"] = invalidIdentity
        root["records"] = records
        try JSONSerialization.data(withJSONObject: root)
            .write(to: fileURL, options: [.atomic])

        let second = AppConstraintRegistry(store: ConstraintStore(fileURL: fileURL))
        XCTAssertNotNil(second.record(for: good))
        XCTAssertNil(second.record(for: bad))
    }

    func testPopupOffStoresPendingCandidateWithoutActivatingIt() {
        let registry = registry()
        let identity = identity()
        XCTAssertEqual(
            registry.observeConfirmedRejection(
                rejection(identity: identity, bound: .minWidth, accepted: 500),
                popupEnabled: false
            ),
            .pendingCandidate
        )
        guard case .candidate(let candidate) = registry.record(for: identity)?.state(for: .minWidth) else {
            return XCTFail("Expected a pending candidate")
        }
        XCTAssertEqual(candidate.value, 500, accuracy: 0.001)
        XCTAssertNil(registry.limits(for: identity).minWidth)
    }

    func testDeniedPermissionDoesNotPersistFutureRuntimeCandidate() {
        let registry = registry()
        let identity = identity()
        _ = registry.ensureRecord(identity: identity, displayName: "Test App")
        registry.setPermission(.denied, for: identity)

        XCTAssertEqual(
            registry.observeConfirmedRejection(
                rejection(identity: identity, bound: .minHeight, accepted: 375),
                popupEnabled: true
            ),
            .ignored
        )
        XCTAssertEqual(
            registry.record(for: identity)?.state(for: .minHeight),
            .unknown
        )
    }

    func testAllowedPermissionLearnsOnlyUnknownBound() {
        let registry = registry()
        let identity = identity()
        _ = registry.ensureRecord(identity: identity, displayName: "Test App")
        registry.setPermission(.allowed, for: identity)

        XCTAssertEqual(
            registry.observeConfirmedRejection(
                rejection(identity: identity, bound: .minWidth, accepted: 500),
                popupEnabled: true
            ),
            .learnedKnown
        )
        XCTAssertEqual(registry.limits(for: identity).minWidth ?? -1, 500, accuracy: 0.001)
    }

    func testAuthorizedExplicitMeasurementStoresOrthogonalBoundsTogether() {
        let registry = registry()
        let identity = identity("all-bounds-after-prompt")
        _ = registry.ensureRecord(identity: identity, displayName: "Test App")
        XCTAssertEqual(
            registry.observeConfirmedRejection(
                rejection(identity: identity, bound: .minWidth, accepted: 640),
                popupEnabled: true
            ),
            .requestPermission
        )
        registry.setPermission(.allowed, for: identity)

        let applied = registry.applyExplicitMeasurement(
            [
                .minWidth: 640,
                .minHeight: 480,
                .maxWidth: 1_200,
                .maxHeight: 900
            ],
            identity: identity,
            displayName: "Test App"
        )

        XCTAssertEqual(applied, Set(AppConstraintBound.allCases))
        let limits = registry.limits(for: identity)
        XCTAssertEqual(limits.minWidth ?? -1, 640, accuracy: 0.001)
        XCTAssertEqual(limits.minHeight ?? -1, 480, accuracy: 0.001)
        XCTAssertEqual(limits.maxWidth ?? -1, 1_200, accuracy: 0.001)
        XCTAssertEqual(limits.maxHeight ?? -1, 900, accuracy: 0.001)
    }

    func testUserEditRejectsContradictoryKnownRangeAtomically() {
        let registry = registry()
        let identity = identity()
        _ = registry.ensureRecord(identity: identity, displayName: "Test App")
        XCTAssertTrue(registry.applyKnownValues(
            [.minWidth: 500, .maxWidth: 900],
            identity: identity,
            source: .userEdited
        ))
        XCTAssertFalse(registry.applyKnownValues(
            [.minWidth: 950, .maxWidth: 800],
            identity: identity,
            source: .userEdited
        ))
        XCTAssertEqual(
            registry.record(for: identity)?.knownValue(for: .minWidth) ?? -1,
            500,
            accuracy: 0.001
        )
        XCTAssertEqual(
            registry.record(for: identity)?.knownValue(for: .maxWidth) ?? -1,
            900,
            accuracy: 0.001
        )
    }

    func testUserEditCanExplicitlyClearOneKnownBound() {
        let registry = registry()
        let identity = identity()
        _ = registry.ensureRecord(identity: identity, displayName: "Test App")
        XCTAssertTrue(registry.applyKnownValues(
            [.minWidth: 500, .maxWidth: 900],
            identity: identity,
            source: .userEdited
        ))
        XCTAssertTrue(registry.applyKnownValues(
            [:],
            clearing: [.maxWidth],
            identity: identity,
            source: .userEdited
        ))
        XCTAssertEqual(registry.limits(for: identity).minWidth ?? -1, 500, accuracy: 0.001)
        XCTAssertNil(registry.limits(for: identity).maxWidth)
    }

    func testPermissionAllowPromotesPendingConfirmedCandidate() {
        let registry = registry()
        let identity = identity()
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .minWidth, accepted: 800),
            popupEnabled: false
        )

        registry.setPermission(.allowed, for: identity)

        XCTAssertEqual(
            registry.limits(for: identity).minWidth ?? -1,
            800,
            accuracy: 0.001
        )
        if case .known(let known) = registry.record(for: identity)?.state(for: .minWidth) {
            XCTAssertEqual(known.source, .learnedRejection)
        } else {
            XCTFail("Permission must activate the already-confirmed candidate")
        }
    }

    func testPermissionAllowPromotesIndependentPendingDimensions() {
        let registry = registry()
        let identity = identity()
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .minWidth, accepted: 640),
            popupEnabled: false
        )
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .minHeight, accepted: 480),
            popupEnabled: false
        )

        registry.setPermission(.allowed, for: identity)

        XCTAssertEqual(registry.limits(for: identity).minWidth ?? -1, 640, accuracy: 0.001)
        XCTAssertEqual(registry.limits(for: identity).minHeight ?? -1, 480, accuracy: 0.001)
    }

    func testPermissionAllowDoesNotActivateConflictingCandidateRange() {
        let registry = registry()
        let identity = identity()
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .minWidth, accepted: 800),
            popupEnabled: false
        )
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .maxWidth, accepted: 700),
            popupEnabled: false
        )

        registry.setPermission(.allowed, for: identity)

        XCTAssertNil(registry.limits(for: identity).minWidth)
        XCTAssertNil(registry.limits(for: identity).maxWidth)
        XCTAssertEqual(registry.record(for: identity)?.candidateConflict, true)
        XCTAssertEqual(registry.record(for: identity)?.needsVerification, true)
    }

    func testDeniedPermissionClearsPendingCandidate() {
        let registry = registry()
        let identity = identity()
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .minWidth, accepted: 640),
            popupEnabled: false
        )

        registry.setPermission(.denied, for: identity)

        XCTAssertEqual(
            registry.record(for: identity)?.state(for: .minWidth),
            .unknown
        )
        XCTAssertNil(registry.limits(for: identity).minWidth)
    }

    func testAllowedLearningKeepsCrossBoundConflictInactive() {
        let registry = registry()
        let identity = identity()
        _ = registry.ensureRecord(identity: identity, displayName: "Test App")
        registry.setPermission(.allowed, for: identity)
        XCTAssertTrue(registry.setKnownValue(
            700,
            for: .maxWidth,
            identity: identity,
            source: .explicitMeasurement
        ))

        XCTAssertEqual(
            registry.observeConfirmedRejection(
                rejection(identity: identity, bound: .minWidth, accepted: 800),
                popupEnabled: true
            ),
            .conflict
        )
        let record = registry.record(for: identity)
        XCTAssertNil(record?.knownValue(for: .minWidth))
        XCTAssertEqual(record?.knownValue(for: .maxWidth) ?? -1, 700, accuracy: 0.001)
        XCTAssertTrue(record?.candidateConflict ?? false)
        XCTAssertTrue(record?.needsVerification ?? false)
        XCTAssertNil(registry.limits(for: identity).minWidth)
    }

    func testKnownContradictionKeepsPersistentKnownActiveUntilVerification() {
        let registry = registry()
        let identity = identity()
        _ = registry.ensureRecord(identity: identity, displayName: "Test App")
        registry.setKnownValue(
            500,
            for: .minWidth,
            identity: identity,
            source: .explicitMeasurement
        )

        XCTAssertEqual(
            registry.observeConfirmedRejection(
                rejection(identity: identity, bound: .minWidth, accepted: 530),
                popupEnabled: true
            ),
            .contradiction
        )
        XCTAssertEqual(
            registry.record(for: identity)?.knownValue(for: .minWidth) ?? -1,
            500,
            accuracy: 0.001
        )
        XCTAssertEqual(registry.limits(for: identity).minWidth ?? -1, 500, accuracy: 0.001)
        XCTAssertEqual(registry.record(for: identity)?.needsVerification, true)
    }

    func testCandidatePlateauAggregatesOnSafeSide() {
        let registry = registry()
        let identity = identity()
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .minWidth, accepted: 500, epsilon: 2),
            popupEnabled: false
        )
        _ = registry.observeConfirmedRejection(
            rejection(identity: identity, bound: .minWidth, accepted: 501, epsilon: 2),
            popupEnabled: false
        )
        guard case .candidate(let candidate) = registry.record(for: identity)?.state(for: .minWidth) else {
            return XCTFail("Expected candidate")
        }
        XCTAssertEqual(candidate.value, 501, accuracy: 0.001)
        XCTAssertEqual(candidate.observations, 2)
    }

    func testConstraintProbeRejectsUnknownAndOrthogonalAmbiguity() {
        let identity = identity()
        let requested = CGRect(x: 0, y: 0, width: 490, height: 400)
        let accepted = CGRect(x: 0, y: 0, width: 500, height: 400)
        let base = ConstraintProbeContext(
            identity: identity,
            displayName: "Test App",
            requestedFrame: requested,
            acceptedFrame: accepted,
            activeAxes: [.width],
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .unknown,
            screenLimitedAxes: [],
            systemLimitedAxes: [],
            peerLimitedAxes: [],
            measurementEpsilon: 1,
            operationGeneration: 1
        )
        XCTAssertTrue(ConstraintProbe.confirmedRejections(from: base).isEmpty)

        let ambiguous = ConstraintProbeContext(
            identity: identity,
            displayName: "Test App",
            requestedFrame: requested,
            acceptedFrame: CGRect(x: 0, y: 0, width: 500, height: 410),
            activeAxes: [.width],
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            screenLimitedAxes: [],
            systemLimitedAxes: [],
            peerLimitedAxes: [],
            measurementEpsilon: 1,
            operationGeneration: 1
        )
        XCTAssertTrue(ConstraintProbe.confirmedRejections(from: ambiguous).isEmpty)
    }

    func testConstraintProbeRequestsCalibrationForUnattributedTwoAxisRejection() {
        let analysis = ConstraintProbe.analyze(ConstraintProbeContext(
            identity: identity(),
            displayName: "Test App",
            requestedFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            acceptedFrame: CGRect(x: 0, y: 0, width: 520, height: 460),
            activeAxes: [.width, .height],
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            screenLimitedAxes: [],
            systemLimitedAxes: [],
            peerLimitedAxes: [],
            measurementEpsilon: 1,
            operationGeneration: 2
        ))
        XCTAssertTrue(analysis.confirmedRejections.isEmpty)
        XCTAssertTrue(analysis.requiresAxisIsolatedCalibration)
    }

    func testConstraintProbeDoesNotRequestCalibrationWhenTwoAxisMismatchIsExplained() {
        let analysis = ConstraintProbe.analyze(ConstraintProbeContext(
            identity: identity(),
            displayName: "Test App",
            requestedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            acceptedFrame: CGRect(x: 0, y: 0, width: 80, height: 80),
            activeAxes: [.width, .height],
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            screenLimitedAxes: [],
            systemLimitedAxes: [.width, .height],
            peerLimitedAxes: [],
            measurementEpsilon: 1,
            operationGeneration: 2
        ))
        XCTAssertTrue(analysis.confirmedRejections.isEmpty)
        XCTAssertFalse(analysis.requiresAxisIsolatedCalibration)
    }

    func testConstraintProbeConfirmsSettledAcceptedMinimumBoundary() {
        let identity = identity()
        let result = ConstraintProbe.confirmedRejections(from: ConstraintProbeContext(
            identity: identity,
            displayName: "Test App",
            requestedFrame: CGRect(x: 0, y: 0, width: 490, height: 400),
            acceptedFrame: CGRect(x: 0, y: 0, width: 500, height: 400),
            activeAxes: [.width],
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            screenLimitedAxes: [],
            systemLimitedAxes: [],
            peerLimitedAxes: [],
            measurementEpsilon: 1,
            operationGeneration: 4
        ))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.bound, .minWidth)
        XCTAssertEqual(result.first?.acceptedValue ?? -1, 500, accuracy: 0.001)
    }

    func testLegalRangeIntersectsMinAndMaxForThreeSplitTopology() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let participants = [
            SplitResizeParticipantGeometry(
                stableIdentity: "A",
                frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                side: .nearOrigin,
                minimumLength: 200,
                maximumLength: 700
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "B",
                frame: CGRect(x: 500, y: 400, width: 500, height: 400),
                side: .farOrigin,
                minimumLength: 300,
                maximumLength: 450
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "C",
                frame: CGRect(x: 500, y: 0, width: 500, height: 400),
                side: .farOrigin,
                minimumLength: 350,
                maximumLength: 400
            )
        ]
        let range = SplitLayoutGeometry.allowedBoundaryRange(
            axis: .horizontal,
            participants: participants,
            screenFrame: screen
        )
        XCTAssertEqual(range?.lowerBound ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(range?.upperBound ?? -1, 650, accuracy: 0.001)
    }

    func testLegalRangeRejectsInfeasibleIntersection() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let participants = [
            SplitResizeParticipantGeometry(
                stableIdentity: "left",
                frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                side: .nearOrigin,
                minimumLength: 700
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "right",
                frame: CGRect(x: 500, y: 0, width: 500, height: 800),
                side: .farOrigin,
                minimumLength: 400
            )
        ]
        XCTAssertNil(SplitLayoutGeometry.allowedBoundaryRange(
            axis: .horizontal,
            participants: participants,
            screenFrame: screen
        ))
    }

    func testLegalRangeRejectsContradictoryParticipantMinAndMax() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        XCTAssertNil(SplitLayoutGeometry.allowedBoundaryRange(
            axis: .horizontal,
            participants: [SplitResizeParticipantGeometry(
                stableIdentity: "left",
                frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                side: .nearOrigin,
                minimumLength: 500,
                maximumLength: 400
            )],
            screenFrame: screen
        ))
    }

    func testPassiveProbeMarksUsableScreenMaximumAsScreenLimited() {
        let requested = CGRect(x: 0, y: 0, width: 1_000, height: 400)
        let accepted = CGRect(x: 0, y: 0, width: 900, height: 400)
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let limited = SystemGeometryPolicy.screenLimitedAxes(
            requestedFrame: requested,
            acceptedFrame: accepted,
            activeAxes: [.width],
            screenFrame: screen,
            epsilon: 1
        )
        XCTAssertEqual(limited, Set([.width]))
        XCTAssertTrue(ConstraintProbe.confirmedRejections(from: ConstraintProbeContext(
            identity: identity(),
            displayName: "Test App",
            requestedFrame: requested,
            acceptedFrame: accepted,
            activeAxes: [.width],
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            screenLimitedAxes: limited,
            systemLimitedAxes: [],
            peerLimitedAxes: [],
            measurementEpsilon: 1,
            operationGeneration: 1
        )).isEmpty)
    }

    func testExplicitMeasurementDoesNotTreatScreenLimitAsMaximum() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let acceptedScreen = AXFrameMutationObservation(
            requestedFrame: screen,
            acceptedFrame: screen,
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            completedSuccessfully: true,
            settlementEvidence: .exactTarget
        )
        XCTAssertNil(ConstraintMeasurementEngine.confirmedValue(
            for: .maxWidth,
            observation: acceptedScreen,
            epsilon: 1,
            screenFrame: screen
        ))

        let appLimited = AXFrameMutationObservation(
            requestedFrame: screen,
            acceptedFrame: CGRect(x: 0, y: 0, width: 900, height: 800),
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            completedSuccessfully: false,
            settlementEvidence: .boundedAlternative
        )
        XCTAssertEqual(
            ConstraintMeasurementEngine.confirmedValue(
                for: .maxWidth,
                observation: appLimited,
                epsilon: 1,
                screenFrame: screen
            ) ?? -1,
            900,
            accuracy: 0.001
        )

        let provisionalOnly = AXFrameMutationObservation(
            requestedFrame: screen,
            acceptedFrame: CGRect(x: 0, y: 0, width: 900, height: 800),
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            completedSuccessfully: false,
            settlementEvidence: .operationLocalAlternative
        )
        XCTAssertNil(ConstraintMeasurementEngine.confirmedValue(
            for: .maxWidth,
            observation: provisionalOnly,
            epsilon: 1,
            screenFrame: screen
        ))
    }

    func testExplicitMinimumMeasurementDoesNotTreatSystemAmbiguityBandAsAppLimit() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let observation = AXFrameMutationObservation(
            requestedFrame: CGRect(x: 100, y: 100, width: 1, height: 400),
            acceptedFrame: CGRect(x: 100, y: 100, width: 120, height: 400),
            mutationWasSent: true,
            sizeMutationSucceeded: true,
            acceptedFrameIsSettled: true,
            liveness: .alive,
            completedSuccessfully: false,
            settlementEvidence: .boundedAlternative
        )
        XCTAssertNil(ConstraintMeasurementEngine.confirmedValue(
            for: .minWidth,
            observation: observation,
            epsilon: 1,
            screenFrame: screen
        ))
    }

    func testBoundaryControlMovesOutOfJunctionExclusion() {
        let placement = ResizeHandleBoundaryPlacementGeometry.controlPlacement(
            span: 0...100,
            excluding: [40...60],
            preferredMidpoint: 50,
            desiredLength: 20
        )
        XCTAssertEqual(placement?.center ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(placement?.length ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(
            ResizeHandleBoundaryPlacementGeometry.freeIntervals(
                span: 0...100,
                excluding: [40...60]
            ),
            [0...40, 60...100]
        )
    }
    func testOperationLocalConstraintEvidenceUsesSettledAcceptedMinimum() {
        let bounds = OperationLocalConstraintEvidencePolicy.settledBounds(
            requestedFrame: CGRect(x: 0, y: 0, width: 400, height: 500),
            acceptedFrame: CGRect(x: 0, y: 0, width: 520, height: 500),
            activeAxes: [.width],
            excludedAxes: [],
            epsilon: 1
        )
        XCTAssertEqual(bounds[.minWidth] ?? -1, 520, accuracy: 0.001)
        XCTAssertNil(bounds[.maxWidth])
        XCTAssertNil(bounds[.minHeight])
    }

    func testOperationLocalConstraintEvidenceDoesNotUseExcludedScreenAxis() {
        let bounds = OperationLocalConstraintEvidencePolicy.settledBounds(
            requestedFrame: CGRect(x: 0, y: 0, width: 400, height: 500),
            acceptedFrame: CGRect(x: 0, y: 0, width: 520, height: 500),
            activeAxes: [.width],
            excludedAxes: [.width],
            epsilon: 1
        )
        XCTAssertTrue(bounds.isEmpty)
    }

    func testInitialSnapFirstRoundMovesOnlyIncomingCandidate() {
        XCTAssertEqual(
            InitialSnapMutationOrderingPolicy.identitiesForRound(
                candidateIdentity: "incoming",
                plannedIdentities: ["left", "right", "incoming"],
                candidateMustSettleFirst: true
            ),
            ["incoming"]
        )
        XCTAssertEqual(
            InitialSnapMutationOrderingPolicy.identitiesForRound(
                candidateIdentity: "incoming",
                plannedIdentities: ["left", "right", "incoming"],
                candidateMustSettleFirst: false
            ),
            ["left", "right", "incoming"]
        )
    }

    func testInitialSnapSettlementStopsImpossibleExactTargetCorrection() {
        XCTAssertTrue(
            AXFrameSettlementPolicy.shouldReturnSettledConstraintResult(
                mode: .returnSettledConstraintResult,
                placementIsAcceptable: false,
                mutationWasSent: true,
                sizeMutationSucceeded: true,
                acceptedSizeIsStable: true,
                settledAfterFinalSizeRequest: true,
                targetProgressWasObserved: true,
                secondsWithoutTargetProgress: 0.10
            )
        )
        XCTAssertFalse(
            AXFrameSettlementPolicy.shouldReturnSettledConstraintResult(
                mode: .returnSettledConstraintResult,
                placementIsAcceptable: false,
                mutationWasSent: true,
                sizeMutationSucceeded: true,
                acceptedSizeIsStable: true,
                settledAfterFinalSizeRequest: true,
                targetProgressWasObserved: false,
                secondsWithoutTargetProgress: 1.0
            )
        )
        XCTAssertFalse(
            AXFrameSettlementPolicy.shouldReturnSettledConstraintResult(
                mode: .requireExactTarget,
                placementIsAcceptable: false,
                mutationWasSent: true,
                sizeMutationSucceeded: true,
                acceptedSizeIsStable: true,
                settledAfterFinalSizeRequest: true,
                targetProgressWasObserved: false,
                secondsWithoutTargetProgress: 1.0
            )
        )
        XCTAssertFalse(
            AXFrameSettlementPolicy.shouldReturnSettledConstraintResult(
                mode: .returnSettledConstraintResult,
                placementIsAcceptable: false,
                mutationWasSent: true,
                sizeMutationSucceeded: true,
                acceptedSizeIsStable: false,
                settledAfterFinalSizeRequest: true,
                targetProgressWasObserved: false,
                secondsWithoutTargetProgress: 1.0
            )
        )
    }

    func testInitialSnapKnownMinimumUsesExactTargetSettlement() {
        var limits = AppConstraintLimits.unknown
        limits.minHeight = 250
        let mode = InitialSnapConstraintSettlementPolicy.mode(
            currentFrame: CGRect(x: 0, y: 0, width: 500, height: 600),
            targetFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            limits: limits,
            epsilon: 1
        )
        guard case .requireExactTarget = mode else {
            return XCTFail("A known minimum must use exact-target settlement")
        }
    }

    func testInitialSnapUnknownMinimumMayReturnSettledConstraintEvidence() {
        let mode = InitialSnapConstraintSettlementPolicy.mode(
            currentFrame: CGRect(x: 0, y: 0, width: 500, height: 600),
            targetFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            limits: .unknown,
            epsilon: 1
        )
        guard case .returnSettledConstraintResult = mode else {
            return XCTFail("An unknown minimum may return settled constraint evidence")
        }
    }

    func testInitialSnapKnownMaximumUsesExactTargetSettlement() {
        var limits = AppConstraintLimits.unknown
        limits.maxWidth = 900
        let mode = InitialSnapConstraintSettlementPolicy.mode(
            currentFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            targetFrame: CGRect(x: 0, y: 0, width: 700, height: 500),
            limits: limits,
            epsilon: 1
        )
        guard case .requireExactTarget = mode else {
            return XCTFail("A known maximum must use exact-target settlement")
        }
    }


    func testOperationLocalSettledAlternativeCannotBecomePersistentConstraintEvidence() {
        XCTAssertFalse(
            AXFrameSettlementEvidence.operationLocalAlternative
                .authorizesPersistentConstraintLearning
        )
        XCTAssertTrue(
            AXFrameSettlementEvidence.boundedAlternative
                .authorizesPersistentConstraintLearning
        )
        XCTAssertFalse(
            AXFrameSettlementEvidence.unresolved
                .authorizesPersistentConstraintLearning
        )
        XCTAssertFalse(
            AXFrameSettlementEvidence.exactTarget
                .authorizesPersistentConstraintLearning
        )
    }


    func testOperationLocalConstraintEvidenceDoesNotGuessAmbiguousAxes() {
        let requested = CGRect(x: 0, y: 0, width: 500, height: 500)
        XCTAssertEqual(
            InitialSnapConstraintSettlementPolicy.attributableOperationLocalAxes(
                requestedFrame: requested,
                acceptedFrame: CGRect(x: 0, y: 0, width: 500, height: 600),
                candidateAxes: [.width, .height],
                epsilon: 1
            ),
            [.width, .height]
        )
        XCTAssertTrue(
            InitialSnapConstraintSettlementPolicy.attributableOperationLocalAxes(
                requestedFrame: requested,
                acceptedFrame: CGRect(x: 0, y: 0, width: 480, height: 600),
                candidateAxes: [.width, .height],
                epsilon: 1
            ).isEmpty
        )
        XCTAssertTrue(
            InitialSnapConstraintSettlementPolicy.attributableOperationLocalAxes(
                requestedFrame: requested,
                acceptedFrame: CGRect(x: 0, y: 0, width: 480, height: 600),
                candidateAxes: [.height],
                epsilon: 1
            ).isEmpty
        )
    }

    func testSharedResizeConstraintEvidenceUsesOnlyBoundariesThatActuallyMoved() {
        XCTAssertEqual(
            HandleResizeConstraintEvidencePolicy.activeAxis(
                boundaryAxis: .horizontal,
                originalCoordinate: 500,
                finalCoordinate: 550,
                participantOwnsBoundary: true
            ),
            .width
        )
        XCTAssertNil(
            HandleResizeConstraintEvidencePolicy.activeAxis(
                boundaryAxis: .vertical,
                originalCoordinate: 500,
                finalCoordinate: 500,
                participantOwnsBoundary: true
            )
        )
        XCTAssertNil(
            HandleResizeConstraintEvidencePolicy.activeAxis(
                boundaryAxis: .vertical,
                originalCoordinate: 500,
                finalCoordinate: 550,
                participantOwnsBoundary: false
            )
        )
    }

    func testInitialSnapOperationLocalEvidenceUsesOnlyUnknownDirectionalAxes() {
        var limits = AppConstraintLimits.unknown
        limits.minWidth = 300
        let axes = InitialSnapConstraintSettlementPolicy.operationLocalAxes(
            currentFrame: CGRect(x: 0, y: 0, width: 700, height: 700),
            targetFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            limits: limits,
            epsilon: 1
        )
        XCTAssertEqual(axes, [.height])
    }

}
