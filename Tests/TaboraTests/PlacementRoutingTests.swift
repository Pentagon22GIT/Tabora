import AppKit
import XCTest
@testable import Tabora

final class PlacementRoutingTests: XCTestCase {
    func testReplacementDefaultAndLayerDecisions() throws {
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.occupiedReplacementEnabled)
        for occupied in SnapZone.allCases {
            for incoming in SnapZone.allCases {
                XCTAssertTrue(OccupiedSplitPolicy.permits(existing: occupied, incoming: incoming,
                    replacementEnabled: true))
                let allowed = occupied == .maximize || incoming == .maximize
                    || !SnapPlacementLayerPolicy.conflicts(existing: occupied, incoming: incoming)
                XCTAssertEqual(OccupiedSplitPolicy.permits(existing: occupied, incoming: incoming,
                    replacementEnabled: false), allowed)
            }
        }
        settings.occupiedReplacementEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).occupiedReplacementEnabled)
    }

    func testSplitRatioSlidersUpdateIndependentDisplayPreference() throws {
        _ = NSApplication.shared
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        let view = DisplaySplitRatioView(screen: try XCTUnwrap(NSScreen.main), key: "fixture", settings: settings)
        func sliders(in view: NSView) -> [NSSlider] {
            view.subviews.compactMap { $0 as? NSSlider } + view.subviews.flatMap { sliders(in: $0) }
        }
        let controls = sliders(in: view)
        XCTAssertEqual(controls.count, 2)
        for (axis, value) in [("left", 70), ("top", 35)] {
            let slider = try XCTUnwrap(controls.first { $0.accessibilityLabel() == L10n.text("settings.ratio." + axis) })
            slider.integerValue = value
            XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        }
        XCTAssertEqual(settings.splitRatio(for: "fixture"), DefaultSplitRatio(left: 70, top: 35))
        XCTAssertEqual(settings.splitRatio(for: "other"), .init())
        if let output = ProcessInfo.processInfo.environment["TABORA_RATIO_PREVIEW"] {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 108),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let content = try XCTUnwrap(window.contentView)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                view.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
            content.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }

    func testGestureExchangeAndIndependentPlacementWithOwnedAXClient() throws {
        try exercisePlacement(threeSlots: false)
    }

    func testEmptyQuarterAndExchangeInThreeWindowGroup() throws {
        try exercisePlacement(threeSlots: true)
    }

    func testConstrainedExchangeKeepsNewDividerAndRejectsInfeasibleSwap() throws {
        try exercisePlacement(threeSlots: false, constrained: true)
    }

    private func exercisePlacement(threeSlots: Bool, constrained: Bool = false) throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable: URL
        if let path = ProcessInfo.processInfo.environment["TABORA_PLACEMENT_FIXTURE"] {
            executable = URL(fileURLWithPath: path)
        } else {
            executable = try buildFixture(in: folder)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = threeSlots ? ["three"] : []
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        let registry = AppConstraintRegistry(store: ConstraintStore(fileURL: folder.appendingPathComponent("constraints.json")))
        let controller = SnapController(settings: settings, appConstraintRegistry: registry)
        controller.isControllerRunning = true
        defer { controller.stop() }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        var raw: CFTypeRef?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        } while (raw as? [AXUIElement])?.count != 3 && Date() < deadline
        let elements = try XCTUnwrap(raw as? [AXUIElement])
        let windows = try elements.map { element -> ManagedWindow in
            var title: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            let id = try XCTUnwrap(RuntimeWindowIDResolver().resolve(element))
            let frame = try XCTUnwrap(controller.windowService.windowServerFrame(pid: process.processIdentifier, windowID: id))
            return ManagedWindow(element: element, pid: process.processIdentifier, title: try XCTUnwrap(title as? String),
                appIcon: nil, frame: frame, isMinimized: false, isFullscreen: false, cgWindowID: id)
        }.sorted { $0.title < $1.title }
        XCTAssertEqual(windows.count, 3)
        guard windows.count == 3 else { return }
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.visibleFrame.contains(CGPoint(x: windows[0].frame.midX, y: windows[0].frame.midY)) })
        let display = try XCTUnwrap(controller.displayID(for: screen))
        let zones: [SnapZone] = [.leftHalf, threeSlots ? .topRight : .rightHalf]
        let placements = zip(windows, zones).map { window, zone in
            SplitPlacementGeometry(stableIdentity: window.stableIdentity, zone: zone, frame: window.frame)
        }
        let group = try XCTUnwrap(controller.explicitGroupStore.reconcileAfterLayoutMutation(
            preferredMemberID: windows[0].stableIdentity, displayID: display, placements: placements, detachedConnections: []))
        for (window, zone) in zip(windows, zones) {
            controller.lockedPlacements[window.stableIdentity] = LockedPlacement(element: window.element,
                pid: window.pid, stableIdentity: window.stableIdentity, cgWindowID: window.cgWindowID,
                zone: zone, displayID: display, appliedFrame: window.frame)
        }
        func perform(_ window: ManagedWindow, _ zone: SnapZone, success: Bool = true) {
            let done = expectation(description: "snap committed")
            controller.snap(window, to: zone, on: screen, continueAssist: false, input: .gesture) {
                XCTAssertEqual($0, success)
                done.fulfill()
            }
            wait(for: [done], timeout: 8)
        }
        if constrained {
            let identity = try XCTUnwrap(controller.resolveAppConstraintIdentity(for: windows[0]))
            let minimum = floor(screen.visibleFrame.width * 0.46)
            registry.applyExplicitMeasurement([.minWidth: minimum], identity: identity.identity,
                displayName: identity.displayName)
            perform(windows[0], .rightHalf)
            let right = try XCTUnwrap(controller.lockedPlacements[windows[0].stableIdentity]?.appliedFrame)
            XCTAssertEqual(right.width, minimum, accuracy: 1)
            perform(windows[0].replacingFrame(right), .leftHalf)
            let left = try XCTUnwrap(controller.lockedPlacements[windows[0].stableIdentity]?.appliedFrame)
            XCTAssertEqual(left.width, screen.visibleFrame.width - minimum, accuracy: 1)
            XCTAssertNotEqual(left.width, windows[0].frame.width)
            registry.applyExplicitMeasurement([.minWidth: ceil(screen.visibleFrame.width * 0.52)],
                identity: identity.identity, displayName: identity.displayName)
            perform(windows[0].replacingFrame(left), .rightHalf, success: false)
            XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout, group.layout)
            XCTAssertEqual(controller.windowService.windowServerFrame(pid: process.processIdentifier,
                windowID: try XCTUnwrap(windows[0].cgWindowID)), left)
            return
        }
        if threeSlots {
            perform(windows[2], .bottomRight)
            let completed = try XCTUnwrap(controller.explicitGroupStore.group(id: group.id))
            XCTAssertEqual(completed.memberIDs.count, 3)
            XCTAssertEqual(completed.layout.zonesByMemberID[windows[2].stableIdentity], .bottomRight)
            perform(windows[0], .topRight)
            let exchanged = try XCTUnwrap(controller.explicitGroupStore.group(id: group.id))
            XCTAssertEqual(exchanged.memberIDs, completed.memberIDs)
            XCTAssertEqual(exchanged.layout.zonesByMemberID, [
                windows[0].stableIdentity: .topRight, windows[1].stableIdentity: .leftHalf,
                windows[2].stableIdentity: .bottomRight])
            settings.occupiedReplacementEnabled = true
            let current = try XCTUnwrap(controller.lockedPlacements[windows[0].stableIdentity]?.appliedFrame)
            perform(windows[0].replacingFrame(current), .rightHalf, success: false)
            XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout, exchanged.layout)
            return
        }
        perform(windows[0], .rightHalf)
        XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout.zonesByMemberID,
            [windows[0].stableIdentity: .rightHalf, windows[1].stableIdentity: .leftHalf])
        for index in 0..<2 {
            let frame = try XCTUnwrap(controller.windowService.windowServerFrame(pid: process.processIdentifier,
                windowID: try XCTUnwrap(windows[index].cgWindowID)))
            XCTAssertEqual(frame, windows[1-index].frame)
        }
        let swappedSource = windows[0].replacingFrame(windows[1].frame)
        perform(swappedSource, .leftHalf)
        XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout, group.layout)
        perform(windows[2], .rightHalf)
        XCTAssertNil(controller.explicitGroupStore.group(containing: windows[2].stableIdentity))
        XCTAssertNotNil(controller.lockedPlacements[windows[2].stableIdentity])
        XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.memberIDs, group.memberIDs)
        settings.occupiedReplacementEnabled = true
        let current = try XCTUnwrap(controller.windowService.windowServerFrame(pid: process.processIdentifier,
            windowID: try XCTUnwrap(windows[2].cgWindowID)))
        perform(windows[2].replacingFrame(current), .rightHalf)
        XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout.zonesByMemberID,
            [windows[0].stableIdentity: .leftHalf, windows[2].stableIdentity: .rightHalf])
        XCTAssertNil(controller.lockedPlacements[windows[1].stableIdentity])
        let placed = try XCTUnwrap(controller.lockedPlacements[windows[2].stableIdentity])
        perform(windows[2].replacingFrame(placed.appliedFrame), .maximize)
        XCTAssertEqual(controller.lockedPlacements[windows[2].stableIdentity]?.appliedFrame, screen.visibleFrame)
        XCTAssertNil(controller.explicitGroupStore.group(containing: windows[2].stableIdentity))
        XCTAssertFalse(AssistCandidateReservationPolicy.isReserved(placementZone: controller.lockedPlacements[windows[2].stableIdentity]?.zone))
    }
    private func buildFixture(in folder: URL) throws -> URL {
        let contents = folder.appendingPathComponent("PlacementFixture.app/Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("PlacementFixture")
        let info = ["CFBundleIdentifier": "local.tabora.placementfixture",
                    "CFBundleExecutable": "PlacementFixture", "CFBundlePackageType": "APPL"]
        try PropertyListEncoder().encode(info).write(to: contents.appendingPathComponent("Info.plist"))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/PlacementFixture.m")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-fobjc-arc", source.path, "-framework", "Cocoa", "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        return executable
    }

}
