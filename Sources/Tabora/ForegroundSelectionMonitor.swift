import Foundation

/// Owns only the passive Window Server selection baseline.
///
/// The controller remains responsible for deciding whether a selection may
/// authorize any action. This object deliberately has no timer, group state,
/// AX mutation, or presentation access. Normal focus/click/Mission Control
/// paths stay event-driven; the existing 1 Hz Recovery watchdog may call
/// `sampleFallback()` only as a lost-event safety net.
final class ForegroundSelectionMonitor {
    typealias SnapshotProvider = () -> WindowServerSelectionSnapshot?
    typealias ChangeHandler = (WindowServerSelectionSnapshot) -> Void

    private let snapshotProvider: SnapshotProvider
    private let changeHandler: ChangeHandler
    private var pollState = WindowServerSelectionPollState()

    private(set) var isEnabled = false

    init(
        snapshotProvider: @escaping SnapshotProvider,
        changeHandler: @escaping ChangeHandler
    ) {
        self.snapshotProvider = snapshotProvider
        self.changeHandler = changeHandler
    }

    /// Returns true only when the lifecycle state actually changed.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled != isEnabled else { return false }
        isEnabled = enabled
        pollState.reset()
        return true
    }

    /// Establishes a fresh non-authorizing baseline after start/re-enable or
    /// after a controller-owned mutation invalidated earlier observations.
    func establishBaseline() {
        guard isEnabled else { return }
        pollState.reset()
        _ = pollState.observe(snapshotProvider())
    }

    /// Aligns the fallback with an event path that already observed an exact
    /// selection, preventing the watchdog from replaying the same event later.
    func synchronize(to snapshot: WindowServerSelectionSnapshot?) {
        guard isEnabled else { return }
        pollState.reset()
        _ = pollState.observe(snapshot)
    }

    /// Called by the existing Recovery watchdog. This method never schedules
    /// itself and therefore cannot create a second long-lived polling loop.
    func sampleFallback() {
        guard isEnabled else { return }
        guard let changed = pollState.observe(snapshotProvider()) else { return }
        changeHandler(changed)
    }

    func invalidateBaseline() {
        pollState.reset()
    }

    func stop() {
        isEnabled = false
        pollState.reset()
    }
}
