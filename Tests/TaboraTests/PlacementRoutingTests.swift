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

    func testConstrainedExchangeRejectsExternallyMovedPeerAndCanRetry() throws {
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

    private func exercisePlacement(threeSlots: Bool, constrained: Bool = false, overlapping: Bool = false, cancelPartial: Bool = false, candidatesExhausted: Bool = false, subdivision: SnapZone? = nil, stageDrag: Bool = false, ownSlot: Bool = false, wideMinimum: Bool = false, movePeerBeforeExchange: Bool = false) throws {
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
        process.arguments = overlapping ? ["overlap"] : (threeSlots ? ["three"] : [])
        let expectedCount = threeSlots && subdivision != nil ? 4 : 3
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
        func perform(_ window: ManagedWindow, _ zone: SnapZone, success: Bool = true, assist: Bool = false, input: SnapInput? = nil, file: StaticString = #filePath, line: UInt = #line) -> Bool {
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
            wait(for: [done], timeout: 8)
            return matched
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
            registry.applyExplicitMeasurement([.minWidth: screen.visibleFrame.width + 100],
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
            let card = try XCTUnwrap(panel.contentView.flatMap(candidateCard))
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
                guard perform(windows[0].replacingFrame(right), .leftHalf, success: false) else { return }
                XCTAssertEqual(controller.explicitGroupStore.group(id: group.id)?.layout.zonesByMemberID[peer.stableIdentity], .leftHalf)
                XCTAssertEqual(controller.windowService.windowServerFrame(windows[0]), right)
                XCTAssertEqual(controller.windowService.windowServerFrame(peer), moved)
                try movePeer(to: recorded)
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
        XCTAssertEqual(controller.lockedPlacements[windows[2].stableIdentity]?.appliedFrame, screen.visibleFrame)
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
        func candidateButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.subviews.contains(where: {
                ($0 as? NSTextField)?.stringValue == windows[0].title
            }) { return button }
            for child in view.subviews {
                if let button = candidateButton(in: child) { return button }
            }
            return nil
        }
        let card = try XCTUnwrap(NSApp.windows.filter(\.isVisible).compactMap { panel in
            panel.contentView.flatMap(candidateButton)
        }.first)
        card.performClick(nil)
        let deadlineForSelection = Date().addingTimeInterval(8)
        while controller.explicitGroupStore.group(containing: windows[0].stableIdentity) == nil,
              Date() < deadlineForSelection {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(controller.explicitGroupStore.group(containing: windows[0].stableIdentity)?.memberIDs,
                       [windows[0].stableIdentity, windows[1].stableIdentity])
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
