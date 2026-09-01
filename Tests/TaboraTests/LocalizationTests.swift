import Foundation
import XCTest
@testable import Tabora

final class LocalizationTests: XCTestCase {
    private let languages = ["ja", "en", "ko", "zh-Hans", "zh-Hant"]

    func testInitialLanguageMappingUsesOnlyPrimaryPreferredLanguage() {
        XCTAssertEqual(AppLanguage.initialLanguage(from: "ja-JP"), .japanese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "en-US"), .english)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "ko-KR"), .korean)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "zh-Hans-CN"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "zh-CN"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "zh-SG"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "zh-Hant-TW"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "zh-TW"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "zh-HK"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "zh-MO"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: "fr-FR"), .japanese)
        XCTAssertEqual(AppLanguage.initialLanguage(from: nil), .japanese)
    }

    func testSelectedLanguageIsStoredOnceAndDoesNotFollowLaterSystemChanges() {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AppLanguage.selected(
                defaults: defaults,
                preferredLanguages: ["ko-KR"]
            ),
            .korean
        )
        XCTAssertEqual(
            AppLanguage.selected(
                defaults: defaults,
                preferredLanguages: ["en-US"]
            ),
            .korean
        )
    }

    func testInvalidStoredLanguageRepairsToJapanese() {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unsupported", forKey: AppLanguage.defaultsKey)

        XCTAssertEqual(AppLanguage.selected(defaults: defaults), .japanese)
        XCTAssertEqual(
            defaults.string(forKey: AppLanguage.defaultsKey),
            AppLanguage.japanese.rawValue
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: "AppleLanguages"),
            [AppLanguage.japanese.rawValue]
        )
    }

    func testEveryLanguageHasExactlyTheSameLocalizationKeysAndPlaceholders() throws {
        let tables = try Dictionary(uniqueKeysWithValues: languages.map {
            ($0, try localizationTable(language: $0, name: "Localizable"))
        })
        let japanese = try XCTUnwrap(tables["ja"])
        XCTAssertFalse(japanese.isEmpty)

        for language in languages {
            let table = try XCTUnwrap(tables[language])
            XCTAssertEqual(Set(table.keys), Set(japanese.keys), language)
            for key in japanese.keys {
                XCTAssertEqual(
                    placeholders(in: table[key] ?? ""),
                    placeholders(in: japanese[key] ?? ""),
                    "\(language): \(key)"
                )
            }
        }
    }

    func testPermissionDescriptionsExistInEveryLanguage() throws {
        let expected = Set([
            "NSAccessibilityUsageDescription",
            "NSScreenCaptureUsageDescription"
        ])
        for language in languages {
            let table = try localizationTable(language: language, name: "InfoPlist")
            XCTAssertEqual(Set(table.keys), expected, language)
        }
    }

    func testNoJapaneseUserFacingLiteralsRemainInSwiftSources() throws {
        let sourceDirectory = projectRoot
            .appendingPathComponent("Sources/Tabora", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        )
        let japanese = try NSRegularExpression(
            pattern: "[ぁ-んァ-ヶ一-龠々ー]"
        )

        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)
            XCTAssertNil(
                japanese.firstMatch(in: contents, range: range),
                file.lastPathComponent
            )
        }
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func localizationTable(
        language: String,
        name: String
    ) throws -> [String: String] {
        let file = projectRoot
            .appendingPathComponent("Sources/Tabora/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("\(name).strings")
        let contents = try String(contentsOf: file, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"(?m)^\s*"([^"]+)"\s*=\s*"(.*)";\s*$"#
        )
        let range = NSRange(contents.startIndex..., in: contents)
        var result: [String: String] = [:]
        let matches = expression.matches(in: contents, range: range)
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: contents),
                  let valueRange = Range(match.range(at: 2), in: contents) else {
                continue
            }
            let key = String(contents[keyRange])
            XCTAssertNil(result[key], "Duplicate key: \(language): \(key)")
            result[key] = String(contents[valueRange])
        }
        XCTAssertEqual(
            matches.count,
            contents.split(separator: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"")
            }.count,
            "Malformed .strings entry: \(file.path)"
        )
        return result
    }

    private func placeholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?(?:\.\d+)?[@df]"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
}
