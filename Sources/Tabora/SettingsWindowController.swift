import AppKit
import CoreGraphics
import SwiftUI

enum SettingsCategory: Int, CaseIterable {
    case general, resize, movement, ratios, tabRecords, gesture, detection, commands, experimental

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .ratios: return "rectangle.split.2x1"
        case .commands: return "command"
        case .tabRecords: return "ruler"
        case .experimental: return "flask"
        case .movement: return "macwindow"
        case .resize: return "arrow.left.and.right"
        case .gesture: return "hand.draw"
        case .detection: return "cursorarrow.motionlines"
        }
    }

    var title: String {
        switch self {
        case .movement: return L10n.text("settings.general.window_movement")
        case .resize: return L10n.text("settings.section.resize")
        case .gesture: return L10n.text("settings.nav.gesture")
        case .detection: return L10n.text("settings.general.drag_detection.title")
        case .general: return L10n.text("settings.category.general")
        case .ratios: return L10n.text("settings.ratio.title")
        case .commands: return L10n.text("settings.category.commands")
        case .tabRecords: return L10n.text("settings.category.constraints")
        case .experimental: return L10n.text("settings.category.experimental")
        }
    }
}

enum SettingsScrollGeometry {
    static func topOrigin(
        documentBounds: CGRect,
        viewportBounds: CGRect,
        isFlipped: Bool
    ) -> CGPoint {
        CGPoint(
            x: documentBounds.minX,
            y: isFlipped
                ? documentBounds.minY
                : max(
                    documentBounds.maxY - viewportBounds.height,
                    documentBounds.minY
                )
        )
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var gestureRegistrationPending: (() -> Bool)?
    var onVisibilityChange: ((Bool) -> Void)?
    var onConstraintMeasurementWillBegin: ((String) -> Bool)?
    var onConstraintMeasurementDidEnd: (() -> Void)?
    var onMissionControlPreviewMemoryLimitChange: ((Int) -> Void)?
    var onMissionControlPreviewCacheClear: (() -> Void)?
    var onMissionControlGroupMigrationRuntimeStatusRequest:
        (() -> GroupSpaceMigrationRuntimeStatus?)?
    var onLanguageApply: ((AppLanguage) -> Bool)?
    private var groupPreviewLabels: [NSTextField] = []
    private var groupMigrationLabels: [NSTextField] = []
    private var dwellLabels: [NSTextField] = []
    private var gestureLabels: [NSTextField] = []
    private weak var cursorDistanceTitle: NSTextField?

    private let settings = AppSettings.shared
    private let experimentalWorkspaceSettings = ExperimentalWorkspaceSettings.shared
    private let scrollView = NSScrollView()
    private let settingsDocumentView = FlippedSettingsDocumentView()
    private let navigation = NSTableView()
    private let heading = NSTextField(labelWithString: "")
    private var categoryViews: [SettingsCategory: NSView] = [:]
    private var categoryContentConstraints: [NSLayoutConstraint] = []
    var onRemoval: ((AppRemovalChoice) -> Void)?
    private var informationWindow: InitialSetupWindowController?
    private var selectedCategory: SettingsCategory = .general
    private var recordingAction: ShortcutAction?
    private var keyMonitor: Any?
    private var shortcutButtons: [ShortcutAction: NSButton] = [:]
    private var clearButtons: [ShortcutAction: NSButton] = [:]
    private let modePopup = NSPopUpButton()
    private let stylePopup = NSPopUpButton()
    private let modeDetail = NSTextField(wrappingLabelWithString: "")
    private let styleDetail = NSTextField(wrappingLabelWithString: "")
    private let linkedResizeOptionsStack = NSStackView()
    private let launchCheckbox = SettingsSwitch(title: L10n.text("settings.general.launch_at_login"), target: nil, action: nil)
    private let windowPreviewsCheckbox = SettingsSwitch(title: L10n.text("settings.general.show_window_previews"), target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private lazy var applyLanguageButton = NSButton(
        title: L10n.text("settings.language.apply_restart"),
        target: self,
        action: #selector(applyLanguage)
    )
    private var pendingLanguage = L10n.language
    private let missionControlGroupMigrationCheckbox = SettingsSwitch(title: L10n.text("settings.experimental.group_migration.checkbox"), target: nil, action: nil)
    private let missionControlGroupMigrationRuntimeStatus = NSTextField(
        labelWithString: L10n.text("settings.experimental.api_status.pending")
    )
    private let restoreSizeOnMoveCheckbox = SettingsSwitch(title: L10n.text("settings.general.restore_size.checkbox"), target: nil, action: nil)
    private let linkedResizeCheckbox = SettingsSwitch(title: L10n.text("settings.general.linked_resize.checkbox"), target: nil, action: nil)
    private let raiseConnectedWindowsOnClickCheckbox = SettingsSwitch(title: L10n.text("settings.general.raise_group.checkbox"), target: nil, action: nil)
    private let resizeCursorAdornmentCheckbox = SettingsSwitch(title: L10n.text("settings.general.resize_cursor.checkbox"), target: nil, action: nil)
    private let resizeCursorAdornmentDistanceSlider = NSSlider()
    private let resizeCursorAdornmentDistanceValue = NSTextField(labelWithString: "")
    private let edgeThresholdSlider = NSSlider()
    private let edgeThresholdValue = NSTextField(labelWithString: "")
    private let cornerBandSlider = NSSlider()
    private let cornerBandValue = NSTextField(labelWithString: "")
    private let sideDwellExpansionCheckbox = SettingsSwitch(title: L10n.text("settings.general.side_dwell.checkbox"), target: nil, action: nil)
    private let sideDwellDurationSlider = NSSlider()
    private let sideDwellDurationValue = NSTextField(labelWithString: "")
    private let missionControlLatestPreviewCheckbox = SettingsSwitch(title: L10n.text("settings.experimental.latest_preview.checkbox"), target: nil, action: nil)
    private let assistLayoutSwitchingCheckbox = SettingsSwitch(title: L10n.text("settings.general.assist.checkbox"), target: nil, action: nil)
    private let workspaceEdgeDelayStatus = NSTextField(
        labelWithString: L10n.text("settings.experimental.workspace.status.checking")
    )
    private lazy var delayWorkspaceEdgeButton = NSButton(
        title: L10n.text("settings.experimental.workspace.delay_button"),
        target: self,
        action: #selector(applyWorkspaceEdgeDelay)
    )
    private lazy var resetWorkspaceEdgeButton = NSButton(
        title: L10n.text("common.restore_defaults"),
        target: self,
        action: #selector(resetWorkspaceEdgeDelay)
    )
    private let previewMemoryLimitSlider = NSSlider()
    private let previewMemoryLimitValue = NSTextField(labelWithString: "")
    private lazy var clearPreviewCacheButton = NSButton(
        title: L10n.text("settings.experimental.preview.clear_cache"),
        target: self,
        action: #selector(clearMissionControlPreviewCache)
    )
    private let constraintRegistry = AppConstraintRegistry.shared
    private let constraintIdentityResolver = AppConstraintIdentityResolver()
    private let constraintWindowService = AXWindowService()
    private lazy var constraintMeasurementEngine = ConstraintMeasurementEngine(
        windowService: constraintWindowService
    )
    private let constraintMeasurementProgressPanel =
        ConstraintMeasurementProgressPanel()
    private let constraintPromptCheckbox = SettingsSwitch(title: L10n.text("settings.constraints.confirm_new"), target: nil, action: nil)
    private let constraintRecordsStack = NSStackView()
    private var constraintIdentitiesByControlID: [String: AppConstraintIdentity] = [:]
    private var constraintMeasurementInProgress = false
    private var constraintMeasurementOperationActive = false

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let toolbar = NSToolbar(identifier: "SettingsWindowControls")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .controlBackgroundColor
        window.title = L10n.text("settings.window.title")
        window.collectionBehavior.insert(.fullScreenNone)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        informationWindow?.close()
        finishRecording()
        constraintMeasurementProgressPanel.dismiss()
        if constraintMeasurementOperationActive {
            constraintMeasurementEngine.cancel { [weak self] _ in
                guard let self else { return }
                self.constraintMeasurementOperationActive = false
                self.constraintMeasurementInProgress = false
                self.onConstraintMeasurementDidEnd?()
            }
        } else if constraintMeasurementInProgress {
            constraintMeasurementInProgress = false
            refreshConstraintRecords()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onVisibilityChange?(false)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onVisibilityChange?(true)
    }

    private let displayRatios = NSStackView()
    private let gestureToggle = SettingsSwitch(title: L10n.text("settings.gesture.snap"), target: nil, action: nil)

    private let gestureMaximizeToggle = SettingsSwitch(title: L10n.text("settings.gesture.maximize"), target: nil, action: nil)

    func refreshGestureOptions() {
        let settings = AppSettings.shared
        for label in gestureLabels { label.alphaValue = settings.gestureSnapEnabled ? 1 : 0.45 }
        shortcutButtons[.toggleSplitLock]?.isEnabled = settings.shortcutAvailable(.toggleSplitLock)
        splitLockCheckbox?.isEnabled = settings.gestureSnapEnabled
        reassignmentToggle?.isEnabled = settings.canReassignByGesture
        reassignmentToggle?.state = settings.gestureReassignmentEnabled ? .on : .off
        reassignmentNote?.alphaValue = settings.canReassignByGesture ? 1 : 0.45
        splitLockCheckbox?.state = settings.splitLockEnabled ? .on : .off
        gestureToggle.state = settings.gestureSnapEnabled ? .on : .off
        gestureMaximizeToggle.isEnabled = settings.gestureSnapEnabled
        gestureMaximizeToggle.state = settings.maximizeOnUpwardGesture ? .on : .off
    }

    @objc private func changeGestureMaximize() {
        guard AppSettings.shared.gestureSnapEnabled else { return }
        AppSettings.shared.maximizeOnUpwardGesture = gestureMaximizeToggle.state == .on
    }

    @objc private func refreshDisplayRatios() {
        for row in displayRatios.arrangedSubviews { row.removeFromSuperview() }
        for screen in NSScreen.screens {
            guard let key = DefaultSplitRatio.displayKey(screen) else { continue }
            let editor = DisplaySplitRatioView(screen: screen, key: key)
            if !displayRatios.arrangedSubviews.isEmpty {
                let divider = NSBox()
                divider.boxType = .separator
                displayRatios.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: displayRatios.widthAnchor).isActive = true
            }
            displayRatios.addArrangedSubview(editor)
            editor.widthAnchor.constraint(equalTo: displayRatios.widthAnchor).isActive = true
        }
    }

    @objc private func changeGroupSubdivision(_ sender: NSSwitch) {
        AppSettings.shared.groupSubdivisionEnabled = sender.state == .on
    }

    private weak var reassignmentToggle: SettingsSwitch?
    private weak var reassignmentNote: NSTextField?
    @objc private func changeReassignment(_ sender: NSSwitch) {
        guard AppSettings.shared.canReassignByGesture else { return }
        AppSettings.shared.gestureReassignmentEnabled = sender.state == .on
    }
    private weak var splitLockCheckbox: SettingsSwitch?
    @objc private func changeSplitLock(_ sender: NSSwitch) {
        guard AppSettings.shared.gestureSnapEnabled else { return }
        AppSettings.shared.splitLockEnabled = sender.state == .on
        refreshGestureOptions()
    }

    @objc private func changeOccupiedReplacement(_ sender: NSSwitch) {
        AppSettings.shared.occupiedReplacementEnabled = sender.state == .on
    }

    @objc private func changeGesture() {
        let requested = gestureToggle.state == .on
        AppSettings.shared.gestureSnapEnabled = requested
        refreshGestureOptions()
        if requested && gestureRegistrationPending?() == true {
            let alert = NSAlert()
            alert.messageText = L10n.text("settings.gesture.unavailable")
            alert.runModal()
        }
    }

    func show() {
        refreshDisplayRatios()
        pendingLanguage = L10n.language
        refresh()
        refreshExperimentalWorkspaceState()
        onVisibilityChange?(true)
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        positionScrollViewAtTop()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let sidebar = SettingsSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        let sidebarTitle = NSTextField(labelWithString: "Tabora")
        sidebarTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarTitle)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionLabel = NSTextField(labelWithString: version ?? L10n.text("common.development"))
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(versionLabel)
        let list = NSScrollView()
        list.translatesAutoresizingMaskIntoConstraints = false
        for pane in [list, scrollView] {
            pane.automaticallyAdjustsContentInsets = false
            pane.contentInsets = .init()
            pane.verticalScrollElasticity = .none
            pane.horizontalScrollElasticity = .none
        }
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        sidebar.addSubview(list)
        let column = NSTableColumn(identifier: .init("category"))
        navigation.addTableColumn(column)
        navigation.headerView = nil
        navigation.style = .sourceList
        navigation.floatsGroupRows = false
        navigation.rowHeight = 36
        navigation.backgroundColor = .clear
        navigation.allowsEmptySelection = false
        navigation.delegate = self
        navigation.dataSource = self
        list.documentView = navigation

        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)
        previewPanel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewPanel)
        previewHeight = previewPanel.heightAnchor.constraint(equalToConstant: 0)
        previewHeight.isActive = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 206),
            versionLabel.leadingAnchor.constraint(equalTo: sidebarTitle.trailingAnchor, constant: 6),
            versionLabel.firstBaselineAnchor.constraint(equalTo: sidebarTitle.firstBaselineAnchor),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 21),
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 50),
            list.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            list.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 25),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewPanel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            previewPanel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            previewPanel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: previewPanel.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        settingsDocumentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = settingsDocumentView
        NSLayoutConstraint.activate([
            settingsDocumentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            settingsDocumentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])

        categoryViews = [
            .general: makeGeneralSettingsView(),
            .movement: makeMovementSettingsView(),
            .resize: makeResizeSettingsView(),
            .gesture: makeGestureSettingsView(),
            .detection: makeDetectionSettingsView(),

            .ratios: makeRatioSettingsView(),
            .commands: makeCommandSettingsView(),
            .tabRecords: makeTabRecordSettingsView(),
            .experimental: makeExperimentalSettingsView()
        ]
        categoryViews.values.forEach(styleSettingGroups)
        navigation.reloadData()
        navigation.selectRowIndexes(IndexSet(integer: rows.firstIndex { $0.1 == selectedCategory } ?? 1), byExtendingSelection: false)
        showSettingsCategory(selectedCategory, resetScroll: false)
    }

    private func makeSettingsStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func note(_ key: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: L10n.text(key))
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12)
        return field
    }

    private func makeRatioSettingsView() -> NSView {
        let stack = makeSettingsStack()
        displayRatios.orientation = .vertical
        displayRatios.alignment = .leading
        displayRatios.spacing = 8
        stack.addArrangedSubview(displayRatios)
        displayRatios.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(note("settings.ratio.disconnected"))
        refreshDisplayRatios()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDisplayRatios),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        return stack
    }

    private func makeGeneralSettingsView() -> NSView {
        let stack = makeSettingsStack()
        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunchAtLogin)
        stack.addArrangedSubview(launchCheckbox)
        groupRows(from: launchCheckbox, in: stack)

        windowPreviewsCheckbox.target = self
        windowPreviewsCheckbox.action = #selector(toggleWindowPreviews)
        stack.addArrangedSubview(windowPreviewsCheckbox)
        stack.setCustomSpacing(4, after: windowPreviewsCheckbox)
        let previewNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.preview_note")
        )
        previewNote.textColor = .secondaryLabelColor
        previewNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(previewNote)
        groupRows(from: windowPreviewsCheckbox, in: stack)

        let languageTitle = NSTextField(
            labelWithString: L10n.text("settings.language.title")
        )
        languageTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(languageTitle)
        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguageSelection)
        languagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        applyLanguageButton.bezelStyle = .rounded
        let languageRow = NSStackView(views: [languagePopup, applyLanguageButton])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 10
        stack.addArrangedSubview(languageRow)
        let languageNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.language.note")
        )
        languageNote.textColor = .secondaryLabelColor
        languageNote.font = .systemFont(ofSize: 11)
        languageNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(languageNote)
        groupRows(from: languageTitle, in: stack)

        let managementTitle = sectionTitle(L10n.text("settings.section.management"))
        stack.addArrangedSubview(managementTitle)
        let information = NSButton(title: L10n.text("information.title"), target: self, action: #selector(showAppInformation))
        information.bezelStyle = .rounded
        let removal = NSButton(title: L10n.text("cleanup.button"), target: self, action: #selector(showRemoval))
        removal.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views: [information, removal]))
        groupRows(from: managementTitle, in: stack)

        return stack
    }

    private func makeMovementSettingsView() -> NSView {
        let stack = makeSettingsStack()
        let replacement = SettingsSwitch(title: L10n.text("settings.replace.occupied"),
            target: self, action: #selector(changeOccupiedReplacement(_:)))
        replacement.state = AppSettings.shared.occupiedReplacementEnabled ? .on : .off
        stack.addArrangedSubview(replacement)
        stack.setCustomSpacing(4, after: replacement)
        stack.addArrangedSubview(note("settings.replace.note"))
        demo(.replace, title: replacement.title, from: replacement, in: stack)
        let subdivision = SettingsSwitch(title: L10n.text("settings.subdivide.title"),
            target: self, action: #selector(changeGroupSubdivision(_:)))
        subdivision.state = AppSettings.shared.groupSubdivisionEnabled ? .on : .off
        stack.addArrangedSubview(subdivision)
        stack.setCustomSpacing(4, after: subdivision)
        stack.addArrangedSubview(note("settings.subdivide.note"))
        demo(.subdivide, title: subdivision.title, from: subdivision, in: stack)
        restoreSizeOnMoveCheckbox.target = self
        restoreSizeOnMoveCheckbox.action = #selector(toggleRestoreSizeOnMove)
        stack.addArrangedSubview(restoreSizeOnMoveCheckbox)
        stack.setCustomSpacing(4, after: restoreSizeOnMoveCheckbox)
        stack.addArrangedSubview(note("settings.general.restore_size.note"))
        demo(.restore, title: restoreSizeOnMoveCheckbox.title, from: restoreSizeOnMoveCheckbox, in: stack)
        assistLayoutSwitchingCheckbox.target = self
        assistLayoutSwitchingCheckbox.action = #selector(
            toggleAssistLayoutSwitching
        )
        stack.addArrangedSubview(assistLayoutSwitchingCheckbox)
        stack.setCustomSpacing(4, after: assistLayoutSwitchingCheckbox)
        let assistLayoutNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.assist.note")
        )
        assistLayoutNote.textColor = .secondaryLabelColor
        assistLayoutNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(assistLayoutNote)
        demo(.assist, title: assistLayoutSwitchingCheckbox.title, from: assistLayoutSwitchingCheckbox, in: stack)
        return stack
    }

    private func makeResizeSettingsView() -> NSView {
        let stack = makeSettingsStack()
        linkedResizeCheckbox.target = self
        linkedResizeCheckbox.action = #selector(toggleLinkedResize)
        stack.addArrangedSubview(linkedResizeCheckbox)
        stack.setCustomSpacing(4, after: linkedResizeCheckbox)
        let linkedResizeNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.linked_resize.note")
        )
        linkedResizeNote.textColor = .secondaryLabelColor
        linkedResizeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(linkedResizeNote)
        demo(.resize(""), title: linkedResizeCheckbox.title, from: linkedResizeCheckbox, in: stack)

        linkedResizeOptionsStack.orientation = .vertical
        linkedResizeOptionsStack.alignment = .leading
        linkedResizeOptionsStack.spacing = 0

        raiseConnectedWindowsOnClickCheckbox.target = self
        raiseConnectedWindowsOnClickCheckbox.action = #selector(toggleRaiseConnectedWindowsOnClick)
        linkedResizeOptionsStack.addArrangedSubview(raiseConnectedWindowsOnClickCheckbox)
        linkedResizeOptionsStack.setCustomSpacing(4, after: raiseConnectedWindowsOnClickCheckbox)
        let raiseConnectedWindowsOnClickNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.raise_group.note")
        )
        raiseConnectedWindowsOnClickNote.textColor = .secondaryLabelColor
        raiseConnectedWindowsOnClickNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(raiseConnectedWindowsOnClickNote)
        demo(.raise, title: raiseConnectedWindowsOnClickCheckbox.title, from: raiseConnectedWindowsOnClickCheckbox, in: linkedResizeOptionsStack)

        let styleDescriptions: [(LinkedResizePresentationStyle, String, String)] = [
            (
                .mac,
                L10n.text("settings.general.resize_style.mac.title"),
                L10n.text("settings.general.resize_style.mac.detail")
            ),
            (
                .windows,
                L10n.text("settings.general.resize_style.windows.title"),
                L10n.text("settings.general.resize_style.windows.detail")
            ),
            (
                .combined,
                L10n.text("settings.general.resize_style.combined.title"),
                L10n.text("settings.general.resize_style.combined.detail")
            )
        ]
        for (value, title, detail) in styleDescriptions {
            stylePopup.addItem(withTitle: title)
            stylePopup.lastItem?.representedObject = value.rawValue
            stylePopup.lastItem?.toolTip = detail
        }
        addResizeMenu(stylePopup, title: L10n.text("settings.general.resize_style.title"), detail: styleDetail,
                      action: #selector(changeLinkedResizePresentationStyle(_:)), preview: "selectedStyle")
        resizeCursorAdornmentCheckbox.target = self
        resizeCursorAdornmentCheckbox.action = #selector(
            toggleResizeCursorAdornment
        )
        linkedResizeOptionsStack.addArrangedSubview(resizeCursorAdornmentCheckbox)
        linkedResizeOptionsStack.setCustomSpacing(4, after: resizeCursorAdornmentCheckbox)
        let resizeCursorAdornmentNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.resize_cursor.note")
        )
        resizeCursorAdornmentNote.textColor = .secondaryLabelColor
        resizeCursorAdornmentNote.font = .systemFont(ofSize: 11)
        resizeCursorAdornmentNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(resizeCursorAdornmentNote)
        demo(.resize("cursor"), title: resizeCursorAdornmentCheckbox.title, from: resizeCursorAdornmentCheckbox, in: linkedResizeOptionsStack)

        let resizeCursorAdornmentDistanceTitle = NSTextField(
            labelWithString: L10n.text("settings.general.resize_cursor.distance")
        )
        cursorDistanceTitle = resizeCursorAdornmentDistanceTitle
        resizeCursorAdornmentDistanceTitle.font = .systemFont(ofSize: 13, weight: .medium)
        linkedResizeOptionsStack.addArrangedSubview(resizeCursorAdornmentDistanceTitle)
        linkedResizeOptionsStack.setCustomSpacing(4, after: resizeCursorAdornmentDistanceTitle)
        resizeCursorAdornmentDistanceSlider.minValue = AppSettings
            .resizeCursorAdornmentDistanceRange.lowerBound
        resizeCursorAdornmentDistanceSlider.maxValue = AppSettings
            .resizeCursorAdornmentDistanceRange.upperBound
        resizeCursorAdornmentDistanceSlider.numberOfTickMarks = 9
        resizeCursorAdornmentDistanceSlider.allowsTickMarkValuesOnly = false
        resizeCursorAdornmentDistanceSlider.widthAnchor.constraint(
            equalToConstant: 260
        ).isActive = true
        resizeCursorAdornmentDistanceSlider.target = self
        resizeCursorAdornmentDistanceSlider.action = #selector(
            changeResizeCursorAdornmentDistance
        )
        let resizeCursorAdornmentDistanceStack = NSStackView(
            views: [resizeCursorAdornmentDistanceSlider, resizeCursorAdornmentDistanceValue]
        )
        resizeCursorAdornmentDistanceStack.orientation = .horizontal
        resizeCursorAdornmentDistanceStack.alignment = .centerY
        resizeCursorAdornmentDistanceStack.spacing = 10
        linkedResizeOptionsStack.addArrangedSubview(resizeCursorAdornmentDistanceStack)
        demo(.resize("cursor"), title: resizeCursorAdornmentDistanceTitle.stringValue, from: resizeCursorAdornmentDistanceTitle, in: linkedResizeOptionsStack)
        resizeCursorAdornmentDistanceSlider.isContinuous = true

        let modeDescriptions: [(LinkedResizeDisplayMode, String, String)] = [
            (.lightweight, L10n.text("settings.general.drag_display.lightweight.title"), L10n.text("settings.general.drag_display.lightweight.detail")),
            (.mainOnly, L10n.text("settings.general.drag_display.standard.title"), L10n.text("settings.general.drag_display.standard.detail")),
            (.allWindows, L10n.text("settings.general.drag_display.all.title"), L10n.text("settings.general.drag_display.all.detail"))
        ]
        for (value, title, detail) in modeDescriptions {
            modePopup.addItem(withTitle: title)
            modePopup.lastItem?.representedObject = value.rawValue
            modePopup.lastItem?.toolTip = detail
        }
        addResizeMenu(modePopup, title: L10n.text("settings.general.drag_display.title"), detail: modeDetail,
                      action: #selector(changeLinkedResizeDisplayMode(_:)), preview: "selectedMode")
        stack.addArrangedSubview(linkedResizeOptionsStack)
        linkedResizeOptionsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private func makeGestureSettingsView() -> NSView {
        let stack = makeSettingsStack()
        gestureToggle.target = self
        gestureToggle.action = #selector(changeGesture)
        stack.addArrangedSubview(gestureToggle)
        stack.setCustomSpacing(4, after: gestureToggle)
        stack.addArrangedSubview(note("settings.gesture.note"))
        demo(.eightWay, title: gestureToggle.title, from: gestureToggle, in: stack)
        gestureMaximizeToggle.target = self
        gestureMaximizeToggle.action = #selector(changeGestureMaximize)
        stack.addArrangedSubview(gestureMaximizeToggle)
        let maximizeNote = note("settings.gesture.maximize.note")
        gestureLabels.append(maximizeNote)
        stack.addArrangedSubview(maximizeNote)
        demo(.snap(CGRect(x: 0.03, y: 0.07, width: 0.94, height: 0.86)), title: gestureMaximizeToggle.title, from: gestureMaximizeToggle, in: stack)
        let lock = SettingsSwitch(title: L10n.text("settings.split_lock"), target: self,
                            action: #selector(changeSplitLock(_:)))
        splitLockCheckbox = lock
        stack.addArrangedSubview(lock)
        stack.setCustomSpacing(4, after: lock)
        let lockNote = note("settings.split_lock.note")
        gestureLabels.append(lockNote)
        stack.addArrangedSubview(lockNote)
        demo(.lock, title: lock.title, from: lock, in: stack)
        let reassign = SettingsSwitch(title: L10n.text("settings.gesture.reassign"), target: self,
                                      action: #selector(changeReassignment(_:)))
        reassignmentToggle = reassign
        stack.addArrangedSubview(reassign)
        let description = note("settings.gesture.reassign.note")
        reassignmentNote = description
        stack.addArrangedSubview(description)
        demo(.reassign, title: reassign.title, from: reassign, in: stack)
        return stack
    }

    private func makeDetectionSettingsView() -> NSView {
        let stack = makeSettingsStack()
        let detectionNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.drag_detection.note")
        )
        detectionNote.textColor = .secondaryLabelColor
        detectionNote.maximumNumberOfLines = 0
        let detectionNoteContainer = NSStackView(views: [detectionNote])
        detectionNoteContainer.edgeInsets = NSEdgeInsets(top: 6, left: 28, bottom: 6, right: 28)
        stack.addArrangedSubview(detectionNoteContainer)


        sideDwellExpansionCheckbox.target = self
        sideDwellExpansionCheckbox.action = #selector(toggleSideDwellExpansion)
        stack.addArrangedSubview(sideDwellExpansionCheckbox)
        demo(.dwell, title: sideDwellExpansionCheckbox.title, from: sideDwellExpansionCheckbox, in: stack)


        configureSlider(
            sideDwellDurationSlider,
            range: AppSettings.sideDwellDurationRange,
            action: #selector(changeSideDwellDuration(_:))
        )
        addDetectionRow(in: stack,
            title: L10n.text("settings.general.side_dwell.title"),
            detail: L10n.text("settings.general.side_dwell.note"),
            slider: sideDwellDurationSlider,
            valueLabel: sideDwellDurationValue
        )

        configureSlider(
            edgeThresholdSlider,
            range: AppSettings.edgeThresholdRange,
            action: #selector(changeEdgeThreshold(_:))
        )
        addDetectionRow(in: stack,
            title: L10n.text("settings.general.edge_range.title"),
            detail: L10n.text("settings.general.edge_range.note"),
            slider: edgeThresholdSlider,
            valueLabel: edgeThresholdValue
        )

        configureSlider(
            cornerBandSlider,
            range: AppSettings.cornerBandRange,
            action: #selector(changeCornerBand(_:))
        )
        addDetectionRow(in: stack,
            title: L10n.text("settings.general.corner_range.title"),
            detail: L10n.text("settings.general.corner_range.note"),
            slider: cornerBandSlider,
            valueLabel: cornerBandValue
        )

        let resetDetectionButton = NSButton(
            title: L10n.text("settings.general.drag_detection.reset"),
            target: self,
            action: #selector(resetDetectionSettings)
        )
        resetDetectionButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetDetectionButton)

        for row in stack.arrangedSubviews.compactMap({ $0 as? NSStackView }) where !(row is SettingsRow) {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(0, after: row)
        }
        return stack
    }

    private func makeCommandSettingsView() -> NSView {
        let stack = makeSettingsStack()
        let note = NSTextField(
            wrappingLabelWithString: L10n.text("settings.commands.note")
        )
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        stack.addArrangedSubview(note)

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            if action == .toggleSplitLock { gestureLabels.append(label) }
            let button = NSButton(
                title: L10n.text("common.not_set"),
                target: self,
                action: #selector(recordShortcut(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            shortcutButtons[action] = button

            let clearButton = NSButton(
                title: L10n.text("common.clear"),
                target: self,
                action: #selector(clearShortcut(_:))
            )
            clearButton.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            clearButton.bezelStyle = .rounded
            clearButton.widthAnchor.constraint(equalToConstant: 70).isActive = true
            clearButtons[action] = clearButton

            grid.addRow(with: [label, button, clearButton])
        }
        let titleWidth = ShortcutAction.allCases.map {
            NSTextField(labelWithString: $0.title).fittingSize.width
        }.max() ?? 0
        grid.column(at: 0).width = ceil(titleWidth)
        grid.column(at: 1).width = 150
        grid.column(at: 2).width = 70
        grid.widthAnchor.constraint(equalToConstant: ceil(titleWidth) + 240).isActive = true
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .leading
        stack.addArrangedSubview(grid)

        stack.addArrangedSubview(NSButton(
            title: L10n.text("settings.commands.clear_all"),
            target: self,
            action: #selector(clearShortcuts)
        ))

        return stack
    }

    private func makeTabRecordSettingsView() -> NSView {
        let stack = makeSettingsStack()
        stack.addArrangedSubview(sectionTitle(L10n.text("settings.constraints.title")))
        constraintPromptCheckbox.target = self
        constraintPromptCheckbox.action = #selector(toggleConstraintRecordingPrompts)
        stack.addArrangedSubview(constraintPromptCheckbox)
        let constraintNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.constraints.note")
        )
        constraintNote.textColor = .secondaryLabelColor
        constraintNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(constraintNote)
        groupRows(from: constraintPromptCheckbox, in: stack)

        constraintRecordsStack.orientation = .vertical
        constraintRecordsStack.alignment = .leading
        constraintRecordsStack.spacing = 0
        stack.addArrangedSubview(constraintRecordsStack)
        constraintRecordsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeExperimentalSettingsView() -> NSView {
        let stack = makeSettingsStack()

        missionControlGroupMigrationCheckbox.target = self
        missionControlGroupMigrationCheckbox.action = #selector(
            toggleMissionControlGroupMigration
        )
        stack.addArrangedSubview(missionControlGroupMigrationCheckbox)
        stack.setCustomSpacing(4, after: missionControlGroupMigrationCheckbox)
        let groupMigrationNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.experimental.group_migration.note")
        )
        groupMigrationLabels = [groupMigrationNote]
        groupMigrationNote.textColor = .secondaryLabelColor
        groupMigrationNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(groupMigrationNote)
        let verifiedEnvironment = NSTextField(
            wrappingLabelWithString: L10n.text("migration.verified_environment")
        )
        verifiedEnvironment.textColor = .secondaryLabelColor
        verifiedEnvironment.font = .systemFont(ofSize: 11)
        verifiedEnvironment.maximumNumberOfLines = 0
        stack.addArrangedSubview(verifiedEnvironment)
        missionControlGroupMigrationRuntimeStatus.font = .systemFont(
            ofSize: 11,
            weight: .medium
        )
        missionControlGroupMigrationRuntimeStatus.maximumNumberOfLines = 0
        stack.addArrangedSubview(missionControlGroupMigrationRuntimeStatus)
        groupRows(from: missionControlGroupMigrationCheckbox, in: stack)

        missionControlLatestPreviewCheckbox.target = self
        missionControlLatestPreviewCheckbox.action = #selector(toggleMissionControlLatestPreview)
        stack.addArrangedSubview(missionControlLatestPreviewCheckbox)
        stack.setCustomSpacing(4, after: missionControlLatestPreviewCheckbox)
        let latestPreviewNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.experimental.latest_preview.note")
        )
        groupPreviewLabels += [latestPreviewNote]
        latestPreviewNote.textColor = .secondaryLabelColor
        latestPreviewNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(latestPreviewNote)
        groupRows(from: missionControlLatestPreviewCheckbox, in: stack)

        let workspaceEdgeTitle = NSTextField(
            labelWithString: L10n.text("settings.experimental.workspace.title")
        )
        workspaceEdgeTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(workspaceEdgeTitle)
        let workspaceEdgeNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.experimental.workspace.note")
        )
        workspaceEdgeNote.textColor = .secondaryLabelColor
        workspaceEdgeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(workspaceEdgeNote)
        workspaceEdgeDelayStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(workspaceEdgeDelayStatus)
        let workspaceEdgeButtons = NSStackView(
            views: [delayWorkspaceEdgeButton, resetWorkspaceEdgeButton]
        )
        workspaceEdgeButtons.orientation = .horizontal
        workspaceEdgeButtons.spacing = 10
        stack.addArrangedSubview(workspaceEdgeButtons)
        groupRows(from: workspaceEdgeTitle, in: stack)


        let previewMemoryTitle = NSTextField(
            labelWithString: L10n.text("settings.experimental.preview.title")
        )
        previewMemoryTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(previewMemoryTitle)
        let previewMemoryNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.experimental.preview.note")
        )
        groupPreviewLabels += [previewMemoryTitle, previewMemoryNote]
        previewMemoryNote.textColor = .secondaryLabelColor
        previewMemoryNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(previewMemoryNote)

        previewMemoryLimitSlider.minValue = Double(
            AppSettings.missionControlPreviewMemoryLimitRange.lowerBound
        )
        previewMemoryLimitSlider.maxValue = Double(
            AppSettings.missionControlPreviewMemoryLimitRange.upperBound
        )
        previewMemoryLimitSlider.numberOfTickMarks = 8
        previewMemoryLimitSlider.allowsTickMarkValuesOnly = true
        previewMemoryLimitSlider.isContinuous = false
        previewMemoryLimitSlider.widthAnchor.constraint(
            equalToConstant: 300
        ).isActive = true
        previewMemoryLimitSlider.target = self
        previewMemoryLimitSlider.action = #selector(
            changeMissionControlPreviewMemoryLimit
        )
        previewMemoryLimitValue.alignment = .right
        previewMemoryLimitValue.font = .monospacedDigitSystemFont(
            ofSize: 12,
            weight: .regular
        )
        previewMemoryLimitValue.widthAnchor.constraint(
            equalToConstant: 70
        ).isActive = true
        let previewMemoryRow = NSStackView(
            views: [previewMemoryLimitSlider, previewMemoryLimitValue]
        )
        previewMemoryRow.orientation = .horizontal
        previewMemoryRow.alignment = .centerY
        previewMemoryRow.spacing = 12
        stack.addArrangedSubview(previewMemoryRow)
        stack.addArrangedSubview(clearPreviewCacheButton)
        groupRows(from: previewMemoryTitle, in: stack)
        for detail in [groupMigrationNote, latestPreviewNote, workspaceEdgeNote, previewMemoryNote] {
            detail.font = .systemFont(ofSize: 12)
        }
        for row in stack.arrangedSubviews.compactMap({ $0 as? SettingsRow }) {
            row.spacing = 5
            row.edgeInsets.top = 10
            row.edgeInsets.bottom = 10
        }

        return stack
    }

    private let groups: [(String, [SettingsCategory])] = [
        ("settings.group.application", [.general]),
        ("settings.group.layout", [.resize, .movement, .ratios, .tabRecords]),
        ("settings.group.input", [.gesture, .detection, .commands]),
        ("settings.category.experimental", [.experimental])
    ]

    private var rows: [(String, SettingsCategory?)] {
        groups.flatMap { key, categories in
            [(L10n.text(key), nil)] + categories.map { ($0.title, Optional($0)) }
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].1 == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].1 != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].1 == nil ? (row == 0 ? 26 : 20) : 32 }

    private struct PreviewItem {
        let anchor: SettingsRow
        let scene: DemoScene
        let title: String
    }

    private let previewPanel = NSView()
    private var previewHeight: NSLayoutConstraint!
    private var previewItems: [PreviewItem] = []
    private var currentPreview: Int?

    private func demo(_ scene: DemoScene, title: String, from first: NSView, in stack: NSStackView) {
        let index = previewItems.count
        let row = groupRows(from: first, in: stack)
        previewItems.append(PreviewItem(anchor: row, scene: scene, title: title))
        row.onEnter = { [weak self] in self?.displayPreview(index) }
    }

    @discardableResult
    private func groupRows(from first: NSView, in stack: NSStackView) -> SettingsRow {
        let row = SettingsRow()
        let views = stack.arrangedSubviews.drop(while: { $0 !== first })
        for view in Array(views) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
            row.addArrangedSubview(view)
            if view is SettingsSwitch || view is NSTextField {
                view.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -(row.edgeInsets.left + row.edgeInsets.right)).isActive = true
            }
        }
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(0, after: row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        return row
    }

    private func styleSettingGroups(_ view: NSView) {
        guard let stack = view as? NSStackView, stack.orientation == .vertical else { return }
        let children = stack.arrangedSubviews
        for (index, child) in children.enumerated() {
            guard let row = child as? SettingsRow else {
                styleSettingGroups(child)
                continue
            }
            let first = index == 0 || !(children[index - 1] is SettingsRow)
            let last = index + 1 == children.count || !(children[index + 1] is SettingsRow)
            row.configureEdges(first: first, last: last)
            stack.setCustomSpacing(last ? 9 : 0, after: row)
        }
    }

    private func displayPreview(_ index: Int?) {
        guard index != currentPreview else { return }
        if let previous = currentPreview { previewItems[previous].anchor.showsPreview = false }
        currentPreview = index
        if let index { previewItems[index].anchor.showsPreview = true }
        previewPanel.subviews.forEach { $0.removeFromSuperview() }
        previewHeight.constant = index == nil ? 0 : 180
        guard let index else { return }
        let item = previewItems[index]
        let caption = NSTextField(labelWithString: item.title)
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .secondaryLabelColor
        let host = NSHostingView(rootView: OperationPreview(scene: item.scene, title: item.title)
            .scaleEffect(1))
        previewPanel.wantsLayer = true
        previewPanel.layer?.cornerRadius = 10
        previewPanel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        for child in [caption, host] {
            child.translatesAutoresizingMaskIntoConstraints = false
            previewPanel.addSubview(child)
        }
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: host.bottomAnchor, constant: 5),
            caption.centerXAnchor.constraint(equalTo: previewPanel.centerXAnchor),
            host.centerXAnchor.constraint(equalTo: previewPanel.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: previewPanel.centerYAnchor, constant: -10)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let category = rows[row].1 else {
            let label = NSTextField(labelWithString: rows[row].0)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let header = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 15),
                label.centerYAnchor.constraint(equalTo: header.centerYAnchor)
            ])
            return header
        }
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: category.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        cell.toolTip = category.title
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.textField = label
        cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(navigation.selectedRow), let category = rows[navigation.selectedRow].1 else { return }
        finishRecording()
        showSettingsCategory(category, resetScroll: true)
    }

    private func showSettingsCategory(
        _ category: SettingsCategory,
        resetScroll: Bool
    ) {
        guard let view = categoryViews[category] else { return }
        selectedCategory = category
        heading.stringValue = category.title
        displayPreview(previewItems.firstIndex { $0.anchor.isDescendant(of: view) })

        NSLayoutConstraint.deactivate(categoryContentConstraints)
        categoryContentConstraints.removeAll()
        for subview in settingsDocumentView.subviews {
            subview.removeFromSuperview()
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        settingsDocumentView.addSubview(view)
        let inset: CGFloat = 20
        categoryContentConstraints = [
            view.leadingAnchor.constraint(equalTo: settingsDocumentView.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: settingsDocumentView.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: settingsDocumentView.topAnchor, constant: 8),
            view.bottomAnchor.constraint(
                lessThanOrEqualTo: settingsDocumentView.bottomAnchor, constant: -16
            )
        ]
        NSLayoutConstraint.activate(categoryContentConstraints)
        settingsDocumentView.layoutSubtreeIfNeeded()
        if resetScroll {
            positionScrollViewAtTop()
        }
    }

    private func configureSlider(_ slider: NSSlider, range: ClosedRange<Double>, action: Selector) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = 0
        slider.isContinuous = false
        slider.target = self
        slider.action = action
        slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    private func addDetectionRow(in stack: NSStackView,
        title: String,
        detail: String,
        slider: NSSlider,
        valueLabel: NSTextField
    ) {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.textColor = .secondaryLabelColor
        detailField.font = .systemFont(ofSize: 11)
        detailField.maximumNumberOfLines = 0
        if slider === sideDwellDurationSlider { dwellLabels = [titleField, detailField] }

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true

        let sliderRow = NSStackView(views: [slider, valueLabel])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 12

        for item in [titleField, detailField, sliderRow] as [NSView] { stack.addArrangedSubview(item) }
        let scene: DemoScene = slider === cornerBandSlider ? .corner : slider === edgeThresholdSlider ? .edge : .dwell
        demo(scene, title: title, from: titleField, in: stack)
    }

    private func addResizeMenu(_ menu: NSPopUpButton, title: String, detail: NSTextField,
                               action: Selector, preview: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let line = NSStackView()
        line.addView(label, in: .leading)
        line.addView(menu, in: .trailing)
        menu.setAccessibilityLabel(title)
        menu.target = self
        menu.action = action
        detail.textColor = .secondaryLabelColor
        linkedResizeOptionsStack.addArrangedSubview(line)
        linkedResizeOptionsStack.addArrangedSubview(detail)
        demo(.resize(preview), title: title, from: line, in: linkedResizeOptionsStack)
        if let row = line.superview as? SettingsRow {
            line.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -56).isActive = true
        }
    }


    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        return field
    }


    private func refresh() {
        refreshGestureOptions()
        if let index = AppLanguage.allCases.firstIndex(of: pendingLanguage) {
            languagePopup.selectItem(at: index)
        }
        applyLanguageButton.title = L10n.text(
            "settings.language.apply_restart",
            language: pendingLanguage
        )
        applyLanguageButton.isEnabled = pendingLanguage != L10n.language
        launchCheckbox.state = settings.launchAtLogin ? .on : .off
        windowPreviewsCheckbox.state = settings.windowPreviewsEnabled ? .on : .off
        restoreSizeOnMoveCheckbox.state = settings.restoreSnappedWindowSizeOnMove ? .on : .off
        linkedResizeCheckbox.state = settings.linkedResizeEnabled ? .on : .off
        raiseConnectedWindowsOnClickCheckbox.state = settings.raiseConnectedWindowsOnClick
            ? .on
            : .off
        raiseConnectedWindowsOnClickCheckbox.isEnabled = settings.linkedResizeEnabled
        for (menu, value, detail) in [
            (modePopup, settings.linkedResizeDisplayMode.rawValue, modeDetail),
            (stylePopup, settings.linkedResizePresentationStyle.rawValue, styleDetail)
        ] {
            menu.selectItem(at: menu.indexOfItem(withRepresentedObject: value))
            menu.isEnabled = settings.linkedResizeEnabled
            detail.stringValue = menu.selectedItem?.toolTip ?? ""
        }
        resizeCursorAdornmentCheckbox.state = settings
            .resizeCursorAdornmentEnabled ? .on : .off
        resizeCursorAdornmentCheckbox.isEnabled = settings
            .linkedResizeEnabled
        resizeCursorAdornmentDistanceSlider.doubleValue = settings
            .resizeCursorAdornmentDistance
        resizeCursorAdornmentDistanceSlider.isEnabled = settings.linkedResizeEnabled
            && settings.resizeCursorAdornmentEnabled
        resizeCursorAdornmentDistanceValue.stringValue = String(
            format: "%d pt",
            Int(settings.resizeCursorAdornmentDistance.rounded())
        )
        resizeCursorAdornmentDistanceValue.textColor = resizeCursorAdornmentDistanceSlider
            .isEnabled ? .labelColor : .tertiaryLabelColor
        linkedResizeOptionsStack.alphaValue = settings.linkedResizeEnabled
            ? 1
            : 0.45
        sideDwellExpansionCheckbox.state = settings.sideDwellExpansionEnabled ? .on : .off
        sideDwellDurationSlider.isEnabled = settings.sideDwellExpansionEnabled
        sideDwellDurationValue.textColor = settings.sideDwellExpansionEnabled ? .labelColor : .tertiaryLabelColor
        sideDwellDurationSlider.doubleValue = settings.sideDwellDuration
        sideDwellDurationValue.stringValue = L10n.format(
            "value.seconds",
            settings.sideDwellDuration
        )
        missionControlLatestPreviewCheckbox.state = settings
            .missionControlLatestPreviewEnabled ? .on : .off
        assistLayoutSwitchingCheckbox.state = settings
            .assistLayoutSwitchingEnabled ? .on : .off
        missionControlGroupMigrationCheckbox.state = settings
            .missionControlGroupMigrationEnabled ? .on : .off
        if let status = onMissionControlGroupMigrationRuntimeStatusRequest?() {
            missionControlGroupMigrationRuntimeStatus.stringValue = status
                .isAvailable
                ? L10n.text("settings.experimental.api_status.available")
                : L10n.text("settings.experimental.api_status.unavailable")
            missionControlGroupMigrationRuntimeStatus.textColor = status
                .isAvailable ? .secondaryLabelColor : .systemRed
            missionControlGroupMigrationRuntimeStatus.toolTip = status.detail
        } else {
            missionControlGroupMigrationRuntimeStatus.stringValue =
                L10n.text("settings.experimental.api_status.pending")
            missionControlGroupMigrationRuntimeStatus.textColor =
                .secondaryLabelColor
            missionControlGroupMigrationRuntimeStatus.toolTip = nil
        }
        edgeThresholdSlider.doubleValue = settings.edgeThreshold
        edgeThresholdValue.stringValue = "\(Int(settings.edgeThreshold.rounded())) pt"
        cornerBandSlider.doubleValue = settings.cornerBand
        cornerBandValue.stringValue = "\(Int(settings.cornerBand.rounded())) pt"
        constraintPromptCheckbox.state = settings.constraintRecordingPromptsEnabled
            ? .on
            : .off
        previewMemoryLimitSlider.doubleValue = Double(
            settings.missionControlPreviewMemoryLimitMiB
        )
        previewMemoryLimitValue.stringValue = String(
            format: "%d MiB",
            AppSettings.missionControlPreviewTotalMemoryLimitMiB(
                settings.missionControlPreviewMemoryLimitMiB
            )
        )
        for label in groupPreviewLabels { label.alphaValue = settings.groupPreviewAvailable ? 1 : 0.45 }
        for label in groupMigrationLabels { label.alphaValue = settings.linkedResizeEnabled ? 1 : 0.45 }
        for label in dwellLabels { label.alphaValue = settings.sideDwellExpansionEnabled ? 1 : 0.45 }
        cursorDistanceTitle?.alphaValue = settings.resizeCursorAdornmentEnabled || !settings.linkedResizeEnabled ? 1 : 0.45
        missionControlLatestPreviewCheckbox.isEnabled = settings.groupPreviewAvailable
        missionControlGroupMigrationCheckbox.isEnabled = settings.linkedResizeEnabled
        previewMemoryLimitSlider.isEnabled = settings.groupPreviewAvailable
        clearPreviewCacheButton.isEnabled = settings.windowPreviewsEnabled
        previewMemoryLimitValue.textColor = settings.groupPreviewAvailable
            ? .labelColor
            : .tertiaryLabelColor
        refreshConstraintRecords()

        let values = settings.shortcuts
        for action in ShortcutAction.allCases {
            let binding = values[action]
            shortcutButtons[action]?.title = binding?.displayText
                ?? L10n.text("common.not_set")
            clearButtons[action]?.isEnabled = binding != nil
        }
    }

    private func refreshConstraintRecords() {
        for view in constraintRecordsStack.arrangedSubviews {
            constraintRecordsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        constraintIdentitiesByControlID.removeAll()

        let records = constraintRegistry.records
        guard !records.isEmpty else {
            let empty = NSTextField(
                wrappingLabelWithString: L10n.text("settings.constraints.empty")
            )
            empty.textColor = .secondaryLabelColor
            constraintRecordsStack.addArrangedSubview(empty)
            return
        }

        for (index, record) in records.enumerated() {
            let controlID = "constraint-record-\(index)"
            constraintIdentitiesByControlID[controlID] = record.identity

            let appName = NSTextField(labelWithString: record.displayName)
            appName.font = .systemFont(ofSize: 13, weight: .semibold)
            appName.lineBreakMode = .byTruncatingMiddle
            appName.toolTip = record.displayName
            appName.lineBreakMode = .byTruncatingTail

            let hasPending = AppConstraintBound.allCases.contains {
                if case .candidate = record.state(for: $0) { return true }
                return false
            }
            if hasPending || record.candidateConflict || record.needsVerification {
                appName.stringValue += (
                    record.candidateConflict || record.needsVerification
                        ? L10n.text("settings.constraints.needs_review_suffix")
                        : L10n.text("settings.constraints.pending_suffix")
                )
            }

            let permissionButton = SettingsSwitch(title: L10n.text("settings.constraints.allow_recording"),
                target: self,
                action: #selector(changeConstraintPermission(_:))
            )
            permissionButton.control.identifier = NSUserInterfaceItemIdentifier(controlID)
            permissionButton.state = record.recordingPermission == .allowed ? .on : .off

            let verifyButton = NSButton(
                title: L10n.text("settings.constraints.measure"),
                target: self,
                action: #selector(acquireConstraintSizes(_:))
            )
            verifyButton.identifier = NSUserInterfaceItemIdentifier(controlID)
            verifyButton.isEnabled = !constraintMeasurementInProgress

            let inspectButton = NSButton(
                title: L10n.text("settings.constraints.inspect"),
                target: self,
                action: #selector(inspectConstraintRecord(_:))
            )
            inspectButton.identifier = NSUserInterfaceItemIdentifier(controlID)

            let deleteButton = NSButton(
                title: L10n.text("common.delete"),
                target: self,
                action: #selector(deleteConstraintRecord(_:))
            )
            deleteButton.identifier = NSUserInterfaceItemIdentifier(controlID)

            let buttons = NSStackView(
                views: [verifyButton, inspectButton, deleteButton]
            )
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8

            for control in [appName, permissionButton, buttons] as [NSView] {
                constraintRecordsStack.addArrangedSubview(control)
            }
            groupRows(from: appName, in: constraintRecordsStack)
        }
        styleSettingGroups(constraintRecordsStack)
    }

    private func constraintDisplayValue(_ value: CGFloat?) -> String {
        guard let value else { return L10n.text("settings.constraints.not_measured") }
        return String(format: "%.0f pt", value)
    }

    @objc private func changeLanguageSelection() {
        guard let rawValue = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else {
            pendingLanguage = L10n.language
            refresh()
            return
        }
        pendingLanguage = language
        applyLanguageButton.title = L10n.text(
            "settings.language.apply_restart",
            language: language
        )
        applyLanguageButton.isEnabled = language != L10n.language
    }

    @objc private func applyLanguage() {
        guard pendingLanguage != L10n.language else { return }
        guard !constraintMeasurementInProgress else {
            let alert = NSAlert()
            alert.messageText = L10n.text("settings.language.busy.title")
            alert.informativeText = L10n.text("settings.language.busy.detail")
            alert.runModal()
            return
        }
        guard onLanguageApply?(pendingLanguage) == true else {
            let alert = NSAlert()
            alert.messageText = L10n.text("settings.language.relaunch_failed.title")
            alert.informativeText = L10n.text("settings.language.relaunch_failed.detail")
            alert.runModal()
            return
        }
        applyLanguageButton.isEnabled = false
    }

    @objc private func toggleConstraintRecordingPrompts() {
        settings.constraintRecordingPromptsEnabled = constraintPromptCheckbox.state == .on
    }

    @objc private func changeConstraintPermission(_ sender: NSSwitch) {
        guard let identity = constraintIdentity(for: sender) else { return }
        constraintRegistry.setPermission(
            sender.state == .on ? .allowed : .denied,
            for: identity
        )
        refreshConstraintRecords()
    }

    @objc private func acquireConstraintSizes(_ sender: NSButton) {
        guard !constraintMeasurementInProgress,
              let identity = constraintIdentity(for: sender),
              let record = constraintRegistry.record(for: identity)
        else { return }

        let windows = constraintWindowService.visibleWindows()
            .filter { constraintWindowService.isEligibleForConstraintLearning($0) }
            .filter {
                constraintIdentityResolver.resolve($0)?.identity == identity
            }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        guard !windows.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.text("constraints.alert.window_unavailable.title")
            alert.informativeText = L10n.format(
                "constraints.alert.open_window.detail",
                record.displayName
            )
            alert.runModal()
            return
        }

        let window: ManagedWindow
        if windows.count == 1 {
            window = windows[0]
        } else {
            let selector = NSPopUpButton(
                frame: NSRect(x: 0, y: 0, width: 360, height: 26),
                pullsDown: false
            )
            var duplicateCounts: [String: Int] = [:]
            let displayTitles = windows.enumerated().map { index, item in
                let base = item.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let title = base.isEmpty
                    ? L10n.format("common.window_number", index + 1)
                    : base
                let nextCount = (duplicateCounts[title] ?? 0) + 1
                duplicateCounts[title] = nextCount
                return nextCount == 1 ? title : "\(title) (\(nextCount))"
            }
            selector.addItems(withTitles: displayTitles)

            let selectionAlert = NSAlert()
            selectionAlert.messageText = L10n.text("constraints.alert.select_window.title")
            selectionAlert.informativeText =
                L10n.text("constraints.alert.select_window.detail")
            selectionAlert.accessoryView = selector
            selectionAlert.addButton(withTitle: L10n.text("common.select"))
            selectionAlert.addButton(withTitle: L10n.text("common.cancel"))
            guard selectionAlert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let selectedIndex = max(0, selector.indexOfSelectedItem)
            guard windows.indices.contains(selectedIndex) else { return }
            window = windows[selectedIndex]
        }

        guard let screen = bestScreen(for: window.frame) else {
            let alert = NSAlert()
            alert.messageText = L10n.text("constraints.alert.window_unavailable.title")
            alert.informativeText =
                L10n.text("constraints.alert.display_unavailable.detail")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.text("settings.constraints.measure")
        alert.informativeText = L10n.text("constraints.alert.measure.detail")
        alert.addButton(withTitle: L10n.text("common.measure"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard onConstraintMeasurementWillBegin?(window.stableIdentity) ?? true else {
            let busy = NSAlert()
            busy.messageText = L10n.text("constraints.alert.busy.title")
            busy.informativeText =
                L10n.text("constraints.alert.busy.detail")
            busy.runModal()
            return
        }

        constraintMeasurementInProgress = true
        constraintMeasurementOperationActive = true
        constraintMeasurementProgressPanel.begin(
            displayName: record.displayName,
            screen: screen
        ) { [weak self] in
            guard let self else { return }
            self.constraintMeasurementInProgress = false
            self.refreshConstraintRecords()
        }
        refreshConstraintRecords()
        constraintMeasurementEngine.measure(
            window: window,
            screenFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor,
            progress: { [weak self] progress in
                self?.constraintMeasurementProgressPanel.update(progress)
            }
        ) { [weak self] result in
            guard let self else { return }
            self.constraintMeasurementOperationActive = false
            self.constraintRegistry.applyExplicitMeasurement(
                result.confirmedValues,
                identity: identity,
                displayName: record.displayName
            )
            self.onConstraintMeasurementDidEnd?()
            self.refreshConstraintRecords()
            self.constraintMeasurementProgressPanel.finish(
                confirmedValueCount: result.confirmedValues.count,
                restoredOriginalFrame: result.restoredOriginalFrame
            )
        }
    }

    @objc private func inspectConstraintRecord(_ sender: NSButton) {
        guard let identity = constraintIdentity(for: sender),
              let record = constraintRegistry.record(for: identity)
        else { return }

        let labels = [
            L10n.text("constraint.bound.min_width"),
            L10n.text("constraint.bound.min_height"),
            L10n.text("constraint.bound.max_width"),
            L10n.text("constraint.bound.max_height")
        ].map {
            NSTextField(labelWithString: $0)
        }
        let values = AppConstraintBound.allCases.map { bound -> NSTextField in
            let value = NSTextField(
                labelWithString: constraintDisplayValue(
                    record.knownValue(for: bound)
                )
            )
            value.alignment = .right
            value.font = .monospacedDigitSystemFont(
                ofSize: 12,
                weight: .regular
            )
            value.widthAnchor.constraint(equalToConstant: 110).isActive = true
            return value
        }
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        for index in values.indices {
            grid.addRow(with: [labels[index], values[index]])
        }

        // NSAlert does not derive an accessory view's outer size from the
        // accessory's Auto Layout content. Give it a concrete container so
        // the value grid cannot collapse to a zero-sized mystery panel.
        let valuePanel = NSView(
            frame: NSRect(x: 0, y: 0, width: 250, height: 112)
        )
        valuePanel.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: valuePanel.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: valuePanel.trailingAnchor),
            grid.topAnchor.constraint(equalTo: valuePanel.topAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: valuePanel.bottomAnchor, constant: -4)
        ])

        let alert = NSAlert()
        alert.messageText = L10n.format(
            "constraints.alert.values.title",
            record.displayName
        )
        alert.informativeText = L10n.text("constraints.alert.values.detail")
        alert.accessoryView = valuePanel
        alert.addButton(withTitle: L10n.text("common.close"))
        alert.runModal()
    }

    @objc private func deleteConstraintRecord(_ sender: NSButton) {
        guard let identity = constraintIdentity(for: sender),
              let record = constraintRegistry.record(for: identity)
        else { return }
        let alert = NSAlert()
        alert.messageText = L10n.format(
            "constraints.alert.delete.title",
            record.displayName
        )
        alert.addButton(withTitle: L10n.text("common.delete"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        constraintRegistry.deleteRecord(identity: identity)
        refreshConstraintRecords()
    }

    private func constraintIdentity(for sender: NSControl) -> AppConstraintIdentity? {
        guard let key = sender.identifier?.rawValue else { return nil }
        return constraintIdentitiesByControlID[key]
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let lhsArea = lhs.visibleFrame.intersection(frame)
            let rhsArea = rhs.visibleFrame.intersection(frame)
            let lhsValue = lhsArea.isNull ? 0 : lhsArea.width * lhsArea.height
            let rhsValue = rhsArea.isNull ? 0 : rhsArea.width * rhsArea.height
            return lhsValue < rhsValue
        }
    }

    @objc private func changeEdgeThreshold(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        settings.edgeThreshold = value
        edgeThresholdValue.stringValue = "\(Int(value)) pt"
    }

    @objc private func changeCornerBand(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        settings.cornerBand = value
        cornerBandValue.stringValue = "\(Int(value)) pt"
    }

    @objc private func changeSideDwellDuration(_ sender: NSSlider) {
        let value = (sender.doubleValue * 10).rounded() / 10
        settings.sideDwellDuration = value
        sideDwellDurationValue.stringValue = L10n.format("value.seconds", value)
    }

    @objc private func toggleSideDwellExpansion() {
        settings.sideDwellExpansionEnabled = sideDwellExpansionCheckbox.state == .on
        refresh()
    }

    @objc private func resetDetectionSettings() {
        settings.resetDragDetectionSettings()
        refresh()
    }

    @objc private func showAppInformation() {
        if informationWindow == nil {
            informationWindow = InitialSetupWindowController(presentation: .review)
        }
        informationWindow?.showWindow(nil)
    }

    @objc private func showRemoval() {
        guard !constraintMeasurementInProgress, !constraintMeasurementOperationActive else {
            let alert = NSAlert()
            alert.messageText = L10n.text("settings.language.busy.title")
            alert.informativeText = L10n.text("cleanup.busy")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("cleanup.title")
        alert.informativeText = L10n.text("cleanup.note")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 470, height: 28))
        AppRemovalChoice.allCases.forEach { popup.addItem(withTitle: $0.title) }
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.text("cleanup.cancel"))
        alert.addButton(withTitle: L10n.text("setup.continue"))
        guard alert.runModal() == .alertSecondButtonReturn,
              let choice = AppRemovalChoice(rawValue: popup.indexOfSelectedItem) else { return }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = choice.title
        let domain = Bundle.main.bundleIdentifier ?? "unbundled"
        confirmation.informativeText = L10n.text("cleanup.note") + "\n\n" + domain
            + (choice == .everything ? "\n" + Bundle.main.bundleURL.path : "")
        confirmation.addButton(withTitle: L10n.text("cleanup.cancel"))
        confirmation.addButton(withTitle: L10n.text("cleanup.confirm"))
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }
        onRemoval?(choice)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try settings.setLaunchAtLogin(launchCheckbox.state == .on)
        } catch {
            launchCheckbox.state = settings.launchAtLogin ? .on : .off
            let alert = NSAlert()
            alert.messageText = L10n.text("settings.general.launch_at_login.error.title")
            alert.informativeText = L10n.text("settings.general.launch_at_login.error.detail")
            alert.runModal()
        }
    }

    @objc private func toggleWindowPreviews() {
        let enabled = windowPreviewsCheckbox.state == .on
        if enabled {
            // Preview capture is optional derived presentation. Request Screen
            // Recording only from this explicit user action; background proxy
            // maintenance must never surprise the user with a permission request.
            _ = CGRequestScreenCaptureAccess()
        }
        settings.windowPreviewsEnabled = enabled
        refresh()
    }

    @objc private func changeMissionControlPreviewMemoryLimit() {
        guard settings.groupPreviewAvailable else { return }
        let value = AppSettings.normalizedMissionControlPreviewMemoryLimitMiB(
            Int(previewMemoryLimitSlider.doubleValue.rounded())
        )
        settings.missionControlPreviewMemoryLimitMiB = value
        onMissionControlPreviewMemoryLimitChange?(value)
        refresh()
    }

    @objc private func toggleMissionControlLatestPreview() {
        guard settings.groupPreviewAvailable else { return }
        settings.missionControlLatestPreviewEnabled =
            missionControlLatestPreviewCheckbox.state == .on
    }

    @objc private func toggleAssistLayoutSwitching() {
        settings.assistLayoutSwitchingEnabled =
            assistLayoutSwitchingCheckbox.state == .on
        refresh()
    }

    @objc private func toggleMissionControlGroupMigration() {
        guard settings.linkedResizeEnabled else { return }
        settings.missionControlGroupMigrationEnabled =
            missionControlGroupMigrationCheckbox.state == .on
        refresh()
    }

    @objc private func clearMissionControlPreviewCache() {
        guard settings.windowPreviewsEnabled else { return }
        onMissionControlPreviewCacheClear?()
    }

    @objc private func toggleRestoreSizeOnMove() {
        settings.restoreSnappedWindowSizeOnMove = restoreSizeOnMoveCheckbox.state == .on
    }

    @objc private func toggleLinkedResize() {
        settings.linkedResizeEnabled = linkedResizeCheckbox.state == .on
        refresh()
    }

    @objc private func toggleRaiseConnectedWindowsOnClick() {
        settings.raiseConnectedWindowsOnClick = raiseConnectedWindowsOnClickCheckbox.state == .on
        refresh()
    }

    @objc private func toggleResizeCursorAdornment() {
        settings.resizeCursorAdornmentEnabled =
            resizeCursorAdornmentCheckbox.state == .on
        refresh()
    }

    @objc private func changeResizeCursorAdornmentDistance() {
        let value = resizeCursorAdornmentDistanceSlider.doubleValue.rounded()
        settings.resizeCursorAdornmentDistance = value
        refresh()
    }

    @objc private func changeLinkedResizeDisplayMode(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = LinkedResizeDisplayMode(rawValue: rawValue) else {
            refresh()
            return
        }
        settings.linkedResizeDisplayMode = mode
        refresh()
    }

    @objc private func changeLinkedResizePresentationStyle(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let style = LinkedResizePresentationStyle(rawValue: rawValue) else {
            refresh()
            return
        }
        settings.linkedResizePresentationStyle = style
        refresh()
    }

    @objc private func applyWorkspaceEdgeDelay() {
        guard confirmWorkspaceMutation(
            message: L10n.text("workspace.confirm_delay.title"),
            detail: L10n.text("workspace.confirm_delay.detail")
        ) else { return }
        setWorkspaceButtonsEnabled(false)
        experimentalWorkspaceSettings.applyDelayedEdgeSwitching {
            [weak self] result in
            self?.finishWorkspaceMutation(result)
        }
    }

    @objc private func resetWorkspaceEdgeDelay() {
        guard confirmWorkspaceMutation(
            message: L10n.text("workspace.confirm_reset.title"),
            detail: L10n.text("workspace.confirm_reset.detail")
        ) else { return }
        setWorkspaceButtonsEnabled(false)
        experimentalWorkspaceSettings.restoreDefaultEdgeSwitching {
            [weak self] result in
            self?.finishWorkspaceMutation(result)
        }
    }

    private func refreshExperimentalWorkspaceState() {
        setWorkspaceButtonsEnabled(false)
        workspaceEdgeDelayStatus.stringValue = L10n.text(
            "settings.experimental.workspace.status.checking"
        )
        experimentalWorkspaceSettings.readEdgeDelay { [weak self] result in
            self?.finishWorkspaceMutation(result, showsFailureAlert: false)
        }
    }

    private func finishWorkspaceMutation(
        _ result: Result<Double?, Error>,
        showsFailureAlert: Bool = true
    ) {
        setWorkspaceButtonsEnabled(true)
        switch result {
        case .success(let value):
            if let value {
                workspaceEdgeDelayStatus.stringValue = L10n.format(
                    "settings.experimental.workspace.status.value",
                    value
                )
            } else {
                workspaceEdgeDelayStatus.stringValue = L10n.text(
                    "settings.experimental.workspace.status.default"
                )
            }
        case .failure(let error):
            workspaceEdgeDelayStatus.stringValue = L10n.text(
                "settings.experimental.workspace.status.unavailable"
            )
            guard showsFailureAlert else { return }
            let alert = NSAlert()
            alert.messageText = L10n.text("workspace.error.title")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func setWorkspaceButtonsEnabled(_ enabled: Bool) {
        delayWorkspaceEdgeButton.isEnabled = enabled
        resetWorkspaceEdgeButton.isEnabled = enabled
    }

    private func confirmWorkspaceMutation(
        message: String,
        detail: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("common.change"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func clearShortcuts() {
        settings.shortcuts = [:]
        refresh()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: raw) else { return }
        var shortcuts = settings.shortcuts
        shortcuts.removeValue(forKey: action)
        settings.shortcuts = shortcuts
        refresh()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: raw), settings.shortcutAvailable(action) else { return }
        recordingAction = action
        sender.title = L10n.text("settings.commands.press_key")
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingAction else { return event }
            if event.keyCode == 53 {
                self.finishRecording()
                return nil
            }
            let allowed: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let modifiers = event.modifierFlags.intersection(allowed)
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }
            let binding = ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers.rawValue))
            var shortcuts = self.settings.shortcuts
            for (otherAction, otherBinding) in shortcuts where otherBinding == binding && otherAction != action {
                shortcuts.removeValue(forKey: otherAction)
            }
            shortcuts[action] = binding
            self.settings.shortcuts = shortcuts
            self.finishRecording()
            return nil
        }
    }

    private func finishRecording() {
        recordingAction = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        refresh()
    }

    private func positionScrollViewAtTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            guard let documentView = self.scrollView.documentView else { return }
            documentView.layoutSubtreeIfNeeded()
            let clipView = self.scrollView.contentView
            let targetOrigin = SettingsScrollGeometry.topOrigin(
                documentBounds: documentView.bounds,
                viewportBounds: clipView.bounds,
                isFlipped: documentView.isFlipped
            )
            let proposedBounds = CGRect(
                origin: targetOrigin,
                size: clipView.bounds.size
            )
            clipView.scroll(to: clipView.constrainBoundsRect(proposedBounds).origin)
            self.scrollView.reflectScrolledClipView(clipView)
        }
    }
}

private final class FlippedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}


private final class SettingsSidebar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(srgbRed: dark ? 0.17 : 0.969, green: dark ? 0.17 : 0.969,
                blue: dark ? 0.18 : 0.975, alpha: 1).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}
