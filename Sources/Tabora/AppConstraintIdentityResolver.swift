import AppKit
import Security

enum AppConstraintInstallationState: Equatable {
    case matching
    case confirmedMissingOrReplaced
    case unknown
}

final class AppConstraintIdentityResolver {
    // Bundle URLs are runtime evidence only. They are deliberately not part of
    // persistent identity and are never written to ConstraintStore. A path
    // disappearing after Tabora observed that exact bundle is stronger
    // evidence than a transient LaunchServices lookup failure.
    private var lastObservedBundleURLByStorageKey: [String: URL] = [:]
    func resolve(_ window: ManagedWindow) -> (identity: AppConstraintIdentity, displayName: String)? {
        guard let application = NSRunningApplication(
            processIdentifier: window.pid
        ), !application.isTerminated,
           let bundleIdentifier = application.bundleIdentifier,
           !bundleIdentifier.isEmpty
        else { return nil }

        let displayName = application.localizedName ?? bundleIdentifier
        if let bundleURL = application.bundleURL,
           let webAppID = chromeWebAppID(bundleURL: bundleURL) {
            let parentBundleIdentifier = chromeParentBundleIdentifier(
                bundleURL: bundleURL
            ) ?? "com.google.Chrome"
            guard let parentURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: parentBundleIdentifier
            ), let parentSigningRequirement = designatedRequirement(
                bundleURL: parentURL
            ) else { return nil }

            // A Chrome App Shim's local bundle identifier/path/profile is not
            // persistent identity. Bind the record to the parent Chrome code
            // identity plus the canonical Web App ID instead.
            let identity = AppConstraintIdentity(
                kind: .chromeWebApp,
                bundleIdentifier: parentBundleIdentifier,
                signingRequirement: parentSigningRequirement,
                parentBundleIdentifier: parentBundleIdentifier,
                webAppID: webAppID
            )
            lastObservedBundleURLByStorageKey[identity.storageKey] = bundleURL
            return (identity, displayName)
        }

        guard let signingRequirement = designatedRequirement(for: application)
        else { return nil }
        let identity = AppConstraintIdentity(
            kind: .nativeApplication,
            bundleIdentifier: bundleIdentifier,
            signingRequirement: signingRequirement
        )
        if let bundleURL = application.bundleURL {
            lastObservedBundleURLByStorageKey[identity.storageKey] = bundleURL
        }
        return (identity, displayName)
    }

    func installationState(
        for identity: AppConstraintIdentity
    ) -> AppConstraintInstallationState {
        switch identity.kind {
        case .nativeApplication:
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identity.bundleIdentifier
            ) {
                guard let requirement = designatedRequirement(bundleURL: url)
                else { return .unknown }
                return requirement == identity.signingRequirement
                    ? .matching
                    : .confirmedMissingOrReplaced
            }

            // LaunchServices returning nil is not proof of uninstall. Only an
            // exact bundle path observed earlier in this process becoming
            // absent authorizes dormant transition.
            if let observedURL = lastObservedBundleURLByStorageKey[
                identity.storageKey
            ], !FileManager.default.fileExists(atPath: observedURL.path) {
                return .confirmedMissingOrReplaced
            }
            return .unknown

        case .chromeWebApp:
            // Chrome Web Apps are separate records. The parent Chrome bundle
            // alone cannot prove that a particular shim still exists. Use the
            // exact shim URL only after this process has observed it.
            if let observedURL = lastObservedBundleURLByStorageKey[
                identity.storageKey
            ] {
                guard FileManager.default.fileExists(atPath: observedURL.path)
                else { return .confirmedMissingOrReplaced }
                guard chromeWebAppID(bundleURL: observedURL) == identity.webAppID
                else { return .confirmedMissingOrReplaced }

                let parentBundleIdentifier = chromeParentBundleIdentifier(
                    bundleURL: observedURL
                ) ?? identity.bundleIdentifier
                guard parentBundleIdentifier == identity.bundleIdentifier,
                      let parentURL = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: parentBundleIdentifier
                      ),
                      let requirement = designatedRequirement(bundleURL: parentURL)
                else { return .unknown }
                return requirement == identity.signingRequirement
                    ? .matching
                    : .confirmedMissingOrReplaced
            }

            // A confirmed replacement of the parent browser invalidates the
            // old Web App identity. A matching parent with no observed shim is
            // still unknown, not proof that the Web App is installed.
            if let parentURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identity.bundleIdentifier
            ), let requirement = designatedRequirement(bundleURL: parentURL),
               requirement != identity.signingRequirement {
                return .confirmedMissingOrReplaced
            }
            return .unknown
        }
    }

    private func chromeWebAppID(bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL),
              let info = bundle.infoDictionary else { return nil }
        let candidates = [
            "CrAppModeShortcutID",
            "CrAppModeShortcutId",
            "CrAppModeAppID",
            "CrAppModeAppId"
        ]
        for key in candidates {
            if let value = info[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func chromeParentBundleIdentifier(bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL),
              let info = bundle.infoDictionary else { return nil }
        let candidates = [
            "CrBundleIdentifier",
            "CrAppModeBrowserBundleIdentifier"
        ]
        for key in candidates {
            if let value = info[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func designatedRequirement(
        for application: NSRunningApplication
    ) -> String? {
        guard let bundleURL = application.bundleURL else { return nil }
        return designatedRequirement(bundleURL: bundleURL)
    }

    private func designatedRequirement(bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess, let staticCode else { return nil }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            staticCode,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess, let requirement else { return nil }

        var text: CFString?
        guard SecRequirementCopyString(
            requirement,
            SecCSFlags(rawValue: 0),
            &text
        ) == errSecSuccess, let text else { return nil }
        return text as String
    }
}
