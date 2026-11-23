import AppKit

/// Tracks the particular Option press that completed a gesture, including the
/// interval before the asynchronous placement opens Assist.
final class GestureOptionPress {
    private var released = false

    func observe(optionDown: Bool) {
        if !optionDown { released = true }
    }

    func permitsAssist(optionDown: Bool) -> Bool {
        observe(optionDown: optionDown)
        return released && optionDown
    }
}

/// Own a precise scroll sequence only when Option was held at its beginning.
final class TrackpadSnapMonitor {
    var target: (() -> WindowServerSelectionSnapshot?)?
    var snap: ((SnapZone, WindowServerSelectionSnapshot, GestureOptionPress) -> Void)?
    private weak var gesturePress: GestureOptionPress?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var generation = 0
    private var selection: WindowServerSelectionSnapshot?
    private var suppressMomentum = false
    private var distance = CGPoint.zero
    private var cancelled = false

    func start() -> Bool {
        if tap != nil { return true }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
            place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.flagsChanged.rawValue),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<TrackpadSnapMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.generation &+= 1
                    monitor.selection = nil
                    monitor.suppressMomentum = false
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if type == .flagsChanged {
                    let flags = event.flags
                    monitor.gesturePress?.observe(optionDown: flags.contains(.maskAlternate))
                    if monitor.selection != nil,
                       flags.intersection([.maskAlternate, .maskControl, .maskShift, .maskCommand]) != .maskAlternate {
                        monitor.cancelled = true
                    }
                } else if type == .scrollWheel, let scroll = NSEvent(cgEvent: event),
                          monitor.consume(scroll) { return nil }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        generation &+= 1
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        selection = nil
        suppressMomentum = false
    }

    static func direction(_ point: CGPoint) -> SnapZone? {
        guard point.x.isFinite, point.y.isFinite, hypot(point.x, point.y) >= 32 else { return nil }
        let octant = Int((atan2(point.y, point.x) / (.pi / 4)).rounded())
        let zones: [SnapZone] = [.rightHalf, .topRight, .topHalf, .topLeft,
                                 .leftHalf, .bottomLeft, .bottomHalf, .bottomRight]
        return zones[(octant + 8) % 8]
    }

    private func consume(_ event: NSEvent) -> Bool {
        return consume(precise: event.hasPreciseScrollingDeltas, phase: event.phase,
            momentum: event.momentumPhase, modifiers: event.modifierFlags,
            delta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
            inverted: event.isDirectionInvertedFromDevice)
    }

    func consume(precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                 modifiers: NSEvent.ModifierFlags, delta: CGPoint, inverted: Bool) -> Bool {
        guard precise else { return false }
        if !momentum.isEmpty {
            let suppress = suppressMomentum
            if momentum.contains(.ended) { suppressMomentum = false }
            return suppress
        }
        let optionOnly = modifiers.intersection([.option, .control, .shift, .command]) == .option
        if phase.contains(.began) {
            suppressMomentum = false
            selection = optionOnly ? target?() : nil
            distance = .zero
            cancelled = false
        }
        guard !phase.isEmpty, let selection else { return false }
        cancelled = cancelled || !optionOnly || phase.contains(.cancelled)
        let sign: CGFloat = inverted ? 1 : -1
        distance.x += sign * delta.x
        distance.y -= sign * delta.y
        if phase.contains(.ended) || phase.contains(.cancelled) {
            self.selection = nil
            suppressMomentum = true
            if !cancelled, let zone = Self.direction(distance) {
                let press = GestureOptionPress()
                gesturePress = press
                let acceptedGeneration = generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == acceptedGeneration, self.target?() == selection else { return }
                    self.snap?(zone, selection, press)
                }
            }
        }
        return true
    }
}
