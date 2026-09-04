import AppKit
import CoreGraphics

enum SettingsCategory: Int, CaseIterable {
    case general
    case commands
    case tabRecords
    case experimental

    var title: String {
        switch self {
        case .general: return L10n.text("settings.category.general")
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

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    var onConstraintMeasurementWillBegin: (() -> Bool)?
    var onConstraintMeasurementDidEnd: (() -> Void)?
    var onMissionControlPreviewMemoryLimitChange: ((Int) -> Void)?
    var onMissionControlPreviewCacheClear: (() -> Void)?
    var onMissionControlGroupMigrationRuntimeStatusRequest:
        (() -> GroupSpaceMigrationRuntimeStatus?)?
    var onLanguageApply: ((AppLanguage) -> Bool)?
    private let settings = AppSettings.shared
    private let experimentalWorkspaceSettings = ExperimentalWorkspaceSettings.shared
    private let scrollView = NSScrollView()
    private let settingsDocumentView = FlippedSettingsDocumentView()
    private lazy var categoryControl = NSSegmentedControl(
        labels: SettingsCategory.allCases.map(\.title),
        trackingMode: .selectOne,
        target: self,
        action: #selector(changeSettingsCategory(_:))
    )
    private var categoryViews: [SettingsCategory: NSView] = [:]
    private var categoryContentConstraints: [NSLayoutConstraint] = []
    private var selectedCategory: SettingsCategory = .general
    private var recordingAction: ShortcutAction?
    private var keyMonitor: Any?
    private var shortcutButtons: [ShortcutAction: NSButton] = [:]
    private var clearButtons: [ShortcutAction: NSButton] = [:]
    private var resizeModeButtons: [LinkedResizeDisplayMode: NSButton] = [:]
    private var resizeStyleButtons: [LinkedResizePresentationStyle: NSButton] = [:]
    private let linkedResizeOptionsStack = NSStackView()
    private let launchCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.general.launch_at_login"),
        target: nil,
        action: nil
    )
    private let windowPreviewsCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.general.show_window_previews"),
        target: nil,
        action: nil
    )
    private let languagePopup = NSPopUpButton()
    private lazy var applyLanguageButton = NSButton(
        title: L10n.text("settings.language.apply_restart"),
        target: self,
        action: #selector(applyLanguage)
    )
    private var pendingLanguage = L10n.language
    private let missionControlGroupMigrationCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.experimental.group_migration.checkbox"),
        target: nil,
        action: nil
    )
    private let missionControlGroupMigrationRuntimeStatus = NSTextField(
        labelWithString: L10n.text("settings.experimental.api_status.pending")
    )
    private let restoreSizeOnMoveCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.general.restore_size.checkbox"),
        target: nil,
        action: nil
    )
    private let linkedResizeCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.general.linked_resize.checkbox"),
        target: nil,
        action: nil
    )
    private let raiseConnectedWindowsOnClickCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.general.raise_group.checkbox"),
        target: nil,
        action: nil
    )
    private let resizeCursorAdornmentCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.general.resize_cursor.checkbox"),
        target: nil,
        action: nil
    )
    private let resizeCursorAdornmentDistanceSlider = NSSlider()
    private let resizeCursorAdornmentDistanceValue = NSTextField(labelWithString: "")
    private let edgeThresholdSlider = NSSlider()
    private let edgeThresholdValue = NSTextField(labelWithString: "")
    private let cornerBandSlider = NSSlider()
    private let cornerBandValue = NSTextField(labelWithString: "")
    private let sideDwellExpansionCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.general.side_dwell.checkbox"),
        target: nil,
        action: nil
    )
    private let sideDwellDurationSlider = NSSlider()
    private let sideDwellDurationValue = NSTextField(labelWithString: "")
    private let assistLayoutSwitchingCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.experimental.assist.checkbox"),
        target: nil,
        action: nil
    )
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
    private let constraintPromptCheckbox = NSButton(
        checkboxWithTitle: L10n.text("settings.constraints.confirm_new"),
        target: nil,
        action: nil
    )
    private let constraintRecordsStack = NSStackView()
    private var constraintIdentitiesByControlID: [String: AppConstraintIdentity] = [:]
    private var constraintMeasurementInProgress = false
    private var constraintMeasurementOperationActive = false

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 580, height: 820),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? L10n.text("common.development")
        window.title = L10n.format("settings.window.title", version)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
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

    func show() {
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

        categoryControl.translatesAutoresizingMaskIntoConstraints = false
        categoryControl.segmentStyle = .rounded
        categoryControl.selectedSegment = selectedCategory.rawValue
        content.addSubview(categoryControl)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            categoryControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            categoryControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            categoryControl.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 28),
            categoryControl.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: categoryControl.bottomAnchor, constant: 14),
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
            .commands: makeCommandSettingsView(),
            .tabRecords: makeTabRecordSettingsView(),
            .experimental: makeExperimentalSettingsView()
        ]
        showSettingsCategory(selectedCategory, resetScroll: false)
    }

    private func makeSettingsStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    private func makeGeneralSettingsView() -> NSView {
        let stack = makeSettingsStack()
        stack.addArrangedSubview(sectionTitle(L10n.text("settings.category.general")))
        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunchAtLogin)
        stack.addArrangedSubview(launchCheckbox)

        windowPreviewsCheckbox.target = self
        windowPreviewsCheckbox.action = #selector(toggleWindowPreviews)
        stack.addArrangedSubview(windowPreviewsCheckbox)
        let previewNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.preview_note")
        )
        previewNote.textColor = .secondaryLabelColor
        previewNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(previewNote)

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

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle(L10n.text("settings.general.window_movement")))
        restoreSizeOnMoveCheckbox.target = self
        restoreSizeOnMoveCheckbox.action = #selector(toggleRestoreSizeOnMove)
        stack.addArrangedSubview(restoreSizeOnMoveCheckbox)
        let restoreSizeNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.restore_size.note")
        )
        restoreSizeNote.textColor = .secondaryLabelColor
        restoreSizeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(restoreSizeNote)

        linkedResizeCheckbox.target = self
        linkedResizeCheckbox.action = #selector(toggleLinkedResize)
        stack.addArrangedSubview(linkedResizeCheckbox)
        let linkedResizeNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.linked_resize.note")
        )
        linkedResizeNote.textColor = .secondaryLabelColor
        linkedResizeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(linkedResizeNote)

        linkedResizeOptionsStack.orientation = .vertical
        linkedResizeOptionsStack.alignment = .leading
        linkedResizeOptionsStack.spacing = 10
        linkedResizeOptionsStack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: 18,
            bottom: 0,
            right: 0
        )

        let linkedResizeAvailabilityNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.linked_resize.options_note")
        )
        linkedResizeAvailabilityNote.textColor = .secondaryLabelColor
        linkedResizeAvailabilityNote.font = .systemFont(ofSize: 11)
        linkedResizeAvailabilityNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(linkedResizeAvailabilityNote)

        raiseConnectedWindowsOnClickCheckbox.target = self
        raiseConnectedWindowsOnClickCheckbox.action = #selector(toggleRaiseConnectedWindowsOnClick)
        linkedResizeOptionsStack.addArrangedSubview(raiseConnectedWindowsOnClickCheckbox)
        let raiseConnectedWindowsOnClickNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.raise_group.note")
        )
        raiseConnectedWindowsOnClickNote.textColor = .secondaryLabelColor
        raiseConnectedWindowsOnClickNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(raiseConnectedWindowsOnClickNote)

        let presentationStyleTitle = NSTextField(
            labelWithString: L10n.text("settings.general.resize_style.title")
        )
        presentationStyleTitle.font = .systemFont(ofSize: 13, weight: .medium)
        linkedResizeOptionsStack.addArrangedSubview(presentationStyleTitle)

        let presentationStyleStack = NSStackView()
        presentationStyleStack.orientation = .vertical
        presentationStyleStack.alignment = .leading
        presentationStyleStack.spacing = 7
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
        for (style, title, detail) in styleDescriptions {
            let button = NSButton(
                radioButtonWithTitle: title,
                target: self,
                action: #selector(changeLinkedResizePresentationStyle(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(style.rawValue)
            resizeStyleButtons[style] = button
            let optionStack = NSStackView()
            optionStack.orientation = .vertical
            optionStack.alignment = .leading
            optionStack.spacing = 2
            optionStack.addArrangedSubview(button)
            let note = NSTextField(wrappingLabelWithString: detail)
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 11)
            note.maximumNumberOfLines = 0
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 500).isActive = true
            optionStack.addArrangedSubview(note)
            presentationStyleStack.addArrangedSubview(optionStack)
        }
        linkedResizeOptionsStack.addArrangedSubview(presentationStyleStack)
        let presentationStyleNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.resize_style.note")
        )
        presentationStyleNote.textColor = .secondaryLabelColor
        presentationStyleNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(presentationStyleNote)

        resizeCursorAdornmentCheckbox.target = self
        resizeCursorAdornmentCheckbox.action = #selector(
            toggleResizeCursorAdornment
        )
        linkedResizeOptionsStack.addArrangedSubview(
            resizeCursorAdornmentCheckbox
        )
        let resizeCursorAdornmentNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.resize_cursor.note")
        )
        resizeCursorAdornmentNote.textColor = .secondaryLabelColor
        resizeCursorAdornmentNote.font = .systemFont(ofSize: 11)
        resizeCursorAdornmentNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(resizeCursorAdornmentNote)

        let resizeCursorAdornmentDistanceTitle = NSTextField(
            labelWithString: L10n.text("settings.general.resize_cursor.distance")
        )
        resizeCursorAdornmentDistanceTitle.font = .systemFont(ofSize: 13, weight: .medium)
        linkedResizeOptionsStack.addArrangedSubview(resizeCursorAdornmentDistanceTitle)
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

        let displayModeTitle = NSTextField(
            labelWithString: L10n.text("settings.general.drag_display.title")
        )
        displayModeTitle.font = .systemFont(ofSize: 13, weight: .medium)
        linkedResizeOptionsStack.addArrangedSubview(displayModeTitle)

        let displayModeStack = NSStackView()
        displayModeStack.orientation = .vertical
        displayModeStack.alignment = .leading
        displayModeStack.spacing = 7
        let modeDescriptions: [(LinkedResizeDisplayMode, String, String)] = [
            (.lightweight, L10n.text("settings.general.drag_display.lightweight.title"), L10n.text("settings.general.drag_display.lightweight.detail")),
            (.mainOnly, L10n.text("settings.general.drag_display.standard.title"), L10n.text("settings.general.drag_display.standard.detail")),
            (.allWindows, L10n.text("settings.general.drag_display.all.title"), L10n.text("settings.general.drag_display.all.detail"))
        ]
        for (mode, title, detail) in modeDescriptions {
            let button = NSButton(
                radioButtonWithTitle: "\(title) — \(detail)",
                target: self,
                action: #selector(changeLinkedResizeDisplayMode(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            resizeModeButtons[mode] = button
            displayModeStack.addArrangedSubview(button)
        }
        linkedResizeOptionsStack.addArrangedSubview(displayModeStack)
        let displayModeNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.drag_display.note")
        )
        displayModeNote.textColor = .secondaryLabelColor
        displayModeNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(displayModeNote)

        stack.addArrangedSubview(linkedResizeOptionsStack)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle(L10n.text("settings.general.drag_detection.title")))
        let detectionNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.general.drag_detection.note")
        )
        detectionNote.textColor = .secondaryLabelColor
        detectionNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(detectionNote)

        sideDwellExpansionCheckbox.target = self
        sideDwellExpansionCheckbox.action = #selector(toggleSideDwellExpansion)
        stack.addArrangedSubview(sideDwellExpansionCheckbox)

        configureSlider(
            sideDwellDurationSlider,
            range: AppSettings.sideDwellDurationRange,
            action: #selector(changeSideDwellDuration(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: L10n.text("settings.general.side_dwell.title"),
            detail: L10n.text("settings.general.side_dwell.note"),
            slider: sideDwellDurationSlider,
            valueLabel: sideDwellDurationValue
        ))

        configureSlider(
            edgeThresholdSlider,
            range: AppSettings.edgeThresholdRange,
            action: #selector(changeEdgeThreshold(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: L10n.text("settings.general.edge_range.title"),
            detail: L10n.text("settings.general.edge_range.note"),
            slider: edgeThresholdSlider,
            valueLabel: edgeThresholdValue
        ))

        configureSlider(
            cornerBandSlider,
            range: AppSettings.cornerBandRange,
            action: #selector(changeCornerBand(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: L10n.text("settings.general.corner_range.title"),
            detail: L10n.text("settings.general.corner_range.note"),
            slider: cornerBandSlider,
            valueLabel: cornerBandValue
        ))

        let resetDetectionButton = NSButton(
            title: L10n.text("settings.general.drag_detection.reset"),
            target: self,
            action: #selector(resetDetectionSettings)
        )
        resetDetectionButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetDetectionButton)

        return stack
    }

    private func makeCommandSettingsView() -> NSView {
        let stack = makeSettingsStack()
        stack.addArrangedSubview(sectionTitle(L10n.text("settings.category.commands")))
        let note = NSTextField(
            wrappingLabelWithString: L10n.text("settings.commands.note")
        )
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        stack.addArrangedSubview(note)

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            let button = NSButton(
                title: L10n.text("common.not_set"),
                target: self,
                action: #selector(recordShortcut(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            shortcutButtons[action] = button

            let clearButton = NSButton(
                title: L10n.text("common.clear"),
                target: self,
                action: #selector(clearShortcut(_:))
            )
            clearButton.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            clearButton.bezelStyle = .rounded
            clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
            clearButtons[action] = clearButton

            grid.addRow(with: [label, button, clearButton])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .fill
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

        constraintRecordsStack.orientation = .vertical
        constraintRecordsStack.alignment = .leading
        constraintRecordsStack.spacing = 12
        stack.addArrangedSubview(constraintRecordsStack)
        return stack
    }

    private func makeExperimentalSettingsView() -> NSView {
        let stack = makeSettingsStack()
        stack.addArrangedSubview(sectionTitle(L10n.text("settings.category.experimental")))

        let groupMigrationTitle = NSTextField(
            labelWithString: L10n.text("settings.experimental.group_migration.title")
        )
        groupMigrationTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(groupMigrationTitle)
        missionControlGroupMigrationCheckbox.target = self
        missionControlGroupMigrationCheckbox.action = #selector(
            toggleMissionControlGroupMigration
        )
        stack.addArrangedSubview(missionControlGroupMigrationCheckbox)
        let groupMigrationNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.experimental.group_migration.note")
        )
        groupMigrationNote.textColor = .secondaryLabelColor
        groupMigrationNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(groupMigrationNote)
        let verifiedEnvironment = NSTextField(
            wrappingLabelWithString: GroupSpaceMigrationRuntimeStatus
                .verifiedEnvironmentDescription
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
        stack.addArrangedSubview(separator())

        let assistLayoutTitle = NSTextField(
            labelWithString: L10n.text("settings.experimental.assist.title")
        )
        assistLayoutTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(assistLayoutTitle)
        assistLayoutSwitchingCheckbox.target = self
        assistLayoutSwitchingCheckbox.action = #selector(
            toggleAssistLayoutSwitching
        )
        stack.addArrangedSubview(assistLayoutSwitchingCheckbox)
        let assistLayoutNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.experimental.assist.note")
        )
        assistLayoutNote.textColor = .secondaryLabelColor
        assistLayoutNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(assistLayoutNote)
        stack.addArrangedSubview(separator())

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

        stack.addArrangedSubview(separator())

        let previewMemoryTitle = NSTextField(
            labelWithString: L10n.text("settings.experimental.preview.title")
        )
        previewMemoryTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(previewMemoryTitle)
        let previewMemoryNote = NSTextField(
            wrappingLabelWithString: L10n.text("settings.experimental.preview.note")
        )
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

        return stack
    }

    @objc private func changeSettingsCategory(_ sender: NSSegmentedControl) {
        guard let category = SettingsCategory(rawValue: sender.selectedSegment) else {
            return
        }
        finishRecording()
        showSettingsCategory(category, resetScroll: true)
    }

    private func showSettingsCategory(
        _ category: SettingsCategory,
        resetScroll: Bool
    ) {
        guard let view = categoryViews[category] else { return }
        selectedCategory = category
        categoryControl.selectedSegment = category.rawValue

        NSLayoutConstraint.deactivate(categoryContentConstraints)
        categoryContentConstraints.removeAll()
        for subview in settingsDocumentView.subviews {
            subview.removeFromSuperview()
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        settingsDocumentView.addSubview(view)
        categoryContentConstraints = [
            view.leadingAnchor.constraint(equalTo: settingsDocumentView.leadingAnchor, constant: 28),
            view.trailingAnchor.constraint(equalTo: settingsDocumentView.trailingAnchor, constant: -28),
            view.topAnchor.constraint(equalTo: settingsDocumentView.topAnchor, constant: 22),
            view.bottomAnchor.constraint(
                lessThanOrEqualTo: settingsDocumentView.bottomAnchor,
                constant: -26
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

    private func settingRow(
        title: String,
        detail: String,
        slider: NSSlider,
        valueLabel: NSTextField
    ) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.textColor = .secondaryLabelColor
        detailField.font = .systemFont(ofSize: 11)
        detailField.maximumNumberOfLines = 0

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true

        let sliderRow = NSStackView(views: [slider, valueLabel])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 12

        let stack = NSStackView(views: [titleField, detailField, sliderRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 17, weight: .semibold)
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return box
    }

    private func refresh() {
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
        for (mode, button) in resizeModeButtons {
            button.state = settings.linkedResizeDisplayMode == mode ? .on : .off
            button.isEnabled = settings.linkedResizeEnabled
        }
        for (style, button) in resizeStyleButtons {
            button.state = settings.linkedResizePresentationStyle == style ? .on : .off
            button.isEnabled = settings.linkedResizeEnabled
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
        let previewControlsAreEnabled = settings.windowPreviewsEnabled
        previewMemoryLimitSlider.isEnabled = previewControlsAreEnabled
        clearPreviewCacheButton.isEnabled = previewControlsAreEnabled
        previewMemoryLimitValue.textColor = previewControlsAreEnabled
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
            appName.widthAnchor.constraint(equalToConstant: 140).isActive = true

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

            let permissionButton = NSButton(
                checkboxWithTitle: L10n.text("settings.constraints.allow_recording"),
                target: self,
                action: #selector(changeConstraintPermission(_:))
            )
            permissionButton.identifier = NSUserInterfaceItemIdentifier(controlID)
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
                views: [permissionButton, verifyButton, inspectButton, deleteButton]
            )
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8

            let row = NSStackView(
                views: [appName, buttons]
            )
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
            constraintRecordsStack.addArrangedSubview(row)
        }
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

    @objc private func changeConstraintPermission(_ sender: NSButton) {
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

        guard onConstraintMeasurementWillBegin?() ?? true else {
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
            self.onConstraintMeasurementDidEnd?()
            self.constraintRegistry.applyExplicitMeasurement(
                result.confirmedValues,
                identity: identity,
                displayName: record.displayName
            )
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

    private func constraintIdentity(for sender: NSButton) -> AppConstraintIdentity? {
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
        let value = AppSettings.normalizedMissionControlPreviewMemoryLimitMiB(
            Int(previewMemoryLimitSlider.doubleValue.rounded())
        )
        settings.missionControlPreviewMemoryLimitMiB = value
        onMissionControlPreviewMemoryLimitChange?(value)
        refresh()
    }

    @objc private func toggleAssistLayoutSwitching() {
        settings.assistLayoutSwitchingEnabled =
            assistLayoutSwitchingCheckbox.state == .on
        refresh()
    }

    @objc private func toggleMissionControlGroupMigration() {
        settings.missionControlGroupMigrationEnabled =
            missionControlGroupMigrationCheckbox.state == .on
        refresh()
    }

    @objc private func clearMissionControlPreviewCache() {
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

    @objc private func changeLinkedResizeDisplayMode(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let mode = LinkedResizeDisplayMode(rawValue: rawValue) else {
            refresh()
            return
        }
        settings.linkedResizeDisplayMode = mode
        refresh()
    }

    @objc private func changeLinkedResizePresentationStyle(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
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
              let action = ShortcutAction(rawValue: raw) else { return }
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
