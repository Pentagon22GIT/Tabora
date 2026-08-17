import CoreGraphics
import XCTest
@testable import Tabora

final class MissionControlGroupProxyTests: XCTestCase {
    func testTransitionTokenIsGroupScopedGenerationScopedAndExpires() {
        let groupA = SnapGroupID()
        let groupB = SnapGroupID()
        let token = MissionControlTransitionTokenPolicy.make(
            groupID: groupA, presentationGeneration: 7, now: 10
        )
        XCTAssertTrue(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupA, presentationGeneration: 7, now: 11
        ))
        XCTAssertFalse(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupB, presentationGeneration: 7, now: 11
        ))
        XCTAssertFalse(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupA, presentationGeneration: 8, now: 11
        ))
        XCTAssertFalse(MissionControlTransitionTokenPolicy.isValid(
            token, groupID: groupA, presentationGeneration: 7, now: 13
        ))
    }

    func testProxyMustBeBehindMembersOfEveryPresentableGroup() {
        let allMemberIDs: Set<CGWindowID> = [10, 11, 20, 21]

        XCTAssertTrue(
            MissionControlProxyOrderingPolicy.isBehindAllRequiredWindows(
                proxyWindowID: 99,
                requiredWindowIDs: allMemberIDs,
                orderedWindowIDs: [10, 11, 20, 21, 99]
            )
        )
        XCTAssertFalse(
            MissionControlProxyOrderingPolicy.isBehindAllRequiredWindows(
                proxyWindowID: 99,
                requiredWindowIDs: allMemberIDs,
                orderedWindowIDs: [10, 11, 99, 20, 21]
            )
        )
    }

    func testMissingWindowServerEvidenceFailsClosed() {
        XCTAssertFalse(
            MissionControlProxyOrderingPolicy.isBehindAllRequiredWindows(
                proxyWindowID: 99,
                requiredWindowIDs: [10, 11, 20, 21],
                orderedWindowIDs: [10, 11, 20, 99]
            )
        )
    }

    func testOrderingRecoveryIsBoundedAndBacksOff() {
        XCTAssertEqual(
            MissionControlProxyOrderingRecoveryPolicy.verificationDelays,
            [0, 0.04, 0.12, 0.28]
        )
        XCTAssertEqual(
            MissionControlProxyOrderingRecoveryPolicy
                .delayAfterFailedAttempt(0),
            0.04
        )
        XCTAssertEqual(
            MissionControlProxyOrderingRecoveryPolicy
                .delayAfterFailedAttempt(2),
            0.28
        )
        XCTAssertNil(
            MissionControlProxyOrderingRecoveryPolicy
                .delayAfterFailedAttempt(3)
        )
    }

    func testGroupPresentationFastRecoveryIsBounded() {
        XCTAssertEqual(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 1
            ),
            0.06
        )
        XCTAssertEqual(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 4
            ),
            0.15
        )
        XCTAssertEqual(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 6
            ),
            0.35
        )
        XCTAssertNil(
            MissionControlGroupPresentationRetryPolicy.delay(
                forFailureCount: 7
            )
        )
    }

    func testPreviewSizingPreservesUsefulResolutionWithinBudget() {
        let eightMiB = 8 * 1024 * 1024
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.targetPixelSize(
                sourceWidth: 1440,
                sourceHeight: 900,
                byteBudget: eightMiB
            ),
            MissionControlPreviewPixelSize(width: 1440, height: 900)
        )
    }

    func testPreviewSizingBoundsLargeWindowsWithoutFixedPixelCap() throws {
        let eightMiB = 8 * 1024 * 1024
        let target = MissionControlPreviewSizingPolicy.targetPixelSize(
            sourceWidth: 3840,
            sourceHeight: 2160,
            byteBudget: eightMiB
        )
        let resolved = try XCTUnwrap(target)
        XCTAssertLessThan(resolved.width, 3840)
        XCTAssertLessThan(resolved.height, 2160)
        XCTAssertLessThanOrEqual(
            resolved.width * resolved.height
                * MissionControlPreviewSizingPolicy.bytesPerPixel,
            eightMiB + 8192
        )
        XCTAssertEqual(
            Double(resolved.width) / Double(resolved.height),
            16.0 / 9.0,
            accuracy: 0.01
        )
    }

    func testPreviewBudgetUsesTheSameRuleForTwoThreeFourAndMultipleGroups() {
        let total = 32 * 1024 * 1024
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 2
            ),
            total / 2
        )
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 3
            ),
            total / 3
        )
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 4
            ),
            total / 4
        )
        XCTAssertEqual(
            MissionControlPreviewSizingPolicy.perImageByteBudget(
                totalByteBudget: total, presentableMemberCount: 8
            ),
            total / 8
        )
    }
}
