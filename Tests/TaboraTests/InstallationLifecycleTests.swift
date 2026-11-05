import AppKit
import XCTest
@testable import Tabora

private final class MemoryInstallationDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func persistentDomain(forName domainName: String) -> [String: Any]? { values }
    override func removePersistentDomain(forName domainName: String) { values.removeAll() }
    override func synchronize() -> Bool { true }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

final class InstallationLifecycleTests: XCTestCase {
    func testFreshInstallationRemainsPendingAfterLocalizationAndCancellation() {
        let defaults = MemoryInstallationDefaults()
        XCTAssertTrue(InstallationLifecycle.needsSetup(domain: "dev.pent.Tabora", defaults: defaults))
        defaults.set("en", forKey: "appLanguage")
        XCTAssertTrue(InstallationLifecycle.needsSetup(domain: "dev.pent.Tabora", defaults: defaults))
        defaults.set(true, forKey: InstallationLifecycle.completionKey)
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: "dev.pent.Tabora", defaults: defaults))
    }
    func testExistingInstallationMigratesWithoutWizard() {
        let defaults = MemoryInstallationDefaults()
        defaults.set(false, forKey: "windowPreviewsEnabled")
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: "dev.pent.Tabora", defaults: defaults))
        XCTAssertEqual(defaults.values["windowPreviewsEnabled"] as? Bool, false)
        XCTAssertEqual(defaults.values[InstallationLifecycle.completionKey] as? Bool, true)
    }
    func testExistingRecordsAndUnbundledExecutablesDoNotStartSetup() {
        let defaults = MemoryInstallationDefaults()
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: "dev.pent.Tabora.community", defaults: defaults, hasExistingRecords: true))
        let empty = MemoryInstallationDefaults()
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: nil, defaults: empty))
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: "another.app", defaults: empty))
        XCTAssertTrue(empty.values.isEmpty)
    }
    func testNoticeRevisionIsIndependentFromSetupAndLanguage() {
        let defaults = MemoryInstallationDefaults()
        let domain = "dev.pent.Tabora"
        defaults.set(true, forKey: InstallationLifecycle.completionKey)
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: domain, defaults: defaults))
        XCTAssertTrue(AppInformationNotice.needsPresentation(domain: domain, defaults: defaults))
        // Merely checking/presenting does not record a viewed revision.
        XCTAssertTrue(AppInformationNotice.needsPresentation(domain: domain, defaults: defaults))
        AppInformationNotice.markViewed(defaults: defaults)
        defaults.set("en", forKey: "appLanguage")
        XCTAssertFalse(AppInformationNotice.needsPresentation(domain: domain, defaults: defaults))
        XCTAssertTrue(AppInformationNotice.needsPresentation(domain: domain, defaults: defaults, revision: "next-substantive-revision"))
        XCTAssertFalse(AppInformationNotice.needsPresentation(domain: nil, defaults: defaults))
        XCTAssertFalse(AppInformationNotice.needsPresentation(domain: "other.app", defaults: defaults))
    }

    func testLegacyMigrationDoesNotPretendInformationWasViewed() {
        let defaults = MemoryInstallationDefaults()
        defaults.set(false, forKey: "windowPreviewsEnabled")
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: "dev.pent.Tabora", defaults: defaults))
        XCTAssertTrue(AppInformationNotice.needsPresentation(domain: "dev.pent.Tabora", defaults: defaults))
        XCTAssertNil(defaults.values[AppInformationNotice.viewedRevisionKey])
    }

    func testInformationUpdateAndReadOnlyReviewHaveDifferentWriteBoundaries() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        for presentation in [InstallationPresentation.informationUpdate, .review] {
            let defaults = MemoryInstallationDefaults()
            defaults.set(true, forKey: "windowPreviewsEnabled")
            defaults.set("ja", forKey: "appLanguage")
            let window = InitialSetupWindowController(language: .english,
                presentation: presentation, defaults: defaults)
            var finished = false
            window.onComplete = { finished = true }
            XCTAssertNil(defaults.values[AppInformationNotice.viewedRevisionKey])
            window.perform(NSSelectorFromString("advance"))
            XCTAssertTrue(finished)
            XCTAssertEqual(defaults.values["windowPreviewsEnabled"] as? Bool, true)
            XCTAssertEqual(defaults.values["appLanguage"] as? String, "ja")
            XCTAssertNil(defaults.values[InstallationLifecycle.completionKey])
            XCTAssertEqual(defaults.values[AppInformationNotice.viewedRevisionKey] as? String,
                presentation == .informationUpdate ? AppInformationNotice.currentRevision : nil)
        }
    }

    func testSettingsResetPreservesOnlyActuallyViewedRevisionAndUninstallClearsIt() throws {
        let defaults = MemoryInstallationDefaults()
        let domain = "dev.pent.Tabora"
        defaults.set("older-revision", forKey: AppInformationNotice.viewedRevisionKey)
        defaults.set(true, forKey: "windowPreviewsEnabled")
        try AppRemoval.resetPreferences(domain: domain, defaults: defaults, preservingInstallationState: true)
        XCTAssertNil(defaults.values["windowPreviewsEnabled"])
        XCTAssertEqual(defaults.values[AppInformationNotice.viewedRevisionKey] as? String, "older-revision")
        XCTAssertTrue(AppInformationNotice.needsPresentation(domain: domain, defaults: defaults))
        XCTAssertFalse(InstallationLifecycle.needsSetup(domain: domain, defaults: defaults))
        try AppRemoval.resetPreferences(domain: domain, defaults: defaults, preservingInstallationState: false)
        XCTAssertTrue(defaults.values.isEmpty)
        XCTAssertTrue(InstallationLifecycle.needsSetup(domain: domain, defaults: defaults))
        XCTAssertTrue(AppInformationNotice.needsPresentation(domain: domain, defaults: defaults))
    }

    func testDismissingInformationAllowsStartupWithoutAcceptingTermsOrChangingOptions() throws {
        let defaults = MemoryInstallationDefaults()
        defaults.set(false, forKey: "windowPreviewsEnabled")
        let controller = InitialSetupWindowController(language: .japanese,
            presentation: .informationUpdate, defaults: defaults)
        var started = false
        controller.onComplete = { started = true }
        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))
        XCTAssertTrue(started)
        XCTAssertFalse(AppInformationNotice.needsPresentation(domain: "dev.pent.Tabora", defaults: defaults))
        XCTAssertEqual(defaults.values["windowPreviewsEnabled"] as? Bool, false)
        XCTAssertNil(defaults.values[InstallationLifecycle.completionKey])
        controller.close()
    }

}
