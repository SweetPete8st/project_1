import Foundation
import ShredCore

/// Placement-independent skate-push rhythm detector for automatic session start.
///
/// Origin: rewritten from the SkatePushAutoStart prototype's `PushSignalProcessor`
/// (docs/decisions/ADR-0004). The algorithm is preserved — gravity-axis split, horizontal
/// dominance, adaptive noise floor, refractory period, cadence-consistency confidence,
/// backdated first push — but the implementation is pure DetectionKit code: no Core Motion,
/// no locks, no UI state, consumes `MotionFrame` like every other detector, replayable
/// against synthetic negatives (walking / jogging / vehicle).
///
/// Product boundary (per the integration brief): this detector makes NO placement-dependent
/// claims. It emits only: estimated first-push time, confidence, push count, cadence.
/// Sessions it starts run without a `CalibrationRecord`, which structurally disables stance
/// analytics downstream.
public struct AutoStartConfig: Sendable, Codable, Equatable {
    /// Arming-phase sampling rate. 50 Hz balances fidelity and battery (the full 100 Hz
    /// capture starts only once a session begins).
    public var sampleRateHz: Double = 50
    /// Absolute minimum horizontal peak (on the SMOOTHED signal), g. 0.17 keeps gentle
    /// cruising pushes (~0.24 g raw) detectable; the negative controls hold well below it.
    public var minimumHorizontalPeakG: Double = 0.17
    /// Required change in smoothed horizontal acceleration, g/s.
    public var minimumJerkGPerSecond: Double = 0.85
    /// Two peaks closer than this are one physical push.
    public var refractoryPeriod: Double = 0.30
    /// Expected inter-push interval band. Below → merged; above → rhythm broken.
    public var minimumPushInterval: Double = 0.44
    public var maximumPushInterval: Double = 1.80
    /// Candidate pushes needed to confirm.
    public var pushesRequiredToStart: Int = 4
    /// Max coefficient of variation of cadence intervals.
    public var maximumCadenceCV: Double = 0.34
    /// Final confidence gate, 0…1. Negatives are rejected by the hard gates long before
    /// this (they never accumulate candidates, so confidence stays 0); the gate's job is
    /// to demand rhythm consistency from borderline positives.
    public var minimumDetectionConfidence: Double = 0.68
    /// EMA smoothing factor at 50 Hz (rate-adjusted internally).
    public var smoothingAlphaAt50Hz: Double = 0.26
    /// Noise-floor EMA factor and clip.
    public var noiseFloorAlpha: Double = 0.008
    public var noiseFloorClipG: Double = 0.22
    /// Adaptive peak threshold = max(minimumHorizontalPeakG, noiseFloor × this).
    public var noiseFloorMultiplier: Double = 3.25

    public init() {}
}

/// Confirmed auto-start decision. Times are sensor-clock seconds (callers convert to wall
/// clock via `ClockAnchors`).
public struct AutoStartDetection: Sendable, Codable, Equatable {
    public var firstPushTime: Double
    public var confirmedTime: Double
    public var confidence: Double
    public var estimatedPushesPerMinute: Double
    public var pushCount: Int
}

public final class AutoStartDetector {
    public struct Output: Sendable {
        public var horizontalG: Double
        public var candidateCount: Int
        public var confidence: Double
        /// Sensor time of a newly registered push candidate, if any.
        public var registeredPushTime: Double?
        /// Non-nil exactly once per arming: the confirmed detection.
        public var detection: AutoStartDetection?
    }

    public let config: AutoStartConfig

    private struct Candidate {
        var timestamp: Double
        var horizontalG: Double
        var verticalG: Double
        var jerk: Double
        var rotationRate: Double
    }

    private struct Sample {
        var timestamp: Double
        var horizontalG: Double
        var verticalG: Double
        var jerk: Double
        var rotationRate: Double
    }

    private var smoothedHorizontal = 0.0
    private var smoothedVertical = 0.0
    private var noiseFloor = 0.035
    /// Recent per-frame jerk values (~200 ms). A peak's jerk evidence is the max over its
    /// rising flank — instantaneous jerk AT a local maximum is ≈ 0 by definition (fixes a
    /// latent prototype bug; see ADR-0004).
    private var jerkWindow: [Double] = []
    private var older: Sample?
    private var previous: Sample?
    private var candidates: [Candidate] = []
    private var lastAcceptedPeak = -Double.infinity
    private var hasDetected = false
    private var lastTimestamp: Double?

    public init(config: AutoStartConfig = AutoStartConfig()) {
        self.config = config
    }

    public func reset() {
        smoothedHorizontal = 0
        smoothedVertical = 0
        noiseFloor = 0.035
        jerkWindow.removeAll(keepingCapacity: true)
        older = nil
        previous = nil
        candidates.removeAll(keepingCapacity: true)
        lastAcceptedPeak = -.infinity
        hasDetected = false
        lastTimestamp = nil
    }

    public func push(motion: MotionFrame) -> Output {
        // Gravity-axis split: vertical = component along gravity, horizontal = remainder.
        // Orientation-independent by construction.
        let a = motion.userAccel
        var g = motion.gravity
        let gLen = g.shredLength
        g = gLen > 0.001 ? g / gLen : SIMD3(0, 0, -1)
        let signedVertical = Double(a.x * g.x + a.y * g.y + a.z * g.z)
        let hVec = SIMD3<Float>(
            a.x - Float(signedVertical) * g.x,
            a.y - Float(signedVertical) * g.y,
            a.z - Float(signedVertical) * g.z)
        let horizontal = Double(hVec.shredLength)
        let vertical = abs(signedVertical)
        let rotation = Double(motion.rotationRate.shredLength)

        // Rate-adjusted EMA (α given at 50 Hz).
        let dt = lastTimestamp.map { max(motion.sensorTime - $0, 0.001) } ?? (1 / config.sampleRateHz)
        lastTimestamp = motion.sensorTime
        let alpha = 1 - pow(1 - config.smoothingAlphaAt50Hz, 50 * dt)
        let priorSmoothed = smoothedHorizontal
        smoothedHorizontal += alpha * (horizontal - smoothedHorizontal)
        smoothedVertical += alpha * (vertical - smoothedVertical)
        let instantJerk = abs(smoothedHorizontal - priorSmoothed) / dt
        jerkWindow.append(instantJerk)
        let jerkSpan = max(2, Int(0.2 / max(dt, 0.001)))
        if jerkWindow.count > jerkSpan {
            jerkWindow.removeFirst(jerkWindow.count - jerkSpan)
        }
        let jerk = jerkWindow.max() ?? instantJerk

        // Adaptive noise baseline; clipped so impacts don't inflate it.
        noiseFloor =
            (1 - config.noiseFloorAlpha) * noiseFloor
            + config.noiseFloorAlpha * min(smoothedHorizontal, config.noiseFloorClipG)

        let sample = Sample(
            timestamp: motion.sensorTime, horizontalG: smoothedHorizontal,
            verticalG: smoothedVertical, jerk: jerk, rotationRate: rotation)

        var registered: Double?
        var detection: AutoStartDetection?
        var confidence = currentConfidence()

        if let o = older, let p = previous {
            let isLocalMax = p.horizontalG > o.horizontalG && p.horizontalG >= sample.horizontalG
            let threshold = max(
                config.minimumHorizontalPeakG, noiseFloor * config.noiseFloorMultiplier)
            let dominance = p.horizontalG / (p.verticalG + 0.045)
            let refractoryOK = p.timestamp - lastAcceptedPeak >= config.refractoryPeriod
            let pushLike =
                isLocalMax && p.horizontalG >= threshold && p.jerk >= config.minimumJerkGPerSecond
                && dominance >= 1.05 && refractoryOK

            if pushLike {
                register(
                    Candidate(
                        timestamp: p.timestamp, horizontalG: p.horizontalG,
                        verticalG: p.verticalG, jerk: p.jerk, rotationRate: p.rotationRate))
                registered = p.timestamp
                lastAcceptedPeak = p.timestamp
                confidence = currentConfidence()

                if !hasDetected, candidates.count >= config.pushesRequiredToStart,
                    confidence >= config.minimumDetectionConfidence,
                    let first = candidates.first, let last = candidates.last
                {
                    let intervals = cadenceIntervals()
                    let meanInterval = intervals.reduce(0, +) / Double(max(intervals.count, 1))
                    detection = AutoStartDetection(
                        firstPushTime: first.timestamp,
                        confirmedTime: last.timestamp,
                        confidence: confidence,
                        estimatedPushesPerMinute: meanInterval > 0 ? 60 / meanInterval : 0,
                        pushCount: candidates.count)
                    hasDetected = true
                }
            }
        }

        older = previous
        previous = sample

        return Output(
            horizontalG: horizontal, candidateCount: candidates.count, confidence: confidence,
            registeredPushTime: registered, detection: detection)
    }

    private func register(_ c: Candidate) {
        guard let last = candidates.last else {
            candidates = [c]
            return
        }
        let interval = c.timestamp - last.timestamp
        if interval < config.minimumPushInterval {
            // Second bump of the same push — keep the stronger peak.
            if c.horizontalG > last.horizontalG {
                candidates[candidates.count - 1] = c
            }
            return
        }
        if interval > config.maximumPushInterval {
            // Rhythm broke; start over from this candidate.
            candidates = [c]
            return
        }
        candidates.append(c)
        let maxHistory = max(config.pushesRequiredToStart + 2, 6)
        if candidates.count > maxHistory {
            candidates.removeFirst(candidates.count - maxHistory)
        }
    }

    private func cadenceIntervals() -> [Double] {
        guard candidates.count >= 2 else { return [] }
        return zip(candidates.dropFirst(), candidates).map { $0.timestamp - $1.timestamp }
    }

    /// Weighted evidence blend; cadence consistency and horizontal dominance dominate.
    private func currentConfidence() -> Double {
        guard candidates.count >= 2 else { return 0 }
        let intervals = cadenceIntervals()
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance =
            intervals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)
        let cv = mean > 0 ? variance.squareRoot() / mean : 1
        let cadenceScore = clamp(1 - cv / config.maximumCadenceCV)

        let avgPeak = candidates.map(\.horizontalG).reduce(0, +) / Double(candidates.count)
        let strengthScore = clamp((avgPeak - config.minimumHorizontalPeakG) / 0.28)

        let avgDominance =
            candidates.map { $0.horizontalG / ($0.verticalG + 0.045) }.reduce(0, +)
            / Double(candidates.count)
        let dominanceScore = clamp((avgDominance - 1.0) / 1.5)

        let avgJerk = candidates.map(\.jerk).reduce(0, +) / Double(candidates.count)
        let jerkScore = clamp((avgJerk - config.minimumJerkGPerSecond) / 2.0)

        // Rotation is supporting evidence only — a tightly-pocketed phone may barely rotate.
        let avgRotation =
            candidates.map(\.rotationRate).reduce(0, +) / Double(candidates.count)
        let rotationScore = clamp(avgRotation / 2.4)

        let countScore = clamp(
            Double(candidates.count - 1) / Double(max(config.pushesRequiredToStart - 1, 1)))

        // Rhythm and dominance carry the decision; amplitude-derived scores support it.
        // (Rebalanced from the prototype, which under-scored gentle cruising pushes — an
        // explicit product requirement. Negatives are held out by the hard gates, not by
        // this blend.)
        return clamp(
            0.34 * cadenceScore + 0.24 * dominanceScore + 0.12 * strengthScore
                + 0.10 * jerkScore + 0.06 * rotationScore + 0.14 * countScore)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}
