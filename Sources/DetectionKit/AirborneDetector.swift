import Foundation
import ShredCore

/// Pop → free-fall → landing state machine, docs/spec/03 §3, plus in-flight rotation (03 §5).
/// Emits airborne/drop events with airtime, ballistic height, landing peak g, and rotation.
final class AirborneDetector {
    private let tuning: DetectionTuning
    private let sampleRate: Double
    private let accelClipG: Float
    private let stance: Stance?

    private enum Phase {
        case ground
        case popCandidate(tPop: Double, popPeak: Float)
        case flight(tPop: Double?, tUp: Double, lowStreak: Int, yawAtTakeoff: Float)
        case landing(
            tPop: Double?, tUp: Double, tLand: Double, yawAtTakeoff: Float, yawAtLand: Float,
            peakG: Float, peakJerk: Float)
    }

    private var phase: Phase = .ground
    /// Median pre-pop yaw rate for drift correction (03 §5), sampled continuously.
    private var yawRateRing: SampleRing
    private var pending: [DetectedEvent] = []
    private var lowStreakForDrop = 0
    private var dropStreakStart: Double?
    private var dropStartYaw: Float = 0

    init(tuning: DetectionTuning, sampleRate: Double, accelClipG: Float, stance: Stance?) {
        self.tuning = tuning
        self.sampleRate = sampleRate
        self.accelClipG = accelClipG
        self.stance = stance
        self.yawRateRing = SampleRing(capacity: Int(sampleRate * 2))
    }

    func push(frame f: ProcessedFrame, activity: ActivityState) {
        yawRateRing.push(t: f.t, value: Double(f.yawRate))

        switch phase {
        case .ground:
            guard activity == .riding else {
                trackDropEntry(f, activity: activity)
                return
            }
            if f.jerk > tuning.popJerkThreshold && f.aRawMag > tuning.popAccelThreshold {
                phase = .popCandidate(tPop: f.t, popPeak: f.aRawMag)
            } else {
                trackDropEntry(f, activity: activity)
            }

        case .popCandidate(let tPop, _):
            if f.aRawMag < tuning.flightAccelThreshold {
                phase = .flight(tPop: tPop, tUp: f.t, lowStreak: 1, yawAtTakeoff: f.yawUnwrapped)
            } else if f.t - tPop > tuning.popToFlightMaxGap {
                phase = .ground
            }

        case .flight(let tPop, let tUp, let lowStreak, let yawTakeoff):
            if f.aRawMag < tuning.flightAccelThreshold {
                phase = .flight(
                    tPop: tPop, tUp: tUp, lowStreak: lowStreak + 1, yawAtTakeoff: yawTakeoff)
                if f.t - tUp > tuning.airtimeMax {
                    phase = .ground  // implausible; abandon
                }
            } else if f.aRawMag > tuning.landAccelThreshold && f.jerk.magnitude > tuning.landJerkThreshold {
                let minStreak = Int(tuning.flightMinDuration * sampleRate)
                if lowStreak >= minStreak {
                    phase = .landing(
                        tPop: tPop, tUp: tUp, tLand: f.t, yawAtTakeoff: yawTakeoff,
                        yawAtLand: f.yawUnwrapped, peakG: f.aRawMag, peakJerk: f.jerk.magnitude)
                } else {
                    phase = .ground
                }
            } else if f.aRawMag > tuning.flightAccelThreshold * 2 {
                // Left the free-fall band without a landing signature (leg noise); if the
                // streak was already valid keep waiting for the true landing spike briefly.
                let minStreak = Int(tuning.flightMinDuration * sampleRate)
                if lowStreak < minStreak {
                    phase = .ground
                }
            }

        case .landing(let tPop, let tUp, let tLand, let yawTakeoff, let yawLand, let peakG, let peakJerk):
            // Collect the landing-peak window, then emit.
            if f.t - tLand <= tuning.landingPeakWindow {
                let newPeak = max(peakG, f.aRawMag)
                let newJerk = max(peakJerk, f.jerk.magnitude)
                phase = .landing(
                    tPop: tPop, tUp: tUp, tLand: tLand, yawAtTakeoff: yawTakeoff,
                    yawAtLand: yawLand, peakG: newPeak, peakJerk: newJerk)
            } else {
                emit(
                    tPop: tPop, tUp: tUp, tLand: tLand, yawTakeoff: yawTakeoff, yawLand: yawLand,
                    peakG: peakG)
                phase = .ground
            }
        }
    }

    /// Drops skip the pop: a free-fall window opening from riding without a pop spike.
    private func trackDropEntry(_ f: ProcessedFrame, activity: ActivityState) {
        guard activity == .riding else {
            lowStreakForDrop = 0
            dropStreakStart = nil
            return
        }
        if f.aRawMag < tuning.flightAccelThreshold {
            if lowStreakForDrop == 0 {
                dropStreakStart = f.t
                dropStartYaw = f.yawUnwrapped
            }
            lowStreakForDrop += 1
            let needed = Int(tuning.dropFlightMinDuration * sampleRate)
            if lowStreakForDrop >= needed, let start = dropStreakStart {
                phase = .flight(tPop: nil, tUp: start, lowStreak: lowStreakForDrop,
                                yawAtTakeoff: dropStartYaw)
                lowStreakForDrop = 0
                dropStreakStart = nil
            }
        } else {
            lowStreakForDrop = 0
            dropStreakStart = nil
        }
    }

    private func emit(
        tPop: Double?, tUp: Double, tLand: Double, yawTakeoff: Float, yawLand: Float,
        peakG: Float
    ) {
        let airtime = tLand - tUp
        guard airtime >= tuning.airtimeMin && airtime <= tuning.airtimeMax else { return }

        // Rotation with pre-pop drift correction (03 §5).
        let refT = tPop ?? tUp
        let drift = Float(yawRateRing.median(from: refT - 1.0, to: refT - 0.05) ?? 0)
        var deltaDeg = (yawLand - yawTakeoff - drift * Float(airtime)) * 180 / .pi
        // Guard NaN from degenerate attitude streams.
        if !deltaDeg.isFinite { deltaDeg = 0 }
        let bucket: RotationBucket
        let absDeg = abs(deltaDeg)
        switch absDeg {
        case ..<tuning.rotationNoneMaxDeg: bucket = .none
        case tuning.rotationHalfMinDeg...tuning.rotationHalfMaxDeg: bucket = .half
        case tuning.rotationFullMinDeg...tuning.rotationFullMaxDeg: bucket = .full
        default: bucket = .partial
        }
        // Frontside/backside: for a regular rider, counterclockwise (positive Δψ viewed
        // from above) is frontside; goofy mirrors. Only meaningful with real rotation.
        var direction: SpinDirection?
        if bucket != .none, let s = stance {
            let ccw = deltaDeg > 0
            direction = (ccw == (s == .regular)) ? .frontside : .backside
        }

        let clipped = peakG >= accelClipG * tuning.clipFraction
        let g = 9.80665
        let est = g * airtime * airtime / 8.0  // FR-31 ballistic both-feet model

        // Confidence from gate margins (03 §3.5).
        let flightMargin = Double(tuning.flightAccelThreshold) * 0.5
        let airMargin = min(1, (airtime - tuning.airtimeMin) / 0.1)
        let landMargin = min(1, Double(peakG - tuning.landAccelThreshold) / 2.0)
        let popScore = tPop != nil ? 1.0 : 0.7
        let confidence = max(0, min(1, 0.4 * airMargin + 0.3 * landMargin + 0.3 * popScore))
        _ = flightMargin

        let metrics = EventMetrics.Airborne(
            airtime: airtime,
            airtimeUncertainty: 1.5 / sampleRate,
            estHeight: est,
            landingPeakG: peakG,
            landingClipped: clipped,
            rotationDegrees: deltaDeg,
            rotationBucket: bucket,
            direction: direction,
            hadPop: tPop != nil)

        let kind: EventKind = tPop == nil ? .drop : .airborne
        let wrapped: EventMetrics =
            kind == .drop
            ? .drop(EventMetrics.Drop(airborne: metrics, baroDropHeight: nil))
            : .airborne(metrics)
        pending.append(
            DetectedEvent(
                kind: kind, tStart: tPop ?? tUp, tEnd: tLand + tuning.landingPeakWindow,
                confidence: confidence, metrics: wrapped))
    }

    func drain() -> [DetectedEvent] {
        defer { pending.removeAll() }
        return pending
    }

    func finalize() -> [DetectedEvent] {
        // Flush a landing still collecting its peak window.
        if case .landing(let tPop, let tUp, let tLand, let yawT, let yawL, let peakG, _) = phase {
            emit(tPop: tPop, tUp: tUp, tLand: tLand, yawTakeoff: yawT, yawLand: yawL, peakG: peakG)
            phase = .ground
        }
        return drain()
    }
}
