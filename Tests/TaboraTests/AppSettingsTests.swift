import XCTest
@testable import Tabora

final class AppSettingsTests: XCTestCase {
    func testWorkspaceEdgePreferencePreservesOriginalOnFailure() throws {
        let domain = "TaboraTests." + UUID().uuidString
        let key = "workspaces-edge-delay" as CFString
        func store(_ value: CFPropertyList?) {
            CFPreferencesSetValue(key, value, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            XCTAssertTrue(CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        }
        func read() -> CFPropertyList? {
            CFPreferencesCopyValue(key, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        defer { store(nil) }
        var restarts = 0
        let settings = ExperimentalWorkspaceSettings(domain: domain) {
            restarts += 1
            if restarts == 1 { throw WorkspaceEdgeDelayError.verificationFailed }
        }
        func apply() throws -> Double? {
            let done = expectation(description: "Workspace preference transaction")
            var outcome: Result<Double?, Error>?
            settings.applyDelayedEdgeSwitching { outcome = $0; done.fulfill() }
            wait(for: [done], timeout: 3)
            return try XCTUnwrap(outcome).get()
        }
        store("invalid" as CFString)
        XCTAssertThrowsError(try apply())
        XCTAssertEqual(read() as? String, "invalid")
        XCTAssertEqual(restarts, 0)
        store("1.50" as CFString)
        XCTAssertThrowsError(try apply())
        XCTAssertEqual(read() as? String, "1.50")
        XCTAssertEqual(restarts, 2)
        XCTAssertEqual(try apply(), ExperimentalWorkspaceSettings.delayedValue)
        XCTAssertEqual(try apply(), ExperimentalWorkspaceSettings.delayedValue)
        XCTAssertEqual(restarts, 3)
        let done = expectation(description: "Remove test preference")
        settings.restoreDefaultEdgeSwitching { result in
            switch result {
            case .success(let value): XCTAssertNil(value)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertNil(read())
        XCTAssertEqual(restarts, 4)
    }

    func testMenuHintsFollowReassignmentAndClearingWithoutRegisteringAnotherHotkey() throws {
        let menu = NSMenu()
        let action = ShortcutAction.leftHalf
        let item = menu.addItem(withTitle: action.title, action: nil, keyEquivalent: "")
        item.representedObject = action
        let quit = menu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "q")
        let flags: NSEvent.ModifierFlags = [.shift, .option]
        let binding = ShortcutBinding(keyCode: 123, modifiers: UInt32(flags.rawValue))
        for binding in [binding, binding, ShortcutBinding(keyCode: 126, modifiers: 0)] {
            TaboraApp.updateShortcutHints(in: menu, bindings: [action: binding])
            XCTAssertEqual(item.title, action.title)
            XCTAssertEqual(item.keyEquivalent, binding.keyCode == 123 ? "\u{f702}" : "\u{f700}")
            XCTAssertEqual(item.keyEquivalentModifierMask.rawValue, UInt(binding.modifiers))
        }
        TaboraApp.updateShortcutHints(in: menu, bindings: [.toggleSplitLock: binding])
        if #available(macOS 14, *) { XCTAssertNil(item.badge) }
        XCTAssertTrue(item.keyEquivalent.isEmpty)
        XCTAssertEqual(item.title, action.title)
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(menu.items.count, 2)
    }

    func testDisplayingOutOfRangeSavedKeyCodeUsesUnknownLabel() {
        let binding = ShortcutBinding(keyCode: .max, modifiers: 0)
        XCTAssertEqual(binding.displayText, L10n.format("key.unknown", Int(UInt32.max)))
    }

    func testGroupDependenciesPreserveStoredChoicesAndIndependentFeatures() throws {
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        for linked in [false, true] {
            for images in [false, true] {
                for child in [false, true] {
                    settings.missionControlLatestPreviewEnabled = child
                    settings.missionControlGroupMigrationEnabled = child
                    settings.linkedResizeEnabled = linked
                    settings.windowPreviewsEnabled = images
                    XCTAssertEqual(settings.groupPreviewAvailable, linked && images)
                    XCTAssertEqual(settings.transientGroupPreviewEnabled, linked && images && child)
                    XCTAssertEqual(settings.groupMigrationEnabled, linked && child)
                    XCTAssertEqual(settings.missionControlLatestPreviewEnabled, child)
                    XCTAssertEqual(settings.missionControlGroupMigrationEnabled, child)
                    XCTAssertEqual(settings.windowPreviewsEnabled, images)
                }
            }
        }
    }

    func testSettingsCategoriesUseTheRequestedStableOrder() {
        XCTAssertEqual(
            SettingsCategory.allCases.map(\.title),
            [
                L10n.text("settings.category.general"),
                L10n.text("settings.section.resize"),
                L10n.text("settings.general.window_movement"),
                L10n.text("settings.ratio.title"),
                L10n.text("settings.category.constraints"),
                L10n.text("settings.nav.gesture"),
                L10n.text("settings.general.drag_detection.title"),
                L10n.text("settings.category.commands"),
                L10n.text("settings.category.experimental")
            ]
        )
    }

    func testConnectedWindowForegroundingIsOptIn() {
        XCTAssertFalse(AppSettings.defaultRaiseConnectedWindowsOnClick)
    }

    func testLightweightModeResizesNoWindowLive() {
        XCTAssertFalse(LinkedResizeDisplayMode.lightweight.resizesMainWindowLive)
        XCTAssertFalse(LinkedResizeDisplayMode.lightweight.resizesLinkedWindowsLive)
    }

    func testDefaultModeIsLightweight() {
        XCTAssertEqual(AppSettings.defaultLinkedResizeDisplayMode, .lightweight)
        XCTAssertFalse(LinkedResizeDisplayMode.lightweight.resizesMainWindowLive)
        XCTAssertFalse(LinkedResizeDisplayMode.lightweight.resizesLinkedWindowsLive)
    }

    func testCombinedInteractionStyleIsTheDefaultContract() {
        XCTAssertEqual(AppSettings.defaultLinkedResizePresentationStyle, .combined)
    }

    func testResizeCursorAdornmentIsEnabledByDefault() {
        XCTAssertTrue(AppSettings.defaultResizeCursorAdornmentEnabled)
    }

    func testMissionControlPreviewMemoryLimitUsesBoundedSteps() {
        XCTAssertEqual(
            AppSettings.defaultMissionControlPreviewMemoryLimitMiB,
            32
        )
        XCTAssertEqual(
            AppSettings.normalizedMissionControlPreviewMemoryLimitMiB(1),
            16
        )
        XCTAssertEqual(
            AppSettings.normalizedMissionControlPreviewMemoryLimitMiB(41),
            48
        )
        XCTAssertEqual(
            AppSettings.normalizedMissionControlPreviewMemoryLimitMiB(999),
            128
        )
        XCTAssertEqual(
            AppSettings.missionControlPreviewMemoryByteLimit(32),
            32 * 1024 * 1024
        )
        XCTAssertEqual(
            AppSettings.missionControlPreviewTotalMemoryLimitMiB(32),
            64
        )
        XCTAssertEqual(
            AppSettings.missionControlPreviewTotalMemoryLimitMiB(999),
            256
        )
    }

    func testLatestPreviewOptInAndPromotedAssistPreserveIndependentPreferences() throws {
        let name = "TaboraTests.PreviewSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "experimentalAssistLayoutSwitchingEnabled")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(AppSettings.defaultMissionControlLatestPreviewEnabled)
        XCTAssertFalse(settings.missionControlLatestPreviewEnabled)
        XCTAssertTrue(settings.assistLayoutSwitchingEnabled)
        settings.missionControlLatestPreviewEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).missionControlLatestPreviewEnabled)
        settings.missionControlLatestPreviewEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).missionControlLatestPreviewEnabled)
        XCTAssertTrue(settings.assistLayoutSwitchingEnabled)
        settings.assistLayoutSwitchingEnabled = false
        XCTAssertFalse(defaults.bool(forKey: "experimentalAssistLayoutSwitchingEnabled"))
    }

    func testAssistDefaultsAndUpgradeRespectStoredChoices() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.assistLayoutSwitchingEnabled)
        settings.initializeAssistPreference(newInstallation: false)
        XCTAssertFalse(settings.assistLayoutSwitchingEnabled)
        settings.initializeAssistPreference(newInstallation: true)
        XCTAssertFalse(settings.assistLayoutSwitchingEnabled)
        settings.assistLayoutSwitchingEnabled = true
        settings.initializeAssistPreference(newInstallation: false)
        XCTAssertTrue(settings.assistLayoutSwitchingEnabled)
    }

    func testGestureRequiresOneReleaseBeforeAssistUsesOption() {
        let press = GestureOptionPress()
        XCTAssertFalse(press.permitsAssist(optionDown: true))
        press.observe(optionDown: false)
        XCTAssertTrue(press.permitsAssist(optionDown: true))
        XCTAssertFalse(press.permitsAssist(optionDown: false))
        XCTAssertTrue(press.permitsAssist(optionDown: true))
    }

    func testMissionControlGroupMigrationIsExperimentalByDefault() {
        XCTAssertFalse(AppSettings.defaultMissionControlGroupMigrationEnabled)
    }

    func testResizeCursorAdornmentDistanceHasSafeDefaultAndClamps() {
        XCTAssertEqual(AppSettings.defaultResizeCursorAdornmentDistance, 8)
        XCTAssertEqual(AppSettings.normalizedResizeCursorAdornmentDistance(1), 4)
        XCTAssertEqual(AppSettings.normalizedResizeCursorAdornmentDistance(8), 8)
        XCTAssertEqual(AppSettings.normalizedResizeCursorAdornmentDistance(40), 12)
        XCTAssertEqual(
            AppSettings.defaultResizeCursorAdornmentDistance,
            (AppSettings.resizeCursorAdornmentDistanceRange.lowerBound
                + AppSettings.resizeCursorAdornmentDistanceRange.upperBound) / 2
        )
        XCTAssertEqual(
            ResizeCursorAdornmentMetrics.distanceRange.lowerBound,
            CGFloat(AppSettings.resizeCursorAdornmentDistanceRange.lowerBound)
        )
        XCTAssertEqual(
            ResizeCursorAdornmentMetrics.distanceRange.upperBound,
            CGFloat(AppSettings.resizeCursorAdornmentDistanceRange.upperBound)
        )
    }

    func testNonFiniteGeometrySettingsReturnEstablishedDefaults() {
        XCTAssertEqual(
            AppSettings.normalizedResizeCursorAdornmentDistance(.nan),
            AppSettings.defaultResizeCursorAdornmentDistance
        )
        XCTAssertEqual(
            AppSettings.normalizedEdgeThreshold(.infinity),
            AppSettings.defaultEdgeThreshold
        )
        XCTAssertEqual(
            AppSettings.normalizedCornerBand(-Double.infinity),
            AppSettings.defaultCornerBand
        )
        XCTAssertEqual(
            AppSettings.normalizedSideDwellDuration(.nan),
            AppSettings.defaultSideDwellDuration
        )
    }

    func testAdornmentDistanceControlsOnlyCursorClearance() {
        for distance: CGFloat in [4, 6, 8, 10, 12] {
            let nearestEdge = ResizeCursorAdornmentMetrics.centerOffset(
                for: distance
            ) - ResizeCursorAdornmentMetrics.triangleDepth / 2
            XCTAssertEqual(
                nearestEdge,
                distance,
                accuracy: 0.0001
            )
        }
    }

    func testResizeAdornmentUsesADeeperThanBaseGrowth() {
        XCTAssertGreaterThan(ResizeCursorAdornmentMetrics.triangleDepth, 7.24)
        XCTAssertGreaterThan(ResizeCursorAdornmentMetrics.triangleBase, 8.26)
        XCTAssertGreaterThan(
            ResizeCursorAdornmentMetrics.triangleDepth - 7.24,
            ResizeCursorAdornmentMetrics.triangleBase - 8.26
        )
        XCTAssertGreaterThan(
            ResizeCursorAdornmentMetrics.triangleTipCornerInset,
            ResizeCursorAdornmentMetrics.triangleBaseCornerInset
        )
    }

    func testHandleHoverUsesBoundedOneShotDwell() {
        XCTAssertGreaterThan(ResizeHandleHoverPolicy.activationDelay, 0.05)
        XCTAssertLessThan(ResizeHandleHoverPolicy.activationDelay, 0.20)
    }

    func testEveryPresentationStyleOwnsTheStandardArrowCursorRect() {
        XCTAssertTrue(ResizeHandleSystemCursorPolicy.usesArrowCursorRect(for: .mac))
        XCTAssertTrue(ResizeHandleSystemCursorPolicy.usesArrowCursorRect(for: .windows))
        XCTAssertTrue(ResizeHandleSystemCursorPolicy.usesArrowCursorRect(for: .combined))
    }

    func testArrowRestorationLeaseIsFiniteAndLocal() {
        XCTAssertFalse(ResizeHandleSystemCursorPolicy.restorationDelays.isEmpty)
        XCTAssertEqual(
            ResizeHandleSystemCursorPolicy.restorationDelays,
            ResizeHandleSystemCursorPolicy.restorationDelays.sorted()
        )
        XCTAssertLessThanOrEqual(
            ResizeHandleSystemCursorPolicy.restorationDelays.last
                ?? Double.infinity,
            0.20
        )
        XCTAssertGreaterThan(
            ResizeHandleSystemCursorPolicy.restorationContainmentPadding,
            0
        )
        XCTAssertLessThanOrEqual(
            ResizeHandleSystemCursorPolicy.restorationContainmentPadding,
            2
        )
    }

    func testVerticalAdornmentIsCenteredOnThePointer() {
        XCTAssertEqual(
            ResizeCursorAdornmentMetrics.verticalPairHorizontalAlignment,
            0
        )
        XCTAssertEqual(
            ResizeCursorAdornmentMetrics.horizontalPairVerticalAlignment,
            0.5
        )
    }

    func testInteractionStylesOnlyControlPresentation() {
        XCTAssertTrue(LinkedResizePresentationStyle.mac.showsCenterControl)
        XCTAssertFalse(LinkedResizePresentationStyle.mac.showsSharedBoundary)
        XCTAssertFalse(LinkedResizePresentationStyle.windows.showsCenterControl)
        XCTAssertTrue(LinkedResizePresentationStyle.windows.showsSharedBoundary)
        XCTAssertTrue(LinkedResizePresentationStyle.combined.showsCenterControl)
        XCTAssertTrue(LinkedResizePresentationStyle.combined.showsSharedBoundary)
    }

    func testAllWindowsModeAlwaysIncludesTheMainWindow() {
        XCTAssertTrue(LinkedResizeDisplayMode.allWindows.resizesMainWindowLive)
        XCTAssertTrue(LinkedResizeDisplayMode.allWindows.resizesLinkedWindowsLive)
    }

    func testNoModeCanResizeOnlyLinkedWindows() {
        XCTAssertFalse(LinkedResizeDisplayMode.allCases.contains {
            $0.resizesLinkedWindowsLive && !$0.resizesMainWindowLive
        })
    }
}
