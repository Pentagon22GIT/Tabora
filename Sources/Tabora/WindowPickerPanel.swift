import AppKit
import CoreGraphics

enum PickerPreviewWorkPolicy {
    static let totalPreviewByteBudget = 32 * 1024 * 1024
    static let bytesPerPixel = 4
    static let maximumCaptureAttempts = 3

    static func perImageByteBudget(candidateCount: Int) -> Int {
        guard candidateCount > 0 else { return 0 }
        return totalPreviewByteBudget / candidateCount
    }

    static func retryDelay(afterFailedAttempt attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [0.18, 0.55]
        guard delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }
}

private final class PreviewImageLoader {
    private static let maximumPreviewPixelSize = CGSize(width: 680, height: 420)
    private let provider: (CGWindowID?) -> CGImage?
    private let perImageByteBudget: Int
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.pent.Tabora.preview-loader"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    // Reuse the established interactive readiness budget. Preview is derived
    // state: a slow Window Server capture may continue off-main, but the picker
    // must fall back to its placeholder instead of waiting behind it.
    private let presentationTimeout: TimeInterval = 0.45
    private var cache: [String: NSImage] = [:]
    private var completed: Set<String> = []
    private var placeholderDelivered: Set<String> = []
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private var operations: [String: Operation] = [:]
    private var generation: UInt64 = 0

    init(
        provider: @escaping (CGWindowID?) -> CGImage?,
        candidateCount: Int
    ) {
        self.provider = provider
        perImageByteBudget = PickerPreviewWorkPolicy.perImageByteBudget(
            candidateCount: candidateCount
        )
    }

    func request(_ window: ManagedWindow, completion: @escaping (NSImage?) -> Void) {
        let key = window.stableIdentity
        if completed.contains(key) {
            completion(cache[key])
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        let windowID = window.cgWindowID
        let timeout = presentationTimeout
        let requestGeneration = generation

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.deliverTimeoutPlaceholder(key: key, generation: requestGeneration)
        }
        startCapture(
            key: key,
            windowID: windowID,
            generation: requestGeneration,
            attempt: 0
        )
    }

    private func startCapture(
        key: String,
        windowID: CGWindowID?,
        generation: UInt64,
        attempt: Int
    ) {
        guard self.generation == generation, pending[key] != nil else { return }
        let provider = self.provider
        let byteBudget = perImageByteBudget
        let operation = BlockOperation { [weak self] in
            guard self != nil else { return }
            let imageRef = provider(windowID).flatMap { source in
                Self.makePreviewImage(
                    from: source,
                    byteBudget: byteBudget
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishRequest(
                    key: key,
                    imageRef: imageRef,
                    windowID: windowID,
                    generation: generation,
                    attempt: attempt
                )
            }
        }
        operations[key] = operation
        Self.queue.addOperation(operation)
    }

    func cancel() {
        generation &+= 1
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        cache.removeAll()
        completed.removeAll()
        placeholderDelivered.removeAll()
        pending.removeAll()
    }

    private func deliverTimeoutPlaceholder(key: String, generation: UInt64) {
        guard self.generation == generation,
              !completed.contains(key),
              placeholderDelivered.insert(key).inserted else { return }
        // The timeout is presentation-only. Keep subscribers until the actual
        // derived capture finishes so a late image can replace the placeholder
        // without rebuilding the picker or its transaction.
        let callbacks = pending[key] ?? []
        callbacks.forEach { $0(nil) }
    }

    private func finishRequest(
        key: String,
        imageRef: CGImage?,
        windowID: CGWindowID?,
        generation: UInt64,
        attempt: Int
    ) {
        guard self.generation == generation else { return }
        operations.removeValue(forKey: key)
        if imageRef == nil,
           attempt + 1 < PickerPreviewWorkPolicy.maximumCaptureAttempts,
           let retryDelay = PickerPreviewWorkPolicy.retryDelay(
               afterFailedAttempt: attempt
           ) {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + retryDelay
            ) { [weak self] in
                self?.startCapture(
                    key: key,
                    windowID: windowID,
                    generation: generation,
                    attempt: attempt + 1
                )
            }
            return
        }
        let image = imageRef.map { NSImage(cgImage: $0, size: .zero) }
        if let image { cache[key] = image }
        guard completed.insert(key).inserted else { return }
        placeholderDelivered.remove(key)
        let callbacks = pending.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(image) }
    }

    private static func makePreviewImage(
        from source: CGImage,
        byteBudget: Int
    ) -> CGImage? {
        let sourceSize = CGSize(
            width: CGFloat(source.width),
            height: CGFloat(source.height)
        )
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let dimensionScale = min(min(
            maximumPreviewPixelSize.width / sourceSize.width,
            maximumPreviewPixelSize.height / sourceSize.height
        ), 1)
        var width = max(
            Int((sourceSize.width * dimensionScale).rounded(.down)),
            1
        )
        var height = max(
            Int((sourceSize.height * dimensionScale).rounded(.down)),
            1
        )
        guard byteBudget >= PickerPreviewWorkPolicy.bytesPerPixel else {
            return nil
        }
        let sourceCost = max(
            source.bytesPerRow * source.height,
            source.width * source.height
                * PickerPreviewWorkPolicy.bytesPerPixel
        )
        if dimensionScale == 1, sourceCost <= byteBudget {
            return source
        }
        let estimatedCost = width * height
            * PickerPreviewWorkPolicy.bytesPerPixel
        if estimatedCost > byteBudget {
            let budgetScale = sqrt(
                Double(byteBudget) / Double(estimatedCost)
            )
            width = max(
                Int((Double(width) * budgetScale).rounded(.down)),
                1
            )
            height = max(
                Int((Double(height) * budgetScale).rounded(.down)),
                1
            )
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        for _ in 0..<8 {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return nil }
            let actualCost = max(
                context.bytesPerRow * height,
                width * height * PickerPreviewWorkPolicy.bytesPerPixel
            )
            if actualCost > byteBudget {
                let scale = min(
                    sqrt(Double(byteBudget) / Double(actualCost)) * 0.98,
                    0.98
                )
                width = max(Int((Double(width) * scale).rounded(.down)), 1)
                height = max(Int((Double(height) * scale).rounded(.down)), 1)
                continue
            }
            context.interpolationQuality = .high
            context.draw(
                source,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            guard let image = context.makeImage() else { return nil }
            let imageCost = max(
                image.bytesPerRow * image.height,
                image.width * image.height
                    * PickerPreviewWorkPolicy.bytesPerPixel
            )
            if imageCost <= byteBudget { return image }
            let scale = min(
                sqrt(Double(byteBudget) / Double(imageCost)) * 0.98,
                0.98
            )
            width = max(Int((Double(width) * scale).rounded(.down)), 1)
            height = max(Int((Double(height) * scale).rounded(.down)), 1)
        }
        return nil
    }
}

final class WindowPickerPanel: NSObject {
    private var panels: [NSPanel] = []
    private var onSelect: ((ManagedWindow, SnapZone) -> Void)?
    private var onCancel: (() -> Void)?
    private var previewLoader: PreviewImageLoader?
    private var selectionPending = false

    var isVisible: Bool { !panels.isEmpty }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        panels.contains { NSMouseInRect(point, $0.frame, false) }
    }

    func show(
        windowsByZone: [SnapZone: [ManagedWindow]],
        zoneFrames: [SnapZone: CGRect],
        backdropFrames: [CGRect] = [],
        previewProvider: @escaping (CGWindowID?) -> CGImage?,
        onCancel: @escaping () -> Void,
        onSelect: @escaping (ManagedWindow, SnapZone) -> Void
    ) {
        hide(notifyCancel: false)
        guard windowsByZone.values.contains(where: { !$0.isEmpty }),
              !zoneFrames.isEmpty else { return }
        self.onSelect = onSelect
        self.onCancel = onCancel
        selectionPending = false
        let uniqueCandidateCount = Set(
            windowsByZone.values.flatMap { windows in
                windows.map(\.stableIdentity)
            }
        ).count
        let previewLoader = PreviewImageLoader(
            provider: previewProvider,
            candidateCount: uniqueCandidateCount
        )
        self.previewLoader = previewLoader

        for frame in backdropFrames where frame.width > 1 && frame.height > 1 {
            let panel = makePanel(frame: frame)
            panel.contentView = PickerBackdropView(onCancel: { [weak self] in
                self?.hide(notifyCancel: true)
            })
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        for zone in SnapZone.allCases {
            guard let frame = zoneFrames[zone],
                  frame.width >= 80,
                  frame.height >= 80,
                  let windows = windowsByZone[zone],
                  !windows.isEmpty else { continue }
            let panel = makePanel(frame: frame)
            let content = PickerZoneView(
                windows: windows,
                zone: zone,
                previewLoader: previewLoader,
                selection: { [weak self] window, selectedZone in
                    guard let self, !self.selectionPending else { return }
                    self.selectionPending = true
                    self.onSelect?(window, selectedZone)
                },
                onCancel: { [weak self] in
                    self?.hide(notifyCancel: true)
                }
            )
            panel.contentView = content
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        if panels.isEmpty {
            hide(notifyCancel: true)
        }
    }

    func allowAnotherSelection() {
        selectionPending = false
    }

    func hide(notifyCancel: Bool = false) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        let cancel = onCancel
        onSelect = nil
        onCancel = nil
        previewLoader?.cancel()
        previewLoader = nil
        selectionPending = false
        if notifyCancel { cancel?() }
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        return panel
    }
}

private final class PickerBackdropView: NSView {
    private let effectView = NSVisualEffectView()
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(0.12).cgColor
        addSubview(effectView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effectView.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        onCancel()
    }
}

private final class PickerZoneView: NSView {
    private let previewLoader: PreviewImageLoader
    private let onCancel: () -> Void
    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let canvas = CenteredCardCanvas()
    private var scrollObserver: NSObjectProtocol?
    private var lastPreviewScrollOrigin = CGPoint.zero

    init(
        windows: [ManagedWindow],
        zone: SnapZone,
        previewLoader: PreviewImageLoader,
        selection: @escaping (ManagedWindow, SnapZone) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.previewLoader = previewLoader
        self.onCancel = onCancel
        super.init(frame: .zero)
        build(windows: windows, zone: zone, selection: selection)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        scrollView.frame = bounds
        canvas.viewportSize = bounds.size
        canvas.frame.size.width = bounds.width
        canvas.relayout()
        // Large displays can expose more than the historical first 12 cards.
        // Request the actual visible range after geometry settles so an
        // on-screen candidate never waits for a synthetic scroll event.
        canvas.loadPreviews(
            near: scrollView.contentView.bounds,
            prefetchCount: 6,
            using: previewLoader
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !containsCard(at: point) else { return }
        onCancel()
    }

    private func containsCard(at point: CGPoint) -> Bool {
        guard let hit = hitTest(point) else { return false }
        var current: NSView? = hit
        while let view = current {
            if view is WindowCardButton { return true }
            current = view.superview
        }
        return false
    }

    private func build(
        windows: [ManagedWindow],
        zone: SnapZone,
        selection: @escaping (ManagedWindow, SnapZone) -> Void
    ) {
        wantsLayer = true

        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        addSubview(effectView)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handlePreviewScroll()
        }

        canvas.onBackgroundClick = { [weak self] in self?.onCancel() }
        for window in windows {
            let card = WindowCardButton(window: window, zone: zone, actionHandler: selection)
            canvas.addCard(card)
        }
        canvas.loadInitialPreviews(count: 12, using: previewLoader)
    }

    private func handlePreviewScroll() {
        let origin = scrollView.contentView.bounds.origin
        guard origin != lastPreviewScrollOrigin else { return }
        lastPreviewScrollOrigin = origin
        canvas.loadPreviews(
            near: scrollView.contentView.bounds,
            prefetchCount: 6,
            using: previewLoader
        )
    }
}

private final class CenteredCardCanvas: NSView {
    var viewportSize: CGSize = .zero
    var onBackgroundClick: (() -> Void)?
    private var cards: [WindowCardButton] = []
    private let horizontalPadding: CGFloat = 34
    private let verticalPadding: CGFloat = 34
    private let spacingX: CGFloat = 22
    private let spacingY: CGFloat = 26

    override var isFlipped: Bool { true }

    func addCard(_ card: WindowCardButton) {
        cards.append(card)
        addSubview(card)
    }

    func loadInitialPreviews(count: Int, using loader: PreviewImageLoader) {
        cards.prefix(max(count, 0)).forEach { $0.loadPreview(using: loader) }
    }

    func loadPreviews(near visibleRect: CGRect, prefetchCount: Int, using loader: PreviewImageLoader) {
        let visibleIndices = cards.indices.filter { cards[$0].frame.intersects(visibleRect) }
        guard let first = visibleIndices.first, let last = visibleIndices.last else { return }
        let start = max(first - max(prefetchCount, 0), 0)
        let end = min(last + max(prefetchCount, 0), cards.count - 1)
        guard start <= end else { return }
        for index in start...end {
            cards[index].loadPreview(using: loader)
        }
    }

    func relayout() {
        guard viewportSize.width > 0 else { return }

        let effectiveHorizontalPadding = min(horizontalPadding, max(viewportSize.width * 0.08, 8))
        let effectiveVerticalPadding = min(verticalPadding, max(viewportSize.height * 0.08, 8))
        let available = max(viewportSize.width - effectiveHorizontalPadding * 2, 1)
        let preferredWidth = min(max(available * 0.34, 180), 340)
        let columns = max(1, Int((available + spacingX) / (preferredWidth + spacingX)))
        let cardWidth = min(340, max(64, (available - CGFloat(max(columns - 1, 0)) * spacingX) / CGFloat(columns)))
        let previewHeight = cardWidth < 160 ? min(cardWidth, 88) : cardWidth * 0.60
        let cardHeight = previewHeight + (cardWidth < 120 ? 0 : 34)
        let rows = max(1, Int(ceil(Double(cards.count) / Double(columns))))
        let contentHeight = CGFloat(rows) * cardHeight + CGFloat(max(rows - 1, 0)) * spacingY
        let canvasHeight = max(viewportSize.height, contentHeight + effectiveVerticalPadding * 2)
        frame.size = CGSize(width: viewportSize.width, height: canvasHeight)

        let totalWidth = CGFloat(columns) * cardWidth + CGFloat(max(columns - 1, 0)) * spacingX
        let startX = max((viewportSize.width - totalWidth) / 2, effectiveHorizontalPadding)
        let startY = max((canvasHeight - contentHeight) / 2, effectiveVerticalPadding)

        for (index, card) in cards.enumerated() {
            let row = index / columns
            let column = index % columns
            let x = startX + CGFloat(column) * (cardWidth + spacingX)
            let y = startY + CGFloat(row) * (cardHeight + spacingY)
            card.frame = CGRect(x: x, y: y, width: cardWidth, height: cardHeight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard cards.allSatisfy({ !$0.frame.contains(point) }) else { return }
        onBackgroundClick?()
    }
}

private final class WindowCardButton: NSButton {
    private let managedWindow: ManagedWindow
    private let zone: SnapZone
    private let actionHandler: (ManagedWindow, SnapZone) -> Void
    private let previewView = NSImageView()
    private let placeholderIconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var didRequestPreview = false

    init(window: ManagedWindow, zone: SnapZone, actionHandler: @escaping (ManagedWindow, SnapZone) -> Void) {
        self.managedWindow = window
        self.zone = zone
        self.actionHandler = actionHandler
        super.init(frame: .zero)
        target = self
        action = #selector(selectWindow)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        build(window)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let iconOnly = bounds.width < 120 || bounds.height < 100
        let compact = bounds.width < 160
        let titleHeight: CGFloat = 24
        titleField.isHidden = iconOnly
        previewView.isHidden = compact
        placeholderIconView.isHidden = previewView.image != nil && !compact
        previewView.frame = CGRect(x: 0, y: titleHeight + 8, width: bounds.width, height: max(bounds.height - titleHeight - 8, 0))
        let iconSide = min(iconOnly ? 52 : 64, max(min(bounds.width, bounds.height) - 16, 24))
        placeholderIconView.frame = CGRect(
            x: bounds.midX - iconSide / 2,
            y: (iconOnly ? bounds.midY : previewView.frame.midY) - iconSide / 2,
            width: iconSide,
            height: iconSide
        )
        titleField.frame = CGRect(x: 2, y: 0, width: max(bounds.width - 4, 0), height: titleHeight)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func build(_ window: ManagedWindow) {
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 6
        previewView.layer?.masksToBounds = true
        previewView.layer?.borderWidth = 0
        previewView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        previewView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor

        placeholderIconView.image = window.appIcon
        placeholderIconView.imageScaling = .scaleProportionallyDown

        titleField.stringValue = window.title
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.alignment = .left
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.textColor = .labelColor

        addSubview(previewView)
        addSubview(placeholderIconView)
        addSubview(titleField)
    }

    func loadPreview(using loader: PreviewImageLoader) {
        guard !didRequestPreview else { return }
        didRequestPreview = true
        loader.request(managedWindow) { [weak self] image in
            guard let self, let image else { return }
            self.previewView.image = image
            self.placeholderIconView.isHidden = !self.previewView.isHidden
        }
    }

    override func mouseEntered(with event: NSEvent) {
        previewView.layer?.borderWidth = 3
    }

    override func mouseExited(with event: NSEvent) {
        previewView.layer?.borderWidth = 0
    }

    @objc private func selectWindow() {
        actionHandler(managedWindow, zone)
    }
}
