import AppKit

enum ConstraintMeasurementBoundOutcome: Equatable {
    case confirmed(CGFloat)
    case noMeasurableBound
    case indeterminate
}

struct ConstraintMeasurementResult: Equatable {
    let outcomes: [AppConstraintBound: ConstraintMeasurementBoundOutcome]
    let restoredOriginalFrame: Bool

    var confirmedValues: [AppConstraintBound: CGFloat] {
        Dictionary(uniqueKeysWithValues: outcomes.compactMap { bound, outcome in
            guard case .confirmed(let value) = outcome else { return nil }
            return (bound, value)
        })
    }
}

enum ConstraintMeasurementPhase: Equatable {
    case preparing
    case measuring(AppConstraintBound)
    case restoringOriginalFrame
}

struct ConstraintMeasurementProgress: Equatable {
    let fractionCompleted: Double
    let phase: ConstraintMeasurementPhase
}

enum ConstraintMeasurementProgressPolicy {
    static func boundFraction(
        index: Int,
        boundCount: Int,
        fractionWithinBound: Double
    ) -> Double {
        guard boundCount > 0 else { return 0.94 }
        let safeIndex = min(max(index, 0), boundCount)
        let within = min(max(fractionWithinBound, 0), 1)
        let completed = Double(safeIndex) + within
        return min(0.94, 0.06 + (completed / Double(boundCount)) * 0.88)
    }

    static func aggregateFraction(
        itemIndex: Int,
        itemCount: Int,
        itemFraction: Double
    ) -> Double {
        guard itemCount > 0 else { return 1 }
        let safeIndex = min(max(itemIndex, 0), itemCount)
        let within = min(max(itemFraction, 0), 1)
        return min(max((Double(safeIndex) + within) / Double(itemCount), 0), 1)
    }
}

/// Explicit/user-authorized constraint verification. Measurement is deliberately
/// separate from passive runtime learning: every bound is isolated to one axis,
/// an indeterminate observation never overwrites persistent evidence, and a
/// minimum is discovered by progressively shrinking above the system-limit
/// ambiguity band rather than treating a 1-point request as app evidence.
final class ConstraintMeasurementEngine {
    private let windowService: AXWindowService
    private var generation: UInt64 = 0
    private var activeSnapshot: WindowSnapshot?

    init(windowService: AXWindowService) {
        self.windowService = windowService
    }

    func cancel(completion: @escaping (Bool) -> Void) {
        generation &+= 1
        guard let snapshot = activeSnapshot else {
            completion(true)
            return
        }
        windowService.cancelFrameOperation(for: snapshot.element)
        windowService.restore(snapshot) { [weak self] restored in
            self?.activeSnapshot = nil
            completion(restored)
        }
    }

    func measure(
        window: ManagedWindow,
        screenFrame: CGRect,
        backingScaleFactor: CGFloat,
        progress: ((ConstraintMeasurementProgress) -> Void)? = nil,
        completion: @escaping (ConstraintMeasurementResult) -> Void
    ) {
        generation &+= 1
        let measurementGeneration = generation
        let original = windowService.snapshot(window)
        activeSnapshot = original
        let epsilon = SystemGeometryPolicy.measurementEpsilon(
            backingScaleFactor: backingScaleFactor
        )
        let bounds = AppConstraintBound.allCases
        var outcomes: [AppConstraintBound: ConstraintMeasurementBoundOutcome] = [:]

        func report(
            _ fractionCompleted: Double,
            phase: ConstraintMeasurementPhase
        ) {
            guard measurementGeneration == self.generation else { return }
            progress?(ConstraintMeasurementProgress(
                fractionCompleted: min(max(fractionCompleted, 0), 1),
                phase: phase
            ))
        }

        func boundProgress(
            index: Int,
            fractionWithinBound: Double
        ) -> Double {
            // Leave explicit room for baseline preparation and the final
            // reliable restore. A progress value is presentation only and
            // never changes the measurement/restore transaction order.
            return ConstraintMeasurementProgressPolicy.boundFraction(
                index: index,
                boundCount: bounds.count,
                fractionWithinBound: fractionWithinBound
            )
        }

        func finish() {
            guard measurementGeneration == self.generation else { return }
            report(0.96, phase: .restoringOriginalFrame)
            self.windowService.restore(original) { restored in
                guard measurementGeneration == self.generation else { return }
                self.activeSnapshot = nil
                report(1, phase: .restoringOriginalFrame)
                completion(ConstraintMeasurementResult(
                    outcomes: outcomes,
                    restoredOriginalFrame: restored
                ))
            }
        }

        func restoreThenContinue(_ index: Int) {
            guard measurementGeneration == self.generation else { return }
            self.windowService.setFrameAnchoredObserved(
                original.frame,
                sizeConstraintAnchor: CGPoint(x: 0.5, y: 0.5),
                requiredCommitSizeAxes: [.width, .height],
                for: original.element,
                pid: original.pid
            ) { observation in
                guard measurementGeneration == self.generation else { return }
                guard observation.acceptedFrameIsSettled,
                      observation.liveness == .alive,
                      let acceptedFrame = observation.acceptedFrame,
                      Self.framesApproximatelyEqual(
                          acceptedFrame,
                          original.frame,
                          epsilon: max(epsilon, 1)
                      ) else {
                    // Never continue a multi-bound calibration from a window
                    // that failed to return to the exact pre-measurement
                    // baseline. Finish immediately and let the final reliable
                    // restore own recovery of the original geometry.
                    finish()
                    return
                }
                measureBound(index)
            }
        }

        func recordAndContinue(
            _ outcome: ConstraintMeasurementBoundOutcome,
            bound: AppConstraintBound,
            nextIndex: Int
        ) {
            outcomes[bound] = outcome
            restoreThenContinue(nextIndex)
        }

        func measureMinimum(
            _ bound: AppConstraintBound,
            index: Int,
            probeLengths: [CGFloat],
            probeIndex: Int
        ) {
            guard measurementGeneration == self.generation else { return }
            guard probeLengths.indices.contains(probeIndex) else {
                recordAndContinue(.noMeasurableBound, bound: bound, nextIndex: index + 1)
                return
            }
            let probeFraction = Double(probeIndex)
                / Double(max(probeLengths.count, 1))
            report(
                boundProgress(index: index, fractionWithinBound: probeFraction),
                phase: .measuring(bound)
            )
            let target = Self.targetFrame(
                for: bound,
                activeLength: probeLengths[probeIndex],
                originalFrame: original.frame,
                screenFrame: screenFrame
            )
            self.windowService.setFrameAnchoredObserved(
                target,
                sizeConstraintAnchor: CGPoint(x: 0.5, y: 0.5),
                requiredCommitSizeAxes: bound.isWidth ? [.width] : [.height],
                for: original.element,
                pid: original.pid
            ) { observation in
                guard measurementGeneration == self.generation else { return }
                guard let classification = Self.minimumProbeOutcome(
                    for: bound,
                    observation: observation,
                    epsilon: epsilon
                ) else {
                    recordAndContinue(.indeterminate, bound: bound, nextIndex: index + 1)
                    return
                }
                switch classification {
                case .confirmed:
                    recordAndContinue(classification, bound: bound, nextIndex: index + 1)
                case .noMeasurableBound:
                    report(
                        boundProgress(
                            index: index,
                            fractionWithinBound: Double(probeIndex + 1)
                                / Double(max(probeLengths.count, 1))
                        ),
                        phase: .measuring(bound)
                    )
                    measureMinimum(
                        bound,
                        index: index,
                        probeLengths: probeLengths,
                        probeIndex: probeIndex + 1
                    )
                case .indeterminate:
                    recordAndContinue(.indeterminate, bound: bound, nextIndex: index + 1)
                }
            }
        }

        func measureBound(_ index: Int) {
            guard measurementGeneration == self.generation else { return }
            guard index < bounds.count else {
                finish()
                return
            }
            guard self.windowService.windowLiveness(
                element: original.element,
                pid: original.pid
            ) == .alive else {
                finish()
                return
            }

            let bound = bounds[index]
            report(
                boundProgress(index: index, fractionWithinBound: 0),
                phase: .measuring(bound)
            )
            if bound.isMinimum {
                let originalLength = bound.isWidth
                    ? original.frame.width : original.frame.height
                let probeLengths = Self.minimumProbeLengths(
                    originalLength: originalLength,
                    epsilon: epsilon
                )
                measureMinimum(
                    bound,
                    index: index,
                    probeLengths: probeLengths,
                    probeIndex: 0
                )
                return
            }

            let target = Self.targetFrame(
                for: bound,
                activeLength: bound.isWidth ? screenFrame.width : screenFrame.height,
                originalFrame: original.frame,
                screenFrame: screenFrame
            )
            self.windowService.setFrameAnchoredObserved(
                target,
                sizeConstraintAnchor: CGPoint(x: 0.5, y: 0.5),
                requiredCommitSizeAxes: bound.isWidth ? [.width] : [.height],
                for: original.element,
                pid: original.pid
            ) { observation in
                guard measurementGeneration == self.generation else { return }
                if let value = Self.confirmedValue(
                    for: bound,
                    observation: observation,
                    epsilon: epsilon,
                    screenFrame: screenFrame
                ) {
                    recordAndContinue(.confirmed(value), bound: bound, nextIndex: index + 1)
                } else if Self.observationAcceptedRequestedActiveLength(
                    bound: bound,
                    observation: observation,
                    epsilon: epsilon
                ) {
                    recordAndContinue(.noMeasurableBound, bound: bound, nextIndex: index + 1)
                } else {
                    recordAndContinue(.indeterminate, bound: bound, nextIndex: index + 1)
                }
            }
        }

        report(0.02, phase: .preparing)
        restoreThenContinue(0)
    }

    static func confirmedValue(
        for bound: AppConstraintBound,
        observation: AXFrameMutationObservation,
        epsilon: CGFloat,
        screenFrame: CGRect
    ) -> CGFloat? {
        guard observation.mutationWasSent,
              observation.sizeMutationSucceeded,
              observation.acceptedFrameIsSettled,
              observation.liveness == .alive,
              let accepted = observation.acceptedFrame
        else { return nil }

        let requested = observation.requestedFrame
        let activeRequested = bound.isWidth ? requested.width : requested.height
        let activeAccepted = bound.isWidth ? accepted.width : accepted.height
        let orthogonalRequested = bound.isWidth ? requested.height : requested.width
        let orthogonalAccepted = bound.isWidth ? accepted.height : accepted.width

        guard abs(orthogonalAccepted - orthogonalRequested) <= epsilon else {
            return nil
        }

        if abs(activeAccepted - activeRequested) > epsilon {
            guard observation.settlementEvidence
                .authorizesPersistentConstraintLearning else { return nil }
        }

        if bound.isMinimum {
            // A request inside the system ambiguity band is not app-specific
            // evidence. Automatic calibration reaches app minima using staged
            // probes that stay above this band.
            guard activeRequested > SystemGeometryPolicy.minimumWindowLength + epsilon,
                  activeAccepted > activeRequested + epsilon else { return nil }
            return activeAccepted
        }

        let usableLength = bound.isWidth ? screenFrame.width : screenFrame.height
        guard activeRequested <= usableLength + epsilon,
              activeAccepted < activeRequested - epsilon,
              activeAccepted < usableLength - epsilon
        else { return nil }
        return activeAccepted
    }

    private static func minimumProbeOutcome(
        for bound: AppConstraintBound,
        observation: AXFrameMutationObservation,
        epsilon: CGFloat
    ) -> ConstraintMeasurementBoundOutcome? {
        guard bound.isMinimum,
              observation.mutationWasSent,
              observation.sizeMutationSucceeded,
              observation.acceptedFrameIsSettled,
              observation.liveness == .alive,
              let accepted = observation.acceptedFrame else { return nil }
        let requested = observation.requestedFrame
        let activeRequested = bound.isWidth ? requested.width : requested.height
        let activeAccepted = bound.isWidth ? accepted.width : accepted.height
        let orthogonalRequested = bound.isWidth ? requested.height : requested.width
        let orthogonalAccepted = bound.isWidth ? accepted.height : accepted.width
        guard abs(orthogonalAccepted - orthogonalRequested) <= epsilon else {
            return nil
        }
        if activeAccepted > activeRequested + epsilon,
           activeRequested > SystemGeometryPolicy.minimumWindowLength + epsilon {
            guard observation.settlementEvidence
                .authorizesPersistentConstraintLearning else { return nil }
            return .confirmed(activeAccepted)
        }
        guard abs(activeAccepted - activeRequested) <= epsilon else { return nil }
        return .noMeasurableBound
    }

    private static func observationAcceptedRequestedActiveLength(
        bound: AppConstraintBound,
        observation: AXFrameMutationObservation,
        epsilon: CGFloat
    ) -> Bool {
        guard observation.mutationWasSent,
              observation.sizeMutationSucceeded,
              observation.acceptedFrameIsSettled,
              observation.liveness == .alive,
              let accepted = observation.acceptedFrame else { return false }
        let requested = observation.requestedFrame
        let activeRequested = bound.isWidth ? requested.width : requested.height
        let activeAccepted = bound.isWidth ? accepted.width : accepted.height
        let orthogonalRequested = bound.isWidth ? requested.height : requested.width
        let orthogonalAccepted = bound.isWidth ? accepted.height : accepted.width
        return abs(activeAccepted - activeRequested) <= epsilon
            && abs(orthogonalAccepted - orthogonalRequested) <= epsilon
    }

    private static func minimumProbeLengths(
        originalLength: CGFloat,
        epsilon: CGFloat
    ) -> [CGFloat] {
        guard originalLength.isFinite, originalLength > 0 else { return [] }
        let safeFloor = SystemGeometryPolicy.minimumWindowLength
            + epsilon * 2 + 1
        guard originalLength > safeFloor + epsilon else { return [] }
        var result: [CGFloat] = []
        var next = originalLength / 2
        while next > safeFloor + epsilon {
            result.append(next)
            next /= 2
        }
        if result.last.map({ abs($0 - safeFloor) > epsilon }) ?? true {
            result.append(safeFloor)
        }
        return result
    }

    private static func framesApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        epsilon: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= epsilon
            && abs(lhs.minY - rhs.minY) <= epsilon
            && abs(lhs.width - rhs.width) <= epsilon
            && abs(lhs.height - rhs.height) <= epsilon
    }

    private static func targetFrame(
        for bound: AppConstraintBound,
        activeLength: CGFloat,
        originalFrame: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        var target = originalFrame
        switch bound {
        case .minWidth:
            target.size.width = activeLength
            target.origin.x = originalFrame.midX - target.width / 2
        case .minHeight:
            target.size.height = activeLength
            target.origin.y = originalFrame.midY - target.height / 2
        case .maxWidth:
            target.origin.x = screenFrame.minX
            target.size.width = activeLength
        case .maxHeight:
            target.origin.y = screenFrame.minY
            target.size.height = activeLength
        }
        return target
    }
}
