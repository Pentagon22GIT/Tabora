import AppKit
import Darwin
import ServiceManagement

enum AppRemovalChoice: Int, CaseIterable {
    case settings, constraints, everything
    var title: String {
        L10n.text(["cleanup.settings", "cleanup.records", "cleanup.all"][rawValue])
    }
}

enum AppRemovalError: Error, LocalizedError {
    case unsafeTarget(String)
    case operation(String, Int32)
    var errorDescription: String? {
        switch self {
        case .unsafeTarget(let path): return L10n.format("cleanup.unsafe_target", path)
        case .operation(let path, let code): return L10n.format("cleanup.operation_error", path, Int(code))
        }
    }
}

/// No shell, privileged helper, path input from UI, glob, or recursive deletion.
/// The only persisted product file is constraints-v1.json. Preview pixels are RAM-only.
enum AppRemoval {
    static func validateDomain(_ domain: String) throws {
        guard geteuid() != 0, InstallationLifecycle.domains.contains(domain) else {
            throw AppRemovalError.unsafeTarget(domain)
        }
    }

    static func removeConstraints(home: URL, domain: String, dryRun: Bool = false) throws {
        try validateDomain(domain)
        // Anchor each component to an open descriptor. Never follow a symlink,
        // including ancestors; a renamed parent cannot redirect unlinkat.
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AppRemovalError.operation("/", errno) }
        defer { close(descriptor) }
        let components = home.pathComponents.filter { $0 != "/" }
            + ["Library", "Application Support", "Tabora", domain]
        for component in components {
            guard component != ".", component != "..", !component.contains("/") else {
                throw AppRemovalError.unsafeTarget(component)
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return }
                throw AppRemovalError.operation(component, errno)
            }
            close(descriptor)
            descriptor = next
        }
        var parent = stat()
        guard fstat(descriptor, &parent) == 0, parent.st_uid == geteuid(),
              parent.st_mode & 0o022 == 0 else {
            throw AppRemovalError.unsafeTarget(domain)
        }
        let name = "constraints-v1.json"
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw AppRemovalError.operation(name, errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
            throw AppRemovalError.unsafeTarget(name)
        }
        // unlinkat removes only this directory entry, even if replaced by a
        // symlink after validation; it never traverses that link's destination.
        if !dryRun, unlinkat(descriptor, name, 0) != 0 {
            throw AppRemovalError.operation(name, errno)
        }
        // Leave empty directories in place: never recursively remove unknown data.
    }

    private static func pathHasNoSymlinkComponents(_ url: URL, directory: Bool) -> Bool {
        // URL.standardizedFileURL can rewrite /private/tmp to /tmp on macOS.
        // Validate actual components with descriptors instead of comparing URL aliases.
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return false }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        for (index, component) in components.enumerated() {
            guard component != ".", component != "..", !component.contains("/") else { return false }
            let isDirectory = directory || index < components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isDirectory ? O_DIRECTORY : O_NONBLOCK)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else { return false }
            close(descriptor)
            descriptor = next
        }
        var info = stat()
        return fstat(descriptor, &info) == 0
            && info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
    }

    static func validateApplication(_ url: URL, domain: String, home: URL) throws {
        try validateDomain(domain)
        let target = url
        let parent = target.deletingLastPathComponent()
        let allowedParents = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        guard target.pathExtension == "app", allowedParents.contains(parent),
              pathHasNoSymlinkComponents(target, directory: true),
              pathHasNoSymlinkComponents(target.appendingPathComponent("Contents/Info.plist"), directory: false),
              let bundle = Bundle(url: target), bundle.bundleIdentifier == domain,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Tabora",
              pathHasNoSymlinkComponents(target.appendingPathComponent("Contents/MacOS/Tabora"), directory: false),
              FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AppRemovalError.unsafeTarget(target.path)
        }
    }

    static func resetPreferences(domain: String, defaults: UserDefaults = .standard,
                                 preservingInstallationState: Bool) throws {
        try validateDomain(domain)
        let viewedRevision = defaults.persistentDomain(forName: domain)?[
            AppInformationNotice.viewedRevisionKey
        ] as? String
        defaults.removePersistentDomain(forName: domain)
        if preservingInstallationState {
            defaults.set(true, forKey: InstallationLifecycle.completionKey)
            // Preserve only the information revision actually viewed, not the current revision.
            if let viewedRevision {
                defaults.set(viewedRevision, forKey: AppInformationNotice.viewedRevisionKey)
            }
        }
        guard defaults.synchronize() else { throw AppRemovalError.operation(domain, EIO) }
    }

    static func perform(_ choice: AppRemovalChoice, domain: String, applicationURL: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        try validateDomain(domain)
        // A valid product domain alone does not authorize deleting the other
        // edition. Bind every removal choice to this running bundle.
        guard Bundle.main.bundleIdentifier == domain,
              Bundle.main.bundleURL == applicationURL else {
            throw AppRemovalError.unsafeTarget(domain)
        }
        if choice == .everything {
            try validateApplication(applicationURL, domain: domain, home: home)
        }
        if choice != .settings {
            try removeConstraints(home: home, domain: domain, dryRun: true)
        }
        if choice != .constraints {
            // Login-at-launch is a setting too: resetting preferences must not
            // leave an OS-owned automatic launch registration behind.
            // requiresApproval also represents a registration that must be removed.
            if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        }
        if choice != .settings { try removeConstraints(home: home, domain: domain) }
        if choice != .constraints {
            try resetPreferences(domain: domain, preservingInstallationState: choice == .settings)
        }
        if choice == .everything {
            try validateApplication(applicationURL, domain: domain, home: home)
            // Recoverable removal of this exact bundle only. No Trash emptying.
            try FileManager.default.trashItem(at: applicationURL, resultingItemURL: nil)
        }
    }
}
