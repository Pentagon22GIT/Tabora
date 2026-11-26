import AppKit

final class SettingsSwitch: NSStackView {
    let control = NSSwitch()
    private let label: NSTextField
    var title: String { label.stringValue }
    var target: AnyObject? {
        get { control.target }
        set { control.target = newValue }
    }
    var action: Selector? {
        get { control.action }
        set { control.action = newValue }
    }
    var state: NSControl.StateValue {
        get { control.state }
        set { control.state = newValue }
    }
    var isEnabled: Bool {
        get { control.isEnabled }
        set { control.isEnabled = newValue; label.textColor = newValue ? .labelColor : .disabledControlTextColor }
    }

    init(title: String, target: AnyObject?, action: Selector?) {
        label = NSTextField(wrappingLabelWithString: title)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.controlSize = .small
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setAccessibilityLabel(title)
        addArrangedSubview(label)
        addView(control, in: .trailing)
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class SettingsRow: NSStackView {
    var onEnter: (() -> Void)? { didSet { updateTrackingAreas() } }
    private var hoverArea: NSTrackingArea?
    private var drawsDivider = false

    func configureEdges(first: Bool, last: Bool) {
        var corners: CACornerMask = []
        if first { corners.formUnion(isFlipped ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        if last { corners.formUnion(isFlipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = corners
        layer?.masksToBounds = true
        drawsDivider = !last
        needsDisplay = true
    }

    var showsPreview = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        wantsLayer = true
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 8, left: 28, bottom: 8, right: 28)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard onEnter != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Repaint the whole invalidated surface when the active preview changes.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let level: CGFloat = dark ? (showsPreview ? 0.22 : 0.17) : (showsPreview ? 0.950 : 0.976)
        NSColor(srgbRed: level, green: level + 0.005, blue: level + 0.014, alpha: 1).setFill()
        bounds.fill()
        guard drawsDivider else { return }
        let thickness = 1 / (window?.backingScaleFactor ?? 1)
        let bottom = isFlipped ? bounds.maxY - thickness : bounds.minY
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX + edgeInsets.left, y: bottom, width: bounds.width - edgeInsets.left - edgeInsets.right, height: thickness).fill()
    }
}
