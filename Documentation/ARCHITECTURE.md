# Architecture

This document describes the Tabora v1.0.0 architecture inherited from the SnapFlow Final Baseline. It is descriptive; it does not redefine behavior.

## Application entry and settings

- `AppMain.swift` owns the menu-bar application lifecycle, menu commands, global shortcut registration, update-link opening, and Accessibility settings shortcut.
- `AppSettings.swift` stores user settings in the current app's `UserDefaults.standard` domain and controls login-item registration through `ServiceManagement`.
- `SettingsWindowController.swift` presents settings without introducing a separate persistence layer.

## Window observation and identity

- `AXWindowService.swift` combines Accessibility observation with Window Server identities.
- `WindowSafetyPolicies.swift` contains safety-oriented state and authorization policies used to keep temporary observation failure distinct from confirmed disappearance.
- PID + CGWindowID are used where a physical Window Server surface must be identified; AX geometry remains the mutation / native-resize geometry domain.

## Placement and snap control

- `SnapController.swift` coordinates drag observation, snap selection, Assist, restore state, recovery, and high-level application state.
- `SnapZone.swift` and `SplitLayout.swift` model target zones and layout relationships.
- Placement logic applies to two-, three-, and four-window arrangements through shared structural rules rather than a three-window-only special case.

## Explicit groups and resize

- `SnapGroup.swift` models persistent group relationships and group-level state.
- `SnapController+ExplicitGroups.swift` reconciles group membership and structural changes.
- `SnapController+HandleResize.swift`, `ResizeHandleOverlay.swift`, and `ResizeHandleGeometry.swift` own shared-resize presentation and interaction.
- `SnapController+NativeResize.swift` distinguishes true native resize / departure from Tabora-owned shared resize.
- `LiveResizeScheduler.swift` coalesces live resize requests so stale targets do not accumulate.
- `VirtualResizeOverlay.swift` provides lightweight resize presentation.

## Foreground and Mission Control

- `SnapController+GroupForeground.swift` authorizes group foregrounding using Window Server ordering evidence and AX operation targets.
- `MissionControlGroupProxy.swift` provides Mission Control proxy behavior and scoped transition authorization. Proxy ordering is verified while hidden/non-interactive; transient ordering failure receives bounded revalidation and then becomes low-frequency Recovery debt rather than permanent candidate loss.
- Mission Control presentation suppression caused by temporary AX / display / geometry uncertainty is tracked per group. Fast retries are finite; unresolved debt is re-observed by the independent 1 Hz Recovery watchdog.
- Selection evidence is bounded and group-specific; stale transition evidence must not authorize a later unrelated action.

## Assist and previews

- `WindowPickerPanel.swift` presents candidate windows.
- `AXWindowService.previewCGImage` captures preview images only when preview functionality is enabled.
- Preview data is derived, bounded, disposable state and is not authoritative for window identity or placement correctness. Mission Control previews share the existing 32 MiB cache budget across all currently presentable members instead of using a fixed 720×480 cap.

## Recovery

Tabora retains an independent low-frequency Recovery watchdog. Recovery is a safety net for lost mouse-up, Assist cleanup, presentation recovery, observer re-arming, and transient AX / Window Server failures. Mouse event monitors receive a bounded readiness burst at startup/re-enable; after that, Recovery performs only a single re-arm attempt per 1 Hz tick. Healthy Recovery must not become a second unrestricted global discovery loop.

## Settings and OS integration

- `ExperimentalWorkspaceSettings.swift` optionally reads/writes the Dock `workspaces-edge-delay` preference and restarts Dock when the user explicitly applies or restores that setting.
- `ServiceManagement` is used for login-item registration.

## Build identities

- Official: `dev.pent.Tabora`
- Community: `dev.pent.Tabora.community`

The two identities intentionally use separate trust and TCC domains.
