import AppKit
import QuartzCore

final class OverlayPanel {
    static let sideExpansionPulseDuration: TimeInterval = 0.72

    private let panel: NSPanel
    private let secondaryPanel: NSPanel
    private var isShowing = false
    private var displayedTargetFrame: CGRect?
    private var displayedCandidateFrames: [CGRect]?
    private static let zoneColor = NSColor(
        srgbRed: CGFloat(0x50) / 255,
        green: CGFloat(0x8D) / 255,
        blue: CGFloat(0xE5) / 255,
        alpha: 1
    )

    init() {
        panel = Self.makePanel()
        secondaryPanel = Self.makePanel()
        applyStyle(to: panel, isActive: true)
        applyStyle(to: secondaryPanel, isActive: false)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        panel.contentView = view
        return panel
    }

    func show(frame: CGRect, from anchor: CGPoint) {
        secondaryPanel.orderOut(nil)
        displayedCandidateFrames = nil
        applyStyle(to: panel, isActive: true)
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ]
        panel.alphaValue = 1
        let targetFrame = frame.insetBy(dx: 6, dy: 6)
        let wasShowing = isShowing
        if wasShowing,
           let displayedTargetFrame,
           Self.framesAreVisuallyEqual(displayedTargetFrame, targetFrame) {
            return
        }
        isShowing = true
        displayedTargetFrame = targetFrame

        if !wasShowing {
            let initialSize: CGFloat = 28
            let initialFrame = CGRect(
                x: anchor.x - initialSize / 2,
                y: anchor.y - initialSize / 2,
                width: initialSize,
                height: initialSize
            )
            panel.alphaValue = 0.35
            panel.setFrame(initialFrame, display: true)
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasShowing ? 0.10 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func showSideCandidates(
        frames: [CGRect],
        activeIndex: Int,
        from anchor: CGPoint
    ) {
        guard frames.count == 2, frames.indices.contains(activeIndex) else {
            hide()
            return
        }
        let targetFrames = ExpandedSideSelectionPolicy.guideFrames(
            candidateFrames: frames,
            outerInset: 6
        )
        guard targetFrames.count == 2 else {
            hide()
            return
        }
        let wasShowing = isShowing
        let wasShowingCandidates = displayedCandidateFrames != nil
        isShowing = true
        displayedTargetFrame = targetFrames[0]
        displayedCandidateFrames = targetFrames

        let panels = [panel, secondaryPanel]
        let lowerIndex = targetFrames[0].minY <= targetFrames[1].minY
            ? 0 : 1
        let initialSize: CGFloat = 28
        let initialFrame = CGRect(
            x: anchor.x - initialSize / 2,
            y: anchor.y - initialSize / 2,
            width: initialSize,
            height: initialSize
        )
        for index in panels.indices {
            let candidatePanel = panels[index]
            applyStyle(
                to: candidatePanel,
                isActive: index == activeIndex
            )
            candidatePanel.contentView?.layer?.cornerRadius = 12
            candidatePanel.contentView?.layer?.maskedCorners =
                index == lowerIndex
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            if !wasShowing || (!wasShowingCandidates && index == 1) {
                candidatePanel.alphaValue = 0.2
                candidatePanel.setFrame(initialFrame, display: true)
                candidatePanel.orderFrontRegardless()
            } else if !candidatePanel.isVisible {
                candidatePanel.orderFrontRegardless()
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasShowingCandidates ? 0.10 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            for index in panels.indices {
                panels[index].animator().alphaValue = index == activeIndex
                    ? 1
                    : 0.70
                panels[index].animator().setFrame(
                    targetFrames[index],
                    display: true
                )
            }
        }
    }

    func pulse(
        times: Int = 3,
        duration: TimeInterval = OverlayPanel.sideExpansionPulseDuration
    ) {
        guard isShowing,
              times > 0,
              let layer = panel.contentView?.layer else { return }

        var values: [NSNumber] = [1]
        for _ in 0..<times {
            values.append(0.48)
            values.append(1)
        }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        layer.removeAnimation(forKey: "snap-zone-pulse")
        layer.add(animation, forKey: "snap-zone-pulse")
    }

    func finishPulse() {
        panel.contentView?.layer?.removeAnimation(forKey: "snap-zone-pulse")
        secondaryPanel.contentView?.layer?.removeAnimation(
            forKey: "snap-zone-pulse"
        )
    }

    func hide() {
        isShowing = false
        displayedTargetFrame = nil
        displayedCandidateFrames = nil
        panel.contentView?.layer?.removeAllAnimations()
        secondaryPanel.contentView?.layer?.removeAllAnimations()
        panel.alphaValue = 1
        secondaryPanel.alphaValue = 1
        panel.orderOut(nil)
        secondaryPanel.orderOut(nil)
    }

    private func applyStyle(to panel: NSPanel, isActive: Bool) {
        panel.contentView?.layer?.backgroundColor = Self.zoneColor
            .withAlphaComponent(isActive ? 0.22 : 0.15)
            .cgColor
        panel.contentView?.layer?.borderColor = Self.zoneColor
            .withAlphaComponent(isActive ? 0.90 : 0.64)
            .cgColor
        panel.contentView?.layer?.borderWidth = isActive ? 2 : 1.5
    }

    private static func framesAreVisuallyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        let tolerance: CGFloat = 0.75
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
