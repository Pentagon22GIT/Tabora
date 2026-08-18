import AppKit
import QuartzCore

final class OverlayPanel {
    static let sideExpansionPulseDuration: TimeInterval = 0.72

    private let panel: NSPanel
    private let secondaryPanel: NSPanel
    private let candidateLayers = [CALayer(), CALayer()]
    private let candidateDividerLayer = CALayer()
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
        configureCandidatePresentationLayers()
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
        view.layer?.masksToBounds = true
        panel.contentView = view
        return panel
    }

    func show(frame: CGRect, from anchor: CGPoint) {
        secondaryPanel.orderOut(nil)
        hideCandidatePresentation()
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
        let completedFrame = targetFrames.reduce(targetFrames[0]) {
            $0.union($1)
        }

        isShowing = true
        displayedTargetFrame = completedFrame
        displayedCandidateFrames = targetFrames
        secondaryPanel.orderOut(nil)

        // Keep the original left/right half guide in place and only divide
        // its interior. The side-dwell pulse is already the explicit
        // transition cue, so entering corner-candidate mode must not move,
        // grow, fade, or spawn a second guide window from the pointer/edge.
        if !wasShowing || !Self.framesAreVisuallyEqual(panel.frame, completedFrame) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.setFrame(completedFrame, display: true)
            }
        }
        panel.alphaValue = 1
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        applyCandidatePresentation(
            targetFrames: targetFrames,
            activeIndex: activeIndex,
            animated: wasShowingCandidates
        )
    }

    private func configureCandidatePresentationLayers() {
        guard let contentLayer = panel.contentView?.layer else { return }
        for layer in candidateLayers {
            layer.isHidden = true
            contentLayer.addSublayer(layer)
        }
        candidateDividerLayer.isHidden = true
        contentLayer.addSublayer(candidateDividerLayer)
    }

    private func applyCandidatePresentation(
        targetFrames: [CGRect],
        activeIndex: Int,
        animated: Bool
    ) {
        guard targetFrames.count == 2,
              targetFrames.indices.contains(activeIndex),
              let contentLayer = panel.contentView?.layer else { return }

        let containerFrame = targetFrames.reduce(targetFrames[0]) {
            $0.union($1)
        }

        // The outer geometry remains the exact half-snap guide. Candidate
        // regions are rendered inside that one panel, so the first expanded
        // state is literally the existing guide plus a horizontal divider.
        contentLayer.backgroundColor = NSColor.clear.cgColor
        // Keep the shared outer half-guide visible, but slightly softer
        // than the currently selected candidate. This preserves the full
        // two-choice shape while making ownership obvious at a glance.
        contentLayer.borderColor = Self.zoneColor
            .withAlphaComponent(0.56)
            .cgColor
        contentLayer.borderWidth = 1.5
        contentLayer.cornerRadius = 12
        contentLayer.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ]

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.10)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }

        for index in candidateLayers.indices {
            let target = targetFrames[index]
            let localFrame = CGRect(
                x: target.minX - containerFrame.minX,
                y: target.minY - containerFrame.minY,
                width: target.width,
                height: target.height
            )
            let layer = candidateLayers[index]
            let isActive = index == activeIndex
            layer.isHidden = false
            layer.frame = localFrame
            layer.backgroundColor = Self.zoneColor
                .withAlphaComponent(isActive ? 0.30 : 0.07)
                .cgColor
            layer.borderColor = Self.zoneColor
                .withAlphaComponent(isActive ? 0.95 : 0.42)
                .cgColor
            layer.borderWidth = isActive ? 2.0 : 1.25
            layer.cornerRadius = 12
            if abs(target.maxY - containerFrame.maxY) <= 0.75 {
                layer.maskedCorners = [
                    .layerMinXMaxYCorner,
                    .layerMaxXMaxYCorner
                ]
            } else {
                layer.maskedCorners = [
                    .layerMinXMinYCorner,
                    .layerMaxXMinYCorner
                ]
            }
        }

        let lowerIndex = targetFrames[0].minY <= targetFrames[1].minY
            ? 0 : 1
        let dividerY = targetFrames[lowerIndex].maxY - containerFrame.minY
        let dividerThickness: CGFloat = 1.5
        candidateDividerLayer.isHidden = false
        candidateDividerLayer.backgroundColor = Self.zoneColor
            .withAlphaComponent(0.55)
            .cgColor
        candidateDividerLayer.frame = CGRect(
            x: 0,
            y: dividerY - dividerThickness / 2,
            width: containerFrame.width,
            height: dividerThickness
        )

        CATransaction.commit()
    }

    private func hideCandidatePresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in candidateLayers {
            layer.removeAllAnimations()
            layer.isHidden = true
        }
        candidateDividerLayer.removeAllAnimations()
        candidateDividerLayer.isHidden = true
        CATransaction.commit()
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
        hideCandidatePresentation()
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
