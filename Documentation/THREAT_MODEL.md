# Threat Model

## Assets to protect

- User control over windows and workspace state
- Accessibility and Screen Capture permission boundaries
- Correct association between AX windows and Window Server surfaces
- Group membership and shared-resize authorization
- Release identity and Official signing trust
- Public repository integrity

## Trust boundaries

### macOS Accessibility / Window Server

Tabora consumes state from AX and Window Server that can be delayed, temporarily unavailable, incomplete, or changing during transitions. Neither a temporary AX failure nor a partial discovery result is treated as proof that a window disappeared.

### Other GUI applications

Other applications may be slow, buggy, create large numbers of windows, rapidly create/destroy surfaces, expose duplicate titles, show modal sheets, or temporarily refuse move/resize operations. Tabora must fail closed without corrupting group state.

### User interaction

Pointer-down evidence, native-resize edges, Tabora-owned shared boundaries, Mission Control selection, and application switching can overlap in time. Authorization must bind to fresh physical identity and the correct interaction owner.

### Build / release supply chain

The public repository, GitHub Actions dependencies, release tags, hashes, code signing certificate, and Maintainer environment form a separate trust boundary from runtime window management.

## Threats and mitigations

### Malicious or broken GUI applications

Threats:
- misleading titles
- reused / ambiguous Window IDs
- AX stalls or `cannotComplete`
- temporary inability to move/resize
- unexpected modal surfaces

Mitigations:
- PID + CGWindowID identity where physical ownership matters
- AX unknown distinct from confirmed missing
- no structural destruction from optional discovery failure
- exact-target fail-closed behavior

### Large window count / resource exhaustion

Threats:
- broad discovery causing excessive work
- preview capture memory pressure
- irrelevant Window Server churn triggering recovery repeatedly

Mitigations:
- optional discovery may be budgeted while correctness-critical targets are not
- relevant-scene Recovery
- bounded, disposable preview cache
- per-group / per-descriptor recovery debt

### Identity ambiguity

Threats:
- same-title windows
- detached browser tabs/windows
- hidden or previously existing same-PID surfaces becoming visible

Mitigations:
- complete Window Server census required for detached adoption
- title/geometry are not sufficient identity by themselves
- physical evidence is resolved back to the exact AX target before committed mutation

### Cursor / input ownership confusion

Threat:
A transient observation failure could remove Tabora's shared-resize surface and expose the underlying macOS native resize edge, causing an unintended group departure.

Mitigation:
Short quarantine is limited to the last validated Tabora-owned region when the physical participants still exist. Confirmed occlusion or structural destruction releases the region.

### Mission Control stale evidence

Threat:
A transition observed for one group could authorize interaction with another group or a later stale proxy.

Mitigation:
Transition evidence is scoped to group identity / generation and expires or is consumed.

### Signing-key compromise

Threat:
An attacker with the Tabora Official private key could create a binary satisfying the configured designated requirement.

Mitigation:
- private key never stored in the repository or GitHub Actions
- certificate fingerprint is public configuration only
- compromise triggers a new Tabora certificate and explicit user trust reset guidance
- SnapFlow certificate is not reused for Tabora

## Out of scope

- Vulnerabilities in macOS itself
- Third-party forks after they diverge from this source
- Attackers that already fully control the user's account or machine

Out-of-scope conditions may still be investigated if they expose a practical weakness in Tabora's own trust boundaries.
