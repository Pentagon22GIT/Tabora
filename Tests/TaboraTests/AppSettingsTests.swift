import XCTest
@testable import Tabora

final class AppSettingsTests: XCTestCase {
    func testSettingsCategoriesUseTheRequestedStableOrder() {
        XCTAssertEqual(
            SettingsCategory.allCases.map(\.title),
            ["一般", "コマンド", "サイズ制約", "試験的機能"]
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
    }

    func testAssistLayoutSwitchingIsExperimentalByDefault() {
        XCTAssertFalse(AppSettings.defaultAssistLayoutSwitchingEnabled)
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
