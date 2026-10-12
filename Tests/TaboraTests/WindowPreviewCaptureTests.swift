import CoreGraphics
import XCTest
@testable import Tabora

final class WindowPreviewCaptureTests: XCTestCase {
    private let request = PreviewFullSizeRequest(
        ownerPID: 42,
        windowSize: CGSize(width: 800, height: 500),
        targetPixelSize: CGSize(width: 1600, height: 1000)
    )

    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testTransientSourceRetriesAnEmptyResultButStopsAtSuccess() throws {
        let source = try image(160, 100)
        for emptyAttempts in 0...1 {
            var calls = 0
            let result = MissionControlPreviewSourceRetryPolicy.capture(
                shouldContinue: { true },
                provider: {
                    calls += 1
                    return calls > emptyAttempts ? source : nil
                }
            )
            XCTAssertTrue(result === source)
            XCTAssertEqual(calls, emptyAttempts + 1)
        }
    }

    func testTransientEmptySourceRetryIsBounded() {
        var calls = 0
        let result = MissionControlPreviewSourceRetryPolicy.capture(
            shouldContinue: { true },
            provider: { calls += 1; return nil }
        )
        XCTAssertNil(result)
        XCTAssertEqual(calls, 2)
    }

    func testTransientRetryNeverContinuesOrPublishesAfterCancellation() throws {
        let source = try image(160, 100)
        for returnedImage in [nil, source] as [CGImage?] {
            var authorized = true
            var calls = 0
            let result = MissionControlPreviewSourceRetryPolicy.capture(
                shouldContinue: { authorized },
                provider: {
                    calls += 1
                    authorized = false
                    return returnedImage
                }
            )
            XCTAssertNil(result)
            XCTAssertEqual(calls, 1)
        }
        var calls = 0
        XCTAssertNil(MissionControlPreviewSourceRetryPolicy.capture(
            shouldContinue: { false },
            provider: { calls += 1; return source }
        ))
        XCTAssertEqual(calls, 0)
    }

    func testNormalCaptureDoesNotCallFullSizeSource() throws {
        let source = try image(800, 500)
        var calls = 0
        let result = PreviewCaptureRoutingPolicy.capture(
            fullSizeRequest: nil, shouldCapture: { true },
            legacy: { source }, fullSize: { calls += 1; return nil }
        )
        XCTAssertTrue(result === source)
        XCTAssertEqual(calls, 0)
    }

    func testTransientPrefersFullSizeSourceWithoutComparingLegacyCanvas() throws {
        let full = try image(800, 500)
        var calls: [String] = []
        let result = try XCTUnwrap(PreviewCaptureRoutingPolicy.capture(
            fullSizeRequest: request, shouldCapture: { true },
            legacy: { calls.append("legacy"); return full },
            fullSize: { calls.append("fullSize"); return full }
        ))
        XCTAssertTrue(result === full)
        XCTAssertEqual(calls, ["fullSize"])
        let member = MissionControlTransientPreviewMemberPlan(
            stableIdentity: "member", pid: 42, windowID: 10,
            relativeFrame: CGRect(origin: .zero, size: request.windowSize),
            targetPixelSize: MissionControlPreviewPixelSize(width: 400, height: 250),
            byteBudget: 400 * 250 * 4
        )
        let rendered = try XCTUnwrap(MissionControlTransientPreviewCapturer
            .makePreviewImage(from: result, member: member))
        XCTAssertEqual(rendered.width, 400)
        XCTAssertEqual(rendered.height, 250)
        XCTAssertLessThanOrEqual(rendered.bytesPerRow * rendered.height, member.byteBudget)
    }

    func testUnavailableIncompatibleOrSmallerFullSizeSourceUsesLegacyFallback() throws {
        let source = try image(160, 100)
        for candidate in [nil, try image(80, 50), try image(500, 800)] as [CGImage?] {
            var calls: [String] = []
            let result = PreviewCaptureRoutingPolicy.capture(
                fullSizeRequest: request, shouldCapture: { true },
                legacy: { calls.append("legacy"); return source },
                fullSize: { calls.append("fullSize"); return candidate }
            )
            XCTAssertTrue(result === source)
            XCTAssertEqual(calls, ["fullSize", "legacy"])
        }
    }

    func testEqualCanvasSizeDoesNotRejectFullSizePixelsOrDisableSmallHotImages() throws {
        let candidate = try image(160, 100)
        // Deliberately distinct image objects with identical dimensions.
        for original in [nil, try image(160, 100), try image(100, 160)] as [CGImage?] {
            let result = PreviewCaptureRoutingPolicy.capture(
                fullSizeRequest: request, shouldCapture: { true },
                legacy: { original }, fullSize: { candidate }
            )
            XCTAssertTrue(result === candidate)
        }
    }

    func testCancellationBeforeBetweenAndAfterCallsNeverPublishes() throws {
        let small = try image(160, 100)
        let full = try image(800, 500)
        for cancelAt in 0...2 {
            var authorized = cancelAt != 0
            var legacyCalls = 0
            var fullSizeCalls = 0
            let result = PreviewCaptureRoutingPolicy.capture(
                fullSizeRequest: request, shouldCapture: { authorized },
                legacy: {
                    legacyCalls += 1
                    authorized = false
                    return full
                },
                fullSize: {
                    fullSizeCalls += 1
                    if cancelAt == 1 { authorized = false }
                    return small
                }
            )
            XCTAssertNil(result)
            XCTAssertEqual(fullSizeCalls, cancelAt == 0 ? 0 : 1)
            XCTAssertEqual(legacyCalls, cancelAt == 2 ? 1 : 0)
        }
    }

    func testInvalidPlanDoesNotLaunchPrivateCapture() throws {
        let source = try image(160, 100)
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 500)] {
            let invalid = PreviewFullSizeRequest(
                ownerPID: 42, windowSize: size, targetPixelSize: request.targetPixelSize
            )
            XCTAssertFalse(invalid.isValid)
            let result = PreviewCaptureRoutingPolicy.capture(
                fullSizeRequest: invalid, shouldCapture: { true },
                legacy: { source },
                fullSize: { XCTFail("Invalid plan launched capture"); return nil }
            )
            XCTAssertTrue(result === source)
        }
    }
}
