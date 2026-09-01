import AppKit
import CoreGraphics

enum SettingsCategory: Int, CaseIterable {
    case general
    case commands
    case tabRecords
    case experimental

    var title: String {
        switch self {
        case .general: return "一般"
        case .commands: return "コマンド"
        case .tabRecords: return "サイズ制約"
        case .experimental: return "試験的機能"
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
    private let launchCheckbox = NSButton(checkboxWithTitle: "ログイン時にTaboraを起動", target: nil, action: nil)
    private let windowPreviewsCheckbox = NSButton(
        checkboxWithTitle: "配置候補にウィンドウ画像を表示",
        target: nil,
        action: nil
    )
    private let missionControlGroupMigrationCheckbox = NSButton(
        checkboxWithTitle: "Mission Controlでグループを別Desktopへ移動",
        target: nil,
        action: nil
    )
    private let missionControlGroupMigrationRuntimeStatus = NSTextField(
        labelWithString: "現在のAPI状態: 確認待ち"
    )
    private let restoreSizeOnMoveCheckbox = NSButton(
        checkboxWithTitle: "移動時にスナップ前のサイズへ戻す",
        target: nil,
        action: nil
    )
    private let linkedResizeCheckbox = NSButton(
        checkboxWithTitle: "分割ウィンドウを一緒にリサイズ",
        target: nil,
        action: nil
    )
    private let raiseConnectedWindowsOnClickCheckbox = NSButton(
        checkboxWithTitle: "スナップ中のウィンドウ選択による最前面移動",
        target: nil,
        action: nil
    )
    private let resizeCursorAdornmentCheckbox = NSButton(
        checkboxWithTitle: "カーソル付近にリサイズ方向を表示",
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
        checkboxWithTitle: "左右端で待つと上下半分を四隅へ切り替える",
        target: nil,
        action: nil
    )
    private let sideDwellDurationSlider = NSSlider()
    private let sideDwellDurationValue = NSTextField(labelWithString: "")
    private let assistLayoutSwitchingCheckbox = NSButton(
        checkboxWithTitle: "4分割Assistを3分割へ切り替える",
        target: nil,
        action: nil
    )
    private let workspaceEdgeDelayStatus = NSTextField(labelWithString: "確認中…")
    private lazy var delayWorkspaceEdgeButton = NSButton(
        title: "Space移動を60秒まで遅延",
        target: self,
        action: #selector(applyWorkspaceEdgeDelay)
    )
    private lazy var resetWorkspaceEdgeButton = NSButton(
        title: "デフォルトに戻す",
        target: self,
        action: #selector(resetWorkspaceEdgeDelay)
    )
    private let previewMemoryLimitSlider = NSSlider()
    private let previewMemoryLimitValue = NSTextField(labelWithString: "")
    private lazy var clearPreviewCacheButton = NSButton(
        title: "画像キャッシュを解放",
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
        checkboxWithTitle: "新しいサイズ制約を確認",
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
        ) as? String ?? "Development"
        window.title = "Tabora \(version) 設定"
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
        stack.addArrangedSubview(sectionTitle("一般"))
        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunchAtLogin)
        stack.addArrangedSubview(launchCheckbox)

        windowPreviewsCheckbox.target = self
        windowPreviewsCheckbox.action = #selector(toggleWindowPreviews)
        stack.addArrangedSubview(windowPreviewsCheckbox)
        let previewNote = NSTextField(
            wrappingLabelWithString: "画面収録の許可が必要です。画像は保存・送信しません。"
        )
        previewNote.textColor = .secondaryLabelColor
        previewNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(previewNote)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("ウィンドウ移動"))
        restoreSizeOnMoveCheckbox.target = self
        restoreSizeOnMoveCheckbox.action = #selector(toggleRestoreSizeOnMove)
        stack.addArrangedSubview(restoreSizeOnMoveCheckbox)
        let restoreSizeNote = NSTextField(
            wrappingLabelWithString: "スナップしたウィンドウを動かすと、元の大きさに戻します。"
        )
        restoreSizeNote.textColor = .secondaryLabelColor
        restoreSizeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(restoreSizeNote)

        linkedResizeCheckbox.target = self
        linkedResizeCheckbox.action = #selector(toggleLinkedResize)
        stack.addArrangedSubview(linkedResizeCheckbox)
        let linkedResizeNote = NSTextField(
            wrappingLabelWithString: "選択した操作方式で共有境界を動かすと、隣のウィンドウも一緒にサイズが変わります。"
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
            wrappingLabelWithString: "以下の設定は、分割ウィンドウの連動リサイズがオンのときだけ使用されます。"
        )
        linkedResizeAvailabilityNote.textColor = .secondaryLabelColor
        linkedResizeAvailabilityNote.font = .systemFont(ofSize: 11)
        linkedResizeAvailabilityNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(linkedResizeAvailabilityNote)

        raiseConnectedWindowsOnClickCheckbox.target = self
        raiseConnectedWindowsOnClickCheckbox.action = #selector(toggleRaiseConnectedWindowsOnClick)
        linkedResizeOptionsStack.addArrangedSubview(raiseConnectedWindowsOnClickCheckbox)
        let raiseConnectedWindowsOnClickNote = NSTextField(
            wrappingLabelWithString: "デスクトップ上でスナップ中のウィンドウを通常クリックした時だけ、接続されているウィンドウも一緒に最前面へ移動します。Mission Controlやアプリ切替による単体選択は維持されます。"
        )
        raiseConnectedWindowsOnClickNote.textColor = .secondaryLabelColor
        raiseConnectedWindowsOnClickNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(raiseConnectedWindowsOnClickNote)

        let presentationStyleTitle = NSTextField(
            labelWithString: "共有リサイズの操作表示"
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
                "つまみ表示（mac風）",
                "通常は中央のつまみだけを表示します。交点がある分割では交点操作を優先します。"
            ),
            (
                .windows,
                "共有境界表示（Windows風）",
                "中央のつまみを表示せず、共有境界を線で表示します。境界のどこからでも一緒にリサイズできます。"
            ),
            (
                .combined,
                "つまみ＋共有境界表示（推奨）",
                "中央のつまみと細い共有境界線を表示します。境界のどこからでも一緒にリサイズできます。"
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
            wrappingLabelWithString: "共有リサイズ処理は3方式で共通です。交点では1つの操作領域だけが入力を受け取ります。"
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
            wrappingLabelWithString: "通常のカーソルは変更せず、共有境界の上だけ固定サイズの方向表示を添えます。カーソルを大きくしている場合は間隔を広げられます。"
        )
        resizeCursorAdornmentNote.textColor = .secondaryLabelColor
        resizeCursorAdornmentNote.font = .systemFont(ofSize: 11)
        resizeCursorAdornmentNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(resizeCursorAdornmentNote)

        let resizeCursorAdornmentDistanceTitle = NSTextField(
            labelWithString: "カーソルからの距離"
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

        let displayModeTitle = NSTextField(labelWithString: "ドラッグ中の表示")
        displayModeTitle.font = .systemFont(ofSize: 13, weight: .medium)
        linkedResizeOptionsStack.addArrangedSubview(displayModeTitle)

        let displayModeStack = NSStackView()
        displayModeStack.orientation = .vertical
        displayModeStack.alignment = .leading
        displayModeStack.spacing = 7
        let modeDescriptions: [(LinkedResizeDisplayMode, String, String)] = [
            (.lightweight, "軽量", "すべてアイコンで表示"),
            (.mainOnly, "標準", "操作中のウィンドウだけ内容を表示"),
            (.allWindows, "すべて表示", "すべてのウィンドウ内容を表示")
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
            wrappingLabelWithString: "表示するウィンドウが多いほど、動作が重くなる場合があります。"
        )
        displayModeNote.textColor = .secondaryLabelColor
        displayModeNote.maximumNumberOfLines = 0
        linkedResizeOptionsStack.addArrangedSubview(displayModeNote)

        stack.addArrangedSubview(linkedResizeOptionsStack)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("ドラッグ判定"))
        let detectionNote = NSTextField(wrappingLabelWithString: "画面の端や四隅が反応する範囲を調整します。")
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
            title: "四分割に切り替わるまで",
            detail: "待機後は左右半分をなくし、上下50%ずつを四隅として選択します。",
            slider: sideDwellDurationSlider,
            valueLabel: sideDwellDurationValue
        ))

        configureSlider(
            edgeThresholdSlider,
            range: AppSettings.edgeThresholdRange,
            action: #selector(changeEdgeThreshold(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: "画面端の反応範囲",
            detail: "大きくすると、端から少し離れていても反応します。",
            slider: edgeThresholdSlider,
            valueLabel: edgeThresholdValue
        ))

        configureSlider(
            cornerBandSlider,
            range: AppSettings.cornerBandRange,
            action: #selector(changeCornerBand(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: "四隅の反応範囲",
            detail: "大きくすると、左右分割より四分割を選びやすくなります。",
            slider: cornerBandSlider,
            valueLabel: cornerBandValue
        ))

        let resetDetectionButton = NSButton(title: "ドラッグ判定を標準に戻す", target: self, action: #selector(resetDetectionSettings))
        resetDetectionButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetDetectionButton)

        return stack
    }

    private func makeCommandSettingsView() -> NSView {
        let stack = makeSettingsStack()
        stack.addArrangedSubview(sectionTitle("コマンド"))
        let note = NSTextField(wrappingLabelWithString: "ボタンを押してキーを入力します。Escでキャンセルできます。")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        stack.addArrangedSubview(note)

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            let button = NSButton(title: "未設定", target: self, action: #selector(recordShortcut(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            shortcutButtons[action] = button

            let clearButton = NSButton(title: "消去", target: self, action: #selector(clearShortcut(_:)))
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

        stack.addArrangedSubview(NSButton(title: "すべてのショートカットを消去", target: self, action: #selector(clearShortcuts)))

        return stack
    }

    private func makeTabRecordSettingsView() -> NSView {
        let stack = makeSettingsStack()
        stack.addArrangedSubview(sectionTitle("アプリ別のサイズ制約"))
        constraintPromptCheckbox.target = self
        constraintPromptCheckbox.action = #selector(toggleConstraintRecordingPrompts)
        stack.addArrangedSubview(constraintPromptCheckbox)
        let constraintNote = NSTextField(
            wrappingLabelWithString: "確認済みの制約を、配置と共有リサイズに使用します。"
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
        stack.addArrangedSubview(sectionTitle("試験的機能"))

        let groupMigrationTitle = NSTextField(
            labelWithString: "グループのDesktop間移送"
        )
        groupMigrationTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(groupMigrationTitle)
        missionControlGroupMigrationCheckbox.target = self
        missionControlGroupMigrationCheckbox.action = #selector(
            toggleMissionControlGroupMigration
        )
        stack.addArrangedSubview(missionControlGroupMigrationCheckbox)
        let groupMigrationNote = NSTextField(
            wrappingLabelWithString: "Mission ControlでTaboraのグループ画像を別Desktopへドロップすると移動予約になり、所属する実ウィンドウ画像にも予約済みの影を表示します。Mission Controlを閉じた後に実ウィンドウをまとめて移送し、複数グループは表示された順番で一件ずつ処理します。非公開APIを使用するため、既定ではオフです。"
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
            labelWithString: "2 / 3 / 4分割Assist切り替え"
        )
        assistLayoutTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(assistLayoutTitle)
        assistLayoutSwitchingCheckbox.target = self
        assistLayoutSwitchingCheckbox.action = #selector(
            toggleAssistLayoutSwitching
        )
        stack.addArrangedSubview(assistLayoutSwitchingCheckbox)
        let assistLayoutNote = NSTextField(
            wrappingLabelWithString: "Option（⌥）を押している間、隣接する四隅2枚の残りを1つへ統合できます。また、左右または上下の半分が1枚だけ配置され、異なる2ウィンドウを残り領域へ配置できる場合は、その領域を2つへ分けた3分割候補を表示します。"
        )
        assistLayoutNote.textColor = .secondaryLabelColor
        assistLayoutNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(assistLayoutNote)
        stack.addArrangedSubview(separator())

        let workspaceEdgeTitle = NSTextField(
            labelWithString: "画面端でのSpace移動を遅延"
        )
        workspaceEdgeTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(workspaceEdgeTitle)
        let workspaceEdgeNote = NSTextField(
            wrappingLabelWithString: "macOS全体の未公開Preferenceを変更します。将来のmacOSでは動作しない可能性があり、適用時にDockが再起動します。Tabora終了時には元へ戻しません。"
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
            labelWithString: "Mission Control画像メモリ"
        )
        previewMemoryTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(previewMemoryTitle)
        let previewMemoryNote = NSTextField(
            wrappingLabelWithString: "ウィンドウ画像に使用するメモリ上限です。上限を増やすと、多数のウィンドウでも画像を高精細に保ちやすくなります。変更時は既存キャッシュだけを解放し、安全な通常画面で再取得します。"
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
        sideDwellDurationValue.stringValue = String(format: "%.1f 秒", settings.sideDwellDuration)
        assistLayoutSwitchingCheckbox.state = settings
            .assistLayoutSwitchingEnabled ? .on : .off
        missionControlGroupMigrationCheckbox.state = settings
            .missionControlGroupMigrationEnabled ? .on : .off
        if let status = onMissionControlGroupMigrationRuntimeStatusRequest?() {
            missionControlGroupMigrationRuntimeStatus.stringValue = status
                .isAvailable
                ? "現在のAPI状態: 利用可能"
                : "現在のAPI状態: 利用不可（機能をオフにしてください）"
            missionControlGroupMigrationRuntimeStatus.textColor = status
                .isAvailable ? .secondaryLabelColor : .systemRed
            missionControlGroupMigrationRuntimeStatus.toolTip = status.detail
        } else {
            missionControlGroupMigrationRuntimeStatus.stringValue =
                "現在のAPI状態: 確認待ち"
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
            settings.missionControlPreviewMemoryLimitMiB
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
            shortcutButtons[action]?.title = binding?.displayText ?? "未設定"
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
                wrappingLabelWithString: "記録されたアプリはありません。"
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
                        ? "（要確認）"
                        : "（確認待ち）"
                )
            }

            let permissionButton = NSButton(
                checkboxWithTitle: "記録を許可",
                target: self,
                action: #selector(changeConstraintPermission(_:))
            )
            permissionButton.identifier = NSUserInterfaceItemIdentifier(controlID)
            permissionButton.state = record.recordingPermission == .allowed ? .on : .off

            let verifyButton = NSButton(
                title: "サイズを取得",
                target: self,
                action: #selector(acquireConstraintSizes(_:))
            )
            verifyButton.identifier = NSUserInterfaceItemIdentifier(controlID)
            verifyButton.isEnabled = !constraintMeasurementInProgress

            let inspectButton = NSButton(
                title: "値を確認",
                target: self,
                action: #selector(inspectConstraintRecord(_:))
            )
            inspectButton.identifier = NSUserInterfaceItemIdentifier(controlID)

            let deleteButton = NSButton(
                title: "削除",
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
        guard let value else { return "未取得" }
        return String(format: "%.0f pt", value)
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
            alert.messageText = "対象ウィンドウを確認できません"
            alert.informativeText = "\(record.displayName) の標準ウィンドウを開いてから、もう一度実行してください。"
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
                let title = base.isEmpty ? "ウィンドウ \(index + 1)" : base
                let nextCount = (duplicateCounts[title] ?? 0) + 1
                duplicateCounts[title] = nextCount
                return nextCount == 1 ? title : "\(title) (\(nextCount))"
            }
            selector.addItems(withTitles: displayTitles)

            let selectionAlert = NSAlert()
            selectionAlert.messageText = "対象ウィンドウを選択"
            selectionAlert.informativeText =
                "サイズを取得するウィンドウを選んでください。"
            selectionAlert.accessoryView = selector
            selectionAlert.addButton(withTitle: "選択")
            selectionAlert.addButton(withTitle: "キャンセル")
            guard selectionAlert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let selectedIndex = max(0, selector.indexOfSelectedItem)
            guard windows.indices.contains(selectedIndex) else { return }
            window = windows[selectedIndex]
        }

        guard let screen = bestScreen(for: window.frame) else {
            let alert = NSAlert()
            alert.messageText = "対象ウィンドウを確認できません"
            alert.informativeText =
                "対象ウィンドウがあるディスプレイを確認できませんでした。"
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "サイズを取得"
        alert.informativeText = "ウィンドウを動かして最小・最大サイズを取得します。"
        alert.addButton(withTitle: "取得する")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard onConstraintMeasurementWillBegin?() ?? true else {
            let busy = NSAlert()
            busy.messageText = "操作の完了後にもう一度実行してください"
            busy.informativeText =
                "スナップやリサイズなどの操作中はサイズを取得できません。"
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

        let labels = ["最小幅", "最小高", "最大幅", "最大高"].map {
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
        alert.messageText = "\(record.displayName) の制約値"
        alert.informativeText = "現在保存されている値です。更新は「サイズを取得」から行います。"
        alert.accessoryView = valuePanel
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
    }

    @objc private func deleteConstraintRecord(_ sender: NSButton) {
        guard let identity = constraintIdentity(for: sender),
              let record = constraintRegistry.record(for: identity)
        else { return }
        let alert = NSAlert()
        alert.messageText = "\(record.displayName) の記録を削除しますか？"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
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
        sideDwellDurationValue.stringValue = String(format: "%.1f 秒", value)
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
            alert.messageText = "ログイン項目を変更できませんでした"
            alert.informativeText = error.localizedDescription
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
            message: "Space移動の発火を60秒まで遅らせますか？",
            detail: "macOS全体の設定を変更し、Dockを再起動します。"
        ) else { return }
        setWorkspaceButtonsEnabled(false)
        experimentalWorkspaceSettings.applyDelayedEdgeSwitching {
            [weak self] result in
            self?.finishWorkspaceMutation(result)
        }
    }

    @objc private func resetWorkspaceEdgeDelay() {
        guard confirmWorkspaceMutation(
            message: "Space移動の遅延をデフォルトに戻しますか？",
            detail: "未公開Preferenceが存在する場合は削除し、Dockを再起動します。"
        ) else { return }
        setWorkspaceButtonsEnabled(false)
        experimentalWorkspaceSettings.restoreDefaultEdgeSwitching {
            [weak self] result in
            self?.finishWorkspaceMutation(result)
        }
    }

    private func refreshExperimentalWorkspaceState() {
        setWorkspaceButtonsEnabled(false)
        workspaceEdgeDelayStatus.stringValue = "現在値を確認中…"
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
                workspaceEdgeDelayStatus.stringValue = String(
                    format: "現在の遅延: %.1f秒",
                    value
                )
            } else {
                workspaceEdgeDelayStatus.stringValue = "現在の遅延: macOSデフォルト"
            }
        case .failure(let error):
            workspaceEdgeDelayStatus.stringValue = "現在値を確認できません"
            guard showsFailureAlert else { return }
            let alert = NSAlert()
            alert.messageText = "Workspace設定を変更できませんでした"
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
        alert.addButton(withTitle: "変更する")
        alert.addButton(withTitle: "キャンセル")
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
        sender.title = "キーを入力…"
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
