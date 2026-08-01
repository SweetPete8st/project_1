import Foundation
import ShredCore

/// GNSS+inertial speed fusion, hard-decel and powerslide detection, docs/spec/03 §7.
final class SpeedFusion {
    private let tuning: DetectionTuning
    private let sampleRate: Double
    static let g = 9.80665

    // 1D Kalman on scalar ground speed.
    private var v: Double = 0
    private var p: Double = 4.0  // variance, m²/s²
    private var initialized = false
    private var lastPredictT: Double?

    // Travel bearing (compass, rad) from the freshest valid fix.
    private var course: Double = -1
    private var courseT = -1.0
    private var lastFixSpeed: Double = -1
    private var lastFixT = -1.0

    /// 10 Hz fused speed series for charts.
    private(set) var speedSeries: [(t: Double, v: Double)] = []
    private var lastSeriesT = -1.0

    private(set) var topSpeed: Double = 0
    private(set) var topSpeedValidated = false
    private var candidateTop: Double = 0

    // Decel event tracking.
    private var decelActive = false
    private var decelStart = 0.0
    private var decelStartV = 0.0
    private var decelPeak = 0.0
    private var accelSmoothed = 0.0
    // Powerslide inputs within the decel window.
    private var slidePeakYawRate: Float = 0
    private var slidePeakLateral: Float = 0
    private var slideYawExcursion: Float = 0
    private var decelStartYaw: Float = 0
    private var pending: [DetectedEvent] = []

    var currentSpeed: Double { max(0, v) }
    /// −1 until the first GNSS update initializes the filter — consumers must treat
    /// "unknown" differently from "stationary" (the segmenter's riding gate).
    var currentSpeedOrUnknown: Double { initialized ? max(0, v) : -1 }

    init(tuning: DetectionTuning, sampleRate: Double) {
        self.tuning = tuning
        self.sampleRate = sampleRate
    }

    func push(fix: LocationFix) {
        guard !fix.flagged else { return }
        if fix.course >= 0 {
            course = fix.course
            courseT = fix.sensorTime
        }
        guard fix.speed >= 0 else { return }
        lastFixSpeed = fix.speed
        lastFixT = fix.sensorTime

        let std = fix.speedAccuracy > 0 ? fix.speedAccuracy : tuning.kalmanFallbackMeasurementStd
        let r = std * std
        if !initialized {
            v = fix.speed
            p = r
            initialized = true
            return
        }
        // Update.
        let k = p / (p + r)
        v += k * (fix.speed - v)
        p *= (1 - k)

        // Top-speed validation (fake-PR guard): fused peak counts only when it agrees with
        // a concurrent GNSS speed within tolerance.
        if candidateTop > topSpeed, abs(candidateTop - fix.speed) <= tuning.topSpeedGNSSAgreement {
            topSpeed = candidateTop
            topSpeedValidated = true
        }
        if fix.speed > topSpeed {
            topSpeed = fix.speed
            topSpeedValidated = true
        }
        candidateTop = 0
    }

    func push(frame f: ProcessedFrame, activity: ActivityState) {
        guard initialized else { return }
        let dt = lastPredictT.map { f.t - $0 } ?? (1 / sampleRate)
        lastPredictT = f.t
        guard dt > 0, dt < 1 else { return }

        // Longitudinal accel: world-frame low-passed accel projected onto travel bearing.
        // Compass course (CW from north, y=north x=east): unit = (sin β, cos β).
        var aLong = 0.0
        if course >= 0, f.t - courseT < 5 {
            let bx = sin(course)
            let by = cos(course)
            aLong = Double(f.aWorldLow.x) * bx * Self.g + Double(f.aWorldLow.y) * by * Self.g
        }
        v += aLong * dt
        p += tuning.kalmanProcessNoise * dt
        if v < 0 { v = 0 }
        candidateTop = max(candidateTop, v)

        // Smoothed fused acceleration for decel detection (200 ms EMA).
        let alpha = min(1, dt / 0.2)
        accelSmoothed += (aLong - accelSmoothed) * alpha

        if f.t - lastSeriesT >= 0.1 {
            lastSeriesT = f.t
            speedSeries.append((f.t, max(0, v)))
        }

        trackDecel(f, activity: activity)
    }

    private func trackDecel(_ f: ProcessedFrame, activity: ActivityState) {
        // Lateral accel: component of low-passed world accel perpendicular to travel.
        var lateral: Float = 0
        if course >= 0 {
            let bx = Float(sin(course))
            let by = Float(cos(course))
            let along = f.aWorldLow.x * bx + f.aWorldLow.y * by
            let perp = SIMD3<Float>(f.aWorldLow.x - along * bx, f.aWorldLow.y - along * by, 0)
            lateral = perp.shredLength
        }

        if !decelActive {
            if activity == .riding && accelSmoothed <= tuning.decelThreshold {
                decelActive = true
                decelStart = f.t
                decelStartV = max(0, v)
                decelPeak = accelSmoothed
                decelStartYaw = f.yawUnwrapped
                slidePeakYawRate = 0
                slidePeakLateral = 0
                slideYawExcursion = 0
            }
        } else {
            decelPeak = min(decelPeak, accelSmoothed)
            slidePeakYawRate = max(slidePeakYawRate, abs(f.yawRate))
            slidePeakLateral = max(slidePeakLateral, lateral)
            slideYawExcursion = max(
                slideYawExcursion, abs(wrapAngle(f.yawUnwrapped - decelStartYaw)))
            if accelSmoothed > tuning.decelThreshold * 0.6 {
                let duration = f.t - decelStart
                decelActive = false
                if duration >= tuning.decelMinDuration {
                    emitDecel(end: f.t, duration: duration)
                }
            }
        }
    }

    private func emitDecel(end: Double, duration: Double) {
        let deltaV = max(0, decelStartV - max(0, v))
        let decel = EventMetrics.Decel(deltaV: deltaV, peakDecel: -decelPeak, duration: duration)
        let yawRateDeg = slidePeakYawRate * 180 / .pi
        if yawRateDeg >= tuning.slideYawRateDeg && slidePeakLateral >= tuning.slideLateralG {
            pending.append(
                DetectedEvent(
                    kind: .powerslide, tStart: decelStart, tEnd: end, confidence: 0.9,
                    metrics: .powerslide(
                        EventMetrics.Powerslide(
                            decel: decel,
                            slideAngleDegrees: slideYawExcursion * 180 / .pi,
                            yawPeakRate: yawRateDeg))))
        } else {
            pending.append(
                DetectedEvent(
                    kind: .decel, tStart: decelStart, tEnd: end, confidence: 0.9,
                    metrics: .decel(decel)))
        }
    }

    func drain() -> [DetectedEvent] {
        defer { pending.removeAll() }
        return pending
    }

    func finalize(at t: Double) -> [DetectedEvent] {
        if decelActive {
            let duration = t - decelStart
            decelActive = false
            if duration >= tuning.decelMinDuration {
                emitDecel(end: t, duration: duration)
            }
        }
        return drain()
    }
}
