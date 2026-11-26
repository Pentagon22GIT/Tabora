import AppKit
import XCTest
@testable import Tabora

final class PlacementWindowIntegrationTests: XCTestCase {
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

    func testExternalWindowCanMaximizeWhileSettingsRemainOpen() throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility required") }
        let delegate = TaboraApp()
        _ = delegate.perform(NSSelectorFromString("openSettings"))
        let settings = try XCTUnwrap(NSApp.windows.first { SettingsWindowController.ownsInput($0) && $0.isVisible })
        defer { settings.close() }

        let fixture = Process()
        fixture.executableURL = try Self.compiledFixture.get()
        fixture.arguments = ["candidate-only", "{{120, 160}, {420, 320}}", "160"]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let service = AXWindowService()
        let deadline = Date().addingTimeInterval(5)
        while service.windowServerSelectionSnapshot()?.pid != fixture.processIdentifier && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let selected = try XCTUnwrap(service.windowServerSelectionSnapshot())
        guard selected.pid == fixture.processIdentifier else { return XCTFail("Fixture must own focus") }
        let settingsID = CGWindowID(settings.windowNumber)
        let snapshot = service.windowOcclusionSnapshot()
        XCTAssertTrue(snapshot.contains { $0.windowID == settingsID && $0.pid == getpid() && $0.layer == 0 })
        let candidates = service.visibleWindows()
        XCTAssertTrue(candidates.contains { $0.pid == selected.pid && $0.cgWindowID == selected.windowID })
        XCTAssertFalse(candidates.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
        let original = try XCTUnwrap(service.windowServerFrame(pid: selected.pid, windowID: selected.windowID))
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(CGPoint(x: original.midX, y: original.midY)) })
        let target = SnapZone.maximize.frame(in: screen)
        XCTAssertNotEqual(original, target)
        _ = delegate.perform(NSSelectorFromString("maximize"))
        let end = Date().addingTimeInterval(5)
        while service.windowServerFrame(pid: selected.pid, windowID: selected.windowID) != target && Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(service.windowServerFrame(pid: selected.pid, windowID: selected.windowID), target)
        XCTAssertTrue(settings.isVisible)
        let member = WindowOcclusionParticipant(pid: selected.pid, frame: target, windowID: selected.windowID)
        func settingsCoversMember() throws -> Bool {
            let above = try XCTUnwrap(service.occludingWindows(above: [member], in: service.windowOcclusionSnapshot()))
            return above.contains { $0.windowID == settingsID }
        }
        settings.order(.below, relativeTo: Int(selected.windowID))
        XCTAssertFalse(try settingsCoversMember())
        settings.order(.above, relativeTo: Int(selected.windowID))
        let orderDeadline = Date().addingTimeInterval(2)
        while try !settingsCoversMember(), Date() < orderDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(try settingsCoversMember())
    }

    func testSelfGestureReassignsHalfAndCancelsCorner() throws {
        try exercisePlacement(threeSlots: false, reassign: true)
        try exercisePlacement(threeSlots: true, reassign: true)
    }

    func testSelfGestureFitsUnrecordedMaximumWidth() throws {
        try exercisePlacement(threeSlots: false, reassign: true, maximumWidth: true)
    }

    func testSelfGestureFittingCandidateDoesNotRequestMeasurement() throws {
        try exercisePlacement(threeSlots: false, reassign: true, freelyResizable: true)
    }

    func testSelfGestureRespectsRecordedMaximumWhenAppAcceptsLargerSizes() throws {
        try exercisePlacement(threeSlots: false, reassign: true, freelyResizable: true, recordedMaximum: true)
    }

    func testExplicitMeasurementFindsActualLimitsAndRestoresInitialGeometry() throws {
        try exercisePlacement(threeSlots: false, externalCandidateOnOtherDisplay: false, measuresBounds: true)
    }

    func testLockedCombinedExchangeUsesAllThreeMembersConstraints() throws {
        try exercisePlacement(threeSlots: true, combinedExchange: true)
    }

    func testGestureExchangeAndIndependentPlacementWithOwnedAXClient() throws {
        try exercisePlacement(threeSlots: false)
    }

    func testIndependentMaximizeKeepsGroupExchangeAndRestoreSize() throws {
        try exercisePlacement(threeSlots: false, maximizeMemberInput: .shortcut)
    }

    func testMaximizingStagedDragCommitsGroupDeparture() throws {
        try exercisePlacement(threeSlots: false, maximizeMemberInput: .drag)
    }

    func testPartialGroupUsesSameCornerPlacementForMenuAndGesture() throws {
        for input: SnapInput in [.menu, .gesture] {
            try exercisePlacement(threeSlots: false, maximizeMemberInput: input, partialDeparture: true, ordinaryCorner: true)
        }
    }

    func testPartlyCoveredGroupUsesOrdinaryUpwardGesture() throws {
        try exercisePlacement(threeSlots: false, maximizeMemberInput: .gesture, partialDeparture: true)
    }

    func testMaximizingMemberWithUpwardGestureReleasesGroup() throws {
        try exercisePlacement(threeSlots: false, maximizeMemberInput: .gesture)
    }

    func testEmptyQuarterAndExchangeInThreeWindowGroup() throws {
        try exercisePlacement(threeSlots: true)
    }

    func testConstrainedSnapAfterExternalMoveLeavesPeerUntouched() throws {
        try exercisePlacement(threeSlots: false, constrained: true, movePeerBeforeExchange: true)
    }

    func testConstrainedExchangeKeepsNewDividerAndRejectsInfeasibleSwap() throws {
        try exercisePlacement(threeSlots: false, constrained: true)
    }

    func testOverlappingWindowsWithIdenticalTitlesKeepTheirPhysicalIDs() throws {
        try exercisePlacement(threeSlots: false, overlapping: true)
    }

    func testCancellingIncompleteFourWayAssistReleasesMembersAtTheirCurrentFrames() throws {
        try exercisePlacement(threeSlots: false, cancelPartial: true)
    }

    func testOnlyTwoAvailableWindowsCannotLeaveAnIncompleteQuarterGroup() throws {
        try exercisePlacement(threeSlots: false, cancelPartial: true, candidatesExhausted: true)
    }

    func testSubdivisionOffersOnlySiblingAndCompletesGroup() throws {
        try exercisePlacement(threeSlots: false, subdivision: .topLeft)
    }

    func testThreeSlotSubdivisionAndExpansion() throws {
        try exercisePlacement(threeSlots: true, subdivision: .topLeft)
    }

    func testContinuousDragToOppositeCornerStartsIndependentAssist() throws {
        try exercisePlacement(threeSlots: false, subdivision: .topRight, stageDrag: true)
    }

    func testContinuousDragSubdivisionCancelReleasesPeers() throws {
        try exercisePlacement(threeSlots: false, subdivision: .bottomLeft, stageDrag: true)
    }

    func testGestureToOwnSlotStartsIndependentAssist() throws {
        try exercisePlacement(threeSlots: false, ownSlot: true)
    }

    func testLaterAssistWindowWithUnrecordedMinimumWidensExistingQuarter() throws {
        try exercisePlacement(threeSlots: false, wideMinimum: true)
    }

    func testHalfAssistAcceptsWideWindowFromSameDisplay() throws {
        try exercisePlacement(threeSlots: false, externalCandidateOnOtherDisplay: false)
    }

    func testHalfAssistAcceptsWideWindowFromAnotherDisplay() throws {
        guard NSScreen.screens.count > 1 else { throw XCTSkip("Two displays required") }
        try exercisePlacement(threeSlots: false, externalCandidateOnOtherDisplay: true)
    }

    private func exercisePlacement(threeSlots: Bool, externalCandidateOnOtherDisplay: Bool? = nil, constrained: Bool = false, overlapping: Bool = false, cancelPartial: Bool = false, candidatesExhausted: Bool = false, subdivision: SnapZone? = nil, stageDrag: Bool = false, ownSlot: Bool = false, wideMinimum: Bool = false, movePeerBeforeExchange: Bool = false, combinedExchange: Bool = false, maximizeMemberInput: SnapInput? = nil, reassign: Bool = false, maximumWidth: Bool = false, freelyResizable: Bool = false, recordedMaximum: Bool = false, measuresBounds: Bool = false, partialDeparture: Bool = false, ordinaryCorner: Bool = false) throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable: URL
        if let path = ProcessInfo.processInfo.environment["TABORA_PLACEMENT_FIXTURE"] {
            executable = URL(fileURLWithPath: path)
        } else {
            executable = try Self.compiledFixture.get()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = overlapping ? ["overlap"] : (threeSlots ? ["three"] : [])
        let expectedCount = threeSlots && subdivision != nil ? 4 : 3
        if combinedExchange { process.arguments?.append("exchange-minimum") }
        if wideMinimum { process.arguments?.append("wide-minimum") }
        if expectedCount == 4 { process.arguments?.append("four") }
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
        } while (raw as? [AXUIElement])?.count != expectedCount && Date() < deadline
        let elements = try XCTUnwrap(raw as? [AXUIElement])
        let windows = try elements.map { element -> ManagedWindow in
            var title: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            let id = try XCTUnwrap(RuntimeWindowIDResolver().resolve(element))
            let frame = try XCTUnwrap(controller.windowService.windowServerFrame(pid: process.processIdentifier, windowID: id))
            return ManagedWindow(element: element, pid: process.processIdentifier, title: try XCTUnwrap(title as? String),
                appIcon: nil, frame: frame, isMinimized: false, isFullscreen: false, cgWindowID: id)
        }.sorted { $0.title < $1.title }
        XCTAssertEqual(windows.count, expectedCount)
        guard windows.count == expectedCount else { return }
        if overlapping {
            let candidates = controller.managedVisibleWindows().filter { $0.pid == process.processIdentifier }
            XCTAssertEqual(Set(candidates.compactMap(\.cgWindowID)), Set(windows.compactMap(\.cgWindowID)))
            for (index, window) in windows.enumerated() {
                XCTAssertEqual(candidates.first { $0.stableIdentity == window.stableIdentity }?.cgWindowID, window.cgWindowID)
                let conflicting = window.replacingCGWindowID(windows[(index + 1) % windows.count].cgWindowID)
                XCTAssertNil(controller.windowService.resolvingWindowServerIdentity(conflicting).cgWindowID)
                let unresolved = window.replacingCGWindowID(nil)
                XCTAssertEqual(controller.windowService.resolvingWindowServerIdentity(unresolved).cgWindowID, window.cgWindowID)
            }
            return
        }
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.visibleFrame.contains(CGPoint(x: windows[0].frame.midX, y: windows[0].frame.midY)) })
        let display = try XCTUnwrap(controller.displayID(for: screen))
        let zones: [SnapZone] = [.leftHalf, threeSlots ? .topRight : .rightHalf]
        let placements = zip(windows, zones).map { window, zone in
            SplitPlacementGeometry(stableIdentity: window.stableIdentity, zone: zone, frame: window.frame)
        }
        @discardableResult
        func perform(_ window: ManagedWindow, _ zone: SnapZone, success: Bool = true, assist: Bool = false, input: SnapInput? = nil, duringPlacement: (() -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) -> Bool {
            var matched = false
            let done = expectation(description: "snap committed")
            controller.snap(window, to: zone, on: screen, continueAssist: assist, input: input ?? (stageDrag ? .drag : .gesture)) {
                matched = $0 == success
                if !matched {
                    let slots = windows.map { item in
                        let lock = controller.lockedPlacements[item.stableIdentity]
                        return "\(item.title): group=\(String(describing: controller.explicitGroupStore.group(containing: item.stableIdentity)?.id)), lock=\(String(describing: lock?.appliedFrame)), observed=\(String(describing: controller.windowService.windowServerFrame(item)))"
                    }
                    XCTFail("Snap to \(zone): expected \(success), got \($0). \(slots)", file: file, line: line)
                }
                done.fulfill()
            }
            duringPlacement?()
            wait(for: [done], timeout: 8)
            return matched
        }
        if let externalCandidateOnOtherDisplay {
            let other = externalCandidateOnOtherDisplay
                ? try XCTUnwrap(NSScreen.screens.first { controller.displayID(for: $0) != display })
                : screen
            let initial = CGRect(x: other.visibleFrame.minX + 20, y: other.visibleFrame.minY + 20,
                                 width: ceil(screen.visibleFrame.width * 0.78), height: 460)
            let client = Process()
            client.executableURL = try Self.buildFixture(in: folder, bundleID: "local.tabora.externalcandidate")
            client.arguments = ["candidate-only", NSStringFromRect(initial), String(Double(ceil(screen.visibleFrame.width * 0.56)))]
            if measuresBounds { client.arguments?.append(contentsOf: ["10000", "650"]) }
            try client.run()
            defer { if client.isRunning { client.terminate(); client.waitUntilExit() } }
            let end = Date().addingTimeInterval(5)
            var candidate: ManagedWindow?
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                candidate = controller.managedVisibleWindows().first { $0.pid == client.processIdentifier }
            } while candidate == nil && Date() < end
            let selected = try XCTUnwrap(candidate)
            let start = try XCTUnwrap(controller.windowService.windowServerFrame(selected))
            XCTAssertTrue(other.frame.contains(CGPoint(x: start.midX, y: start.midY)))
            if measuresBounds {
                let engine = ConstraintMeasurementEngine(windowService: controller.windowService)
                let done = expectation(description: "actual minimum, maximum, and restored window")
                engine.measure(window: selected, screenFrame: screen.visibleFrame, backingScaleFactor: screen.backingScaleFactor) { result in
                    XCTAssertEqual(result.confirmedValues[.minWidth] ?? 0, ceil(screen.visibleFrame.width * 0.56), accuracy: 2)
                    XCTAssertEqual(result.confirmedValues[.maxHeight] ?? 0, 650, accuracy: 2)
                    XCTAssertTrue(result.restoredOriginalFrame)
                    done.fulfill()
                }
                wait(for: [done], timeout: 90)
                XCTAssertEqual(controller.windowService.windowServerFrame(selected), start)
                return
            }
            let sourceApp = try XCTUnwrap(controller.resolveAppConstraintIdentity(for: windows[0]))
            let candidateApp = try XCTUnwrap(controller.resolveAppConstraintIdentity(for: selected))
            XCTAssertNotEqual(sourceApp.identity, candidateApp.identity)
            registry.applyExplicitMeasurement([.minWidth: floor(screen.visibleFrame.width * 0.30), .minHeight: 300],
                identity: sourceApp.identity, displayName: sourceApp.displayName)
            let savedWidth = floor(screen.visibleFrame.width * 0.48)
            registry.applyExplicitMeasurement([.minWidth: savedWidth, .minHeight: 160],
                identity: candidateApp.identity, displayName: candidateApp.displayName)
            settings.constraintRecordingPromptsEnabled = false
            settings.assistLayoutSwitchingEnabled = false
            guard perform(windows[0], .leftHalf, assist: true) else { return }
            let slot = SnapZone.rightHalf.frame(in: screen)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0 is NSPanel && $0.frame.contains(CGPoint(x: slot.midX, y: slot.midY)) })
            func card(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.subviews.contains(where: { ($0 as? NSTextField)?.stringValue == selected.title }) { return button }
                return view.subviews.lazy.compactMap(card).first
            }
            try XCTUnwrap(panel.contentView.flatMap(card)).performClick(nil)
            let cutoff = Date().addingTimeInterval(8)
            while controller.explicitGroupStore.group(containing: selected.stableIdentity) == nil && Date() < cutoff {
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
            XCTAssertEqual(controller.explicitGroupStore.group(containing: selected.stableIdentity)?.memberIDs, [windows[0].stableIdentity, selected.stableIdentity])
            let left = try XCTUnwrap(controller.windowService.windowServerFrame(windows[0]))
            let right = try XCTUnwrap(controller.windowService.windowServerFrame(selected))
            XCTAssertEqual(registry.limits(for: candidateApp.identity).minWidth, savedWidth)
            XCTAssertGreaterThanOrEqual(right.width, ceil(screen.visibleFrame.width * 0.56) - 1)
            XCTAssertLessThan(right.width, start.width)
            XCTAssertEqual(left.maxX, right.minX, accuracy: 1)
            XCTAssertEqual(right.maxX, screen.visibleFrame.maxX, accuracy: 1)
            return
        }
        if wideMinimum {
            settings.constraintRecordingPromptsEnabled = false
            settings.assistLayoutSwitchingEnabled = false
            perform(windows[0], .topLeft, assist: true)
            let initial = try XCTUnwrap(controller.windowService.windowServerFrame(windows[0]))
            let session = try XCTUnwrap(controller.activeSession)
            perform(windows[0], .bottomLeft, success: false, input: .assist)
            perform(windows[1], .topLeft, success: false, input: .assist)
            XCTAssertEqual(controller.activeSession, session)
            let app = try XCTUnwrap(controller.resolveAppConstraintIdentity(for: windows[1]))
            registry.applyExplicitMeasurement([.minWidth: ceil(screen.visibleFrame.width * 0.60)],
                identity: app.identity, displayName: app.displayName)
            controller.presentIncompleteAssist(session: session, on: screen, visibleWindows: windows)
            let slot = SnapZone.bottomLeft.frame(in: screen)
            let panel = try XCTUnwrap(NSApp.windows.first {
                $0 is NSPanel && $0.isVisible && $0.frame.contains(CGPoint(x: slot.midX, y: slot.midY))
            })
            func candidateCard(in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.subviews.contains(where: {
                    ($0 as? NSTextField)?.stringValue == windows[1].title
                }) { return button }
                return view.subviews.lazy.compactMap(candidateCard).first
            }
            // Both fixture windows share this app limit: stacked quarters fit,
            // but side-by-side quarters would require at least 120% of the display.
            let blocked = SnapZone.topRight.frame(in: screen)
            XCTAssertFalse(NSApp.windows.contains { panel in
                panel.isVisible && panel is NSPanel && panel.frame.contains(CGPoint(x: blocked.midX, y: blocked.midY))
                    && panel.contentView.flatMap(candidateCard) != nil
            })
            let card = try XCTUnwrap(panel.contentView.flatMap(candidateCard))
            registry.applyExplicitMeasurement([.minWidth: screen.visibleFrame.width + 100],
                identity: app.identity, displayName: app.displayName)
            XCTAssertTrue(card.sendAction(card.action, to: card.target))
            let readinessDeadline = Date().addingTimeInterval(8)
            while controller.isAssistPlacementPending && Date() < readinessDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertFalse(controller.isAssistPlacementPending)
            XCTAssertTrue(controller.picker.isVisible)
            XCTAssertEqual(controller.activeSession, session)
            XCTAssertEqual(controller.windowService.windowServerFrame(windows[0]), initial)
            registry.deleteRecord(identity: app.identity)
            card.performClick(nil)
            let deadline = Date().addingTimeInterval(8)
            while controller.activeSession?.occupiedZones[.bottomLeft] != windows[1].stableIdentity && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertEqual(controller.activeSession?.occupiedZones[.bottomLeft], windows[1].stableIdentity)
            let top = try XCTUnwrap(controller.windowService.windowServerFrame(windows[0]))
            let bottom = try XCTUnwrap(controller.windowService.windowServerFrame(windows[1]))
            XCTAssertGreaterThan(top.width, initial.width)
            XCTAssertGreaterThanOrEqual(bottom.width, ceil(screen.visibleFrame.width * 0.60) - 1)
            XCTAssertEqual(top.maxX, bottom.maxX, accuracy: 1)
            XCTAssertEqual(top.minY, bottom.maxY, accuracy: 1)
            XCTAssertEqual(controller.lockedPlacements[windows[0].stableIdentity]?.appliedFrame, top)
            return
        }
        if cancelPartial {
            settings.assistLayoutSwitchingEnabled = false
            perform(windows[0], .topLeft, assist: true)
            let frame = SnapZone.topRight.frame(in: screen)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) && $0 is NSPanel })
            func findCard(in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.subviews.contains(where: {
                    ($0 as? NSTextField)?.stringValue == windows[1].title
                }) { return button }
                for child in view.subviews {
                    if let card = findCard(in: child) { return card }
                }
                return nil
            }
            let card = try XCTUnwrap(panel.contentView.flatMap(findCard))
            // Replace the picker while the original AX readiness request is pending.
            XCTAssertTrue(card.sendAction(card.action, to: card.target))
            XCTAssertTrue(controller.isAssistPlacementPending)
            controller.presentIncompleteAssist(session: try XCTUnwrap(controller.activeSession), on: screen,
                visibleWindows: windows)
            XCTAssertTrue(card.sendAction(card.action, to: card.target))
            XCTAssertFalse(controller.isAssistPlacementPending)
            let newPanel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0 is NSPanel &&
                $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            let currentCard = try XCTUnwrap(newPanel.contentView.flatMap(findCard))
            currentCard.performClick(nil)
            let deadline = Date().addingTimeInterval(8)
            while controller.activeSession?.occupiedStableIDs.count != 2 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertNil(controller.activeSession?.groupID)
            XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
            XCTAssertFalse(try XCTUnwrap(controller.activeSession).remainingZones.isEmpty)
            let members = Array(windows.prefix(2))
            let frames = try members.map { try XCTUnwrap(controller.windowService.windowServerFrame($0)) }
            if candidatesExhausted {
                controller.presentIncompleteAssist(session: try XCTUnwrap(controller.activeSession), on: screen,
                    visibleWindows: members)
            } else {
                controller.picker.hide(notifyCancel: true)
            }
            XCTAssertFalse(controller.picker.isVisible)
            XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
            XCTAssertNil(controller.activeSession)
            for (index, window) in members.enumerated() {
                XCTAssertNil(controller.lockedPlacements[window.stableIdentity])
                XCTAssertEqual(controller.windowService.windowServerFrame(window), frames[index])
            }
            return
        }
        for (window, zone) in zip(windows, zones) {
            controller.lockedPlacements[window.stableIdentity] = LockedPlacement(element: window.element,
                pid: window.pid, stableIdentity: window.stableIdentity, cgWindowID: window.cgWindowID,
                zone: zone, displayID: display, appliedFrame: window.frame)
        }
        let group: SnapGroup
        if threeSlots {
            controller.activeSession = LayoutSession(displayID: display,
                layoutZones: [.leftHalf, .topRight, .bottomRight],
                occupiedZones: [.leftHalf: windows[0].stableIdentity, .topRight: windows[1].stableIdentity])
            XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
            perform(windows[2], .bottomRight)
            group = try XCTUnwrap(controller.explicitGroupStore.group(containing: windows[2].stableIdentity))
        } else {
            group = try XCTUnwrap(controller.explicitGroupStore.reconcileAfterLayoutMutation(
                preferredMemberID: windows[0].stableIdentity, displayID: display,
                placements: placements, detachedConnections: []))
        }
        if let maximizeMemberInput {
            func assertMaximized(_ window: ManagedWindow, target: CGRect, line: UInt = #line) throws {
                let actual = try XCTUnwrap(controller.windowService.windowServerFrame(window), line: line)
                XCTAssertEqual(actual.origin, target.origin, line: line)
                XCTAssertEqual(actual.width, target.width, line: line)
                // AX settlement accepts a one-point height difference on the real window.
                XCTAssertEqual(actual.height, target.height, accuracy: 1, line: line)
            }
            let cover = windows[2]
            settings.gestureSnapEnabled = true
            settings.maximizeOnUpwardGesture = true
            let coverTarget = screen.visibleFrame
            guard perform(cover, .topHalf, assist: true) else { return }
            try assertMaximized(cover, target: coverTarget)
            XCTAssertNil(controller.lockedPlacements[cover.stableIdentity])
            XCTAssertNil(controller.activeSession)
            XCTAssertEqual(controller.restoreFrames[cover.stableIdentity], cover.frame)
            XCTAssertEqual(controller.explicitGroupStore.group(id: group.id), group)
            XCTAssertTrue(controller.windowService.raise(cover))
            XCTAssertTrue(controller.windowService.raise(windows[0]))
            let isolationDeadline = Date().addingTimeInterval(2)
            func onlySourceIsInFront() -> Bool {
                let scene = controller.windowService.windowOcclusionSnapshot()
                let z = windows.compactMap { window in scene.first { $0.windowID == window.cgWindowID }?.zIndex }
                return z.count == 3 && z[0] < z[2] && z[2] < z[1]
            }
            while !onlySourceIsInFront() && Date() < isolationDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(onlySourceIsInFront())
            if partialDeparture {
                settings.splitLockEnabled = true
                if ordinaryCorner {
                    guard perform(windows[0], .topLeft, assist: true, input: maximizeMemberInput) else { return }
                    XCTAssertEqual(controller.activeSession?.occupiedZones, [.topLeft: windows[0].stableIdentity])
                    XCTAssertEqual(controller.windowService.windowServerFrame(windows[1]), windows[1].frame)
                } else {
                    guard perform(windows[0], .topHalf) else { return }
                    try assertMaximized(windows[0], target: coverTarget)
                }
                XCTAssertNil(controller.explicitGroupStore.group(id: group.id))
                XCTAssertNil(controller.lockedPlacements[windows[1].stableIdentity])
                return
            }
            XCTAssertEqual(controller.explicitGroupStore.group(id: group.id), group)
            XCTAssertTrue(controller.raiseWindows(Array(windows.prefix(2)), withMainWindow: windows[0]))
            let ready = Date().addingTimeInterval(2)
            while controller.connectedGroupFrontmostEvaluation(Array(windows.prefix(2))) != .verifiedFrontmost && Date() < ready {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertEqual(controller.connectedGroupFrontmostEvaluation(Array(windows.prefix(2))), .verifiedFrontmost)
            guard perform(windows[0], .rightHalf) else { return }
            let order = controller.windowService.windowOcclusionSnapshot()
            let coverZ = try XCTUnwrap(order.first { $0.windowID == cover.cgWindowID }).zIndex
            for member in windows.prefix(2) {
                XCTAssertLessThan(try XCTUnwrap(order.first { $0.windowID == member.cgWindowID }).zIndex, coverZ)
            }
            let moved = try XCTUnwrap(controller.windowService.windowServerFrame(windows[0]))
            if maximizeMemberInput == .shortcut {
                guard perform(windows[0].replacingFrame(moved), .maximize, success: false, input: .shortcut, duringPlacement: {
                    controller.explicitGroupStore.suspendForSpaceTransition()
                    controller.explicitGroupStore.markDegraded(groupID: group.id, missingMemberIDs: [])
                }) else { return }
                XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.memberIDs, group.memberIDs)
                XCTAssertEqual(controller.windowService.windowServerFrame(windows[0]), moved)
            }
            if maximizeMemberInput == .drag {
                XCTAssertTrue(controller.stageExplicitGroupDepartureForDrag(containing: windows[0].stableIdentity))
            }
            let direction: SnapZone = maximizeMemberInput == .gesture ? .topHalf : .maximize
            let memberTarget = screen.visibleFrame
            guard perform(windows[0].replacingFrame(moved), direction, input: maximizeMemberInput) else { return }
            XCTAssertNil(controller.stagedGroupDeparture)
            try assertMaximized(windows[0], target: memberTarget)
            XCTAssertEqual(controller.windowService.windowServerFrame(windows[1]), windows[0].frame)
            XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
            XCTAssertTrue(controller.lockedPlacements.isEmpty)
            XCTAssertEqual(controller.restoreFrames[cover.stableIdentity], cover.frame)
            XCTAssertEqual(controller.restoreFrames[windows[0].stableIdentity], windows[0].frame)
            return
        }
        if reassign {
            settings.occupiedReplacementEnabled = false
            settings.constraintRecordingPromptsEnabled = freelyResizable
            let candidateProcess = Process()
            candidateProcess.executableURL = try Self.buildFixture(in: folder, bundleID: "local.tabora.reassignmentcandidate")
            let minimum = maximumWidth || freelyResizable ? 160 : ceil(screen.visibleFrame.width * 0.64)
            let maximum = floor(screen.visibleFrame.width * 0.42)
            let initial = CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY + 30,
                                 width: maximumWidth ? maximum - 100 : ceil(screen.visibleFrame.width * 0.78), height: 450)
            candidateProcess.arguments = threeSlots ? ["candidate-only"]
                : ["candidate-only", NSStringFromRect(initial), String(Double(minimum))]
            if maximumWidth { candidateProcess.arguments?.append(contentsOf: [String(Double(maximum)), "10000"]) }
            var external: ManagedWindow?
            if !threeSlots {
                try candidateProcess.run()
            }
            defer {
                if candidateProcess.isRunning {
                    candidateProcess.terminate()
                    candidateProcess.waitUntilExit()
                }
            }
            if !threeSlots {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    external = controller.managedVisibleWindows().first { $0.pid == candidateProcess.processIdentifier }
                } while external == nil && Date() < deadline
                XCTAssertNotNil(external)
                controller.windowService.focus(windows[0])
                XCTAssertTrue(controller.raiseWindows(Array(windows.prefix(2)), withMainWindow: windows[0]))
            }
            if recordedMaximum {
                let app = try XCTUnwrap(controller.resolveAppConstraintIdentity(for: try XCTUnwrap(external)))
                registry.applyExplicitMeasurement([.maxWidth: maximum], identity: app.identity, displayName: app.displayName)
            }
            let groupWindows = windows.filter { group.memberIDs.contains($0.stableIdentity) }
            XCTAssertTrue(controller.raiseWindows(groupWindows, withMainWindow: windows[0]))
            let presentationDeadline = Date().addingTimeInterval(2)
            let selections = try Set(groupWindows.map {
                WindowServerSelectionSnapshot(pid: $0.pid, windowID: try XCTUnwrap($0.cgWindowID))
            })
            func groupIsInFront() -> Bool {
                GroupFrontmostEvaluationPolicy.evaluate(memberSelections: selections,
                    snapshot: controller.windowService.windowOcclusionSnapshot(), displayFrame: screen.frame) == .verifiedFrontmost
            }
            while !groupIsInFront() && Date() < presentationDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(groupIsInFront())
            settings.gestureSnapEnabled = true
            settings.splitLockEnabled = true
            let index = threeSlots ? 1 : 0
            let source = windows[index]
            let zone = zones[index]
            guard perform(source, zone, success: false) else { return }
            let originalFrames = windows.map { controller.windowService.windowServerFrame($0) }
            settings.gestureReassignmentEnabled = true
            controller.groupForegroundModes[group.id] = .soloPresented(memberID: source.stableIdentity)
            guard perform(source, zone) else { return }
            let session = try XCTUnwrap(controller.activeSession)
            XCTAssertEqual(session.remainingZones, [zone])
            XCTAssertEqual(session.occupiedStableIDs, group.memberIDs.subtracting([source.stableIdentity]))
            let slot = zone.frame(in: screen)
            let panels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible &&
                $0.frame.contains(CGPoint(x: slot.midX, y: slot.midY)) }
            func cards(_ view: NSView) -> [NSButton] {
                if let button = view as? NSButton,
                   button.subviews.contains(where: { $0 is NSTextField }) { return [button] }
                return view.subviews.flatMap(cards)
            }
            let buttons = panels.compactMap(\.contentView).flatMap(cards)
            func card(for window: ManagedWindow) -> NSButton? {
                buttons.first { button in button.subviews.contains {
                    ($0 as? NSTextField)?.stringValue == window.title
                } }
            }
            XCTAssertNotNil(card(for: source))
            for peer in windows where session.occupiedStableIDs.contains(peer.stableIdentity) {
                XCTAssertNil(card(for: peer))
            }
            if threeSlots {
                controller.picker.hide(notifyCancel: true)
                XCTAssertNil(controller.activeSession)
                XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout.zonesByMemberID, group.layout.zonesByMemberID)
                XCTAssertEqual(Set(controller.lockedPlacements.keys), group.memberIDs)
                XCTAssertEqual(windows.map { controller.windowService.windowServerFrame($0) }, originalFrames)
                // Cover only the left half; both right-hand members stay exposed.
                try candidateProcess.run()
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    external = controller.managedVisibleWindows().first { $0.pid == candidateProcess.processIdentifier }
                } while external == nil && Date() < deadline
                _ = try XCTUnwrap(external)
                XCTAssertTrue(controller.windowService.raise(source))
                // The last recovery observation can predate the current desktop.
                // The cover is affirmative evidence for an ordinary snap.
                controller.explicitGroupStore.markDegraded(groupID: group.id, missingMemberIDs: [windows[0].stableIdentity])
                guard perform(source, .leftHalf, assist: true) else { return }
                XCTAssertNil(controller.explicitGroupStore.group(id: group.id))
                XCTAssertEqual(controller.activeSession?.occupiedStableIDs, [source.stableIdentity])
                let candidates = NSApp.windows.filter { $0.isVisible && $0 is NSPanel }
                    .compactMap(\.contentView).flatMap(cards).flatMap { $0.subviews.compactMap { ($0 as? NSTextField)?.stringValue } }
                XCTAssertTrue(candidates.contains(windows[2].title))
                controller.picker.hide(notifyCancel: true)
            } else {
                let incoming = try XCTUnwrap(external)
                let startFrame = initial
                XCTAssertTrue(controller.windowService.setFrame(startFrame, for: incoming.element))
                var unexpectedPrompt = false
                let promptObserver = Timer(timeInterval: 0.05, repeats: true) { _ in
                    if freelyResizable && controller.isConstraintPermissionPromptActive && NSApp.modalWindow != nil {
                        unexpectedPrompt = true
                        NSApp.abortModal()
                    }
                }
                RunLoop.main.add(promptObserver, forMode: .common)
                RunLoop.main.add(promptObserver, forMode: .modalPanel)
                defer { promptObserver.invalidate() }
                try XCTUnwrap(card(for: incoming)).performClick(nil)
                let startDeadline = Date().addingTimeInterval(4)
                while !controller.isSnapPlacementInProgress && Date() < startDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                }
                XCTAssertTrue(controller.isSnapPlacementInProgress)
                XCTAssertNil(controller.explicitGroupStore.group(id: group.id))
                XCTAssertNil(controller.activeSession?.pendingGestureGroupID)
                // Selection has already handed off to ordinary Assist.
                settings.gestureReassignmentEnabled = false
                let deadline = Date().addingTimeInterval(8)
                while controller.explicitGroupStore.group(containing: incoming.stableIdentity) == nil && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                }
                XCTAssertEqual(controller.explicitGroupStore.group(containing: incoming.stableIdentity)?.memberIDs,
                               session.occupiedStableIDs.union([incoming.stableIdentity]))
                let candidateFrame = try XCTUnwrap(controller.windowService.windowServerFrame(incoming))
                let peerFrame = try XCTUnwrap(controller.windowService.windowServerFrame(windows[1]))
                if freelyResizable {
                    XCTAssertFalse(unexpectedPrompt)
                    if recordedMaximum {
                        XCTAssertEqual(candidateFrame.width, maximum, accuracy: 1)
                    } else {
                        XCTAssertEqual(candidateFrame, try XCTUnwrap(originalFrames[index]))
                    }
                } else if maximumWidth {
                    XCTAssertEqual(candidateFrame.width, maximum, accuracy: 1)
                } else {
                    XCTAssertEqual(candidateFrame.width, minimum, accuracy: 1)
                }
                XCTAssertEqual(candidateFrame.maxX, peerFrame.minX, accuracy: 1)
                XCTAssertEqual(peerFrame.maxX, screen.visibleFrame.maxX, accuracy: 1)
                XCTAssertNil(controller.lockedPlacements[source.stableIdentity])
                let order = controller.windowService.windowOcclusionSnapshot()
                let selected = try XCTUnwrap(order.first { $0.windowID == incoming.cgWindowID && $0.pid == incoming.pid })
                let displaced = try XCTUnwrap(order.first { $0.windowID == source.cgWindowID && $0.pid == source.pid })
                XCTAssertLessThan(selected.zIndex, displaced.zIndex)
            }
            return
        }
        if combinedExchange {
            XCTAssertFalse(settings.splitLockEnabled)
            XCTAssertNil(settings.shortcuts[.toggleSplitLock])
            settings.splitLockEnabled = true
            settings.constraintRecordingPromptsEnabled = false
            let app = try XCTUnwrap(controller.resolveAppConstraintIdentity(for: windows[0]))
            let source = try XCTUnwrap(controller.windowService.windowServerFrame(windows[0]))
            let initialFrames = try windows.map { try XCTUnwrap(controller.windowService.windowServerFrame($0)) }
            func verifyOriginalPlacement() {
                XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout, group.layout)
                for (window, frame) in zip(windows, initialFrames) {
                    XCTAssertEqual(controller.windowService.windowServerFrame(window), frame)
                    XCTAssertEqual(controller.lockedPlacements[window.stableIdentity]?.appliedFrame, frame)
                }
                XCTAssertNil(controller.activeSession)
            }
            registry.applyExplicitMeasurement([.minWidth: ceil(screen.visibleFrame.width * 0.55)],
                identity: app.identity, displayName: app.displayName)
            perform(windows[0].replacingFrame(source), .rightHalf, success: false)
            verifyOriginalPlacement()
            registry.applyExplicitMeasurement([.minWidth: floor(screen.visibleFrame.width * 0.45)],
                identity: app.identity, displayName: app.displayName)
            // The recorded 45% minimum contradicts this window's actual 54% minimum.
            // Existing evidence cannot authorize a speculative new split.
            perform(windows[0].replacingFrame(source), .rightHalf, success: false)
            verifyOriginalPlacement()
            registry.deleteRecord(identity: app.identity)
            // Force a lifecycle change between AX application and structural commit.
            perform(windows[0].replacingFrame(source), .rightHalf, success: false, duringPlacement: {
                controller.explicitGroupStore.suspendForSpaceTransition()
                controller.explicitGroupStore.markDegraded(groupID: group.id, missingMemberIDs: [])
            })
            verifyOriginalPlacement()
            guard perform(windows[0].replacingFrame(source), .rightHalf, duringPlacement: {
                XCTAssertTrue(controller.isSnapPlacementInProgress)
                let before = controller.explicitGroupStore.group(id: group.id)
                let peer = windows.first { $0.stableIdentity != before?.preferredMemberID }!
                controller.explicitGroupStore.setPreferredMember(peer.stableIdentity)
                XCTAssertNotEqual(before?.revision, controller.explicitGroupStore.group(id: group.id)?.revision)
            }) else { return }
            let result = try XCTUnwrap(controller.explicitGroupStore.group(id: group.id))
            let expected: [SnapZone] = [.rightHalf, .topLeft, .bottomLeft]
            for (window, zone) in zip(windows, expected) {
                XCTAssertEqual(result.layout.zonesByMemberID[window.stableIdentity], zone)
                let frame = try XCTUnwrap(controller.windowService.windowServerFrame(window))
                XCTAssertGreaterThanOrEqual(frame.width + 1, floor(screen.visibleFrame.width * 0.45))
                if zone == .rightHalf { XCTAssertGreaterThanOrEqual(frame.width, ceil(screen.visibleFrame.width * 0.54)) }
                XCTAssertEqual(frame, controller.lockedPlacements[window.stableIdentity]?.appliedFrame)
            }
            XCTAssertNil(controller.activeSession)
            return
        }
        if ownSlot {
            settings.occupiedReplacementEnabled = true
            perform(windows[0], .leftHalf, assist: true)
            XCTAssertNil(controller.explicitGroupStore.group(id: group.id))
            XCTAssertNil(controller.stagedGroupDeparture)
            XCTAssertNil(controller.lockedPlacements[windows[1].stableIdentity])
            let session = try XCTUnwrap(controller.activeSession)
            XCTAssertNil(session.groupID)
            XCTAssertEqual(session.occupiedZones, [.leftHalf: windows[0].stableIdentity])
            controller.picker.hide(notifyCancel: true)
            XCTAssertNil(controller.activeSession)
            XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
            return
        }
        if let subdivision {
            settings.constraintRecordingPromptsEnabled = false
            XCTAssertTrue(settings.groupSubdivisionEnabled)
            if stageDrag {
                XCTAssertTrue(controller.stageExplicitGroupDepartureForDrag(containing: windows[0].stableIdentity))
                controller.isSnapPlacementInProgress = true
                XCTAssertFalse(controller.restoreStagedGroupDepartureIfPossible())
                XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
                controller.isSnapPlacementInProgress = false
            }
            perform(windows[0], subdivision, assist: true)
            XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
            XCTAssertNil(controller.stagedGroupDeparture)
            let session = try XCTUnwrap(controller.activeSession)
            if subdivision == .topRight {
                XCTAssertEqual(session.occupiedStableIDs, [windows[0].stableIdentity])
                XCTAssertNil(controller.lockedPlacements[windows[1].stableIdentity])
            } else {
                let sibling: SnapZone = subdivision == .topLeft ? .bottomLeft : .topLeft
                XCTAssertEqual(session.remainingZones, [sibling])
                XCTAssertEqual(session.occupiedZones[threeSlots ? .topRight : .rightHalf], windows[1].stableIdentity)
                if stageDrag {
                    controller.picker.hide(notifyCancel: true)
                    XCTAssertTrue(controller.lockedPlacements.isEmpty)
                } else {
                    perform(windows[expectedCount - 1], sibling)
                    XCTAssertEqual(controller.explicitGroupStore.groups.first?.memberIDs, Set(windows.map(\.stableIdentity)))
                    if threeSlots {
                        let source = try XCTUnwrap(controller.windowService.windowServerFrame(windows[0]))
                        perform(windows[0].replacingFrame(source), .bottomRight)
                        let swapped = try XCTUnwrap(controller.explicitGroupStore.group(containing: windows[0].stableIdentity))
                        XCTAssertEqual(swapped.layout.zonesByMemberID[windows[0].stableIdentity], .bottomRight)
                        XCTAssertEqual(swapped.layout.zonesByMemberID[windows[2].stableIdentity], subdivision)
                        let frame = try XCTUnwrap(controller.windowService.windowServerFrame(windows[0]))
                        perform(windows[0].replacingFrame(frame), .leftHalf, assist: true)
                        XCTAssertTrue(controller.explicitGroupStore.groups.isEmpty)
                        XCTAssertEqual(controller.activeSession?.occupiedStableIDs, [windows[0].stableIdentity])
                    }
                }
            }
            return
        }
        if constrained {
            let identity = try XCTUnwrap(controller.resolveAppConstraintIdentity(for: windows[0]))
            let minimum = floor(screen.visibleFrame.width * 0.46)
            registry.applyExplicitMeasurement([.minWidth: minimum], identity: identity.identity,
                displayName: identity.displayName)
            guard perform(windows[0], .rightHalf) else { return }
            let right = try XCTUnwrap(controller.lockedPlacements[windows[0].stableIdentity]?.appliedFrame)
            XCTAssertEqual(right.width, minimum, accuracy: 1)
            if movePeerBeforeExchange {
                let peer = windows[1]
                let recorded = try XCTUnwrap(controller.lockedPlacements[peer.stableIdentity]?.appliedFrame)
                // A superseded reliable write must terminate exactly once and
                // must not apply its delayed resize over the successor.
                let obsolete = expectation(description: "Superseded AX write")
                let successor = expectation(description: "Latest AX write")
                var stale = recorded
                stale.size.height -= 20
                controller.windowService.setFrameReliably(stale, for: peer.element) { success in
                    XCTAssertFalse(success)
                    obsolete.fulfill()
                }
                controller.windowService.setFrameReliably(recorded, for: peer.element) { success in
                    XCTAssertTrue(success)
                    successor.fulfill()
                }
                wait(for: [obsolete, successor], timeout: 3)
                XCTAssertEqual(controller.windowService.windowServerFrame(peer), recorded)
                func movePeer(to frame: CGRect) throws {
                    XCTAssertTrue(controller.windowService.setFrame(frame, for: peer.element))
                    let deadline = Date().addingTimeInterval(2)
                    while controller.windowService.windowServerFrame(peer) != frame && Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    }
                    XCTAssertEqual(controller.windowService.windowServerFrame(peer), frame)
                }
                let moved = recorded.insetBy(dx: 24, dy: 24)
                try movePeer(to: moved)
                guard perform(windows[0].replacingFrame(right), .leftHalf, assist: true) else { return }
                XCTAssertNil(controller.explicitGroupStore.group(id: group.id))
                XCTAssertEqual(controller.activeSession?.occupiedStableIDs, [windows[0].stableIdentity])
                XCTAssertEqual(controller.windowService.windowServerFrame(peer), moved)
                controller.picker.hide(notifyCancel: true)
                return
            }
            guard perform(windows[0].replacingFrame(right), .leftHalf) else { return }
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
            let completed = try XCTUnwrap(controller.explicitGroupStore.group(id: group.id))
            XCTAssertEqual(completed.memberIDs.count, 3)
            XCTAssertEqual(completed.layout.zonesByMemberID[windows[2].stableIdentity], .bottomRight)
            settings.groupSubdivisionEnabled = false
            XCTAssertFalse(AppSettings(defaults: defaults).groupSubdivisionEnabled)
            for input in [SnapInput.shortcut, .menu] {
                perform(windows[0], .topRight, success: false, input: input)
                XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout, completed.layout)
            }
            settings.groupSubdivisionEnabled = true
            perform(windows[0], .topRight)
            let exchanged = try XCTUnwrap(controller.explicitGroupStore.group(id: group.id))
            XCTAssertEqual(exchanged.memberIDs, completed.memberIDs)
            XCTAssertEqual(exchanged.layout.zonesByMemberID, [
                windows[0].stableIdentity: .topRight, windows[1].stableIdentity: .leftHalf,
                windows[2].stableIdentity: .bottomRight])
            settings.occupiedReplacementEnabled = true
            let current = try XCTUnwrap(controller.lockedPlacements[windows[0].stableIdentity]?.appliedFrame)
            settings.groupSubdivisionEnabled = false
            perform(windows[0].replacingFrame(current), .leftHalf)
            XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout, completed.layout)
            let restored = try XCTUnwrap(controller.lockedPlacements[windows[0].stableIdentity]?.appliedFrame)
            perform(windows[0].replacingFrame(restored), .rightHalf, assist: true)
            XCTAssertNil(controller.explicitGroupStore.group(id: group.id))
            XCTAssertEqual(controller.activeSession?.occupiedStableIDs, [windows[0].stableIdentity])
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
        let originalMembers = try zip(windows, zones).map { window, zone in
            GroupSpaceMigrationMember(stableIdentity: window.stableIdentity, element: window.element,
                pid: window.pid, windowID: try XCTUnwrap(window.cgWindowID), zone: zone,
                sourceFrame: window.frame, limits: .unknown)
        }
        let staleMigration = GroupSpaceMigrationCapture(transactionID: UUID(),
            structuralSnapshot: GroupSpaceStructuralSnapshot(groupID: group.id, memberIDs: group.memberIDs,
                zonesByMemberID: group.layout.zonesByMemberID, displayID: display),
            preferredMemberID: group.preferredMemberID, members: originalMembers,
            sourceSpace: try XCTUnwrap(TaboraSpaceID(1)), destinationSpace: try XCTUnwrap(TaboraSpaceID(2)),
            sourceVisibleFrame: screen.visibleFrame, destinationVisibleFrame: screen.visibleFrame,
            destinationDisplayID: display, proxyWindowID: 0, plannedLayout: .indeterminate,
            destinationRestoreFrames: [:])
        controller.dissolveGroupSpaceMigration(staleMigration)
        XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.memberIDs,
                       [windows[0].stableIdentity, windows[2].stableIdentity])
        let placed = try XCTUnwrap(controller.lockedPlacements[windows[2].stableIdentity])
        perform(windows[2].replacingFrame(placed.appliedFrame), .maximize)
        XCTAssertNil(controller.lockedPlacements[windows[2].stableIdentity])
        XCTAssertNotNil(controller.restoreFrames[windows[2].stableIdentity])
        XCTAssertNil(controller.explicitGroupStore.group(containing: windows[2].stableIdentity))
        for (index, zone) in [(0, SnapZone.rightHalf), (1, .leftHalf)] {
            let frame = try XCTUnwrap(controller.windowService.windowServerFrame(windows[index]))
            perform(windows[index].replacingFrame(frame), zone, assist: true)
            XCTAssertNil(controller.explicitGroupStore.group(containing: windows[index].stableIdentity))
            XCTAssertTrue(controller.picker.isVisible)
            if index == 0 {
                controller.picker.hide(notifyCancel: true)
                XCTAssertNil(controller.activeSession)
                XCTAssertEqual(controller.lockedPlacements[windows[0].stableIdentity]?.zone, .rightHalf)
            }
        }
        func candidateButton(in view: NSView, title: String) -> NSButton? {
            if let button = view as? NSButton, button.subviews.contains(where: {
                ($0 as? NSTextField)?.stringValue == title
            }) { return button }
            for child in view.subviews {
                if let button = candidateButton(in: child, title: title) { return button }
            }
            return nil
        }
        func visibleCard(for window: ManagedWindow) -> NSButton? {
            NSApp.windows.filter(\.isVisible).compactMap { panel in
                panel.contentView.flatMap { candidateButton(in: $0, title: window.title) }
            }.first
        }
        XCTAssertNotNil(visibleCard(for: windows[2]))
        let card = try XCTUnwrap(visibleCard(for: windows[0]))
        card.performClick(nil)
        let deadlineForSelection = Date().addingTimeInterval(8)
        while controller.explicitGroupStore.group(containing: windows[0].stableIdentity) == nil,
              Date() < deadlineForSelection {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(controller.explicitGroupStore.group(containing: windows[0].stableIdentity)?.memberIDs,
                       [windows[0].stableIdentity, windows[1].stableIdentity])
    }
    private static let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private static let compiledFixture = Result { try buildFixture(in: fixtureDirectory) }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: fixtureDirectory)
        super.tearDown()
    }

    private static func buildFixture(in folder: URL, bundleID: String = "local.tabora.placementfixture") throws -> URL {
        let contents = folder.appendingPathComponent("PlacementFixture.app/Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("PlacementFixture")
        let info = ["CFBundleIdentifier": bundleID,
                    "CFBundleExecutable": "PlacementFixture", "CFBundlePackageType": "APPL"]
        try PropertyListEncoder().encode(info).write(to: contents.appendingPathComponent("Info.plist"))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/PlacementFixture.m")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-fobjc-arc", source.path, "-framework", "Cocoa", "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw NSError(domain: "PlacementFixtureCompiler", code: Int(compiler.terminationStatus)) }
        return executable
    }

}
