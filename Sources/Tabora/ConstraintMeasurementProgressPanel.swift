import AppKit

/// A fixed, non-modal status surface for explicit constraint measurement.
/// It intentionally does not follow or blur the measured window: measurement
/// owns window geometry, while this panel only reports that transaction.
final class ConstraintMeasurementProgressPanel: NSObject {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private lazy var doneButton = NSButton(
        title: L10n.text("common.done"),
        target: self,
        action: #selector(completeAcknowledgement)
    )
    private var acknowledgement: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 176),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = L10n.text("settings.constraints.measure")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1

        doneButton.bezelStyle = .rounded
        doneButton.isEnabled = false

        let stack = NSStackView(views: [
            titleLabel,
            detailLabel,
            progressIndicator,
            doneButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: progressIndicator)

        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            doneButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    func begin(
        displayName: String,
        screen: NSScreen?,
        acknowledgement: (() -> Void)? = nil
    ) {
        self.acknowledgement = acknowledgement
        titleLabel.stringValue = L10n.format("constraint.progress.title", displayName)
        detailLabel.stringValue = L10n.text("constraint.progress.checking_window")
        detailLabel.textColor = .secondaryLabelColor
        progressIndicator.doubleValue = 0
        doneButton.isEnabled = false
        position(on: screen ?? NSScreen.main)
        panel.orderFrontRegardless()
    }

    func update(_ progress: ConstraintMeasurementProgress) {
        progressIndicator.doubleValue = progress.fractionCompleted
        switch progress.phase {
        case .preparing:
            detailLabel.stringValue = L10n.text("constraint.progress.preparing")
        case .measuring(let bound):
            detailLabel.stringValue = L10n.format(
                "constraint.progress.probing",
                Self.title(for: bound)
            )
        case .restoringOriginalFrame:
            detailLabel.stringValue = L10n.text("constraint.progress.restoring")
        }
    }

    func update(
        fractionCompleted: Double,
        progress: ConstraintMeasurementProgress,
        displayName: String
    ) {
        progressIndicator.doubleValue = min(max(fractionCompleted, 0), 1)
        titleLabel.stringValue = L10n.format("constraint.progress.title", displayName)
        switch progress.phase {
        case .preparing:
            detailLabel.stringValue = L10n.text("constraint.progress.preparing")
        case .measuring(let bound):
            detailLabel.stringValue = L10n.format(
                "constraint.progress.probing",
                Self.title(for: bound)
            )
        case .restoringOriginalFrame:
            detailLabel.stringValue = L10n.text("constraint.progress.restoring")
        }
    }

    func finish(confirmedValueCount: Int, restoredOriginalFrame: Bool) {
        progressIndicator.doubleValue = 1
        doneButton.isEnabled = true
        if !restoredOriginalFrame {
            titleLabel.stringValue = L10n.text("constraint.result.restore_failed.title")
            detailLabel.stringValue = L10n.text("constraint.result.restore_failed.detail")
            detailLabel.textColor = .systemRed
        } else if confirmedValueCount == 0 {
            titleLabel.stringValue = L10n.text("constraint.result.empty.title")
            detailLabel.stringValue = L10n.text("constraint.result.empty.detail")
            detailLabel.textColor = .secondaryLabelColor
        } else {
            titleLabel.stringValue = L10n.text("constraint.result.completed.title")
            detailLabel.stringValue = L10n.text("constraint.result.completed.detail")
            detailLabel.textColor = .secondaryLabelColor
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        acknowledgement = nil
        panel.orderOut(nil)
    }

    @objc private func completeAcknowledgement() {
        guard doneButton.isEnabled else { return }
        let callback = acknowledgement
        acknowledgement = nil
        panel.orderOut(nil)
        callback?()
    }

    private func position(on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let origin = CGPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private static func title(for bound: AppConstraintBound) -> String {
        switch bound {
        case .minWidth: return L10n.text("constraint.bound.min_width")
        case .minHeight: return L10n.text("constraint.bound.min_height")
        case .maxWidth: return L10n.text("constraint.bound.max_width")
        case .maxHeight: return L10n.text("constraint.bound.max_height")
        }
    }
}
