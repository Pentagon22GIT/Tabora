import AppKit
import ApplicationServices

@main
final class TaboraApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var applicationHasStarted = false
    private var needsInitialSetup = false
    private var needsAppInformationNotice = false
    private var setupWindow: InitialSetupWindowController?
    private var statusItem: NSStatusItem!
    private lazy var controller = SnapController()
    private lazy var splitLockNotice = SplitLockNotice()
    private let gestures = TrackpadSnapMonitor()
    private let shortcutManager = GlobalShortcutManager()
    private var settingsWindowIsVisible = false
    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.gestureRegistrationPending = { [weak self] in
            self?.controller.retryGestureRegistration != nil
        }
        controller.onVisibilityChange = { [weak self] isVisible in
            self?.settingsWindowIsVisible = isVisible
            self?.controller.setApplicationUIVisible(isVisible)
        }
        controller.onConstraintMeasurementWillBegin = { [weak self] identity in
            self?.controller.beginConstraintMeasurement(windowIdentity: identity) ?? false
        }
        controller.onConstraintMeasurementDidEnd = { [weak self] in
            self?.controller.endConstraintMeasurement()
        }
        controller.onMissionControlPreviewMemoryLimitChange = { [weak self] value in
            self?.controller.setMissionControlPreviewMemoryLimitMiB(value)
        }
        controller.onMissionControlPreviewCacheClear = { [weak self] in
            self?.controller.clearMissionControlPreviewCache()
        }
        controller.onMissionControlGroupMigrationRuntimeStatusRequest = {
            [weak self] in
            self?.controller.groupSpaceMigrationRuntimeStatus
        }
        controller.onLanguageApply = { [weak self] language in
            self?.relaunch(using: language) ?? false
        }
        controller.onRemoval = { [weak self] choice in self?.removeApplicationData(choice) }
        return controller
    }()
    private var gestureObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var groupSpaceMigrationAPIAlertIsPresented = false

    static func main() {
        let app = NSApplication.shared
        let domain = Bundle.main.bundleIdentifier
        let recordURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tabora")
            .appendingPathComponent(domain ?? "unbundled")
            .appendingPathComponent("constraints-v1.json")
        let needsSetup = InstallationLifecycle.needsSetup(
            domain: domain, hasExistingRecords: FileManager.default.fileExists(atPath: recordURL.path)
        )
        if let domain, InstallationLifecycle.domains.contains(domain) {
            AppSettings.shared.initializeAssistPreference(newInstallation: needsSetup)
        }
        let delegate = TaboraApp()
        delegate.needsInitialSetup = needsSetup
        delegate.needsAppInformationNotice = AppInformationNotice.needsPresentation(domain: domain)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != currentPID }
            if alreadyRunning {
                NSApplication.shared.terminate(nil)
                return
            }
        }

        if needsInitialSetup || needsAppInformationNotice {
            let setup = InitialSetupWindowController(
                presentation: needsInitialSetup ? .initialSetup : .informationUpdate
            )
            setupWindow = setup
            setup.onComplete = { [weak self] in
                self?.setupWindow = nil
                self?.startApplication()
            }
            setup.showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        startApplication()
    }

    private func startApplication() {
        guard !applicationHasStarted else { return }
        applicationHasStarted = true
        gestures.target = { [weak self] in
            guard let c = self?.controller, c.canAcceptGestureSnap else { return nil }
            return c.windowService.windowServerSelectionSnapshot()
        }
        gestures.snap = { [weak self] zone, selection, press in
            guard AppSettings.shared.gestureSnapEnabled else { return }
            self?.controller.snapFocusedWindow(to: zone, input: .gesture, expecting: selection, optionPress: press)
        }
        gestureObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.gestureDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.configureGesture()
            self?.configureShortcuts()
        }
        controller.recoverShortcutRegistration = { [weak self] in self?.shortcutManager.retryMissingBindingsIfDue() }
        configureStatusItem()
        configureShortcuts()
        controller.onGroupSpaceMigrationAPIUnavailable = { [weak self] notice in
            self?.presentGroupSpaceMigrationAPIUnavailableAlert(notice)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.configureShortcuts() }
        controller.start()
        configureGesture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        gestures.stop()
        if let gestureObserver { NotificationCenter.default.removeObserver(gestureObserver) }
        if applicationHasStarted { controller.stop() }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Tabora")

        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("menu.pause"), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("zone.left_half"), action: #selector(snapLeft), keyEquivalent: "").representedObject = ShortcutAction.leftHalf
        menu.addItem(withTitle: L10n.text("zone.right_half"), action: #selector(snapRight), keyEquivalent: "").representedObject = ShortcutAction.rightHalf
        menu.addItem(withTitle: L10n.text("zone.top_half"), action: #selector(snapTop), keyEquivalent: "").representedObject = ShortcutAction.topHalf
        menu.addItem(withTitle: L10n.text("zone.bottom_half"), action: #selector(snapBottom), keyEquivalent: "").representedObject = ShortcutAction.bottomHalf
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("zone.top_left"), action: #selector(snapTopLeft), keyEquivalent: "").representedObject = ShortcutAction.topLeft
        menu.addItem(withTitle: L10n.text("zone.top_right"), action: #selector(snapTopRight), keyEquivalent: "").representedObject = ShortcutAction.topRight
        menu.addItem(withTitle: L10n.text("zone.bottom_left"), action: #selector(snapBottomLeft), keyEquivalent: "").representedObject = ShortcutAction.bottomLeft
        menu.addItem(withTitle: L10n.text("zone.bottom_right"), action: #selector(snapBottomRight), keyEquivalent: "").representedObject = ShortcutAction.bottomRight
        menu.addItem(withTitle: L10n.text("zone.maximize"), action: #selector(maximize), keyEquivalent: "").representedObject = ShortcutAction.maximize
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("command.restore_last"), action: #selector(restoreLast), keyEquivalent: "").representedObject = ShortcutAction.restoreLast
        menu.addItem(withTitle: L10n.text("menu.clear_locks"), action: #selector(clearLocks), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.text("menu.detach_window"),
            action: #selector(detachFocusedWindowFromGroup),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.check_updates"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L10n.text("menu.open_accessibility"), action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("menu.reset_state"), action: #selector(resetState), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Self.updateShortcutHints(in: menu, bindings: AppSettings.shared.shortcuts)
    }

    static func updateShortcutHints(in menu: NSMenu, bindings: [ShortcutAction: ShortcutBinding]) {
        for item in menu.items {
            guard let action = item.representedObject as? ShortcutAction else { continue }
            let binding = bindings[action]
            let equivalent = binding?.menuKeyEquivalent
            item.keyEquivalent = equivalent ?? ""
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(binding?.modifiers ?? 0))
            item.allowsAutomaticKeyEquivalentLocalization = false
            item.allowsAutomaticKeyEquivalentMirroring = false
            item.title = action.title
            if equivalent == nil, let binding { item.title += "  " + binding.displayText }
        }
    }

    private func configureGesture() {
        controller.retryGestureRegistration = nil
        guard AppSettings.shared.gestureSnapEnabled else {
            gestures.stop()
            return
        }
        guard !gestures.start() else { return }
        var nextAttempt: TimeInterval = 0
        var retryDelay: TimeInterval = 1
        controller.retryGestureRegistration = { [weak self] in
            let now = ProcessInfo.processInfo.systemUptime
            guard let self, now >= nextAttempt, AXIsProcessTrusted() else { return }
            if self.gestures.start() {
                self.controller.retryGestureRegistration = nil
            } else {
                nextAttempt = now + retryDelay
                retryDelay = min(retryDelay * 2, 60)
            }
        }
    }

    private func configureShortcuts() {
        shortcutManager.register(bindings: AppSettings.shared.enabledShortcuts) { [weak self] action in
            guard let self, self.controller.isControllerRunning, self.controller.isUserSessionActive else { return }
            if action == .toggleSplitLock {
                guard AppSettings.shared.gestureSnapEnabled else { return }
                AppSettings.shared.splitLockEnabled.toggle()
                self.splitLockNotice.show(enabled: AppSettings.shared.splitLockEnabled, on: NSScreen.main)
                if self.settingsWindowIsVisible { self.settingsWindow.refreshGestureOptions() }
            } else if action == .restoreLast {
                self.controller.restoreLast()
            } else if let zone = action.zone {
                self.controller.snapFocusedWindow(to: zone, input: .shortcut)
            }
        }
    }

    private func presentGroupSpaceMigrationAPIUnavailableAlert(
        _ notice: GroupSpaceMigrationAPIUnavailableNotice
    ) {
        guard !groupSpaceMigrationAPIAlertIsPresented else { return }
        groupSpaceMigrationAPIAlertIsPresented = true
        controller.setApplicationUIVisible(true)
        defer {
            groupSpaceMigrationAPIAlertIsPresented = false
            controller.setApplicationUIVisible(
                settingsWindowIsVisible
            )
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("migration.api_unavailable.title")
        let currentSystem = ProcessInfo.processInfo.operatingSystemVersionString
        alert.informativeText = L10n.format(
            "migration.api_unavailable.detail",
            currentSystem,
            GroupSpaceMigrationRuntimeStatus.verifiedEnvironmentDescription,
            notice.kind.localizedDescription
        )
        alert.addButton(withTitle: L10n.text("migration.api_unavailable.disable"))
        let closeButton = alert.addButton(withTitle: L10n.text("common.close_without_changes"))
        closeButton.keyEquivalent = "\u{1b}"
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AppSettings.shared.missionControlGroupMigrationEnabled = false
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        controller.isEnabled.toggle()
        sender.title = controller.isEnabled
            ? L10n.text("menu.pause")
            : L10n.text("menu.resume")
    }

    @objc private func snapLeft() { controller.snapFocusedWindow(to: .leftHalf, input: .menu) }
    @objc private func snapRight() { controller.snapFocusedWindow(to: .rightHalf, input: .menu) }
    @objc private func snapTop() { controller.snapFocusedWindow(to: .topHalf, input: .menu) }
    @objc private func snapBottom() { controller.snapFocusedWindow(to: .bottomHalf, input: .menu) }
    @objc private func snapTopLeft() { controller.snapFocusedWindow(to: .topLeft, input: .menu) }
    @objc private func snapTopRight() { controller.snapFocusedWindow(to: .topRight, input: .menu) }
    @objc private func snapBottomLeft() { controller.snapFocusedWindow(to: .bottomLeft, input: .menu) }
    @objc private func snapBottomRight() { controller.snapFocusedWindow(to: .bottomRight, input: .menu) }
    @objc private func maximize() { controller.snapFocusedWindow(to: .maximize, input: .menu) }
    @objc private func restoreLast() { controller.restoreLast() }
    @objc private func clearLocks() { controller.clearLocks() }
    @objc private func detachFocusedWindowFromGroup() {
        controller.detachFocusedWindowFromExplicitGroup()
    }
    @objc private func openSettings() { settingsWindow.show() }

    @objc private func checkForUpdates() {
        guard let url = URL(string: "https://github.com/Pentagon22GIT/Tabora/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func resetState() {
        controller.reset()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func removeApplicationData(_ choice: AppRemovalChoice) {
        // Stop capture, observers and writers before deleting persistent state.
        guard controller.prepareForRemoval() else {
            let alert = NSAlert()
            alert.messageText = L10n.text("settings.language.busy.title")
            alert.informativeText = L10n.text("cleanup.busy")
            alert.runModal()
            return
        }
        gestures.stop()
        if let gestureObserver { NotificationCenter.default.removeObserver(gestureObserver) }
        shortcutManager.clear()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        do {
            try AppRemoval.perform(choice, domain: Bundle.main.bundleIdentifier ?? "",
                                   applicationURL: Bundle.main.bundleURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("cleanup.error")
            alert.informativeText = error.localizedDescription + "\n\n" + L10n.text("cleanup.failure_note")
            alert.runModal()
        }
        NSApplication.shared.terminate(nil)
    }

    private func relaunch(using language: AppLanguage) -> Bool {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { return false }

        let script = """
        readonly tabora_relaunch_parent_pid="$1"
        readonly tabora_relaunch_app_path="$2"
        tabora_relaunch_attempt=0
        while /bin/kill -0 "$tabora_relaunch_parent_pid" 2>/dev/null && [ "$tabora_relaunch_attempt" -lt 150 ]; do
          /bin/sleep 0.1
          tabora_relaunch_attempt=$((tabora_relaunch_attempt + 1))
        done
        /bin/kill -0 "$tabora_relaunch_parent_pid" 2>/dev/null && exit 1
        exec /usr/bin/open -g "$tabora_relaunch_app_path"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            script,
            "tabora-relauncher",
            String(ProcessInfo.processInfo.processIdentifier),
            appURL.path
        ]
        do {
            try helper.run()
        } catch {
            return false
        }

        AppLanguage.persist(language)
        UserDefaults.standard.synchronize()
        NSApplication.shared.terminate(nil)
        return true
    }
}
