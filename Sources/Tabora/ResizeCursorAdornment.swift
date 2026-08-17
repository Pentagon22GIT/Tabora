import AppKit

/// Visual resize feedback that never mutates or hides the system cursor.
/// The real cursor remains owned by the foreground application; this panel
/// draws click-through direction marks symmetrically around its hotspot.
final class ResizeCursorAdornment {
    // The distance preference can move the fixed-size marks outward. Keep the
    // click-through panel large enough for the maximum supported spacing.
    private static let panelSize = CGSize(width: 76, height: 76)

    private let panel: ResizeCursorAdornmentPanel
    private let contentView: ResizeCursorAdornmentView
    private weak var owner: NSView?

    init() {
        contentView = ResizeCursorAdornmentView(frame: CGRect(
            origin: .zero,
            size: Self.panelSize
        ))
        panel = ResizeCursorAdornmentPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 3
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.contentView = contentView
    }

    func show(
        owner: NSView,
        kind: ResizeCursorAdornmentKind,
        distance: CGFloat,
        at screenPoint: CGPoint
    ) {
        self.owner = owner
        contentView.kind = kind
        contentView.distance = distance
        panel.setFrameOrigin(origin(for: screenPoint))
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func move(
        owner: NSView,
        kind: ResizeCursorAdornmentKind,
        distance: CGFloat,
        to screenPoint: CGPoint
    ) {
        guard self.owner === owner else {
            show(owner: owner, kind: kind, distance: distance, at: screenPoint)
            return
        }
        contentView.kind = kind
        contentView.distance = distance
        panel.setFrameOrigin(origin(for: screenPoint))
    }

    func hide(owner: NSView) {
        guard self.owner === owner else { return }
        hideAll()
    }

    func hideAll() {
        owner = nil
        panel.orderOut(nil)
    }

    private func origin(for screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - Self.panelSize.width / 2,
            y: screenPoint.y - Self.panelSize.height / 2
        )
    }
}

private final class ResizeCursorAdornmentPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ResizeCursorAdornmentView: NSView {
    var kind: ResizeCursorAdornmentKind = .junction {
        didSet {
            if oldValue != kind {
                needsDisplay = true
            }
        }
    }
    var distance: CGFloat = CGFloat(AppSettings.defaultResizeCursorAdornmentDistance) {
        didSet {
            let normalized = ResizeCursorAdornmentMetrics.normalizedDistance(distance)
            if normalized != distance {
                distance = normalized
            } else if oldValue != distance {
                needsDisplay = true
            }
        }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = CGPoint(
            x: bounds.midX + (kind == .vertical
                ? ResizeCursorAdornmentMetrics.verticalPairHorizontalAlignment
                : 0),
            y: bounds.midY + (kind == .horizontal
                ? ResizeCursorAdornmentMetrics.horizontalPairVerticalAlignment
                : 0)
        )
        let paths = trianglePaths(around: center)

        // Match the macOS pointer language: compact black-filled triangles
        // with a thin white edge. The glyph size is intentionally fixed; only
        // its clearance from the real cursor is user-adjustable.
        NSColor.black.withAlphaComponent(0.94).setFill()
        NSColor.white.withAlphaComponent(0.96).setStroke()
        for path in paths {
            path.lineWidth = ResizeCursorAdornmentMetrics.outlineWidth
            path.lineJoinStyle = .round
            path.fill()
            path.stroke()
        }
    }

    private func trianglePaths(around center: CGPoint) -> [NSBezierPath] {
        let offset = ResizeCursorAdornmentMetrics.centerOffset(for: distance)
        switch kind {
        case .horizontal:
            return [
                triangle(center: CGPoint(x: center.x - offset, y: center.y),
                          direction: .left),
                triangle(center: CGPoint(x: center.x + offset, y: center.y),
                          direction: .right)
            ]
        case .vertical:
            return [
                triangle(center: CGPoint(x: center.x, y: center.y + offset),
                          direction: .up),
                triangle(center: CGPoint(x: center.x, y: center.y - offset),
                          direction: .down)
            ]
        case .junction:
            return [
                triangle(center: CGPoint(x: center.x - offset, y: center.y),
                          direction: .left),
                triangle(center: CGPoint(x: center.x + offset, y: center.y),
                          direction: .right),
                triangle(center: CGPoint(x: center.x, y: center.y + offset),
                          direction: .up),
                triangle(center: CGPoint(x: center.x, y: center.y - offset),
                          direction: .down)
            ]
        }
    }

    private enum TriangleDirection {
        case left
        case right
        case up
        case down
    }

    private func triangle(
        center: CGPoint,
        direction: TriangleDirection
    ) -> NSBezierPath {
        let halfDepth = ResizeCursorAdornmentMetrics.triangleDepth / 2
        let halfBase = ResizeCursorAdornmentMetrics.triangleBase / 2
        let vertices: [CGPoint]
        switch direction {
        case .left:
            vertices = [
                CGPoint(x: center.x - halfDepth, y: center.y),
                CGPoint(x: center.x + halfDepth, y: center.y + halfBase),
                CGPoint(x: center.x + halfDepth, y: center.y - halfBase)
            ]
        case .right:
            vertices = [
                CGPoint(x: center.x + halfDepth, y: center.y),
                CGPoint(x: center.x - halfDepth, y: center.y - halfBase),
                CGPoint(x: center.x - halfDepth, y: center.y + halfBase)
            ]
        case .up:
            vertices = [
                CGPoint(x: center.x, y: center.y + halfDepth),
                CGPoint(x: center.x - halfBase, y: center.y - halfDepth),
                CGPoint(x: center.x + halfBase, y: center.y - halfDepth)
            ]
        case .down:
            vertices = [
                CGPoint(x: center.x, y: center.y - halfDepth),
                CGPoint(x: center.x + halfBase, y: center.y + halfDepth),
                CGPoint(x: center.x - halfBase, y: center.y + halfDepth)
            ]
        }
        let path = roundedTriangle(
            vertices,
            insets: [
                ResizeCursorAdornmentMetrics.triangleTipCornerInset,
                ResizeCursorAdornmentMetrics.triangleBaseCornerInset,
                ResizeCursorAdornmentMetrics.triangleBaseCornerInset
            ]
        )
        path.lineJoinStyle = .round
        return path
    }

    private func roundedTriangle(
        _ vertices: [CGPoint],
        insets: [CGFloat]
    ) -> NSBezierPath {
        precondition(vertices.count == 3)
        precondition(insets.count == vertices.count)
        let path = NSBezierPath()
        for index in vertices.indices {
            let previous = vertices[(index + vertices.count - 1) % vertices.count]
            let vertex = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            let entry = point(
                from: vertex,
                toward: previous,
                distance: insets[index]
            )
            let exit = point(
                from: vertex,
                toward: next,
                distance: insets[index]
            )
            if index == vertices.startIndex {
                path.move(to: entry)
            } else {
                path.line(to: entry)
            }
            // Convert a quadratic curve with `vertex` as its control point to
            // the cubic form exposed by NSBezierPath.
            let firstControl = CGPoint(
                x: entry.x + (vertex.x - entry.x) * 2 / 3,
                y: entry.y + (vertex.y - entry.y) * 2 / 3
            )
            let secondControl = CGPoint(
                x: exit.x + (vertex.x - exit.x) * 2 / 3,
                y: exit.y + (vertex.y - exit.y) * 2 / 3
            )
            path.curve(
                to: exit,
                controlPoint1: firstControl,
                controlPoint2: secondControl
            )
        }
        path.close()
        return path
    }

    private func point(
        from start: CGPoint,
        toward end: CGPoint,
        distance: CGFloat
    ) -> CGPoint {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = hypot(deltaX, deltaY)
        guard length > 0 else { return start }
        let ratio = min(distance / length, 0.45)
        return CGPoint(
            x: start.x + deltaX * ratio,
            y: start.y + deltaY * ratio
        )
    }
}
