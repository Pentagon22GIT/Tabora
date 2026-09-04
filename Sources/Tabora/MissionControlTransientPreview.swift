import AppKit
import CoreGraphics
import Foundation

struct MissionControlTransientPreviewMemberPlan: Equatable {
    let stableIdentity: String
    let pid: pid_t
    let windowID: CGWindowID
    let relativeFrame: CGRect
    let targetPixelSize: MissionControlPreviewPixelSize
    let byteBudget: Int
}

struct MissionControlTransientPreviewGroupPlan: Equatable {
    let groupID: SnapGroupID
    let groupRevision: UInt64
    let displayID: CGDirectDisplayID
    let proxyFrame: CGRect
    let members: [MissionControlTransientPreviewMemberPlan]
}

struct MissionControlTransientPreviewGroupResult {
    let groupID: SnapGroupID
    let groupRevision: UInt64
    let previewsByMemberID: [String: CGImage]
}

struct MissionControlTransientTransformFingerprint: Equatable {
    let framesByWindowID: [CGWindowID: CGRect]
}

enum MissionControlTransientTransformStabilityPolicy {
    static let requiredStableObservations = 2
    // The existing recovery schedule supplies its first repeated observation
    // after 0.08 s. Keeping two equal geometry samples is the safety boundary;
    // matching that first interval avoids deferring otherwise-settled capture
    // to the next 0.24 s pass.
    static let minimumStableInterval: TimeInterval = 0.08
    static let frameTolerance: CGFloat = 1.0

    static func representsSameSettledGeometry(
        _ lhs: MissionControlTransientTransformFingerprint,
        _ rhs: MissionControlTransientTransformFingerprint,
        tolerance: CGFloat = frameTolerance
    ) -> Bool {
        guard Set(lhs.framesByWindowID.keys)
                == Set(rhs.framesByWindowID.keys) else {
            return false
        }
        for (windowID, lhsFrame) in lhs.framesByWindowID {
            guard let rhsFrame = rhs.framesByWindowID[windowID],
                  abs(lhsFrame.minX - rhsFrame.minX) <= tolerance,
                  abs(lhsFrame.minY - rhsFrame.minY) <= tolerance,
                  abs(lhsFrame.width - rhsFrame.width) <= tolerance,
                  abs(lhsFrame.height - rhsFrame.height) <= tolerance else {
                return false
            }
        }
        return true
    }
}

enum MissionControlTransientPreviewValidationPolicy {
    static let maximumAspectRatioError: CGFloat = 0.08

    static func aspectRatioIsCompatible(
        capturedSize: CGSize,
        expectedSize: CGSize
    ) -> Bool {
        guard capturedSize.width > 1, capturedSize.height > 1,
              expectedSize.width > 1, expectedSize.height > 1 else {
            return false
        }
        let capturedRatio = capturedSize.width / capturedSize.height
        let expectedRatio = expectedSize.width / expectedSize.height
        return abs(capturedRatio - expectedRatio) / expectedRatio
            < maximumAspectRatioError
    }
}

enum MissionControlTransientPreviewEligibilityPolicy {
    /// Transient replacement is optional, so it is stricter than the normal
    /// HOT/COLD cache. Normal activity may preserve a previously confirmed HOT
    /// state through an incomplete WindowServer census; transient capture may
    /// not inherit that state. Only a complete current observation proving the
    /// whole group frontmost can authorize one atomic group plan.
    static func authorizedHotGroupIDs<GroupID: Hashable>(
        currentGroupIDs: Set<GroupID>,
        currentEvaluationByGroupID: [GroupID: GroupFrontmostEvaluation]
    ) -> Set<GroupID> {
        Set(currentGroupIDs.filter {
            currentEvaluationByGroupID[$0] == .verifiedFrontmost
        })
    }
}

enum MissionControlTransientPreviewPolicy {
    // Transient pixels are session-only and released at Mission Control exit.
    // Give the lane the same bounded byte ceiling as the normal cache so a
    // temporary replacement does not lose detail merely because it is newer.
    // The two stores remain independent and the combined derived-image ceiling
    // is therefore at most twice the configured normal limit while MC is open.
    static func byteLimit(normalPreviewByteLimit: Int) -> Int {
        max(normalPreviewByteLimit, 0)
    }

    // A memory limit alone does not bound system capture call count because
    // arbitrarily many windows could otherwise be reduced to tiny images.
    // Keep a separate finite work ceiling while preserving at least about
    // 1 MiB/member at the default budget. Each already-authorized group plan
    // is admitted or skipped without splitting it again.
    static let minimumUsefulMemberByteBudget = 1 * 1024 * 1024
    static let hardMaximumMemberCapturesPerSession = 24

    static func captureResolution(
        for member: MissionControlTransientPreviewMemberPlan
    ) -> PreviewCaptureResolution {
        let nominalWidth = max(
            Int(member.relativeFrame.width.rounded(.up)),
            1
        )
        let nominalHeight = max(
            Int(member.relativeFrame.height.rounded(.up)),
            1
        )
        return member.targetPixelSize.width > nominalWidth + 1
            || member.targetPixelSize.height > nominalHeight + 1
            ? .best
            : .nominal
    }

    static func maximumAdmittedMemberCount(totalByteBudget: Int) -> Int {
        guard totalByteBudget >= minimumUsefulMemberByteBudget else { return 0 }
        return min(
            hardMaximumMemberCapturesPerSession,
            totalByteBudget / minimumUsefulMemberByteBudget
        )
    }

    static func admittedPlans(
        _ plans: [MissionControlTransientPreviewGroupPlan],
        totalByteBudget: Int
    ) -> [MissionControlTransientPreviewGroupPlan] {
        let maximumMembers = maximumAdmittedMemberCount(
            totalByteBudget: totalByteBudget
        )
        guard maximumMembers >= 1 else { return [] }

        let ordered = plans.sorted {
            if $0.displayID != $1.displayID {
                return $0.displayID < $1.displayID
            }
            return $0.groupID.rawValue.uuidString
                < $1.groupID.rawValue.uuidString
        }
        var lanes = Dictionary(grouping: ordered, by: \.displayID)
        let displayIDs = lanes.keys.sorted()
        var admitted: [MissionControlTransientPreviewGroupPlan] = []
        var admittedMemberCount = 0
        var madeProgress = true

        while madeProgress && admittedMemberCount < maximumMembers {
            madeProgress = false
            for displayID in displayIDs {
                guard var lane = lanes[displayID], !lane.isEmpty else {
                    continue
                }
                let candidate = lane.removeFirst()
                lanes[displayID] = lane
                madeProgress = true
                let candidateCount = candidate.members.count
                guard candidateCount >= 1,
                      admittedMemberCount + candidateCount <= maximumMembers
                else { continue }
                admitted.append(candidate)
                admittedMemberCount += candidateCount
                if admittedMemberCount >= maximumMembers { break }
            }
        }
        return admitted
    }
}

/// Transient capture deliberately reuses the same direct-window provider as the
/// normal preview cache. A desktop-independent ScreenCaptureKit filter can
/// publish the Mission Control-transformed surface inside an original-size
/// transparent canvas. That output has the right outer dimensions but the
/// wrong pixels for a replacement preview. Direct window capture returns the
/// window bounds themselves and also keeps permission, admission and quality
/// behavior identical to the already-established normal preview path.
///
/// One serial transaction is permitted at a time. Cancellation invalidates
/// results immediately. Work still waiting for shared capture admission is
/// denied before Window Server capture, and completed pixels are revalidated
/// before derived resizing. A system capture already executing synchronously is
/// allowed to finish, after which the physical gate reopens. No canceled session
/// can accumulate a second capture queue behind it.
final class MissionControlTransientPreviewCapturer {
    typealias CaptureAuthorization = () -> Bool
    typealias PreviewProvider = (
        CGWindowID?,
        PreviewCaptureResolution,
        @escaping CaptureAuthorization
    ) -> CGImage?

    private let stateLock = NSLock()
    private let captureQueue = DispatchQueue(
        label: "Tabora.MissionControlTransientPreview",
        qos: .userInitiated
    )
    private var acceptedGeneration: UInt64 = 0
    private var activeTransactionID: UInt64 = 0
    private var physicalTransactionIsInFlight = false

    func cancel() {
        stateLock.lock()
        acceptedGeneration &+= 1
        stateLock.unlock()
    }

    @discardableResult
    func capture(
        generation: UInt64,
        plans: [MissionControlTransientPreviewGroupPlan],
        previewProvider: @escaping PreviewProvider,
        onGroupReady: @escaping (MissionControlTransientPreviewGroupResult) -> Void,
        onFinished: @escaping () -> Void
    ) -> Bool {
        guard !plans.isEmpty else {
            DispatchQueue.main.async { onFinished() }
            return true
        }

        stateLock.lock()
        guard !physicalTransactionIsInFlight else {
            stateLock.unlock()
            return false
        }
        physicalTransactionIsInFlight = true
        activeTransactionID &+= 1
        let transactionID = activeTransactionID
        acceptedGeneration = generation
        stateLock.unlock()

        captureQueue.async { [weak self] in
            guard let self else { return }
            let ownerPIDsByWindowID = Self.currentOnscreenWindowOwners()
            for plan in plans {
                guard self.transactionIsCurrent(
                    transactionID: transactionID,
                    generation: generation
                ) else { break }
                var previews: [String: CGImage] = [:]
                for member in plan.members {
                    let captureIsAuthorized: CaptureAuthorization = { [weak self] in
                        self?.transactionIsCurrent(
                            transactionID: transactionID,
                            generation: generation
                        ) == true
                    }
                    guard captureIsAuthorized(),
                          ownerPIDsByWindowID[member.windowID] == member.pid,
                          let source = previewProvider(
                              member.windowID,
                              MissionControlTransientPreviewPolicy
                                  .captureResolution(for: member),
                              captureIsAuthorized
                          ),
                          // The provider may have waited for the shared capture
                          // admission slot. Recheck the logical MC session before
                          // allocating any derived image work from that result.
                          captureIsAuthorized(),
                          let image = Self.makePreviewImage(
                              from: source,
                              member: member,
                              shouldContinue: captureIsAuthorized
                          ),
                          captureIsAuthorized() else {
                        previews.removeAll()
                        break
                    }
                    previews[member.stableIdentity] = image
                }
                guard previews.count == plan.members.count else { continue }
                let result = MissionControlTransientPreviewGroupResult(
                    groupID: plan.groupID,
                    groupRevision: plan.groupRevision,
                    previewsByMemberID: previews
                )
                // Publish each whole group as soon as it is complete. These
                // blocks and the terminal block below enter the same serial
                // main queue in order, so the physical gate remains valid for
                // every result without delaying the first group behind later
                // captures.
                DispatchQueue.main.async {
                    guard self.transactionIsCurrent(
                        transactionID: transactionID,
                        generation: generation
                    ) else { return }
                    onGroupReady(result)
                }
            }
            DispatchQueue.main.async {
                self.finishTransaction(
                    transactionID: transactionID,
                    onFinished: onFinished
                )
            }
        }
        return true
    }

    private static func currentOnscreenWindowOwners()
        -> [CGWindowID: pid_t] {
        let records = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return Dictionary(
            records.compactMap { record -> (CGWindowID, pid_t)? in
                guard let rawWindowID = record[kCGWindowNumber as String]
                        as? NSNumber,
                      let rawPID = record[kCGWindowOwnerPID as String]
                        as? NSNumber else { return nil }
                return (
                    CGWindowID(rawWindowID.uint32Value),
                    pid_t(rawPID.int32Value)
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func makePreviewImage(
        from source: CGImage,
        member: MissionControlTransientPreviewMemberPlan,
        shouldContinue: () -> Bool = { true }
    ) -> CGImage? {
        guard shouldContinue(),
              MissionControlTransientPreviewValidationPolicy
            .aspectRatioIsCompatible(
                capturedSize: CGSize(
                    width: CGFloat(source.width),
                    height: CGFloat(source.height)
                ),
                expectedSize: member.relativeFrame.size
            ), member.byteBudget > 0 else { return nil }

        let dimensionScale = min(
            CGFloat(member.targetPixelSize.width) / CGFloat(source.width),
            CGFloat(member.targetPixelSize.height) / CGFloat(source.height),
            1
        )
        var width = max(
            Int((CGFloat(source.width) * dimensionScale).rounded(.down)),
            1
        )
        var height = max(
            Int((CGFloat(source.height) * dimensionScale).rounded(.down)),
            1
        )
        let sourceCost = max(
            source.bytesPerRow * source.height,
            source.width * source.height
                * MissionControlPreviewSizingPolicy.bytesPerPixel
        )
        if dimensionScale == 1, sourceCost <= member.byteBudget {
            return shouldContinue() ? source : nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        for _ in 0..<8 {
            guard shouldContinue(),
                  let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return nil }
            let storageCost = max(
                context.bytesPerRow * height,
                width * height
                    * MissionControlPreviewSizingPolicy.bytesPerPixel
            )
            if storageCost > member.byteBudget {
                guard let reduced = MissionControlPreviewSizingPolicy
                    .reducedPixelSize(
                        width: width,
                        height: height,
                        actualByteCost: storageCost,
                        byteBudget: member.byteBudget
                    ) else { return nil }
                width = reduced.width
                height = reduced.height
                continue
            }
            guard shouldContinue() else { return nil }
            context.interpolationQuality = CGInterpolationQuality.high
            context.draw(
                source,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            guard shouldContinue(),
                  let image = context.makeImage(),
                  shouldContinue() else { return nil }
            let imageCost = max(
                image.bytesPerRow * image.height,
                image.width * image.height
                    * MissionControlPreviewSizingPolicy.bytesPerPixel
            )
            if imageCost <= member.byteBudget {
                return shouldContinue() ? image : nil
            }
            guard let reduced = MissionControlPreviewSizingPolicy
                .reducedPixelSize(
                    width: width,
                    height: height,
                    actualByteCost: imageCost,
                    byteBudget: member.byteBudget
                ) else { return nil }
            width = reduced.width
            height = reduced.height
        }
        return nil
    }

    private func transactionIsCurrent(
        transactionID: UInt64,
        generation: UInt64
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return physicalTransactionIsInFlight
            && activeTransactionID == transactionID
            && acceptedGeneration == generation
    }

    private func finishTransaction(
        transactionID: UInt64,
        onFinished: @escaping () -> Void
    ) {
        stateLock.lock()
        let ownsTransaction = physicalTransactionIsInFlight
            && activeTransactionID == transactionID
        if ownsTransaction {
            physicalTransactionIsInFlight = false
        }
        stateLock.unlock()
        guard ownsTransaction else { return }
        DispatchQueue.main.async { onFinished() }
    }

}
