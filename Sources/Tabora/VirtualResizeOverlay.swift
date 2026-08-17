import AppKit
import QuartzCore

struct VirtualResizeItem {
    let stableIdentity: String
    let originalFrame: CGRect
    let targetFrame: CGRect
    let appIcon: NSImage?
}

enum VirtualResizeLayering: Equatable {
    case aboveAllWindows
    case belowLiveWindows
}

enum VirtualResizeOrderingStrategy: Equatable {
    case aboveAllWindows
    case belowLiveWindow(CGWindowID)
    case belowLiveWindowFallback
}

enum VirtualResizePresentationPolicy {
    static func layering(
        liveWindowCount: Int,
        virtualWindowCount: Int
    ) -> VirtualResizeLayering {
        liveWindowCount > 0 && virtualWindowCount > 0
            ? .belowLiveWindows
            : .aboveAllWindows
    }

    static func shouldMaskLiveFrames(
        for layering: VirtualResizeLayering
    ) -> Bool {
        layering == .aboveAllWindows
    }

    /// Align both edges to the same backing-pixel grid. Adjacent window frames
    /// therefore share an exact edge instead of exposing a subpixel seam.
    static func pixelAlignedCoverageFrame(
        _ frame: CGRect,
        backingScaleFactor: CGFloat
    ) -> CGRect {
        guard !frame.isNull, !frame.isInfinite else { return frame }
        let scale = max(backingScaleFactor, 1)
        let align: (CGFloat) -> CGFloat = {
            ($0 * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        let minX = align(frame.minX)
        let minY = align(frame.minY)
        let maxX = align(frame.maxX)
        let maxY = align(frame.maxY)
        return CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
    }


    static func orderingStrategy(
        for layering: VirtualResizeLayering,
        liveWindowID: CGWindowID?
    ) -> VirtualResizeOrderingStrategy {
        switch (layering, liveWindowID) {
        case (.aboveAllWindows, _):
            return .aboveAllWindows
        case let (.belowLiveWindows, windowID?):
            return .belowLiveWindow(windowID)
        case (.belowLiveWindows, nil):
            return .belowLiveWindowFallback
        }
    }
}

final class VirtualResizeOverlay {
    private var canvas: VirtualResizeCanvas?

    func prepare(items: [VirtualResizeItem], screenFrame: CGRect) {
        guard !items.isEmpty else { return }
        let canvas = canvas(for: screenFrame)
        canvas.prepare(items: items, screenFrame: screenFrame)
    }

    /// Returns true only when the caller must use the bounded AXRaise
    /// fallback because no live Window Server identifier was available.
    @discardableResult
    func update(
        items: [VirtualResizeItem],
        liveFrames: [CGRect],
        liveWindowID: CGWindowID?,
        screenFrame: CGRect,
        layering: VirtualResizeLayering
    ) -> Bool {
        guard !items.isEmpty else {
            canvas?.hideContent()
            return false
        }
        let canvas = canvas(for: screenFrame)
        return canvas.update(
            items: items,
            liveFrames: liveFrames,
            liveWindowID: liveWindowID,
            screenFrame: screenFrame,
            layering: layering
        )
    }

    func hideAll() {
        canvas?.hide()
        canvas = nil
    }

    private func canvas(for screenFrame: CGRect) -> VirtualResizeCanvas {
        if let canvas {
            return canvas
        }
        let created = VirtualResizeCanvas(screenFrame: screenFrame)
        canvas = created
        return created
    }
}

private final class VirtualResizeCanvas {
    private let panel: NSPanel
    private let rootView: NSView
    private let concealContainer = NSView()
    private let targetContainer = NSView()
    private let iconContainer = NSView()
    private var followers: [String: VirtualFollowerViews] = [:]
    private var isShowing = false
    private var orderingStrategy: VirtualResizeOrderingStrategy?

    init(screenFrame: CGRect) {
        panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        rootView = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        rootView.wantsLayer = true
        panel.contentView = rootView

        for container in [concealContainer, targetContainer, iconContainer] {
            container.frame = rootView.bounds
            container.autoresizingMask = [.width, .height]
            container.wantsLayer = true
            rootView.addSubview(container)
        }
    }

    func prepare(items: [VirtualResizeItem], screenFrame: CGRect) {
        updateScreenFrame(screenFrame)
        for item in items.sorted(by: { $0.stableIdentity < $1.stableIdentity }) {
            _ = follower(for: item)
        }
        rootView.layoutSubtreeIfNeeded()
        rootView.displayIfNeeded()
    }

    /// Returns true only when relative Window Server ordering was unavailable.
    @discardableResult
    func update(
        items: [VirtualResizeItem],
        liveFrames: [CGRect],
        liveWindowID: CGWindowID?,
        screenFrame: CGRect,
        layering: VirtualResizeLayering
    ) -> Bool {
        updateScreenFrame(screenFrame)
        let strategy = VirtualResizePresentationPolicy.orderingStrategy(
            for: layering,
            liveWindowID: liveWindowID
        )
        let desiredLevel: NSWindow.Level
        switch strategy {
        case .aboveAllWindows:
            desiredLevel = .screenSaver
        case .belowLiveWindow(_), .belowLiveWindowFallback:
            desiredLevel = .normal
        }
        let levelChanged = panel.level != desiredLevel
        if levelChanged {
            panel.level = desiredLevel
        }
        let visibleIdentities = Set(items.map(\.stableIdentity))
        for (identity, follower) in followers where !visibleIdentities.contains(identity) {
            follower.setHidden(true)
        }

        // A live external window cannot be synchronized perfectly with a mask:
        // AX writes and Window Server observation complete asynchronously. In
        // mixed mode the panel is ordered between virtual followers and the
        // live window, so the live window itself provides the exact clipping.
        let localLiveFrames = VirtualResizePresentationPolicy
            .shouldMaskLiveFrames(for: layering)
            ? liveFrames.map { localFrame($0, in: screenFrame) }
            : []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in items.sorted(by: { $0.stableIdentity < $1.stableIdentity }) {
            follower(for: item).update(
                originalFrame: localFrame(item.originalFrame, in: screenFrame),
                targetFrame: localFrame(item.targetFrame, in: screenFrame),
                liveFrames: localLiveFrames,
                appIcon: item.appIcon,
                rootView: rootView,
                backingScaleFactor: panel.backingScaleFactor
            )
        }
        CATransaction.commit()

        let didReorder = !isShowing
            || levelChanged
            || orderingStrategy != strategy
        if didReorder {
            switch strategy {
            case .aboveAllWindows, .belowLiveWindowFallback:
                panel.orderFrontRegardless()
            case let .belowLiveWindow(windowID):
                // The overlay and the external live window share the normal
                // Window Server level. Ordering relative to the actual CG
                // window number establishes the required sandwich directly,
                // instead of racing an AppKit orderFront with a later AXRaise.
                panel.order(.below, relativeTo: Int(windowID))
            }
            isShowing = true
            orderingStrategy = strategy
        }
        return didReorder && strategy == .belowLiveWindowFallback
    }

    func hideContent() {
        followers.values.forEach { $0.setHidden(true) }
        if isShowing {
            panel.orderOut(nil)
            isShowing = false
        }
        orderingStrategy = nil
    }

    func hide() {
        hideContent()
        followers.values.forEach { $0.removeFromSuperview() }
        followers.removeAll()
        panel.orderOut(nil)
    }

    private func follower(for item: VirtualResizeItem) -> VirtualFollowerViews {
        if let existing = followers[item.stableIdentity] {
            existing.updateAppIcon(item.appIcon)
            return existing
        }
        let created = VirtualFollowerViews(
            appIcon: item.appIcon,
            concealContainer: concealContainer,
            targetContainer: targetContainer,
            iconContainer: iconContainer
        )
        followers[item.stableIdentity] = created
        return created
    }

    private func updateScreenFrame(_ screenFrame: CGRect) {
        guard panel.frame != screenFrame else { return }
        panel.setFrame(screenFrame, display: false)
        rootView.frame = CGRect(origin: .zero, size: screenFrame.size)
    }

    private func localFrame(_ frame: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - screenFrame.minX,
            y: frame.minY - screenFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }
}

private final class VirtualFollowerViews {
    private let concealView = NSVisualEffectView()
    private let targetView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let concealMask = CAShapeLayer()
    private let targetMask = CAShapeLayer()
    private let guideColor = NSColor(
        srgbRed: CGFloat(0x50) / 255,
        green: CGFloat(0x8D) / 255,
        blue: CGFloat(0xE5) / 255,
        alpha: 1
    )

    private var appIcon: NSImage?

    init(
        appIcon: NSImage?,
        concealContainer: NSView,
        targetContainer: NSView,
        iconContainer: NSView
    ) {
        self.appIcon = appIcon
        // Concealment is deliberately rectangular. Rounded concealment views
        // leave an uncovered cross where three or four old frames meet.
        configure(effectView: concealView, borderWidth: 0, cornerRadius: 0)
        configure(effectView: targetView, borderWidth: 2, cornerRadius: 12)
        concealView.isHidden = true
        targetView.isHidden = true
        iconView.isHidden = true
        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        concealContainer.addSubview(concealView)
        targetContainer.addSubview(targetView)
        iconContainer.addSubview(iconView)
    }

    func update(
        originalFrame: CGRect,
        targetFrame: CGRect,
        liveFrames: [CGRect],
        appIcon: NSImage?,
        rootView: NSView,
        backingScaleFactor: CGFloat
    ) {
        updateAppIcon(appIcon)
        let concealFrame = VirtualResizePresentationPolicy.pixelAlignedCoverageFrame(
            originalFrame,
            backingScaleFactor: backingScaleFactor
        )
        let alignedTargetFrame = VirtualResizePresentationPolicy
            .pixelAlignedCoverageFrame(
                targetFrame,
                backingScaleFactor: backingScaleFactor
            )
        let guideFrame = alignedTargetFrame.insetBy(dx: 6, dy: 6)

        concealView.isHidden = false
        targetView.isHidden = false
        concealView.frame = concealFrame
        targetView.frame = guideFrame
        applyLiveCutouts(
            to: concealView,
            mask: concealMask,
            liveFrames: liveFrames,
            rootView: rootView
        )
        applyLiveCutouts(
            to: targetView,
            mask: targetMask,
            liveFrames: liveFrames,
            rootView: rootView
        )
        layoutIcon(in: guideFrame)
    }

    func updateAppIcon(_ newIcon: NSImage?) {
        guard appIcon !== newIcon else { return }
        appIcon = newIcon
        iconView.image = newIcon
    }

    func removeFromSuperview() {
        concealView.layer?.removeAllAnimations()
        targetView.layer?.removeAllAnimations()
        iconView.layer?.removeAllAnimations()
        concealView.removeFromSuperview()
        targetView.removeFromSuperview()
        iconView.removeFromSuperview()
    }

    func setHidden(_ hidden: Bool) {
        concealView.isHidden = hidden
        targetView.isHidden = hidden
        iconView.isHidden = hidden || targetView.frame.width < 72 || targetView.frame.height < 72
    }

    private func configure(
        effectView: NSVisualEffectView,
        borderWidth: CGFloat,
        cornerRadius: CGFloat
    ) {
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = guideColor.withAlphaComponent(0.20).cgColor
        effectView.layer?.borderColor = guideColor.withAlphaComponent(0.92).cgColor
        effectView.layer?.borderWidth = borderWidth
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
    }

    private func applyLiveCutouts(
        to view: NSView,
        mask: CAShapeLayer,
        liveFrames: [CGRect],
        rootView: NSView
    ) {
        guard let layer = view.layer else { return }
        let overlaps = liveFrames.compactMap { frame -> CGRect? in
            let frameInView = view.convert(frame, from: rootView)
            let overlap = view.bounds.intersection(frameInView)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
                return nil
            }
            return overlap
        }
        guard !overlaps.isEmpty else {
            layer.mask = nil
            return
        }

        let path = CGMutablePath()
        path.addRect(view.bounds)
        overlaps.forEach { path.addRect($0) }
        mask.frame = view.bounds
        mask.path = path
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        layer.mask = mask
    }

    private func layoutIcon(in targetFrame: CGRect) {
        let side = min(max(min(targetFrame.width, targetFrame.height) * 0.22, 36), 80)
        iconView.isHidden = targetFrame.width < 72 || targetFrame.height < 72
        iconView.frame = CGRect(
            x: targetFrame.midX - side / 2,
            y: targetFrame.midY - side / 2,
            width: side,
            height: side
        )
    }
}
