import AppKit
import ApplicationServices

private func activeWindowObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                          _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<ActiveWindowObserver>.fromOpaque(context).takeUnretainedValue()
        .receive(observer: observer, element: element, notification: notification as String)
}

/// One AXObserver per relevant process, shared by focus and exact managed-window
/// destruction notifications. There is no timer or process-wide window discovery.
final class ActiveWindowObserver {
    struct ManagedTarget {
        let identity: String
        let pid: pid_t
        let element: AXUIElement
    }
    private struct Registration {
        let observer: AXObserver
        let application: AXUIElement
        var focusNotifications: [CFString] = []
        var targets: [String: ManagedTarget] = [:]
    }
    var onFocusedWindowChange: ((pid_t) -> Void)?
    var onDestroyed: ((ManagedTarget) -> Void)?
    private var registrations: [pid_t: Registration] = [:]
    private var focusedPID: pid_t?
    private var managedTargets: [ManagedTarget] = []

    func observeFrontmostApplication() { observe(NSWorkspace.shared.frontmostApplication) }
    func observe(_ application: NSRunningApplication?) {
        let nextPID: pid_t?
        if let application, !application.isTerminated, application.activationPolicy == .regular,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            nextPID = application.processIdentifier
        } else { nextPID = nil }
        if nextPID == focusedPID {
            if let nextPID, registrations[nextPID]?.focusNotifications.isEmpty == false { return }
            if nextPID == nil { return }
        }
        focusedPID = nextPID
        reconcile()
    }

    func synchronizeManagedWindows(_ targets: [ManagedTarget]) {
        managedTargets = targets
        reconcile()
    }

    private func reconcile() {
        precondition(Thread.isMainThread)
        guard AXIsProcessTrusted() else { removeRegistrations(); return }
        let desired = Dictionary(grouping: managedTargets, by: \.pid)
        let pids = Set(registrations.keys).union(desired.keys).union(focusedPID.map { [$0] } ?? [])
        for pid in pids {
            let wanted = Dictionary((desired[pid] ?? []).map { ($0.identity, $0) },
                                    uniquingKeysWith: { first, _ in first })
            var registration: Registration
            if let existing = registrations[pid] { registration = existing }
            else {
                guard pid == focusedPID || !wanted.isEmpty else { continue }
                var observer: AXObserver?
                guard AXObserverCreate(pid, activeWindowObserverCallback, &observer) == .success,
                      let observer else { continue }
                registration = Registration(observer: observer, application: AXUIElementCreateApplication(pid))
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            if pid != focusedPID {
                for name in registration.focusNotifications {
                    AXObserverRemoveNotification(registration.observer, registration.application, name)
                }
                registration.focusNotifications.removeAll()
            } else if registration.focusNotifications.isEmpty {
                for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                    let result = AXObserverAddNotification(registration.observer, registration.application,
                        name as CFString, Unmanaged.passUnretained(self).toOpaque())
                    if result == .success || result == .notificationAlreadyRegistered {
                        registration.focusNotifications.append(name as CFString)
                    }
                }
            }
            for (identity, target) in registration.targets {
                if let replacement = wanted[identity], CFEqual(replacement.element, target.element) { continue }
                AXObserverRemoveNotification(registration.observer, target.element,
                                             kAXUIElementDestroyedNotification as CFString)
                registration.targets.removeValue(forKey: identity)
            }
            for (identity, target) in wanted where registration.targets[identity] == nil {
                let result = AXObserverAddNotification(registration.observer, target.element,
                    kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
                if result == .success { registration.targets[identity] = target }
            }
            if registration.targets.isEmpty && registration.focusNotifications.isEmpty {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
                registrations.removeValue(forKey: pid)
            } else { registrations[pid] = registration }
        }
    }

    fileprivate func receive(observer: AXObserver, element: AXUIElement, notification: String) {
        guard let (pid, registration) = registrations.first(where: { CFEqual($0.value.observer, observer) }) else { return }
        if notification == kAXUIElementDestroyedNotification {
            // Copy before callbacks: retirement can synchronously reconcile subscriptions.
            let matches = registration.targets.values.filter { CFEqual($0.element, element) }
            for target in matches { onDestroyed?(target) }
        } else if pid == focusedPID,
                  notification == kAXFocusedWindowChangedNotification || notification == kAXMainWindowChangedNotification {
            onFocusedWindowChange?(pid)
        }
    }

    private func removeRegistrations() {
        for registration in registrations.values {
            for name in registration.focusNotifications {
                AXObserverRemoveNotification(registration.observer, registration.application, name)
            }
            for target in registration.targets.values {
                AXObserverRemoveNotification(registration.observer, target.element,
                                             kAXUIElementDestroyedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
        }
        registrations.removeAll()
    }
    func stop() {
        removeRegistrations()
        focusedPID = nil
        managedTargets.removeAll()
    }
    deinit { removeRegistrations() }
}
