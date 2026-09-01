import AppKit
import ApplicationServices

@main
final class TaboraApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = SnapController()
    private let shortcutManager = GlobalShortcutManager()
    private var settingsWindowIsVisible = false
    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onVisibilityChange = { [weak self] isVisible in
            self?.settingsWindowIsVisible = isVisible
            self?.controller.setApplicationUIVisible(isVisible)
        }
        controller.onConstraintMeasurementWillBegin = { [weak self] in
            self?.controller.beginConstraintMeasurement() ?? false
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
        return controller
    }()
    private var settingsObserver: NSObjectProtocol?
    private var groupSpaceMigrationAPIAlertIsPresented = false

    static func main() {
        let app = NSApplication.shared
        let delegate = TaboraApp()
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        controller.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Tabora")

        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("menu.pause"), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("zone.left_half"), action: #selector(snapLeft), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("zone.right_half"), action: #selector(snapRight), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("zone.top_half"), action: #selector(snapTop), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("zone.bottom_half"), action: #selector(snapBottom), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("zone.top_left"), action: #selector(snapTopLeft), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("zone.top_right"), action: #selector(snapTopRight), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("zone.bottom_left"), action: #selector(snapBottomLeft), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("zone.bottom_right"), action: #selector(snapBottomRight), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("zone.maximize"), action: #selector(maximize), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("command.restore_last"), action: #selector(restoreLast), keyEquivalent: "")
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
        statusItem.menu = menu
    }

    private func configureShortcuts() {
        shortcutManager.register(bindings: AppSettings.shared.shortcuts) { [weak self] action in
            guard let self else { return }
            if action == .restoreLast {
                self.controller.restoreLast()
            } else if let zone = action.zone {
                self.controller.snapFocusedWindow(to: zone)
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

    @objc private func snapLeft() { controller.snapFocusedWindow(to: .leftHalf) }
    @objc private func snapRight() { controller.snapFocusedWindow(to: .rightHalf) }
    @objc private func snapTop() { controller.snapFocusedWindow(to: .topHalf) }
    @objc private func snapBottom() { controller.snapFocusedWindow(to: .bottomHalf) }
    @objc private func snapTopLeft() { controller.snapFocusedWindow(to: .topLeft) }
    @objc private func snapTopRight() { controller.snapFocusedWindow(to: .topRight) }
    @objc private func snapBottomLeft() { controller.snapFocusedWindow(to: .bottomLeft) }
    @objc private func snapBottomRight() { controller.snapFocusedWindow(to: .bottomRight) }
    @objc private func maximize() { controller.snapFocusedWindow(to: .maximize) }
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
