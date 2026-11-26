import CoreGraphics
import XCTest
@testable import Tabora

final class WindowPreviewCaptureTests: XCTestCase {
    func testStalledGroupAndTransientWorkLeavePickerCapacityAndRecoverOnCompletion() throws {
        for stalledGroup in [true, false] {
            let lanes = PreviewCaptureLanes()
            let first = try XCTUnwrap(lanes.acquire(group: stalledGroup, transient: false, wait: 0))
            let second = try XCTUnwrap(lanes.acquire(group: stalledGroup, transient: false, wait: 0))
            let transient = try XCTUnwrap(lanes.acquire(group: true, transient: true, wait: 0))
            XCTAssertNil(lanes.acquire(group: stalledGroup, transient: false, wait: 0))
            XCTAssertNil(lanes.acquire(group: true, transient: true, wait: 0))
            let independent = try XCTUnwrap(lanes.acquire(group: !stalledGroup, transient: false, wait: 0))
            for slot in [first, second, transient, independent] { slot.signal() }
            try XCTUnwrap(lanes.acquire(group: stalledGroup, transient: false, wait: 0)).signal()
        }
    }

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

    func testSingleSourceRejectsCancelledTransparentAndIncompatibleFrames() throws {
        let visible = try image(160, 100)
        let wrong = try image(100, 160)
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 500,
            bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for candidate in [try XCTUnwrap(context.makeImage()), wrong] {
            XCTAssertNil(PreviewCaptureValidation.image(candidate, request: request, expectedSize: request.windowSize, shouldCapture: { true }))
        }
        for cancelAt in [1, 2, 3] {
            var checks = 0
            let result = PreviewCaptureValidation.image(visible, request: request, expectedSize: request.windowSize) {
                checks += 1
                return checks < cancelAt
            }
            XCTAssertEqual(result != nil, cancelAt == 3)
        }
    }

    func testOutputSizeHonorsSourceScaleCacheTargetAndMemoryBounds() {
        XCTAssertEqual(WindowPreviewCaptureService.pixelSize(size: request.windowSize, scale: 2, target: request.targetPixelSize), request.targetPixelSize)
        XCTAssertEqual(WindowPreviewCaptureService.pixelSize(size: request.windowSize, scale: 1, target: nil), request.windowSize)
        XCTAssertEqual(WindowPreviewCaptureService.pixelSize(size: request.windowSize, scale: 2, target: CGSize(width: 400, height: 300)), CGSize(width: 400, height: 250))
        XCTAssertNil(WindowPreviewCaptureService.pixelSize(size: .zero, scale: 2, target: nil))
        XCTAssertEqual(WindowPreviewCaptureService.pixelSize(size: CGSize(width: 100000, height: 100000), scale: 2, target: nil), CGSize(width: 4096, height: 4096))
    }

    func testReducedTileOnNominalCanvasCannotReplaceUsableSource() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 800, height: 500,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 17, y: 112, width: 551, height: 366))
        let tile = try XCTUnwrap(ctx.makeImage())
        let recovered = try XCTUnwrap(PreviewCaptureValidation.image(tile, request: request, expectedSize: request.windowSize, shouldCapture: { true }))
        XCTAssertEqual(Double(recovered.width), 551, accuracy: 17)
        XCTAssertEqual(Double(recovered.height), 366, accuracy: 11)
        var alpha = [UInt8](repeating: 0, count: 32 * 32 * 4)
        try alpha.withUnsafeMutableBytes { buffer in
            let check = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            check.draw(recovered, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        XCTAssertGreaterThan(stride(from: 3, to: alpha.count, by: 4).filter { alpha[$0] > 200 }.count, 950)
    }

}
