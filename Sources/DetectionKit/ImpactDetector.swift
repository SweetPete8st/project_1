import Foundation
import ShredCore

/// Continuous g-force envelope + discrete impact events, docs/spec/03 §4 / FR-33.
final class ImpactDetector {
    private let tuning: DetectionTuning
    private let accelClipG: Float

    /// 1 s max-magnitude buckets for the session sparkline.
    private(set) var envelope: [(t: Double, peakG: Float)] = []
    private var bucketStart: Double?
    private var bucketPeak: Float = 0

    private var pending: [DetectedEvent] = []
    private var inExceedance = false
    private var exceedStart = 0.0
    private var exceedPeak: Float = 0
    private var exceedPeakT = 0.0
    private var exceedPeakJerk: Float = 0
    private var lastEmitT = -1.0

    init(tuning: DetectionTuning, accelClipG: Float) {
        self.tuning = tuning
        self.accelClipG = accelClipG
    }

    func push(frame f: ProcessedFrame) {
        // Envelope.
        if bucketStart == nil { bucketStart = f.t }
        bucketPeak = max(bucketPeak, f.aRawMag)
        if f.t - bucketStart! >= 1.0 {
            envelope.append((bucketStart!, bucketPeak))
            bucketStart = f.t
            bucketPeak = 0
        }

        // Discrete impacts: local maxima ≥ threshold with min separation.
        if f.aRawMag >= tuning.impactThresholdG {
            if !inExceedance {
                inExceedance = true
                exceedStart = f.t
                exceedPeak = 0
            }
            if f.aRawMag > exceedPeak {
                exceedPeak = f.aRawMag
                exceedPeakT = f.t
                exceedPeakJerk = f.jerk.magnitude
            }
        } else if inExceedance {
            inExceedance = false
            if lastEmitT < 0 || exceedPeakT - lastEmitT >= tuning.impactSeparation {
                lastEmitT = exceedPeakT
                let clipped = exceedPeak >= accelClipG * tuning.clipFraction
                pending.append(
                    DetectedEvent(
                        kind: .impact, tStart: exceedStart, tEnd: exceedPeakT + 0.05,
                        confidence: 1.0,
                        metrics: .impact(
                            EventMetrics.Impact(
                                peakG: clipped ? accelClipG : exceedPeak, clipped: clipped,
                                jerkPeak: exceedPeakJerk, contextEventID: nil))))
            }
        }
    }

    func drain() -> [DetectedEvent] {
        defer { pending.removeAll() }
        return pending
    }

    func finalize(at t: Double) -> [DetectedEvent] {
        if let start = bucketStart, bucketPeak > 0 {
            envelope.append((start, bucketPeak))
            bucketStart = nil
        }
        _ = t
        return drain()
    }
}
