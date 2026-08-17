# Security and Correctness Invariants

These invariants are inherited from the final SnapFlow stabilization and apply equally to 2 / 3 / 4 split layouts.

## Window state semantics

1. Structural existence is not the same as current interaction eligibility.
2. Temporary AX failure / timeout / `cannotComplete` is not confirmed disappearance.
3. Partial or failed discovery is not an authoritative empty result.
4. Existing group membership must not be destroyed solely because a member is temporarily unavailable for interaction.
5. A correctness-critical exact target must not depend on optional broad-discovery budgets.

## Identity and geometry

1. Window Server evidence may identify the physical surface and Z-order.
2. AX geometry is the baseline for AX native-resize comparison and committed AX mutations.
3. CG geometry must not be compared directly against AX current geometry as a native-resize baseline.
4. PID + CGWindowID must be considered together where ownership matters.
5. Incomplete detached-window census must fail closed rather than adopting an ambiguous surface.

## Group integrity

1. Unknown observation state alone must not retire a group.
2. Legitimate native resize, legitimate drag departure, and confirmed member closure must remain effective departure paths.
3. Passive geometry mismatch alone must not invent a user departure.
4. Degradation confirmation must require fresh evidence rather than repeated calls inside the same observation epoch.
5. One group's transient failure must not suspend unrelated groups' handles or consume unrelated recovery debt.
6. These rules apply to 2-, 3-, and 4-window groups; three-window layouts are a high-sensitivity regression case, not a separate behavioral class.

## Shared resize and cursor ownership

1. Tabora-owned shared interaction regions must retain input ownership while their ownership is freshly validated.
2. Temporary uncertainty may quarantine only the last validated Tabora-owned region; it must not expand onto ordinary native edges.
3. Confirmed destruction / occlusion must release Tabora input ownership.
4. Shared-resize authorization and native-resize departure must remain distinguishable.

## Recovery

1. The low-frequency Recovery watchdog must remain independent.
2. Recovery must observe relevant group surfaces and external surfaces that can affect validated Tabora interaction regions.
3. Distant unrelated window churn must not force broad recovery work.
4. Relevant external occluder arrival, removal, or ordering change must be detectable.
5. Observation results from one epoch must not be silently reused as fresh authorization after rollback or transition.
6. Fast observer/presentation retries must be bounded; unresolved liveness debt falls back to the independent low-frequency watchdog rather than creating a second high-frequency loop.

## Foreground / Mission Control

1. Z-order / occlusion comes from Window Server evidence; AX determines operation targets.
2. Indeterminate foreground state must fail closed for automatic authorization.
3. Mission Control transition evidence must be group-scoped, short-lived, and not reusable after expiry / rebuild / invalidation.
4. Ordering verification failure must not leave an interactive stale proxy visible.
5. A transient ordering or presentation observation failure must not destroy structural group membership or permanently retire an otherwise valid Mission Control candidate; recovery debt remains group-scoped.

## Preview and optional data

1. Preview images are derived and disposable.
2. Preview cache pressure or failure must not alter placement correctness.
3. Optional candidate discovery must not become structural authority.
4. Preview resolution must remain memory-bounded across 2 / 3 / 4 layouts and multiple groups; quality changes must not weaken identity or ordering authorization.

## Release trust

1. Tabora Official and Community identities are separate.
2. SnapFlow's signing identity must not be reused as Tabora Official.
3. Private keys, tokens, passwords, and local secrets must never enter the public repository.
4. Official build verification must fail if the Tabora certificate fingerprint is not explicitly configured.
