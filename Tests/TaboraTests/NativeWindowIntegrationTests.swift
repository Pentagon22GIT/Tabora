import AppKit
import XCTest
@testable import Tabora

final class NativeWindowIntegrationTests: XCTestCase {
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
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility required") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let controller = SnapController()
        controller.isControllerRunning = true
        controller.isReconcilingPlacementMutation = true
        let windows = (0..<2).map { index -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 120 + index * 360, y: 180, width: 360, height: 280),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.title = "Tabora owned split fixture \(index)"
            window.backgroundColor = index == 0 ? .systemBlue : .systemOrange
            window.orderFront(nil)
            return window
        }
        defer { controller.stop(); windows.forEach { $0.close() } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        var raw: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
            kAXWindowsAttribute as CFString, &raw), .success)
        let elements = try XCTUnwrap(raw as? [AXUIElement])
        let managed = try windows.map { window -> ManagedWindow in
            let id = CGWindowID(window.windowNumber)
            let element = try XCTUnwrap(elements.first { RuntimeWindowIDResolver().resolve($0) == id })
            let frame = try XCTUnwrap(AXWindowService().windowServerFrame(pid: getpid(), windowID: id))
            return ManagedWindow(element: element, pid: getpid(), title: window.title, appIcon: nil,
                frame: frame, isMinimized: false, isFullscreen: false, cgWindowID: id)
        }
        let zones: [SnapZone] = [.leftHalf, .rightHalf]
        let placements = zip(managed, zones).map { window, zone in
            SplitPlacementGeometry(stableIdentity: window.stableIdentity, zone: zone, frame: window.frame)
        }
        let group = try XCTUnwrap(controller.explicitGroupStore.reconcileAfterLayoutMutation(
            preferredMemberID: managed[0].stableIdentity, displayID: CGMainDisplayID(),
            placements: placements, detachedConnections: []))
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
                    let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, .boundsIgnoreFraming)
                    print("SPLIT_CAPTURE: id=\(id) pixels=\(image?.width ?? 0)x\(image?.height ?? 0)")
                    return image
                }, transientPreviewProvider: { _, _ in nil })
        }
        refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let descriptor = try XCTUnwrap(proxy.spaceDescriptor(for: group.id))
        let proxyWindow = try XCTUnwrap(app.windows.first { $0.windowNumber > 0 && CGWindowID($0.windowNumber) == descriptor.windowID })
        XCTAssertTrue(proxyWindow.isVisible, "Must start with a real visible proxy, not only a dictionary entry")
        XCTAssertGreaterThan(proxyWindow.alphaValue, 0)
        proxyWindow.displayIfNeeded()
        let previewImage = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
            descriptor.windowID, .boundsIgnoreFraming))
        let bitmap = NSBitmapImageRep(cgImage: previewImage)
        let leftColor = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4,
            y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let rightColor = try XCTUnwrap(bitmap.colorAt(x: 3 * bitmap.pixelsWide / 4,
            y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(abs(leftColor.redComponent - rightColor.redComponent), 0.3,
            "The proxy must contain both captured window images, not an empty placeholder")
        if let folder = ProcessInfo.processInfo.environment["TABORA_UI_SNAPSHOT_DIR"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("split-proxy-before-close.png"))
        }
        let start = ProcessInfo.processInfo.systemUptime
        windows[0].performClose(nil)
        let deadline = start + 0.5
        while proxy.hasPresentation(for: group.id), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        let retired = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(proxy.hasPresentation(for: group.id))
        XCTAssertFalse(proxyWindow.isVisible)
        XCTAssertTrue(controller.lockedPlacements.isEmpty)
        XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
        XCTAssertTrue(windows[1].isVisible)
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, descriptor.windowID) as? [[String: Any]]
        XCTAssertFalse(info?.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true } ?? false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
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
        let choices = stack.arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0.action == nil }
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
                   let pixels = CGWindowListCreateImage(.null, .optionIncludingWindow,
                        CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
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
                    let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
                        CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
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
