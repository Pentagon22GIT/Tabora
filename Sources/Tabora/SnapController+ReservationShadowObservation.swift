import Foundation

extension SnapController {
    /// Top-level gate for the dedicated reservation-shadow observer. It is
    /// intentionally narrower than `groupSpaceMigrationCanMonitor`: transient
    /// migration interaction state must not tear down a passive presentation
    /// observer, while feature/controller/session shutdown must stop it.
    var groupSpaceMigrationReservationShadowObservationIsAllowed: Bool {
        groupSpaceMigrationFeatureIsEnabled
            && isEnabled
            && isControllerRunning
            && isUserSessionActive
            && settings.linkedResizeEnabled
            && !isApplicationInteractionSuppressed
    }

    /// Full geometry acquisition for the exact physical members frozen by the
    /// accepted reservation. The observer owns these desktop baselines; this
    /// path deliberately does not consult `lastGroupWindowServerEvidence...`,
    /// because ordinary Active Space recovery is allowed to clear that cache.
    func groupSpaceMigrationReservationShadowObservationSample(
        baselines: [GroupSpaceMigrationReservationShadowBaseline]
    ) -> GroupSpaceMigrationReservationShadowObservationSample {
        guard missionControlGroupPresentationIsEnabled,
              !baselines.isEmpty else {
            return GroupSpaceMigrationReservationShadowObservationSample(
                state: .unresolved,
                windowServerSnapshot: []
            )
        }
        let members = baselines.flatMap(\.members)
        let selections = Set(members.map { member in
            WindowServerSelectionSnapshot(
                pid: member.identity.pid,
                windowID: member.identity.windowID
            )
        })
        guard selections.count == members.count else {
            return GroupSpaceMigrationReservationShadowObservationSample(
                state: .unresolved,
                windowServerSnapshot: []
            )
        }

        let snapshot = windowService.windowOcclusionSnapshotOnScreen(
            forExactSelections: selections
        )
        let observations = baselines.map { baseline in
            GroupSpaceMigrationReservationShadowObservationPolicy.observe(
                baseline: baseline,
                snapshot: snapshot
            )
        }
        return GroupSpaceMigrationReservationShadowObservationSample(
            state: GroupSpaceMigrationReservationShadowObservationPolicy
                .aggregate(observations),
            windowServerSnapshot: snapshot
        )
    }

    /// Settled presentation does not need all member positions every 100 ms.
    /// Probe one deterministic exact member per reserved group instead. The
    /// baseline remains reservation-owned, so an ordinary Space-transition
    /// cache reset cannot strand this observer in `.unresolved` forever.
    func groupSpaceMigrationReservationShadowExitProbe(
        baselines: [GroupSpaceMigrationReservationShadowBaseline]
    ) -> GroupSpaceMigrationReservationShadowExitProbeSample {
        guard missionControlGroupPresentationIsEnabled,
              !baselines.isEmpty else {
            return GroupSpaceMigrationReservationShadowExitProbeSample(
                state: .unresolved,
                sentinelFrames: [:]
            )
        }
        let sentinels = baselines.compactMap(\.members.first)
        guard sentinels.count == baselines.count else {
            return GroupSpaceMigrationReservationShadowExitProbeSample(
                state: .unresolved,
                sentinelFrames: [:]
            )
        }
        let selections = Set(sentinels.map { sentinel in
            WindowServerSelectionSnapshot(
                pid: sentinel.identity.pid,
                windowID: sentinel.identity.windowID
            )
        })
        guard selections.count == sentinels.count else {
            return GroupSpaceMigrationReservationShadowExitProbeSample(
                state: .unresolved,
                sentinelFrames: [:]
            )
        }
        let snapshot = windowService.windowOcclusionSnapshotOnScreen(
            forExactSelections: selections
        )
        let currentFramesByIdentity = Dictionary(
            snapshot.map { surface in
                (
                    GroupSpaceMigrationReservationShadowIdentity(
                        pid: surface.pid,
                        windowID: surface.windowID
                    ),
                    surface.frame
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        let observations = sentinels.map { sentinel
            -> GroupSpaceMigrationReservationShadowObservationState in
            GroupSpaceMigrationReservationShadowProbePolicy.classify(
                expectedFrame: sentinel.expectedFrame,
                currentFrame: currentFramesByIdentity[sentinel.identity]
            )
        }
        return GroupSpaceMigrationReservationShadowExitProbeSample(
            state: GroupSpaceMigrationReservationShadowProbePolicy.aggregate(
                observations
            ),
            sentinelFrames: currentFramesByIdentity
        )
    }
}
