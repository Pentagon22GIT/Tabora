import XCTest
@testable import Tabora

final class AppRemovalTests: XCTestCase {
    private var home: URL!
    private let domain = "dev.pent.Tabora.community"
    override func setUpWithError() throws {
        // Canonicalize only the test fixture root (/var is a macOS alias).
        home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("TaboraRemovalTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    private func record(_ domain: String? = nil) throws -> URL {
        let folder = home.appendingPathComponent("Library/Application Support/Tabora/" + (domain ?? self.domain))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("constraints-v1.json")
        try Data("fixture".utf8).write(to: file)
        return file
    }
    func testRemovalOnlyTouchesExactEditionRecord() throws {
        let target = try record()
        let other = try record("dev.pent.Tabora")
        let unknown = target.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unknown)
        try AppRemoval.removeConstraints(home: home, domain: domain, dryRun: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        try AppRemoval.removeConstraints(home: home, domain: domain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: other), "fixture")
        XCTAssertEqual(try String(contentsOf: unknown), "keep")
        try AppRemoval.removeConstraints(home: home, domain: domain)
    }
    func testSymlinkAtLeafCannotDeleteVictim() throws {
        let target = try record()
        let victim = home.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
        XCTAssertThrowsError(try AppRemoval.removeConstraints(home: home, domain: domain))
        XCTAssertEqual(try String(contentsOf: victim), "keep")
    }
    func testSymlinkAncestorCannotRedirectDeletion() throws {
        let victimHome = home.appendingPathComponent("other")
        let victimLibrary = victimHome.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: victimLibrary, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library"), withDestinationURL: victimLibrary)
        XCTAssertThrowsError(try AppRemoval.removeConstraints(home: home, domain: domain))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victimLibrary.path))
    }
    func testHardLinkAndDirectoryAtLeafAreRejected() throws {
        let target = try record()
        try FileManager.default.linkItem(at: target, to: home.appendingPathComponent("alias"))
        XCTAssertThrowsError(try AppRemoval.removeConstraints(home: home, domain: domain))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AppRemoval.removeConstraints(home: home, domain: domain))
    }
    func testArbitraryDomainsAndSharedWritableDirectoryAreRejected() throws {
        XCTAssertThrowsError(try AppRemoval.removeConstraints(home: home, domain: "../../victim"))
        let target = try record()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: target.deletingLastPathComponent().path)
        XCTAssertThrowsError(try AppRemoval.removeConstraints(home: home, domain: domain))
    }
    func testValidOwnedApplicationIsAcceptedButExecutableSymlinkIsRejected() throws {
        let application = home.appendingPathComponent("Applications/Tabora Community.app")
        let contents = application.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Tabora")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": domain, "CFBundleExecutable": "Tabora", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("fixture, never executed".utf8).write(to: executable)
        XCTAssertNoThrow(try AppRemoval.validateApplication(application, domain: domain, home: home))
        let foreign = home.appendingPathComponent("foreign-executable")
        try Data("keep".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: foreign)
        XCTAssertThrowsError(try AppRemoval.validateApplication(application, domain: domain, home: home))
        XCTAssertEqual(try String(contentsOf: foreign), "keep")
    }

    func testUninstallRefusesSourceBuildAndNonApplicationPaths() {
        XCTAssertThrowsError(try AppRemoval.validateApplication(home.appendingPathComponent("Tabora.app"), domain: domain, home: home))
        XCTAssertThrowsError(try AppRemoval.validateApplication(home, domain: domain, home: home))
    }
}
