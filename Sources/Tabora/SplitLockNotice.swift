import AppKit

/// Passive, short-lived feedback for an explicit In-Group Gestures toggle.
final class SplitLockNotice: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let label = NSTextField(labelWithString: "")
    private var dismissal: Timer?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        background.addSubview(label)
        contentView = background
    }

    func show(enabled: Bool, on screen: NSScreen?) {
        guard let bounds = (screen ?? NSScreen.main)?.visibleFrame else { return }
        dismissal?.invalidate()
        label.stringValue = L10n.text(enabled ? "notice.split_lock.on" : "notice.split_lock.off")
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + 32,
                          height: ceil(label.intrinsicContentSize.height) + 16)
        setFrame(NSRect(x: floor(bounds.midX - size.width / 2), y: bounds.maxY - size.height - 10,
                        width: size.width, height: size.height), display: false)
        label.frame = NSRect(origin: .zero, size: size).insetBy(dx: 16, dy: 8)
        orderFrontRegardless()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            self?.orderOut(nil)
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
