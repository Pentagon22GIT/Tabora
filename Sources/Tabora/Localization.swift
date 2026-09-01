import Foundation

enum AppLanguage: String, CaseIterable, Codable {
    case japanese = "ja"
    case english = "en"
    case korean = "ko"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    static let defaultsKey = "appLanguage"

    var localeIdentifier: String { rawValue }

    var displayName: String {
        L10n.text("language.name.\(rawValue)", language: self)
    }

    static func selected(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let stored = defaults.string(forKey: defaultsKey) {
            guard let language = AppLanguage(rawValue: stored) else {
                persist(.japanese, defaults: defaults)
                return .japanese
            }
            persist(language, defaults: defaults)
            return language
        }

        let language = initialLanguage(from: preferredLanguages.first)
        persist(language, defaults: defaults)
        return language
    }

    static func initialLanguage(from identifier: String?) -> AppLanguage {
        guard let identifier else { return .japanese }
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized == "ja" || normalized.hasPrefix("ja-") {
            return .japanese
        }
        if normalized == "en" || normalized.hasPrefix("en-") {
            return .english
        }
        if normalized == "ko" || normalized.hasPrefix("ko-") {
            return .korean
        }
        if normalized.contains("hant")
            || normalized.hasPrefix("zh-tw")
            || normalized.hasPrefix("zh-hk")
            || normalized.hasPrefix("zh-mo") {
            return .traditionalChinese
        }
        if normalized == "zh"
            || normalized.contains("hans")
            || normalized.hasPrefix("zh-cn")
            || normalized.hasPrefix("zh-sg") {
            return .simplifiedChinese
        }
        return .japanese
    }

    static func persist(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
        defaults.set([language.rawValue], forKey: "AppleLanguages")
    }
}

enum L10n {
    static let language = AppLanguage.selected()

    static func text(
        _ key: String,
        language: AppLanguage = L10n.language
    ) -> String {
        let localized = bundle(for: language).localizedString(
            forKey: key,
            value: key,
            table: nil
        )
        guard localized == key, language != .japanese else { return localized }
        return bundle(for: .japanese).localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...,
        language: AppLanguage = L10n.language
    ) -> String {
        String(
            format: text(key, language: language),
            locale: Locale(identifier: language.localeIdentifier),
            arguments: arguments
        )
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        let directory = "\(language.rawValue).lproj"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(directory),
           let bundle = Bundle(url: url) {
            return bundle
        }
        if let url = Bundle.module.resourceURL?.appendingPathComponent(directory),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.main
    }
}
