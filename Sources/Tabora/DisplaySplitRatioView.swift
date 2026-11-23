import AppKit

private final class SplitDiagram: NSView {
    var ratio = DefaultSplitRatio() { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 2, dy: 2)
        let outline = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        NSColor.controlAccentColor.setFill()
        let x = box.minX + box.width * CGFloat(ratio.left) / 100
        let y = box.maxY - box.height * CGFloat(ratio.top) / 100
        NSRect(x: x - 1, y: box.minY, width: 2, height: box.height).fill()
        NSRect(x: box.minX, y: y - 1, width: box.width, height: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        outline.stroke()
    }
}

final class DisplaySplitRatioView: NSStackView {
    private let displayKey: String
    private let settings: AppSettings
    private let diagram = SplitDiagram()
    private let left = NSSlider()
    private let top = NSSlider()
    private let leftValue = NSTextField(labelWithString: "")
    private let topValue = NSTextField(labelWithString: "")

    init(screen: NSScreen, key: String, settings: AppSettings = .shared) {
        self.settings = settings
        displayKey = key
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        addArrangedSubview(NSTextField(labelWithString: screen.localizedName))
        let ratio = settings.splitRatio(for: key)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.text("settings.ratio.left")), left, leftValue],
            [NSTextField(labelWithString: L10n.text("settings.ratio.top")), top, topValue]
        ])
        for (slider, value, label) in [(left, ratio.left, "settings.ratio.left"), (top, ratio.top, "settings.ratio.top")] {
            slider.minValue = 1
            slider.maxValue = 99
            slider.integerValue = value
            slider.target = self
            slider.action = #selector(changed(_:))
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 140).isActive = true
            slider.setAccessibilityLabel(L10n.text(label))
        }
        for label in [leftValue, topValue] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        }
        diagram.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let aspect = screen.frame.height / max(1, screen.frame.width)
        diagram.heightAnchor.constraint(equalToConstant: min(72, max(28, 72 * aspect))).isActive = true
        addArrangedSubview(NSStackView(views: [diagram, grid]))
        render(ratio)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed(_ slider: NSSlider) {
        slider.doubleValue = slider.doubleValue.rounded()
        let ratio = DefaultSplitRatio(left: left.integerValue, top: top.integerValue)
        guard ratio != diagram.ratio else { return }
        render(ratio)
        settings.setSplitRatio(ratio, for: displayKey)
    }

    private func render(_ ratio: DefaultSplitRatio) {
        diagram.ratio = ratio
        leftValue.stringValue = "\(ratio.left) : \(100 - ratio.left)"
        topValue.stringValue = "\(ratio.top) : \(100 - ratio.top)"
    }
}
