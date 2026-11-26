import SwiftUI
import ScreenCaptureKit
import AppKit
import XCTest
@testable import Tabora

final class NativeWindowIntegrationTests: XCTestCase {
    // Observe only this test process. Keep this independent of the production
    // layer-zero policy so the oracle can inspect a real floating proxy panel.
    private func observedImage(_ id: CGWindowID) throws -> CGImage {
        guard #available(macOS 14, *) else { throw XCTSkip("Screenshot oracle requires macOS 14") }
        let ready = expectation(description: "Read owned test window")
        var result: CGImage?
        Task {
            defer { ready.fulfill() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == getpid() }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            result = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(result)
    }

    func testScopedScreenshotUsesPlannedPixelsAndRechecksAuthorization() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 320, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.backgroundColor = .systemBlue
        window.orderFrontRegardless()
        window.displayIfNeeded()
        defer { window.close() }
        let id = CGWindowID(window.windowNumber)
        let plan = PreviewFullSizeRequest(ownerPID: getpid(), windowSize: window.frame.size,
                                          targetPixelSize: CGSize(width: 160, height: 100))
        let finished = expectation(description: "Scoped window screenshot")
        DispatchQueue.global().async {
            XCTAssertNil(WindowPreviewCaptureService.capture(for: id, capacityWait: 0.1, expectedOwnerPID: getpid() + 1))
            var checks = 0
            let rejected = WindowPreviewCaptureService.capture(for: id, capacityWait: 0.1, expectedOwnerPID: getpid()) {
                checks += 1
                return checks == 1
            }
            XCTAssertNil(rejected)
            XCTAssertGreaterThanOrEqual(checks, 2, "A revoked request must be rechecked and rejected")
            let captured = WindowPreviewCaptureService.capture(for: id, capacityWait: 0.45, fullSizeRequest: plan)
            XCTAssertEqual(captured?.width, 160)
            XCTAssertEqual(captured?.height, 100)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testPickerRevocationReplacesDisplayedPixelsWithoutClosingSelection() throws {
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.windowPreviewsEnabled = true
        let controller = SnapController(settings: settings)
        controller.isControllerRunning = true
        controller.isApplicationUIVisible = true
        let picker = controller.picker
        defer { picker.hide() }
        func observePermission(_ granted: Bool) {
            controller.reconcilePreviewAccess(preflight: { granted })
            let end = Date().addingTimeInterval(2)
            while controller.previewAccessGranted != granted && Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(controller.previewAccessGranted, granted)
        }
        observePermission(true)
        let frame = CGRect(x: 100, y: 100, width: 420, height: 320)
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "app", accessibilityDescription: nil))
        let candidate = ManagedWindow(element: AXUIElementCreateApplication(getpid()), pid: getpid(),
            title: "Owned fixture", appIcon: icon, frame: frame, isMinimized: false,
            isFullscreen: false, cgWindowID: 7)
        let image = try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
        picker.show(windowsByZone: [.leftHalf: [candidate]], zoneFrames: [.leftHalf: frame],
                    previewProvider: { _, _ in image }, onCancel: {}, onSelect: { _, _ in })
        let views = app.windows.filter { !existing.contains(ObjectIdentifier($0)) }
            .compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? NSImageView }
        let placeholder = try XCTUnwrap(views.first { $0.image === icon })
        let preview = try XCTUnwrap(views.first { $0 !== placeholder })
        let cutoff = Date().addingTimeInterval(2)
        while preview.image == nil && Date() < cutoff {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(preview.image)
        observePermission(false)
        XCTAssertNil(preview.image)
        XCTAssertFalse(placeholder.isHidden)
        XCTAssertTrue(picker.isVisible)
        observePermission(true)
        let reacquired = Date().addingTimeInterval(2)
        while preview.image == nil && Date() < reacquired {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(preview.image)
        // Hold one physical permission probe beyond its deadline. The watchdog
        // must clear already displayed pixels without queuing a second OS call.
        let release = DispatchSemaphore(value: 0)
        controller.reconcilePreviewAccess { _ = release.wait(timeout: .now() + 5); return true }
        RunLoop.main.run(until: Date().addingTimeInterval(3.1))
        controller.reconcilePreviewAccess { XCTFail("overlapping permission probe"); return true }
        XCTAssertFalse(controller.previewAccessGranted)
        release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(controller.previewAccessGranted)
        XCTAssertNil(preview.image)
        XCTAssertFalse(placeholder.isHidden)
        XCTAssertTrue(picker.isVisible)
        observePermission(true)
        let restored = Date().addingTimeInterval(2)
        while preview.image == nil && Date() < restored {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(preview.image)
        settings.windowPreviewsEnabled = false
        controller.reconcilePreviewAccess(preflight: { XCTFail("OFF must skip OS probe"); return true })
        XCTAssertNil(preview.image)
        XCTAssertFalse(placeholder.isHidden)
        XCTAssertTrue(picker.isVisible)
    }

    func testPickerReloadRequestsNewPhysicalWindowForSameAXCard() throws {
        _ = NSApplication.shared
        let picker = WindowPickerPanel()
        defer { picker.hide() }
        let frame = CGRect(x: 200, y: 200, width: 400, height: 300)
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "app", accessibilityDescription: nil))
        let image = try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let first = ManagedWindow(element: AXUIElementCreateApplication(getpid()), pid: getpid(),
            title: "Sample", appIcon: icon, frame: frame, isMinimized: false, isFullscreen: false, cgWindowID: 17)
        let replacement = first.replacingCGWindowID(18)
        let initial = expectation(description: "First physical card")
        let next = expectation(description: "New physical card")
        picker.show(windowsByZone: [.leftHalf: [first]], zoneFrames: [.leftHalf: frame],
            previewProvider: { subject, _ in
                XCTAssertEqual(subject.pid, getpid())
                switch subject.windowID {
                case 17: initial.fulfill()
                case 18: next.fulfill()
                default: XCTFail("Unexpected preview subject")
                }
                return image
            }, onCancel: {}, onSelect: { _, _ in })
        wait(for: [initial], timeout: 2)
        XCTAssertTrue(picker.updateLayout(windowsByZone: [.leftHalf: [replacement]],
            zoneFrames: [.leftHalf: frame], onCancel: {}, onSelect: { _, _ in }))
        wait(for: [next], timeout: 2)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func selectGesturePage(_ root: NSView) throws -> [SettingsSwitch] {
        let table = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: false)
        root.layoutSubtreeIfNeeded()
        let controls = descendants(root).compactMap { $0 as? SettingsSwitch }
        return try ["settings.gesture.snap", "settings.gesture.maximize", "settings.split_lock"].map { key in
            try XCTUnwrap(controls.first { $0.title == L10n.text(key) })
        }
    }

    func testGestureSettingsAlignSwitchesAndPreserveDependencies() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let controls = try selectGesturePage(root)
        let parent = controls[0]
        let row = try XCTUnwrap(descendants(root).compactMap { $0 as? SettingsRow }.first { row in
            row.arrangedSubviews.contains { ($0 as? SettingsSwitch)?.title == L10n.text("settings.gesture.reassign") }
        })
        XCTAssertTrue(row.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == L10n.text("settings.gesture.reassign.note") })
        let position = parent.convert(parent.bounds, to: root)
        XCTAssertGreaterThan(position.width, 0)
        XCTAssertLessThanOrEqual(position.maxX, root.bounds.maxX)
        for child in controls.dropFirst() {
            XCTAssertEqual(child.convert(child.bounds, to: root).minX, position.minX, accuracy: 1)
            XCTAssertEqual(child.isEnabled, parent.state == .on)
        }
    }

    func testGestureCheckboxesPersistAcrossParentToggleAndWindowRecreation() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["gestureSnapEnabled", "maximizeOnUpwardGesture", "splitLockEnabled"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.set(false, forKey: $0) }
        func controls(_ controller: SettingsWindowController) throws -> [NSSwitch] {
            try selectGesturePage(XCTUnwrap(controller.window?.contentView)).map(\.control)
        }
        func click(_ control: NSSwitch) {
            control.state = control.state == .on ? .off : .on
            XCTAssertTrue(control.sendAction(control.action, to: control.target))
        }
        let controller = SettingsWindowController()
        defer { controller.window?.close() }
        let checkboxes = try controls(controller)
        for checkbox in checkboxes { click(checkbox) }
        XCTAssertTrue(keys.allSatisfy { defaults.bool(forKey: $0) })
        click(checkboxes[0])
        XCTAssertTrue(checkboxes.dropFirst().allSatisfy { !$0.isEnabled && $0.state == .on })
        XCTAssertTrue(keys.dropFirst().allSatisfy { defaults.bool(forKey: $0) })
        let reopened = SettingsWindowController()
        defer { reopened.window?.close() }
        let restored = try controls(reopened)
        click(restored[0])
        XCTAssertTrue(restored.allSatisfy { $0.isEnabled && $0.state == .on })
    }

    func testShortcutRecordingEndsWhenSettingsLoseKeyboardFocus() throws {
        let controller = SettingsWindowController()
        controller.show()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let root = try XCTUnwrap(window.contentView)
        let navigation = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
        var changes: [Bool] = []
        controller.onShortcutRecordingChange = { changes.append($0) }
        for row in 0..<navigation.numberOfRows where navigation.delegate?.tableView?(navigation, shouldSelectRow: row) == true {
            navigation.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: {
                $0.action == NSSelectorFromString("recordShortcut:") && $0.isEnabled
            }) {
                XCTAssertTrue(button.sendAction(button.action, to: button.target))
                break
            }
        }
        XCTAssertEqual(changes, [true])
        // XCTest may run without owning system keyboard focus. Deliver AppKit's
        // delegate notification to the actual recorder after its button action.
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertEqual(changes, [true, false])
        XCTAssertTrue(window.isVisible)
    }

    func testSettingsPreviewLifecycle() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        window.animationBehavior = .none
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
        controller.show()
        // General is the first selectable category, shared resize the second.
        let categories = (0..<table.numberOfRows).filter {
            table.delegate?.tableView?(table, shouldSelectRow: $0) == true
        }
        table.selectRowIndexes(IndexSet(integer: categories[1]), byExtendingSelection: false)
        let rows = descendants(root).compactMap { $0 as? SettingsRow }.filter { $0.onEnter != nil }
        let selected = try XCTUnwrap(rows.last)
        selected.onEnter?()
        func dispatchFocusEvents() {
            // XCTest drives the run loop but does not dispatch AppKit focus events.
            let deadline = Date().addingTimeInterval(0.75)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        func check(_ hosts: Int, line: UInt = #line) {
            dispatchFocusEvents()
            XCTAssertEqual(descendants(root).filter { $0 is NSHostingView<OperationPreview> }.count, hosts, "active=\(NSApp.isActive) key=\(window.isKeyWindow) occlusion=\(window.occlusionState.rawValue)", line: line)
        }
        dispatchFocusEvents()
        guard NSApp.isActive else {
            throw XCTSkip("The real keyboard-focus test needs foreground access to the desktop")
        }
        check(1)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
                             styleMask: .titled, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        check(0)
        XCTAssertTrue(window.isVisible)
        window.makeKeyAndOrderFront(nil)
        check(1)
        XCTAssertTrue(selected.showsPreview)
        window.miniaturize(nil)
        check(0)
        window.deminiaturize(nil)
        check(1)
        XCTAssertTrue(selected.showsPreview)
        window.close()
        check(0)
        controller.show()
        check(1)
        XCTAssertTrue(selected.showsPreview)
        table.selectRowIndexes(IndexSet(integer: categories[0]), byExtendingSelection: false)
        check(0)
    }

    func testSettingsDescriptionsFitInEveryLanguageAndCategory() throws {
        _ = NSApplication.shared
        let original = L10n.language
        defer { L10n.language = original }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        for language in AppLanguage.allCases {
            L10n.language = language
            let controller = SettingsWindowController()
            let window = try XCTUnwrap(controller.window)
            defer { window.close() }
            let root = try XCTUnwrap(window.contentView)
            let categories = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
            for index in 0..<categories.numberOfRows where categories.delegate?.tableView?(categories, shouldSelectRow: index) == true {
                categories.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                root.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first { $0.documentView !== categories })
                let document = try XCTUnwrap(scroll.documentView)
                let page = try XCTUnwrap(document.subviews.first)
                let contentEnd = page.convert(page.bounds, to: document).maxY
                let expectedRange = max(0, contentEnd + 16 - scroll.contentView.bounds.height)
                var proposed = scroll.contentView.bounds
                proposed.origin.y = document.bounds.height
                XCTAssertEqual(scroll.contentView.constrainBoundsRect(proposed).minY, expectedRange, accuracy: 1)
                for field in descendants(document).compactMap({ $0 as? NSTextField })
                    where !field.isHiddenOrHasHiddenAncestor && !field.stringValue.isEmpty {
                    let frame = field.convert(field.bounds, to: document)
                    let info = "\(language) tab \(index): \(field.stringValue)"
                    XCTAssertLessThanOrEqual(frame.maxX, scroll.contentSize.width + 1, info)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1, info)
                    if field.maximumNumberOfLines == 1 || field.cell?.wraps == false {
                        XCTAssertLessThanOrEqual(field.intrinsicContentSize.width, frame.width + 1, info)
                    }
                    if let cell = field.cell, cell.wraps {
                        let needed = cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: frame.width, height: 10000))
                        XCTAssertGreaterThanOrEqual(frame.height + 1, needed.height, info)
                    }
                }
            }
        }
    }

    func testSplitLockNoticeDoesNotTakeFocusAndDismisses() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let notice = SplitLockNotice()
        defer { notice.orderOut(nil) }
        let previousKey = NSApp.keyWindow
        notice.show(enabled: true, on: screen)
        notice.show(enabled: false, on: screen)
        XCTAssertTrue(notice.isVisible)
        XCTAssertTrue(notice.ignoresMouseEvents)
        XCTAssertFalse(notice.canBecomeKey)
        XCTAssertFalse(notice.canBecomeMain)
        XCTAssertTrue(NSApp.keyWindow === previousKey)
        XCTAssertEqual(notice.frame.maxY, screen.visibleFrame.maxY - 10, accuracy: 1)
        let deadline = Date().addingTimeInterval(3)
        while notice.isVisible && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(notice.isVisible)
    }

    func testPhysicalLivenessDistinguishesMinimizedClosedAndWrongOwner() throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility required") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        defer { window.close() }
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let id = CGWindowID(window.windowNumber)
        let service = AXWindowService()
        var value: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
            kAXWindowsAttribute as CFString, &value), .success)
        let element = try XCTUnwrap((value as? [AXUIElement])?.first { RuntimeWindowIDResolver().resolve($0) == id })
        XCTAssertEqual(service.physicalWindowLiveness(element: element, pid: getpid(), windowID: id), .alive)
        XCTAssertEqual(service.physicalWindowLiveness(element: element, pid: getpid() + 1, windowID: id), .missing)
        window.miniaturize(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(service.physicalWindowLiveness(element: element, pid: getpid(), windowID: id), .alive)
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(service.physicalWindowLiveness(element: element, pid: getpid(), windowID: id), .missing)
    }

    func testPhysicalRetirementAcrossLayoutsWithoutAXDestructionNotification() throws {
        let layouts: [[SnapZone]] = [
            [.leftHalf, .rightHalf],
            [.leftHalf, .topRight, .bottomRight],
            [.topLeft, .topRight, .bottomLeft, .bottomRight]
        ]
        for zones in layouts {
            for closedIndex in zones.indices {
                let controller = SnapController()
                controller.isControllerRunning = true
                controller.isReconcilingPlacementMutation = true
                defer { controller.stop() }
                let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
                let members = zones.indices.map { "fixture-\(zones.count)-\($0)" }
                let group = try XCTUnwrap(controller.explicitGroupStore.reconcileAfterLayoutMutation(
                    preferredMemberID: members[0], displayID: CGMainDisplayID(),
                    placements: zones.indices.map {
                        SplitPlacementGeometry(stableIdentity: members[$0], zone: zones[$0], frame: zones[$0].frame(in: bounds))
                    }, detachedConnections: []))
                controller.lockedPlacements = Dictionary(uniqueKeysWithValues: zones.indices.map {
                    (members[$0], LockedPlacement(element: AXUIElementCreateApplication(getpid()), pid: getpid(),
                        stableIdentity: members[$0], cgWindowID: CGWindowID(100 + $0), zone: zones[$0],
                        displayID: CGMainDisplayID(), appliedFrame: zones[$0].frame(in: bounds)))
                })
                // An unavailable all-Space query must preserve structural truth.
                controller.reconcileMissingExplicitGroupWindows(windowServerSnapshot: [], exactLiveness: { _, _ in .unknown })
                XCTAssertEqual(controller.explicitGroupStore.groups.map(\.id), [group.id])
                // Hidden/minimized/off-Space exact windows still exist.
                controller.reconcileMissingExplicitGroupWindows(windowServerSnapshot: [], exactLiveness: { _, _ in .alive })
                XCTAssertEqual(controller.lockedPlacements.count, zones.count)
                // No AX callback, even while a transform-preservation gate is set.
                controller.isPreservingGroupPresentationForWindowServerTransform = true
                controller.reconcileMissingExplicitGroupWindows(windowServerSnapshot: [], exactLiveness: { pid, id in
                    XCTAssertEqual(pid, getpid())
                    return id == CGWindowID(100 + closedIndex) ? .missing : .alive
                })
                XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
                XCTAssertTrue(controller.lockedPlacements.isEmpty)
            }
        }
    }

    func testExactWindowDescriptionUsesRealWindowServerIdentity() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        defer { window.close() }
        let id = CGWindowID(window.windowNumber)
        let service = AXWindowService()
        let frame = try XCTUnwrap(service.windowServerFrame(pid: getpid(), windowID: id))
        XCTAssertEqual(frame.width, window.frame.width, accuracy: 1)
        XCTAssertEqual(frame.height, window.frame.height, accuracy: 1)
        XCTAssertNil(service.windowServerFrame(pid: getpid() + 1, windowID: id))
    }

    func testManagedWindowDestroyedNotification() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("The test host has no Accessibility authorization; live AX close latency remains unverified.")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var value: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
            kAXWindowsAttribute as CFString, &value), .success)
        let elements = try XCTUnwrap(value as? [AXUIElement])
        let element = try XCTUnwrap(elements.first {
            RuntimeWindowIDResolver().resolve($0) == CGWindowID(window.windowNumber)
        })
        let observer = ActiveWindowObserver()
        defer { observer.stop() }
        let delivered = expectation(description: "destroy notification")
        observer.onDestroyed = { target in
            XCTAssertEqual(target.identity, "owned-fixture")
            observer.stop()
            delivered.fulfill()
        }
        observer.synchronizeManagedWindows([.init(identity: "owned-fixture", pid: getpid(), element: element)])
        window.close()
        wait(for: [delivered], timeout: 0.5)
    }

    /// Runs the production group/proxy/destruction path with real native windows.
    /// Does not start the controller's global input monitors or recovery timer.
    func testSplitWindowCloseRetiresVisibleProxyAndPeerLocks() throws {
        try assertSplitWindowClose(zones: [.leftHalf, .rightHalf], closedIndex: 0, deliversNotification: true)
    }

    func testSplitCloseWithStaleAXCensusAndNoNotificationAcrossAllLayouts() throws {
        let layouts: [[SnapZone]] = [
            [.leftHalf, .rightHalf], [.leftHalf, .topRight, .bottomRight],
            [.topLeft, .topRight, .bottomLeft, .bottomRight]
        ]
        for zones in layouts {
            for index in zones.indices {
                try assertSplitWindowClose(zones: zones, closedIndex: index, deliversNotification: false)
            }
        }
    }

    func testMinimizedMemberRemovesPixelsButPreservesGroupAcrossAllLayouts() throws {
        for zones: [SnapZone] in [
            [.leftHalf, .rightHalf], [.leftHalf, .topRight, .bottomRight],
            [.topLeft, .topRight, .bottomLeft, .bottomRight]
        ] {
            try assertSplitWindowClose(zones: zones, closedIndex: zones.count - 1,
                                       deliversNotification: false, minimizesMember: true)
        }
    }

    func testRevokingDisplayedGroupPixelsPreservesProxyAndPlacement() throws {
        try assertSplitWindowClose(zones: [.leftHalf, .rightHalf], closedIndex: 1,
                                   deliversNotification: false, verifyRevocation: true)
    }

    func testDesktopRecoveryWithdrawsProxyOrderedAboveItsMembers() throws {
        try assertSplitWindowClose(zones: [.leftHalf, .rightHalf], closedIndex: 0,
                                   deliversNotification: false, unexpectedProxyFocus: true)
    }

    private func assertSplitWindowClose(zones: [SnapZone], closedIndex: Int,
                                       deliversNotification: Bool, minimizesMember: Bool = false,
                                       verifyRevocation: Bool = false, unexpectedProxyFocus: Bool = false) throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility required") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let controller = SnapController()
        controller.isControllerRunning = true
        controller.isReconcilingPlacementMutation = true
        let visible = try XCTUnwrap(NSScreen.screens.first).visibleFrame.insetBy(dx: 24, dy: 24)
        let bounds = CGRect(x: ceil(visible.minX), y: ceil(visible.minY),
                            width: 2 * floor(min(720, visible.width) / 2),
                            height: 2 * floor(min(560, visible.height) / 2))
        let windows = zones.indices.map { index -> NSWindow in
            let window = NSWindow(contentRect: zones[index].frame(in: bounds),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.tabbingMode = .disallowed
            window.setFrame(zones[index].frame(in: bounds), display: false)
            window.title = "Tabora owned split fixture \(index)"
            window.backgroundColor = index == 0 ? .systemBlue : .systemOrange
            window.orderFront(nil)
            return window
        }
        defer { controller.stop(); windows.forEach { $0.close() } }
        // WindowServer may temporarily report compositor-scaled bounds for our
        // windows. Establish the physical fixture before exercising closure.
        let service = controller.windowService
        let expected = zones.map { $0.frame(in: bounds) }
        let layoutDeadline = Date().addingTimeInterval(2)
        var observed: [CGRect?]
        repeat {
            observed = windows.map { service.windowServerFrame(pid: getpid(), windowID: CGWindowID($0.windowNumber)) }
            if zip(observed, expected).allSatisfy({ $0 == $1 }) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        } while Date() < layoutDeadline
        guard zip(observed, expected).allSatisfy({ $0 == $1 }) else {
            return XCTFail("Before closure: expected fixture frames \(expected), observed \(observed)")
        }
        var raw: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
            kAXWindowsAttribute as CFString, &raw), .success)
        let elements = try XCTUnwrap(raw as? [AXUIElement])
        let managed = try windows.map { window -> ManagedWindow in
            let id = CGWindowID(window.windowNumber)
            let element = try XCTUnwrap(elements.first { RuntimeWindowIDResolver().resolve($0) == id })
            let frame = try XCTUnwrap(AXWindowService().windowServerFrame(pid: getpid(), windowID: id))
            return ManagedWindow(element: element, pid: getpid(), title: window.title, appIcon: NSImage(systemSymbolName: "app", accessibilityDescription: nil),
                frame: frame, isMinimized: false, isFullscreen: false, cgWindowID: id)
        }
        let placements = zip(managed, zones).map { window, zone in
            SplitPlacementGeometry(stableIdentity: window.stableIdentity, zone: zone, frame: window.frame)
        }
        let group = try XCTUnwrap(controller.explicitGroupStore.reconcileAfterLayoutMutation(
            preferredMemberID: managed[0].stableIdentity, displayID: CGMainDisplayID(),
            placements: placements, detachedConnections: []), "Fixture frames: \(managed.map(\.frame)) zones: \(zones)")
        controller.lockedPlacements = Dictionary(uniqueKeysWithValues: zip(managed, zones).map { window, zone in
            (window.stableIdentity, LockedPlacement(element: window.element, pid: window.pid,
                stableIdentity: window.stableIdentity, cgWindowID: window.cgWindowID, zone: zone,
                displayID: CGMainDisplayID(), appliedFrame: window.frame))
        })
        let proxy = controller.missionControlGroupProxyController
        // This fixture supplies its own scoped census; never enumerate or mutate
        // other apps through the controller's normal presentation callbacks.
        proxy.onPreviewCacheReady = nil
        proxy.onPreviewConfirmationNeeded = nil
        func refresh() {
            proxy.update(groups: [group], visibleWindowsByIdentity: Dictionary(uniqueKeysWithValues:
                managed.map { ($0.stableIdentity, $0) }), displayOrdinalsByGroupID: [group.id: 1],
                structuralGroupIDs: [group.id], structuralMemberIDs: group.memberIDs,
                structuralMemberIDsByGroupID: [group.id: group.memberIDs],
                previewVisibilityEvaluationByGroupID: [group.id: .hot], previewsEnabled: true,
                previewCacheByteLimit: 16 * 1024 * 1024,
                previewProvider: { id, authorized in
                    guard authorized(), let id else { return nil }
                    let image = WindowPreviewCaptureService.capture(for: id, capacityWait: 0.45, isGroupPreview: true, expectedOwnerPID: getpid(), shouldCapture: authorized)
                    print("SPLIT_CAPTURE: id=\(id) pixels=\(image?.width ?? 0)x\(image?.height ?? 0)")
                    return image
                }, transientPreviewProvider: { _, _ in nil })
        }
        proxy.onPreviewCacheReady = { refresh() }
        defer { proxy.onPreviewCacheReady = nil }
        refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let descriptor = try XCTUnwrap(proxy.spaceDescriptor(for: group.id))
        let proxyWindow = try XCTUnwrap(app.windows.first { $0.windowNumber > 0 && CGWindowID($0.windowNumber) == descriptor.windowID })
        XCTAssertTrue(proxyWindow.isVisible, "Must start with a real visible proxy, not only a dictionary entry")
        XCTAssertGreaterThan(proxyWindow.alphaValue, 0)
        if unexpectedProxyFocus {
            proxy.onPreviewCacheReady = nil
            proxy.currentTransitionAuthorization = { _ in false }
            proxyWindow.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let observation = controller.windowService.windowOcclusionSnapshotObservation(includingOrder: true)
            proxy.withdrawUnsafeDesktopProxies(orderedWindowIDs: observation.orderedWindowIDs)
            XCTAssertFalse(proxyWindow.isVisible)
            XCTAssertTrue(proxyWindow.ignoresMouseEvents)
            XCTAssertEqual(controller.explicitGroupStore.groups.map(\.id), [group.id])
            return
        }
        proxyWindow.displayIfNeeded()
        let readyDeadline = Date().addingTimeInterval(3)
        var bitmap: NSBitmapImageRep
        var leftColor: NSColor
        var rightColor: NSColor
        repeat {
            bitmap = NSBitmapImageRep(cgImage: try observedImage(descriptor.windowID))
            leftColor = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4,
            y: bitmap.pixelsHigh / 4)?.usingColorSpace(.deviceRGB))
            rightColor = try XCTUnwrap(bitmap.colorAt(x: 3 * bitmap.pixelsWide / 4,
            y: bitmap.pixelsHigh / 4)?.usingColorSpace(.deviceRGB))
            if abs(leftColor.redComponent - rightColor.redComponent) > 0.3 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        } while Date() < readyDeadline
        // The fixture census is valid only until closure. Stop replaying it
        // before handing lifecycle ownership back to the controller.
        proxy.onPreviewCacheReady = nil
        XCTAssertGreaterThan(abs(leftColor.redComponent - rightColor.redComponent), 0.3,
            "The proxy must contain both captured window images, not an empty placeholder")
        if verifyRevocation {
            proxy.setPreviewsEnabled(false)
            proxyWindow.displayIfNeeded()
            let cleared = NSBitmapImageRep(cgImage: try observedImage(descriptor.windowID))
            let a = try XCTUnwrap(cleared.colorAt(x: cleared.pixelsWide / 4,
                y: cleared.pixelsHigh / 4)?.usingColorSpace(.deviceRGB))
            let b = try XCTUnwrap(cleared.colorAt(x: 3 * cleared.pixelsWide / 4,
                y: cleared.pixelsHigh / 4)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(abs(a.redComponent - b.redComponent), 0.05)
            XCTAssertGreaterThan(max(abs(a.redComponent - leftColor.redComponent),
                                     abs(b.redComponent - rightColor.redComponent)), 0.15)
            XCTAssertTrue(proxyWindow.isVisible)
            XCTAssertEqual(controller.explicitGroupStore.groups.map(\.id), [group.id])
            XCTAssertEqual(controller.lockedPlacements.count, zones.count)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["TABORA_UI_SNAPSHOT_DIR"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("split-proxy-before-close.png"))
        }
        if !deliversNotification { controller.activeWindowObserver.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        if minimizesMember { windows[closedIndex].miniaturize(nil) }
        else { windows[closedIndex].performClose(nil) }
        if !deliversNotification {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            // Deliberately supply the stale pre-close AX census. The shared
            // physical-lifetime gate must run before geometry/preservation.
            let snapshot = managed.indices.filter { $0 != closedIndex }.map {
                WindowOcclusionSnapshot(windowID: managed[$0].cgWindowID!, pid: getpid(),
                    frame: managed[$0].frame, zIndex: $0, layer: 0)
            }
            let census = minimizesMember ? managed.enumerated().filter { $0.offset != closedIndex }.map(\.element) : managed
            controller.refreshResizeHandles(using: census, windowServerSnapshot: snapshot,
                                             windowServerSnapshotCompleteness: .complete)
        }
        let deadline = start + 0.5
        while proxy.hasPresentation(for: group.id), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        let retired = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(proxy.hasPresentation(for: group.id))
        XCTAssertFalse(proxyWindow.isVisible)
        if minimizesMember {
            XCTAssertEqual(controller.lockedPlacements.count, zones.count)
            XCTAssertEqual(controller.explicitGroupStore.groups.map(\.id), [group.id])
        } else {
            XCTAssertTrue(controller.lockedPlacements.isEmpty)
            XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
        }
        for index in zones.indices where index != closedIndex {
            XCTAssertTrue(windows[index].isVisible)
        }
        // AppKit publishes orderOut to Window Server on the next run-loop turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, descriptor.windowID) as? [[String: Any]]
        XCTAssertFalse(info?.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true } ?? false)
        XCTAssertFalse(proxy.hasPresentation(for: group.id), "Late capture/order callbacks must not resurrect a retired proxy")
        XCTAssertFalse(proxyWindow.isVisible)
        print("SPLIT_CLOSE: proxy retired and WindowServer hidden in \((retired - start) * 1000) ms")
    }

    func testCanceledPhysicalCaptureCannotOverlapOrPublishIntoNewSession() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 432,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 432))
        let pixels = try XCTUnwrap(context.makeImage())
        let plan = MissionControlTransientPreviewGroupPlan(groupID: SnapGroupID(), groupRevision: 1,
            displayID: CGMainDisplayID(), proxyFrame: window.frame,
            members: [.init(stableIdentity: "fixture", pid: getpid(), windowID: CGWindowID(window.windowNumber),
                relativeFrame: CGRect(x: 0, y: 0, width: 640, height: 432),
                targetPixelSize: .init(width: 640, height: 432), byteBudget: 640 * 432 * 4)])
        let capturer = MissionControlTransientPreviewCapturer()
        let entered = expectation(description: "provider entered")
        let finished = expectation(description: "physical capture quiesced")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); capturer.cancel() }
        XCTAssertTrue(capturer.capture(generation: 10, plans: [plan], previewProvider: { _, authorized in
            XCTAssertTrue(authorized())
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            XCTAssertFalse(authorized())
            return pixels
        }, onGroupReady: { _ in XCTFail("Canceled pixels were published") }, onFinished: { finished.fulfill() }))
        wait(for: [entered], timeout: 1)
        capturer.cancel()
        XCTAssertFalse(capturer.capture(generation: 11, plans: [plan], previewProvider: { _, _ in
            XCTFail("A second physical capture overlapped"); return pixels
        }, onGroupReady: { _ in XCTFail("Overlapping capture published") }, onFinished: {}))
        release.signal()
        wait(for: [finished], timeout: 1)
        let next = expectation(description: "new session published")
        let ended = expectation(description: "new session completed")
        XCTAssertTrue(capturer.capture(generation: 12, plans: [plan], previewProvider: { _, authorized in
            XCTAssertTrue(authorized()); return pixels
        }, onGroupReady: { result in
            XCTAssertEqual(result.groupID, plan.groupID); next.fulfill()
        }, onFinished: { ended.fulfill() }))
        wait(for: [next, ended], timeout: 1)
    }

    func testInitialSetupNavigatesInOneWindowAndPreservesChoices() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let controller = InitialSetupWindowController(language: .japanese)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        let number = window.windowNumber
        func primaryOrigin() throws -> CGPoint {
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(content.subviews.flatMap(\.subviews).first {
                $0.identifier?.rawValue == "setup.primary"
            })
            return button.convert(CGPoint(x: button.bounds.maxX, y: 0), to: content)
        }
        let firstOrigin = try primaryOrigin()
        XCTAssertEqual(firstOrigin.x, window.contentView!.bounds.width - 28, accuracy: 1)
        controller.perform(NSSelectorFromString("advance"))
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(window.windowNumber, number)
        let stack = try XCTUnwrap(window.contentView?.subviews.first as? NSStackView)
        let choices = descendants(stack).compactMap { $0 as? NSSwitch }
        XCTAssertEqual(choices.count, 2)
        choices.forEach { $0.state = .on }
        let secondOrigin = try primaryOrigin()
        XCTAssertEqual(firstOrigin.x, secondOrigin.x, accuracy: 1)
        XCTAssertEqual(firstOrigin.y, secondOrigin.y, accuracy: 1)
        controller.perform(NSSelectorFromString("goBack"))
        XCTAssertTrue(controller.window === window)
        controller.perform(NSSelectorFromString("advance"))
        XCTAssertTrue(choices.allSatisfy { $0.state == .on })
        XCTAssertEqual(window.windowNumber, number)
        // Never press Finish: no login-item or screen-recording mutation.
    }

    func testAppInformationNoticeLayoutsDoNotApplySettings() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        for language in AppLanguage.allCases {
            for presentation in [InstallationPresentation.informationUpdate, .review] {
                let controller = InitialSetupWindowController(language: language, presentation: presentation)
                let window = try XCTUnwrap(controller.window)
                window.animationBehavior = .none
                window.orderFront(nil)
                defer { window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded()
                let stack = try XCTUnwrap(content.subviews.first as? NSStackView)
                for view in stack.arrangedSubviews {
                    XCTAssertGreaterThan(view.frame.height, 0)
                    XCTAssertLessThanOrEqual(view.frame.maxY, stack.bounds.height + 1)
                }
                if presentation == .informationUpdate,
                   let folder = ProcessInfo.processInfo.environment["TABORA_UI_SNAPSHOT_DIR"],
                   let pixels = try? observedImage(CGWindowID(window.windowNumber)),
                   let png = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("information-\(language.rawValue).png"))
                }
            }
        }
    }

    func testSetupLayoutInEveryLanguageWithoutApplyingSettings() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        for language in AppLanguage.allCases {
            let controller = InitialSetupWindowController(language: language)
            let window = try XCTUnwrap(controller.window)
            window.animationBehavior = .none
            window.orderFront(nil)
            defer { window.close() }
            for step in 0...1 {
                let content = try XCTUnwrap(window.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let stack = try XCTUnwrap(content.subviews.first as? NSStackView)
                for view in stack.arrangedSubviews {
                    XCTAssertGreaterThan(view.frame.height, 0)
                    XCTAssertGreaterThanOrEqual(view.frame.minY, 0)
                    XCTAssertLessThanOrEqual(view.frame.maxY, stack.bounds.height + 1)
                }
                if let folder = ProcessInfo.processInfo.environment["TABORA_UI_SNAPSHOT_DIR"] {
                    let image = try observedImage(CGWindowID(window.windowNumber))
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: folder)
                        .appendingPathComponent("setup-\(language.rawValue)-\(step).png"))
                }
                if step == 0 { controller.perform(NSSelectorFromString("advance")) }
            }
        }
    }
}
