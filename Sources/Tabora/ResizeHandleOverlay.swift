import AppKit
import QuartzCore

private struct ResizeHandleJunctionDescriptor {
    let id: String
    let first: ResizeHandleDescriptor
    let second: ResizeHandleDescriptor
    let frame: CGRect

    var interaction: ResizeHandleInteraction {
        .junction(id: id, horizontal: first, vertical: second)
    }
}

/// Owns the short post-drag cursor lease independently of the boundary views.
/// Those views are deliberately removed as soon as geometry changes; tying the
/// delayed restoration to them allowed AppKit's underlying native resize cursor
/// to win after the weakly captured view had already been released.
private final class ResizeHandleSystemCursorRestorer {
    private var generation = 0

    func restoreArrow(whilePointerRemainsNear frame: CGRect) {
        generation &+= 1
        let expectedGeneration = generation
        let restorationRegion = frame.insetBy(
            dx: -ResizeHandleSystemCursorPolicy.restorationContainmentPadding,
            dy: -ResizeHandleSystemCursorPolicy.restorationContainmentPadding
        )
        NSCursor.arrow.set()
        for delay in ResizeHandleSystemCursorPolicy.restorationDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.generation == expectedGeneration,
                      !CGEventSource.buttonState(
                          .combinedSessionState,
                          button: .left
                      ),
                      restorationRegion.contains(NSEvent.mouseLocation) else {
                    return
                }
                NSCursor.arrow.set()
            }
        }
    }

    func cancel() {
        generation &+= 1
    }
}

final class ResizeHandleOverlay {
    var onBegin: ((ResizeHandleInteraction, CGPoint) -> Void)?
    var onChange: ((ResizeHandleInteraction, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleInteraction, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleInteraction) -> Void)?

    private var panels: [String: ResizeHandlePanel] = [:]
    private var junctionPanels: [String: ResizeHandleJunctionPanel] = [:]
    private var activeHandleID: String?
    private var activeJunctionID: String?
    private var isInputSuspended = false
    private var isPresentationSuspended = false
    private var presentedSignatures: [ResizeHandlePresentationSignature] = []
    private var presentedQuarantinedIDs = Set<String>()
    private let cursorAdornment = ResizeCursorAdornment()
    private let systemCursorRestorer = ResizeHandleSystemCursorRestorer()
    private var activeArrowRestorationFrame: CGRect?

    var hasPresentedHandles: Bool {
        !panels.isEmpty || !junctionPanels.isEmpty
    }

    func update(
        _ descriptors: [ResizeHandleDescriptor],
        quarantinedIDs: Set<String> = []
    ) {
        let signatures = descriptors.map(ResizeHandlePresentationSignature.init)
            .sorted { $0.id < $1.id }
        let effectiveQuarantinedIDs = quarantinedIDs.intersection(
            Set(descriptors.map(\.id))
        )
        if signatures == presentedSignatures,
           effectiveQuarantinedIDs == presentedQuarantinedIDs {
            return
        }
        presentedSignatures = signatures
        presentedQuarantinedIDs = effectiveQuarantinedIDs

        let visibleIDs = Set(descriptors.map(\.id))
        let staleIDs = panels.keys.filter {
            !visibleIDs.contains($0) && $0 != activeHandleID
        }
        for id in staleIDs {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }

        for descriptor in descriptors {
            let panel = panels[descriptor.id] ?? makePanel(for: descriptor)
            panels[descriptor.id] = panel
            panel.update(descriptor: descriptor)
            panel.setQuarantined(
                effectiveQuarantinedIDs.contains(descriptor.id)
            )
            if activeHandleID == descriptor.id,
               ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
                   for: descriptor.presentationStyle
               ) {
                activeArrowRestorationFrame = descriptor.interactionFrame()
            }
            panel.setInputSuspended(isInputSuspended)
            if !isPresentationSuspended,
               (activeHandleID == nil && activeJunctionID == nil)
                    || activeHandleID == descriptor.id {
                panel.present()
            } else {
                panel.orderOut(nil)
            }
        }

        let junctions = makeJunctions(from: descriptors)
        let visibleJunctionIDs = Set(junctions.map(\.id))
        let staleJunctionIDs = junctionPanels.keys.filter {
            !visibleJunctionIDs.contains($0) && $0 != activeJunctionID
        }
        for id in staleJunctionIDs {
            junctionPanels.removeValue(forKey: id)?.orderOut(nil)
        }
        for junction in junctions {
            let panel = junctionPanels[junction.id] ?? makeJunctionPanel(for: junction)
            junctionPanels[junction.id] = panel
            panel.update(descriptor: junction)
            panel.setQuarantined(
                effectiveQuarantinedIDs.contains(junction.first.id)
                    || effectiveQuarantinedIDs.contains(junction.second.id)
            )
            if activeJunctionID == junction.id,
               ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
                   for: junction.first.presentationStyle
               ) {
                activeArrowRestorationFrame = junction.frame
            }
            panel.setInputSuspended(isInputSuspended)
            if !isPresentationSuspended,
               (activeHandleID == nil && activeJunctionID == nil)
                    || activeJunctionID == junction.id {
                panel.present()
            } else {
                panel.orderOut(nil)
            }
        }
    }

    func beginInteraction(with interaction: ResizeHandleInteraction) {
        systemCursorRestorer.cancel()
        let arrowDescriptors = interaction.descriptors.filter {
            ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
                for: $0.presentationStyle
            )
        }
        activeArrowRestorationFrame = arrowDescriptors
            .map { $0.interactionFrame() }
            .reduce(nil as CGRect?) { partial, frame in
                partial.map { $0.union(frame) } ?? frame
            }
        switch interaction {
        case .boundary:
            activeHandleID = interaction.id
            activeJunctionID = nil
        case .junction:
            activeHandleID = nil
            activeJunctionID = interaction.id
        }
        for (id, panel) in panels {
            panel.setInteractionActive(id == activeHandleID)
            if id != activeHandleID {
                panel.orderOut(nil)
            }
        }
        for (id, panel) in junctionPanels {
            panel.setInteractionActive(id == activeJunctionID)
            if id != activeJunctionID {
                panel.orderOut(nil)
            }
        }
    }

    func endInteraction() {
        cursorAdornment.hideAll()
        // The cached descriptors were produced while participant windows were
        // still moving. Keep every panel hidden until refreshResizeHandles()
        // has rebuilt the geometry and revalidated Window Server occlusion.
        presentedSignatures = []
        presentedQuarantinedIDs.removeAll()
        activeHandleID = nil
        activeJunctionID = nil
        panels.values.forEach {
            $0.setInteractionActive(false)
            $0.cancelInteraction()
            $0.orderOut(nil)
        }
        junctionPanels.values.forEach {
            $0.setInteractionActive(false)
            $0.cancelInteraction()
            $0.orderOut(nil)
        }
        restoreSystemArrowAfterInteractionIfNeeded()
    }

    func setInputSuspended(_ isSuspended: Bool) {
        guard isInputSuspended != isSuspended else { return }
        isInputSuspended = isSuspended
        panels.values.forEach { $0.setInputSuspended(isSuspended) }
        junctionPanels.values.forEach { $0.setInputSuspended(isSuspended) }
    }

    func setPresentationSuspended(_ isSuspended: Bool) {
        guard isPresentationSuspended != isSuspended else { return }
        isPresentationSuspended = isSuspended
        if isSuspended {
            cursorAdornment.hideAll()
            panels.values.forEach { $0.orderOut(nil) }
            junctionPanels.values.forEach { $0.orderOut(nil) }
            return
        }
        for (id, panel) in panels
            where (activeHandleID == nil && activeJunctionID == nil)
                || activeHandleID == id {
            panel.present()
        }
        for (id, panel) in junctionPanels
            where (activeHandleID == nil && activeJunctionID == nil)
                || activeJunctionID == id {
            panel.present()
        }
    }

    func hideAll() {
        cursorAdornment.hideAll()
        presentedSignatures = []
        presentedQuarantinedIDs.removeAll()
        activeHandleID = nil
        activeJunctionID = nil
        isInputSuspended = false
        isPresentationSuspended = false
        panels.values.forEach {
            $0.cancelInteraction()
            $0.orderOut(nil)
        }
        panels.removeAll()
        junctionPanels.values.forEach {
            $0.cancelInteraction()
            $0.orderOut(nil)
        }
        junctionPanels.removeAll()
        restoreSystemArrowAfterInteractionIfNeeded()
    }

    private func restoreSystemArrowAfterInteractionIfNeeded() {
        guard let frame = activeArrowRestorationFrame else { return }
        activeArrowRestorationFrame = nil
        systemCursorRestorer.restoreArrow(whilePointerRemainsNear: frame)
    }

    func owns(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panels.values.contains { $0 === window }
            || junctionPanels.values.contains { $0 === window }
    }

    private func makePanel(for descriptor: ResizeHandleDescriptor) -> ResizeHandlePanel {
        let panel = ResizeHandlePanel(
            descriptor: descriptor,
            cursorAdornment: cursorAdornment
        )
        panel.handleView.onBegin = { [weak self] descriptor, point in
            self?.onBegin?(.boundary(descriptor), point)
        }
        panel.handleView.onChange = { [weak self] descriptor, point in
            self?.onChange?(.boundary(descriptor), point)
        }
        panel.handleView.onEnd = { [weak self] descriptor, point in
            self?.onEnd?(.boundary(descriptor), point)
        }
        panel.handleView.onCancel = { [weak self] descriptor in
            self?.onCancel?(.boundary(descriptor))
        }
        return panel
    }

    private func makeJunctionPanel(
        for descriptor: ResizeHandleJunctionDescriptor
    ) -> ResizeHandleJunctionPanel {
        let panel = ResizeHandleJunctionPanel(
            descriptor: descriptor,
            cursorAdornment: cursorAdornment
        )
        panel.junctionView.onBegin = { [weak self] interaction, point in
            self?.onBegin?(interaction, point)
        }
        panel.junctionView.onChange = { [weak self] interaction, point in
            self?.onChange?(interaction, point)
        }
        panel.junctionView.onEnd = { [weak self] interaction, point in
            self?.onEnd?(interaction, point)
        }
        panel.junctionView.onCancel = { [weak self] interaction in
            self?.onCancel?(interaction)
        }
        return panel
    }

    private func makeJunctions(
        from descriptors: [ResizeHandleDescriptor]
    ) -> [ResizeHandleJunctionDescriptor] {
        // mac presentation promises that only the visible center control is
        // interactive. Do not create an invisible intersection panel for it.
        let junctionEligible = descriptors.filter {
            $0.presentationStyle != .mac
        }
        let xBoundaries = junctionEligible.filter { $0.axis == .horizontal }
        let yBoundaries = junctionEligible.filter { $0.axis == .vertical }
        let radius = ResizeHandleDescriptor.sharedBoundaryHitThickness / 2
        var result: [ResizeHandleJunctionDescriptor] = []

        for xBoundary in xBoundaries {
            for yBoundary in yBoundaries where
                yBoundary.displayID == xBoundary.displayID {
                let point = CGPoint(
                    x: xBoundary.coordinate,
                    y: yBoundary.coordinate
                )
                let ids = [xBoundary.id, yBoundary.id].sorted()
                let id = ids.joined(separator: "::")
                guard let frame = ResizeHandleJunctionTrackingGeometry.frame(
                    at: point,
                    horizontalSpan: xBoundary.span,
                    verticalSpan: yBoundary.span,
                    screenFrame: xBoundary.screenFrame,
                    radius: radius,
                    isActive: activeJunctionID == id
                ) else { continue }
                result.append(ResizeHandleJunctionDescriptor(
                    id: id,
                    first: xBoundary,
                    second: yBoundary,
                    frame: frame
                ))
            }
        }
        return result
    }

}

private final class ResizeHandlePanel: NSPanel {
    let handleView: ResizeHandleView

    init(
        descriptor: ResizeHandleDescriptor,
        cursorAdornment: ResizeCursorAdornment
    ) {
        handleView = ResizeHandleView(
            descriptor: descriptor,
            cursorAdornment: cursorAdornment
        )
        super.init(
            contentRect: Self.panelFrame(for: descriptor),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        acceptsMouseMovedEvents = descriptor.showsResizeCursorAdornment
        contentView = handleView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(descriptor: ResizeHandleDescriptor) {
        setFrame(Self.panelFrame(for: descriptor), display: false)
        acceptsMouseMovedEvents = descriptor.showsResizeCursorAdornment
        handleView.descriptor = descriptor
        displayIfNeeded()
        handleView.synchronizeHoverState()
    }

    func setInteractionActive(_ isActive: Bool) {
        level = isActive
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .floating
    }

    func setInputSuspended(_ isSuspended: Bool) {
        ignoresMouseEvents = isSuspended
        handleView.setInputSuspended(isSuspended)
    }

    func setQuarantined(_ isQuarantined: Bool) {
        handleView.setQuarantined(isQuarantined)
    }

    func cancelInteraction() {
        handleView.cancelInteraction()
    }

    override func orderOut(_ sender: Any?) {
        handleView.resetHoverState()
        super.orderOut(sender)
    }

    func present() {
        orderFrontRegardless()
        handleView.rearmHoverTracking()
    }

    private static func panelFrame(for descriptor: ResizeHandleDescriptor) -> CGRect {
        descriptor.interactionFrame()
    }
}

private final class ResizeHandleView: NSView {
    var descriptor: ResizeHandleDescriptor {
        didSet {
            if isDragging {
                isAwaitingFirstDragUpdate = false
            }
            updatePillFrame()
            updatePillAppearance(animated: false)
            synchronizeCursorAdornment()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onBegin: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onChange: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleDescriptor) -> Void)?

    private let guideLayer = CALayer()
    private let pillLayer = CALayer()
    private var hoverTrackingArea: NSTrackingArea?
    private var pointerIsInside = false
    private var isHovering = false
    private var hoverActivationGeneration = 0
    private var arrowRestorationGeneration = 0
    private var isDragging = false
    private var isAwaitingFirstDragUpdate = false
    private var isInputSuspended = false
    private var isQuarantined = false
    private let cursorAdornment: ResizeCursorAdornment

    init(
        descriptor: ResizeHandleDescriptor,
        cursorAdornment: ResizeCursorAdornment
    ) {
        self.descriptor = descriptor
        self.cursorAdornment = cursorAdornment
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        guideLayer.backgroundColor = NSColor.systemGray.cgColor
        guideLayer.opacity = 0
        layer?.addSublayer(guideLayer)
        pillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        pillLayer.borderColor = NSColor.black.withAlphaComponent(0.28).cgColor
        pillLayer.borderWidth = 0.5
        pillLayer.shadowColor = NSColor.black.cgColor
        pillLayer.shadowOpacity = 0.24
        pillLayer.shadowRadius = 3
        pillLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(pillLayer)
        updatePillAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updatePillFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let hoverArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .enabledDuringMouseDrag,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverArea)
        hoverTrackingArea = hoverArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
            for: descriptor.presentationStyle
        ) else { return }
        addCursorRect(bounds, cursor: .arrow)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        applySystemArrowIfNeeded()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        applySystemArrowIfNeeded()
        guard !isQuarantined else {
            isHovering = false
            hideCursorAdornment()
            return
        }
        scheduleHoverActivation(at: NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        pointerIsInside = false
        arrowRestorationGeneration &+= 1
        hoverActivationGeneration &+= 1
        isHovering = false
        updatePillAppearance()
        hideCursorAdornment()
    }

    override func mouseMoved(with event: NSEvent) {
        applySystemArrowIfNeeded()
        guard descriptor.showsResizeCursorAdornment,
              !isInputSuspended,
              !isQuarantined else {
            super.mouseMoved(with: event)
            return
        }
        moveCursorAdornment(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        arrowRestorationGeneration &+= 1
        applySystemArrowIfNeeded()
        if isQuarantined {
            pointerIsInside = true
            hoverActivationGeneration &+= 1
            isHovering = false
            hideCursorAdornment()
            updatePillAppearance()
            return
        }
        pointerIsInside = true
        hoverActivationGeneration &+= 1
        isHovering = true
        isDragging = true
        isAwaitingFirstDragUpdate = ResizeHandleDragPresentationPolicy
            .hidesOriginalGeometryUntilFirstUpdate(
                for: descriptor.presentationStyle
        )
        updatePillAppearance()
        showCursorAdornmentIfNeeded(at: NSEvent.mouseLocation)
        onBegin?(descriptor, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = NSEvent.mouseLocation
        onChange?(descriptor, point)
        moveCursorAdornment(to: point)
        applySystemArrowIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        isAwaitingFirstDragUpdate = false
        let localPoint = convert(event.locationInWindow, from: nil)
        if !bounds.contains(localPoint) {
            pointerIsInside = false
            isHovering = false
            hideCursorAdornment()
        } else {
            showCursorAdornmentIfNeeded(at: NSEvent.mouseLocation)
        }
        updatePillAppearance()
        restoreSystemArrowIfNeeded()
        onEnd?(descriptor, NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, isDragging else {
            super.keyDown(with: event)
            return
        }
        isDragging = false
        isAwaitingFirstDragUpdate = false
        updatePillAppearance()
        synchronizeCursorAdornment()
        restoreSystemArrowIfNeeded()
        onCancel?(descriptor)
    }

    func cancelInteraction() {
        guard isDragging else { return }
        isDragging = false
        isAwaitingFirstDragUpdate = false
        updatePillAppearance()
        restoreSystemArrowIfNeeded()
        if !isHovering {
            hideCursorAdornment()
        }
    }

    func setQuarantined(_ quarantined: Bool) {
        guard isQuarantined != quarantined else { return }
        isQuarantined = quarantined
        if quarantined {
            isDragging = false
            isAwaitingFirstDragUpdate = false
            hoverActivationGeneration &+= 1
            isHovering = false
            hideCursorAdornment()
        }
        updatePillAppearance(animated: false)
        window?.invalidateCursorRects(for: self)
    }

    func setInputSuspended(_ isSuspended: Bool) {
        guard isInputSuspended != isSuspended else { return }
        isInputSuspended = isSuspended
        if isSuspended {
            hoverActivationGeneration &+= 1
            hideCursorAdornment()
        }
        synchronizeCursorAdornment()
        updatePillAppearance(animated: false)
    }

    func resetHoverState() {
        pointerIsInside = false
        hoverActivationGeneration &+= 1
        isHovering = false
        hideCursorAdornment()
        updatePillAppearance(animated: false)
    }

    func synchronizeHoverState() {
        synchronizeHoverState(at: NSEvent.mouseLocation)
    }

    func rearmHoverTracking() {
        // Recreate hover tracking whenever a nonactivating panel returns so
        // its visual state does not survive an order-out/order-front cycle.
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        updateTrackingAreas()
        synchronizeHoverState()
    }

    func synchronizeHoverState(at screenPoint: CGPoint) {
        guard let window, window.isVisible, !isInputSuspended else {
            pointerIsInside = false
            hoverActivationGeneration &+= 1
            let wasHovering = isHovering
            isHovering = false
            hideCursorAdornment()
            if wasHovering {
                updatePillAppearance(animated: false)
            }
            return
        }
        if isDragging {
            pointerIsInside = true
            isHovering = true
            synchronizeCursorAdornment(at: screenPoint)
            return
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        let isInside = bounds.contains(localPoint)
        pointerIsInside = isInside
        if isInside {
            applySystemArrowIfNeeded()
            if !isHovering {
                scheduleHoverActivation(at: screenPoint)
            }
        } else {
            hoverActivationGeneration &+= 1
            let wasHovering = isHovering
            isHovering = false
            hideCursorAdornment()
            if wasHovering {
                updatePillAppearance(animated: false)
            }
        }
    }

    private func scheduleHoverActivation(at screenPoint: CGPoint) {
        guard !isInputSuspended, !isDragging, !isHovering else { return }
        hoverActivationGeneration &+= 1
        let generation = hoverActivationGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ResizeHandleHoverPolicy.activationDelay
        ) { [weak self] in
            guard let self,
                  self.hoverActivationGeneration == generation,
                  self.pointerIsInside,
                  !self.isInputSuspended else { return }
            self.isHovering = true
            self.updatePillAppearance()
            self.showCursorAdornmentIfNeeded(at: NSEvent.mouseLocation)
        }
    }

    private func synchronizeCursorAdornment(
        at screenPoint: CGPoint = NSEvent.mouseLocation
    ) {
        if descriptor.showsResizeCursorAdornment,
           isHovering,
           !isInputSuspended {
            showCursorAdornmentIfNeeded(at: screenPoint)
        } else {
            hideCursorAdornment()
        }
    }

    private func showCursorAdornmentIfNeeded(at screenPoint: CGPoint) {
        guard descriptor.showsResizeCursorAdornment,
              isDragging || isHovering,
              !isInputSuspended else { return }
        cursorAdornment.show(
            owner: self,
            kind: ResizeCursorAdornmentKind.kind(for: descriptor.axis),
            distance: descriptor.resizeCursorAdornmentDistance,
            at: screenPoint
        )
    }

    private func moveCursorAdornment(to screenPoint: CGPoint) {
        guard descriptor.showsResizeCursorAdornment,
              isDragging || isHovering,
              !isInputSuspended else { return }
        cursorAdornment.move(
            owner: self,
            kind: ResizeCursorAdornmentKind.kind(for: descriptor.axis),
            distance: descriptor.resizeCursorAdornmentDistance,
            to: screenPoint
        )
    }

    private func hideCursorAdornment() {
        cursorAdornment.hide(owner: self)
    }

    private func restoreSystemArrowIfNeeded() {
        guard ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
            for: descriptor.presentationStyle
        ) else { return }
        arrowRestorationGeneration &+= 1
        let generation = arrowRestorationGeneration
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
        for delay in ResizeHandleSystemCursorPolicy.restorationDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.arrowRestorationGeneration == generation,
                      ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
                          for: self.descriptor.presentationStyle
                      ),
                      self.descriptor.interactionFrame().insetBy(
                          dx: -ResizeHandleSystemCursorPolicy
                              .restorationContainmentPadding,
                          dy: -ResizeHandleSystemCursorPolicy
                              .restorationContainmentPadding
                      ).contains(NSEvent.mouseLocation) else { return }
                NSCursor.arrow.set()
            }
        }
    }

    private func applySystemArrowIfNeeded() {
        guard ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
            for: descriptor.presentationStyle
        ) else { return }
        NSCursor.arrow.set()
    }

    private func updatePillFrame(animated: Bool = false) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }
        let controlThickness: CGFloat = isHovering || isDragging ? 7 : 5
        let controlLength = min(
            isHovering || isDragging ? 42 : 36,
            descriptor.spanLength
        )
        let boundaryThickness: CGFloat
        switch descriptor.presentationStyle {
        case .mac:
            boundaryThickness = 0
        case .windows:
            boundaryThickness = isHovering || isDragging
                ? ResizeHandleDescriptor.windowsBoundaryActiveThickness
                : ResizeHandleDescriptor.windowsBoundaryIdleThickness
        case .combined:
            boundaryThickness = isHovering || isDragging
                ? ResizeHandleDescriptor.combinedBoundaryActiveThickness
                : ResizeHandleDescriptor.combinedBoundaryIdleThickness
        }
        switch descriptor.axis {
        case .horizontal:
            guideLayer.frame = CGRect(
                x: bounds.midX - boundaryThickness / 2,
                y: 0,
                width: boundaryThickness,
                height: bounds.height
            )
            pillLayer.frame = CGRect(
                x: bounds.midX - controlThickness / 2,
                y: bounds.midY - controlLength / 2,
                width: controlThickness,
                height: controlLength
            )
        case .vertical:
            guideLayer.frame = CGRect(
                x: 0,
                y: bounds.midY - boundaryThickness / 2,
                width: bounds.width,
                height: boundaryThickness
            )
            pillLayer.frame = CGRect(
                x: bounds.midX - controlLength / 2,
                y: bounds.midY - controlThickness / 2,
                width: controlLength,
                height: controlThickness
            )
        }
        guideLayer.cornerRadius = boundaryThickness / 2
        pillLayer.cornerRadius = controlThickness / 2
        CATransaction.commit()
    }

    private func updatePillAppearance(animated: Bool = true) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.10)
        } else {
            CATransaction.setDisableActions(true)
        }
        let style = descriptor.presentationStyle
        let visibleOpacity: Float
        if isAwaitingFirstDragUpdate {
            visibleOpacity = 0
        } else if isInputSuspended {
            visibleOpacity = 0.16
        } else if isDragging || isHovering {
            visibleOpacity = 1
        } else {
            visibleOpacity = 0.42
        }
        guideLayer.opacity = style.showsSharedBoundary ? visibleOpacity : 0
        guideLayer.backgroundColor = isDragging
            ? NSColor.controlAccentColor.cgColor
            : NSColor.systemGray.cgColor

        if isAwaitingFirstDragUpdate {
            pillLayer.opacity = 0
        } else if isInputSuspended {
            pillLayer.opacity = style.showsCenterControl ? 0.18 : 0
        } else if isDragging {
            pillLayer.opacity = style.showsCenterControl ? 1 : 0
        } else if isHovering {
            pillLayer.opacity = style.showsCenterControl ? 0.92 : 0
        } else {
            pillLayer.opacity = style.showsCenterControl ? 0.45 : 0
        }
        pillLayer.borderWidth = 0.5
        pillLayer.shadowOpacity = 0.24
        pillLayer.backgroundColor = isDragging
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(isHovering ? 1 : 0.88).cgColor
        CATransaction.commit()
        updatePillFrame(animated: animated)
    }
}

private final class ResizeHandleJunctionPanel: NSPanel {
    let junctionView: ResizeHandleJunctionView

    init(
        descriptor: ResizeHandleJunctionDescriptor,
        cursorAdornment: ResizeCursorAdornment
    ) {
        junctionView = ResizeHandleJunctionView(
            descriptor: descriptor,
            cursorAdornment: cursorAdornment
        )
        super.init(
            contentRect: descriptor.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        acceptsMouseMovedEvents = junctionView.showsResizeCursorAdornment
        contentView = junctionView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(descriptor: ResizeHandleJunctionDescriptor) {
        setFrame(descriptor.frame, display: false)
        junctionView.descriptor = descriptor
        acceptsMouseMovedEvents = junctionView.showsResizeCursorAdornment
        displayIfNeeded()
        junctionView.synchronizeHoverState()
    }

    func setInteractionActive(_ isActive: Bool) {
        level = isActive
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    func cancelInteraction() {
        junctionView.cancelInteraction()
    }

    func setInputSuspended(_ isSuspended: Bool) {
        ignoresMouseEvents = isSuspended
        junctionView.setInputSuspended(isSuspended)
    }

    func setQuarantined(_ isQuarantined: Bool) {
        junctionView.setQuarantined(isQuarantined)
    }

    override func orderOut(_ sender: Any?) {
        junctionView.resetHoverState()
        super.orderOut(sender)
    }

    func present() {
        orderFrontRegardless()
        junctionView.rearmHoverTracking()
    }
}

private final class ResizeHandleJunctionView: NSView {
    var descriptor: ResizeHandleJunctionDescriptor {
        didSet {
            updateAppearance()
            synchronizeCursorAdornment()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onBegin: ((ResizeHandleInteraction, CGPoint) -> Void)?
    var onChange: ((ResizeHandleInteraction, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleInteraction, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleInteraction) -> Void)?

    private var startPoint: CGPoint?
    private var isDragging = false
    private var hoverTrackingArea: NSTrackingArea?
    private var pointerIsInside = false
    private var isHovering = false
    private var hoverActivationGeneration = 0
    private var arrowRestorationGeneration = 0
    private var isInputSuspended = false
    private var isQuarantined = false
    private let cursorAdornment: ResizeCursorAdornment
    private let directionThreshold: CGFloat = 2

    init(
        descriptor: ResizeHandleJunctionDescriptor,
        cursorAdornment: ResizeCursorAdornment
    ) {
        self.descriptor = descriptor
        self.cursorAdornment = cursorAdornment
        super.init(frame: .zero)
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    var showsResizeCursorAdornment: Bool {
        descriptor.first.showsResizeCursorAdornment
            || descriptor.second.showsResizeCursorAdornment
    }

    private func updateAppearance() {
        guard let layer else { return }
        switch descriptor.first.presentationStyle {
        case .mac:
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.cornerRadius = 0
        case .windows:
            layer.backgroundColor = isDragging
                ? NSColor.controlAccentColor.cgColor
                : NSColor.systemGray.withAlphaComponent(
                    isHovering ? 0.82 : 0.42
                ).cgColor
            layer.borderWidth = 0
            layer.cornerRadius = 1
        case .combined:
            layer.backgroundColor = isDragging
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(
                    isHovering ? 0.96 : 0.55
                ).cgColor
            layer.borderColor = isDragging
                ? NSColor.controlAccentColor.cgColor
                : NSColor.systemGray.withAlphaComponent(
                    isHovering ? 0.82 : 0.42
                ).cgColor
            layer.borderWidth = 1
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }

    override func layout() {
        super.layout()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let hoverArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .enabledDuringMouseDrag,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverArea)
        hoverTrackingArea = hoverArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
            for: descriptor.first.presentationStyle
        ) else { return }
        addCursorRect(bounds, cursor: .arrow)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        applySystemArrowIfNeeded()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        applySystemArrowIfNeeded()
        guard !isQuarantined else {
            isHovering = false
            hideCursorAdornment()
            return
        }
        scheduleHoverActivation(at: NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        guard startPoint == nil else { return }
        pointerIsInside = false
        arrowRestorationGeneration &+= 1
        hoverActivationGeneration &+= 1
        isHovering = false
        hideCursorAdornment()
        updateAppearance()
    }

    override func mouseMoved(with event: NSEvent) {
        applySystemArrowIfNeeded()
        guard showsResizeCursorAdornment, !isInputSuspended,
              !isQuarantined else {
            super.mouseMoved(with: event)
            return
        }
        moveCursorAdornment(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        arrowRestorationGeneration &+= 1
        applySystemArrowIfNeeded()
        if isQuarantined {
            pointerIsInside = true
            hoverActivationGeneration &+= 1
            isHovering = false
            startPoint = nil
            isDragging = false
            hideCursorAdornment()
            updateAppearance()
            return
        }
        pointerIsInside = true
        hoverActivationGeneration &+= 1
        isHovering = true
        startPoint = NSEvent.mouseLocation
        isDragging = false
        updateAppearance()
        showCursorAdornmentIfNeeded(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = NSEvent.mouseLocation
        if !isDragging {
            let deltaX = point.x - startPoint.x
            let deltaY = point.y - startPoint.y
            guard hypot(deltaX, deltaY) >= directionThreshold else { return }
            isDragging = true
            updateAppearance()
            moveCursorAdornment(to: point)
            onBegin?(descriptor.interaction, point)
            applySystemArrowIfNeeded()
            return
        }
        onChange?(descriptor.interaction, point)
        moveCursorAdornment(to: point)
        applySystemArrowIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        defer { resetInteraction() }
        guard isDragging else { return }
        restoreSystemArrowIfNeeded()
        onEnd?(descriptor.interaction, NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, isDragging else {
            super.keyDown(with: event)
            return
        }
        restoreSystemArrowIfNeeded()
        onCancel?(descriptor.interaction)
        resetInteraction()
    }

    func cancelInteraction() {
        if isDragging {
            restoreSystemArrowIfNeeded()
        }
        resetInteraction()
    }

    func setQuarantined(_ quarantined: Bool) {
        guard isQuarantined != quarantined else { return }
        isQuarantined = quarantined
        if quarantined {
            resetInteraction()
            hoverActivationGeneration &+= 1
            isHovering = false
            hideCursorAdornment()
        }
        updateAppearance()
        window?.invalidateCursorRects(for: self)
    }

    func setInputSuspended(_ isSuspended: Bool) {
        guard isInputSuspended != isSuspended else { return }
        isInputSuspended = isSuspended
        if isSuspended {
            hoverActivationGeneration &+= 1
            hideCursorAdornment()
        }
        synchronizeCursorAdornment()
    }

    func resetHoverState() {
        pointerIsInside = false
        hoverActivationGeneration &+= 1
        isHovering = false
        hideCursorAdornment()
        updateAppearance()
    }

    func synchronizeHoverState() {
        synchronizeHoverState(at: NSEvent.mouseLocation)
    }

    func rearmHoverTracking() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        updateTrackingAreas()
        synchronizeHoverState()
    }

    func synchronizeHoverState(at screenPoint: CGPoint) {
        guard let window, window.isVisible, !isInputSuspended else {
            pointerIsInside = false
            hoverActivationGeneration &+= 1
            isHovering = false
            hideCursorAdornment()
            updateAppearance()
            return
        }
        if startPoint != nil {
            pointerIsInside = true
            isHovering = true
            synchronizeCursorAdornment(at: screenPoint)
            return
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        let isInside = bounds.contains(localPoint)
        pointerIsInside = isInside
        if isInside {
            applySystemArrowIfNeeded()
            if !isHovering {
                scheduleHoverActivation(at: screenPoint)
            }
        } else {
            hoverActivationGeneration &+= 1
            isHovering = false
            hideCursorAdornment()
            updateAppearance()
        }
    }

    private func scheduleHoverActivation(at screenPoint: CGPoint) {
        guard !isInputSuspended, startPoint == nil, !isHovering else { return }
        hoverActivationGeneration &+= 1
        let generation = hoverActivationGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ResizeHandleHoverPolicy.activationDelay
        ) { [weak self] in
            guard let self,
                  self.hoverActivationGeneration == generation,
                  self.pointerIsInside,
                  !self.isInputSuspended else { return }
            self.isHovering = true
            self.updateAppearance()
            self.showCursorAdornmentIfNeeded(at: NSEvent.mouseLocation)
        }
    }

    private func resetInteraction() {
        startPoint = nil
        isDragging = false
        updateAppearance()
        if !isHovering {
            hideCursorAdornment()
        } else {
            showCursorAdornmentIfNeeded(at: NSEvent.mouseLocation)
        }
    }

    private var currentAdornmentKind: ResizeCursorAdornmentKind { .junction }

    private func synchronizeCursorAdornment(
        at screenPoint: CGPoint = NSEvent.mouseLocation
    ) {
        if showsResizeCursorAdornment,
           isHovering,
           !isInputSuspended {
            showCursorAdornmentIfNeeded(at: screenPoint)
        } else {
            hideCursorAdornment()
        }
    }

    private func showCursorAdornmentIfNeeded(at screenPoint: CGPoint) {
        guard showsResizeCursorAdornment,
              startPoint != nil || isHovering,
              !isInputSuspended else { return }
        cursorAdornment.show(
            owner: self,
            kind: currentAdornmentKind,
            distance: descriptor.first.resizeCursorAdornmentDistance,
            at: screenPoint
        )
    }

    private func moveCursorAdornment(to screenPoint: CGPoint) {
        guard showsResizeCursorAdornment,
              startPoint != nil || isHovering,
              !isInputSuspended else { return }
        cursorAdornment.move(
            owner: self,
            kind: currentAdornmentKind,
            distance: descriptor.first.resizeCursorAdornmentDistance,
            to: screenPoint
        )
    }

    private func hideCursorAdornment() {
        cursorAdornment.hide(owner: self)
    }

    private func restoreSystemArrowIfNeeded() {
        guard ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
            for: descriptor.first.presentationStyle
        ) else { return }
        arrowRestorationGeneration &+= 1
        let generation = arrowRestorationGeneration
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
        for delay in ResizeHandleSystemCursorPolicy.restorationDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self,
                      self.arrowRestorationGeneration == generation,
                      ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
                          for: self.descriptor.first.presentationStyle
                      ),
                      self.descriptor.frame.insetBy(
                          dx: -ResizeHandleSystemCursorPolicy
                              .restorationContainmentPadding,
                          dy: -ResizeHandleSystemCursorPolicy
                              .restorationContainmentPadding
                      ).contains(NSEvent.mouseLocation) else { return }
                NSCursor.arrow.set()
            }
        }
    }

    private func applySystemArrowIfNeeded() {
        guard ResizeHandleSystemCursorPolicy.usesArrowCursorRect(
            for: descriptor.first.presentationStyle
        ) else { return }
        NSCursor.arrow.set()
    }
}
