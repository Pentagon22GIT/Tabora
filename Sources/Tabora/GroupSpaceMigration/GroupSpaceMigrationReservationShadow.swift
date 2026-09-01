import AppKit
import CoreGraphics

struct GroupSpaceMigrationReservationShadowIdentity: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

struct GroupSpaceMigrationReservationShadowReservation: Equatable {
    let groupID: SnapGroupID
    let memberIdentities: Set<GroupSpaceMigrationReservationShadowIdentity>
    let groupLabel: String
    var queuePosition: Int?
    var queueTotal: Int?
}

struct GroupSpaceMigrationReservationShadowSurface: Equatable {
    let identity: GroupSpaceMigrationReservationShadowIdentity
    let displayID: CGDirectDisplayID
    let frame: CGRect
}

struct GroupSpaceMigrationReservationShadowItem: Equatable {
    let groupID: SnapGroupID
    let identity: GroupSpaceMigrationReservationShadowIdentity
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let groupLabel: String
    let queuePosition: Int?
    let queueTotal: Int?
}


struct GroupSpaceMigrationReservationShadowInteractionGate: Equatable {
    private(set) var pointerIsDown = false

    var presentationIsSuppressed: Bool { pointerIsDown }

    mutating func pointerBegan() {
        pointerIsDown = true
    }

    mutating func pointerEnded() {
        pointerIsDown = false
    }

    /// Geometry settlement is owned exclusively by the dedicated observer.
    /// The presenter keeps only a final, cheap button-state fail-safe so a
    /// missed asynchronous monitor callback can never leave a panel visible
    /// under an active pointer interaction.
    mutating func observe(buttonIsDown: Bool) -> Bool {
        if buttonIsDown {
            pointerBegan()
            return false
        }
        if pointerIsDown {
            pointerEnded()
        }
        return true
    }

    mutating func reset() {
        pointerIsDown = false
    }
}

enum GroupSpaceMigrationReservationShadowTypographyPolicy {
    static let statusMaximumPointSize: CGFloat = 26
    static let statusHeightScale: CGFloat = 0.17
}

enum GroupSpaceMigrationReservationShadowPolicy {
    /// Presentation fails closed for ambiguous identity. A physical surface
    /// claimed by two reservations, or reported twice by Window Server, is
    /// omitted instead of being assigned by application name or geometry.
    static func visibleItems(
        reservations: [GroupSpaceMigrationReservationShadowReservation],
        surfaces: [GroupSpaceMigrationReservationShadowSurface]
    ) -> [GroupSpaceMigrationReservationShadowItem] {
        var reservationByIdentity:
            [GroupSpaceMigrationReservationShadowIdentity:
                GroupSpaceMigrationReservationShadowReservation] = [:]
        var ambiguousReservationIdentities =
            Set<GroupSpaceMigrationReservationShadowIdentity>()

        for reservation in reservations {
            for identity in reservation.memberIdentities {
                if reservationByIdentity[identity] != nil {
                    ambiguousReservationIdentities.insert(identity)
                } else {
                    reservationByIdentity[identity] = reservation
                }
            }
        }
        for identity in ambiguousReservationIdentities {
            reservationByIdentity.removeValue(forKey: identity)
        }

        var surfaceByIdentity:
            [GroupSpaceMigrationReservationShadowIdentity:
                GroupSpaceMigrationReservationShadowSurface] = [:]
        var ambiguousSurfaceIdentities =
            Set<GroupSpaceMigrationReservationShadowIdentity>()
        for surface in surfaces where
            reservationByIdentity[surface.identity] != nil {
            if surfaceByIdentity[surface.identity] != nil {
                ambiguousSurfaceIdentities.insert(surface.identity)
            } else {
                surfaceByIdentity[surface.identity] = surface
            }
        }
        for identity in ambiguousSurfaceIdentities {
            surfaceByIdentity.removeValue(forKey: identity)
        }

        return surfaceByIdentity.compactMap { identity, surface in
            guard let reservation = reservationByIdentity[identity] else {
                return nil
            }
            return GroupSpaceMigrationReservationShadowItem(
                groupID: reservation.groupID,
                identity: identity,
                displayID: surface.displayID,
                frame: surface.frame,
                groupLabel: reservation.groupLabel,
                queuePosition: reservation.queuePosition,
                queueTotal: reservation.queueTotal
            )
        }.sorted {
            if $0.displayID != $1.displayID {
                return $0.displayID < $1.displayID
            }
            return $0.identity.windowID < $1.identity.windowID
        }
    }

    static func owningDisplayID(
        for frame: CGRect,
        displays: [(id: CGDirectDisplayID, frame: CGRect)]
    ) -> CGDirectDisplayID? {
        displays.compactMap { display
            -> (id: CGDirectDisplayID, area: CGFloat)? in
            let intersection = frame.intersection(display.frame)
            guard !intersection.isNull,
                  intersection.width > 1,
                  intersection.height > 1 else { return nil }
            return (
                display.id,
                intersection.width * intersection.height
            )
        }.max {
            if $0.area == $1.area { return $0.id > $1.id }
            return $0.area < $1.area
        }?.id
    }
}

/// Passive Mission Control presentation for exact captured physical members.
/// It consumes migration truth but never starts, delays, cancels or rolls back
/// transport. Failure to draw therefore leaves the existing move line intact.
final class GroupSpaceMigrationReservationShadowPresenter {
    private var reservationsByGroupID:
        [SnapGroupID: GroupSpaceMigrationReservationShadowReservation] = [:]
    private var panelsByDisplayID:
        [CGDirectDisplayID: GroupSpaceMigrationReservationShadowPanel] = [:]
    private var latestSurfaces:
        [GroupSpaceMigrationReservationShadowSurface] = []
    private var sceneIsPresent = false
    private var interactionGate =
        GroupSpaceMigrationReservationShadowInteractionGate()
    private var presentationGeneration: UInt64 = 0

    func reserve(
        capture: GroupSpaceMigrationCapture,
        groupLabel: String
    ) {
        let identities = Set(capture.members.map {
            GroupSpaceMigrationReservationShadowIdentity(
                pid: $0.pid,
                windowID: $0.windowID
            )
        })
        guard identities.count == capture.members.count,
              !identities.isEmpty else { return }
        reservationsByGroupID[capture.structuralSnapshot.groupID] =
            GroupSpaceMigrationReservationShadowReservation(
                groupID: capture.structuralSnapshot.groupID,
                memberIdentities: identities,
                groupLabel: groupLabel,
                queuePosition: nil,
                queueTotal: nil
            )
        renderFromCurrentSurfaces()
    }

    /// Retargeting replaces the transport capture. Keep the frozen display
    /// label and FIFO metadata, but follow only the newly accepted exact
    /// physical identities.
    func refreshCapture(_ capture: GroupSpaceMigrationCapture) {
        let groupID = capture.structuralSnapshot.groupID
        guard let existing = reservationsByGroupID[groupID] else { return }
        let identities = Set(capture.members.map {
            GroupSpaceMigrationReservationShadowIdentity(
                pid: $0.pid,
                windowID: $0.windowID
            )
        })
        guard identities.count == capture.members.count,
              !identities.isEmpty else {
            reservationsByGroupID.removeValue(forKey: groupID)
            renderFromCurrentSurfaces()
            return
        }
        reservationsByGroupID[groupID] =
            GroupSpaceMigrationReservationShadowReservation(
                groupID: groupID,
                memberIdentities: identities,
                groupLabel: existing.groupLabel,
                queuePosition: existing.queuePosition,
                queueTotal: existing.queueTotal
            )
        renderFromCurrentSurfaces()
    }

    func updateQueue(
        groupID: SnapGroupID,
        position: Int,
        total: Int
    ) {
        guard var reservation = reservationsByGroupID[groupID] else { return }
        reservation.queuePosition = max(position, 1)
        reservation.queueTotal = max(max(total, position), 1)
        reservationsByGroupID[groupID] = reservation
        renderFromCurrentSurfaces()
    }

    func cancelReservation(groupID: SnapGroupID) {
        reservationsByGroupID.removeValue(forKey: groupID)
        renderFromCurrentSurfaces()
    }

    func finish(groupID: SnapGroupID) {
        cancelReservation(groupID: groupID)
    }

    func missionControlDidBecomePresent() {
        guard !sceneIsPresent else { return }
        presentationGeneration &+= 1
        sceneIsPresent = true
        interactionGate.reset()
        latestSurfaces.removeAll()
        panelsByDisplayID.values.forEach { $0.forceHide() }
    }

    /// Reuses SnapController's existing mouse monitor. The presenter does not
    /// install a monitor of its own and never feeds this state into migration.
    func pointerInteractionDidBegin() {
        guard sceneIsPresent, !interactionGate.pointerIsDown else { return }
        interactionGate.pointerBegan()
        latestSurfaces.removeAll()
        panelsByDisplayID.values.forEach { $0.forceHide() }
    }

    func pointerInteractionDidEnd() {
        guard sceneIsPresent else { return }
        interactionGate.pointerEnded()
        latestSurfaces.removeAll()
        panelsByDisplayID.values.forEach { $0.forceHide() }
    }

    /// Hide immediately when Mission Control presentation is no longer proven.
    /// Physical move readiness remains owned by GroupSpaceMigrationLine and
    /// never waits for presentation cleanup.
    func missionControlDidBecomeAbsent() {
        guard sceneIsPresent || !latestSurfaces.isEmpty else {
            panelsByDisplayID.values.forEach { $0.forceHide() }
            return
        }
        sceneIsPresent = false
        interactionGate.reset()
        latestSurfaces.removeAll()
        panelsByDisplayID.values.forEach { $0.forceHide() }
    }

    /// Fail-closed visual suppression used by pointer/lifecycle hints and by an
    /// unresolved observer sample. Keep the scene/gate state so a later proven
    /// Mission Control transform can rebuild from a fresh snapshot.
    func suppressPresentationImmediately() {
        latestSurfaces.removeAll()
        panelsByDisplayID.values.forEach { $0.forceHide() }
    }

    /// Space changes invalidate only derived thumbnail geometry. They are not
    /// cancellation evidence for an accepted migration reservation.
    func invalidateDerivedGeometry() {
        latestSurfaces.removeAll()
        panelsByDisplayID.values.forEach { $0.forceHide() }
    }

    func displayTopologyDidChange() {
        presentationGeneration &+= 1
        sceneIsPresent = false
        interactionGate.reset()
        latestSurfaces.removeAll()
        panelsByDisplayID.values.forEach { $0.dispose() }
        panelsByDisplayID.removeAll()
    }

    func resetAll() {
        presentationGeneration &+= 1
        sceneIsPresent = false
        interactionGate.reset()
        latestSurfaces.removeAll()
        reservationsByGroupID.removeAll()
        panelsByDisplayID.values.forEach { $0.forceHide() }
    }

    /// Called only with a fresh Window Server snapshot supplied by the
    /// reservation-shadow observer or an existing controller observation.
    /// This presenter owns no timer and never performs migration work.
    func sync(
        windowServerSnapshot: [WindowOcclusionSnapshot],
        transformIsProven: Bool
    ) {
        guard sceneIsPresent else { return }
        let buttonIsDown = CGEventSource.buttonState(
            .combinedSessionState,
            button: .left
        )
        let wasSuppressed = interactionGate.presentationIsSuppressed
        guard transformIsProven,
              interactionGate.observe(buttonIsDown: buttonIsDown) else {
            latestSurfaces.removeAll()
            if !wasSuppressed {
                panelsByDisplayID.values.forEach { $0.forceHide() }
            }
            return
        }
        let displays = NSScreen.screens.compactMap { screen
            -> (id: CGDirectDisplayID, frame: CGRect)? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.frame)
        }
        guard !displays.isEmpty else {
            invalidateDerivedGeometry()
            return
        }

        latestSurfaces = windowServerSnapshot.compactMap {
            surface -> GroupSpaceMigrationReservationShadowSurface? in
            guard surface.layer == 0,
                  let displayID = GroupSpaceMigrationReservationShadowPolicy
                    .owningDisplayID(for: surface.frame, displays: displays)
            else { return nil }
            return GroupSpaceMigrationReservationShadowSurface(
                identity: GroupSpaceMigrationReservationShadowIdentity(
                    pid: surface.pid,
                    windowID: surface.windowID
                ),
                displayID: displayID,
                frame: surface.frame
            )
        }
        reconcilePanels(with: displays)
        renderFromCurrentSurfaces()
    }

    private func reconcilePanels(
        with displays: [(id: CGDirectDisplayID, frame: CGRect)]
    ) {
        let currentDisplayIDs = Set(displays.map(\.id))
        for displayID in Array(panelsByDisplayID.keys) where
            !currentDisplayIDs.contains(displayID) {
            panelsByDisplayID.removeValue(forKey: displayID)?.dispose()
        }
        for display in displays {
            panelsByDisplayID[display.id]?.updateDisplayFrame(display.frame)
        }
    }

    private func renderFromCurrentSurfaces() {
        guard sceneIsPresent,
              !interactionGate.presentationIsSuppressed else { return }
        let items = GroupSpaceMigrationReservationShadowPolicy.visibleItems(
            reservations: Array(reservationsByGroupID.values),
            surfaces: latestSurfaces
        )
        let itemsByDisplay = Dictionary(grouping: items, by: \.displayID)

        for (displayID, panel) in panelsByDisplayID where
            itemsByDisplay[displayID] == nil {
            panel.forceHide()
        }

        for (displayID, displayItems) in itemsByDisplay {
            guard let screen = NSScreen.screens.first(where: { screen in
                guard let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber else { return false }
                return CGDirectDisplayID(number.uint32Value) == displayID
            }) else { continue }
            let panel = panelsByDisplayID[displayID]
                ?? GroupSpaceMigrationReservationShadowPanel(
                    displayFrame: screen.frame
                )
            panelsByDisplayID[displayID] = panel
            panel.update(
                items: displayItems,
                displayFrame: screen.frame,
                generation: presentationGeneration
            )
            panel.showImmediately()
        }
    }
}

private final class GroupSpaceMigrationReservationShadowPanel: NSPanel {
    private let shadowView = GroupSpaceMigrationReservationShadowView()

    init(displayFrame: CGRect) {
        super.init(
            contentRect: displayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        contentView = shadowView
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(
        items: [GroupSpaceMigrationReservationShadowItem],
        displayFrame: CGRect,
        generation: UInt64
    ) {
        updateDisplayFrame(displayFrame)
        shadowView.items = items.map { item in
            GroupSpaceMigrationReservationShadowDrawItem(
                frame: CGRect(
                    x: item.frame.minX - displayFrame.minX,
                    y: item.frame.minY - displayFrame.minY,
                    width: item.frame.width,
                    height: item.frame.height
                ),
                groupLabel: item.groupLabel,
                queuePosition: item.queuePosition,
                queueTotal: item.queueTotal
            )
        }
        shadowView.presentationGeneration = generation
    }

    func updateDisplayFrame(_ displayFrame: CGRect) {
        if frame != displayFrame {
            setFrame(displayFrame, display: false)
        }
    }

    func showImmediately() {
        alphaValue = 1
        orderFrontRegardless()
        displayIfNeeded()
    }

    func forceHide() {
        orderOut(nil)
        alphaValue = 1
        shadowView.items = []
    }

    func dispose() {
        forceHide()
        close()
    }
}

private struct GroupSpaceMigrationReservationShadowDrawItem {
    let frame: CGRect
    let groupLabel: String
    let queuePosition: Int?
    let queueTotal: Int?
}

private final class GroupSpaceMigrationReservationShadowView: NSView {
    var items: [GroupSpaceMigrationReservationShadowDrawItem] = [] {
        didSet { needsDisplay = true }
    }
    var presentationGeneration: UInt64 = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        _ = presentationGeneration
        for item in items {
            let frame = item.frame.intersection(bounds).insetBy(dx: 1, dy: 1)
            guard frame.width > 8, frame.height > 8 else { continue }
            let radius = min(10, frame.width * 0.06, frame.height * 0.06)
            NSColor.black.withAlphaComponent(0.43).setFill()
            NSBezierPath(
                roundedRect: frame,
                xRadius: radius,
                yRadius: radius
            ).fill()
            drawLabels(for: item, in: frame)
        }
    }

    private func drawLabels(
        for item: GroupSpaceMigrationReservationShadowDrawItem,
        in frame: CGRect
    ) {
        let inset = max(4, min(16, frame.width * 0.06))
        let textFrame = frame.insetBy(dx: inset, dy: inset)
        guard textFrame.width > 12, textFrame.height > 12 else { return }

        let reservationStatus = L10n.text("migration.shadow.reserved")
        var lines: [(text: String, weight: NSFont.Weight, scale: CGFloat)] = [
            (
                reservationStatus,
                .bold,
                GroupSpaceMigrationReservationShadowTypographyPolicy
                    .statusHeightScale
            )
        ]
        if textFrame.height >= 38 {
            lines.append((item.groupLabel, .semibold, 0.15))
        }
        if textFrame.height >= 62,
           let position = item.queuePosition,
           let total = item.queueTotal,
           total > 1 {
            lines.append((
                L10n.format("migration.shadow.waiting", position, total),
                .medium,
                0.115
            ))
        }

        let spacing = max(2, min(7, textFrame.height * 0.025))
        let availableLineHeight = max(
            6,
            (textFrame.height - spacing * CGFloat(lines.count - 1))
                / CGFloat(lines.count)
        )
        let rendered = lines.map { line in
            let font = fittedFont(
                text: line.text,
                weight: line.weight,
                maximumPointSize: min(
                    line.text == reservationStatus
                        ? GroupSpaceMigrationReservationShadowTypographyPolicy
                            .statusMaximumPointSize
                        : 22,
                    textFrame.height * line.scale,
                    availableLineHeight * 0.82
                ),
                maximumWidth: textFrame.width,
                maximumHeight: availableLineHeight
            )
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: centeredParagraphStyle
            ]
            return (
                text: line.text,
                attributes: attributes,
                height: line.text.size(withAttributes: attributes).height
            )
        }
        let totalHeight = rendered.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(rendered.count - 1, 0))
        var y = textFrame.midY - totalHeight / 2
        for line in rendered {
            line.text.draw(
                in: CGRect(
                    x: textFrame.minX,
                    y: y,
                    width: textFrame.width,
                    height: line.height
                ),
                withAttributes: line.attributes
            )
            y += line.height + spacing
        }
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }

    private func fittedFont(
        text: String,
        weight: NSFont.Weight,
        maximumPointSize: CGFloat,
        maximumWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> NSFont {
        var pointSize = max(1, maximumPointSize)
        while pointSize > 5 {
            let font = NSFont.systemFont(ofSize: pointSize, weight: weight)
            let size = text.size(withAttributes: [.font: font])
            if size.width <= maximumWidth && size.height <= maximumHeight {
                return font
            }
            pointSize -= 1
        }
        return NSFont.systemFont(ofSize: max(1, pointSize), weight: weight)
    }
}
