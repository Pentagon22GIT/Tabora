import AppKit
import ApplicationServices

/// Evaluated before localization writes its defaults. A product update must not
/// turn existing users into first-time installations.
enum InstallationLifecycle {
    static let completionKey = "initialSetupCompleted"
    static let domains: Set<String> = ["dev.pent.Tabora", "dev.pent.Tabora.community"]

    static func needsSetup(domain: String?, defaults: UserDefaults = .standard,
                           hasExistingRecords: Bool = false) -> Bool {
        guard let domain, domains.contains(domain) else { return false }
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        if let completed = stored[completionKey] as? Bool { return !completed }
        if !stored.isEmpty || hasExistingRecords {
            defaults.set(true, forKey: completionKey)
            return false
        }
        defaults.set(false, forKey: completionKey)
        return true
    }
}

/// Independent of the app/build version and language. Bump only when the
/// privacy/permission or other important information changes, not for layout or translation corrections.
enum AppInformationNotice {
    static let currentRevision = "2026-11-05.1"
    static let viewedRevisionKey = "viewedAppInformationRevision"

    static func needsPresentation(domain: String?, defaults: UserDefaults = .standard,
                                  revision: String = currentRevision) -> Bool {
        guard let domain, InstallationLifecycle.domains.contains(domain) else { return false }
        return defaults.persistentDomain(forName: domain)?[viewedRevisionKey] as? String != revision
    }

    static func markViewed(defaults: UserDefaults = .standard) {
        defaults.set(currentRevision, forKey: viewedRevisionKey)
    }
}

enum InstallationPresentation {
    case initialSetup, informationUpdate, review
}

final class InitialSetupWindowController: NSWindowController, NSWindowDelegate {
    var onComplete: (() -> Void)?
    private var language: AppLanguage
    private var step = 0
    private let presentation: InstallationPresentation
    private let defaults: UserDefaults
    private let languagePopup = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let previews = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(language: AppLanguage = AppLanguage.selected(),
         presentation: InstallationPresentation = .initialSetup,
         defaults: UserDefaults = .standard) {
        self.language = language
        self.presentation = presentation
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func text(_ key: String) -> String { L10n.text(key, language: language) }

    private func render() {
        guard let window else { return }
        window.title = text(presentation == .initialSetup ? "setup.title" : "information.title")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            footer.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -20)
        ])
        func label(_ key: String, heading: Bool = false) {
            let view = NSTextField(wrappingLabelWithString: text(key))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = heading ? 2 : 4
            view.attributedStringValue = NSAttributedString(string: text(key), attributes: [
                .font: NSFont.systemFont(ofSize: heading ? 22 : 14, weight: heading ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
            view.maximumNumberOfLines = 0
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if step == 0 {
            if presentation == .initialSetup {
                languagePopup.removeAllItems()
                for item in AppLanguage.allCases { languagePopup.addItem(withTitle: item.displayName) }
                languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: language) ?? 0)
                languagePopup.target = self
                languagePopup.action = #selector(changeLanguage)
                stack.addArrangedSubview(languagePopup)
                label("setup.welcome", heading: true)
                label("setup.about")
            } else {
                label("information.title", heading: true)
                label("information.notice")
            }
            for (title, body) in [("setup.privacy_title", "setup.privacy"), ("setup.license_title", "setup.license")] {
                let heading = NSTextField(labelWithString: text(title))
                heading.font = .systemFont(ofSize: 14, weight: .semibold)
                stack.addArrangedSubview(heading)
                stack.setCustomSpacing(6, after: heading)
                label(body)
            }
        } else {
            label("setup.options", heading: true)
            label("setup.permissions")
            let access = NSButton(title: text("menu.open_accessibility"), target: self,
                                  action: #selector(openAccessibility))
            access.bezelStyle = .rounded
            stack.addArrangedSubview(access)
            login.title = text("settings.general.launch_at_login")
            previews.title = text("settings.general.show_window_previews")
            label("setup.optional")
            stack.addArrangedSubview(login)
            stack.addArrangedSubview(previews)
        }
        let next = NSButton(title: text(presentation == .review ? "information.close" : presentation == .informationUpdate ? "information.confirm" : step == 0 ? "setup.continue" : "setup.finish"),
                            target: self, action: #selector(advance))
        next.bezelStyle = .rounded
        next.keyEquivalent = "\r"
        next.identifier = NSUserInterfaceItemIdentifier("setup.primary")
        next.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(next)
        NSLayoutConstraint.activate([
            next.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            next.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        if presentation == .initialSetup && step == 1 {
            let back = NSButton(title: text("setup.back"), target: self, action: #selector(goBack))
            back.bezelStyle = .rounded
            back.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(back)
            NSLayoutConstraint.activate([
                back.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
                back.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
            ])
        }
    }
    @objc private func goBack() {
        guard presentation == .initialSetup, step == 1 else { return }
        step = 0
        render()
    }
    @objc private func changeLanguage() {
        language = AppLanguage.allCases[languagePopup.indexOfSelectedItem]
        render()
    }
    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func advance() {
        if presentation != .initialSetup {
            if presentation == .informationUpdate { AppInformationNotice.markViewed(defaults: defaults) }
            close()
            onComplete?()
            return
        }
        if step == 0 { step = 1; render(); return }
        do {
            // Do not unregister a pre-existing login item when the default is OFF.
            if login.state == .on { try AppSettings.shared.setLaunchAtLogin(true) }
        } catch {
            let alert = NSAlert()
            alert.messageText = text("settings.general.launch_at_login.error.title")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        if previews.state == .on { _ = CGRequestScreenCaptureAccess() }
        AppSettings.shared.windowPreviewsEnabled = previews.state == .on
        AppLanguage.persist(language)
        L10n.language = language
        defaults.set(true, forKey: InstallationLifecycle.completionKey)
        AppInformationNotice.markViewed(defaults: defaults)
        close()
        onComplete?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if presentation == .initialSetup {
            // Setup remains pending until optional choices are explicitly applied.
            NSApplication.shared.terminate(nil)
        } else if presentation == .informationUpdate {
            // This is an informational notice, not a license acceptance gate.
            // Dismissing it allows normal startup without changing permissions.
            AppInformationNotice.markViewed(defaults: defaults)
            onComplete?()
        }
        return true
    }
}
