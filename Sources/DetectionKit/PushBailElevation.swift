import Foundation
import ShredCore

/// Push (kick stroke) counting, docs/spec/03 §9: fused-speed upticks ≥ pushSpeedDelta within
/// pushWindow while riding, coincident with a vertical bob on the pocket leg, separated by
/// pushMinSeparation.
final class PushDetector {
    private let tuning: DetectionTuning

    private(set) var pushTimes: [Double] = []
    private var speedRing: SampleRing
    private var lastPushT = -1.0
    private var lastVertDipT = -10.0
    private var vertLowPrev: Float = 0
    private var falling = false

    init(tuning: DetectionTuning, sampleRate: Double) {
        self.tuning = tuning
        self.speedRing = SampleRing(capacity: 64)
    }

    func push(speed: Double, at t: Double) {
        speedRing.push(t: t, value: speed)
    }

    func push(frame f: ProcessedFrame, activity: ActivityState) {
        // Track vertical dips (pushing leg unloading) on low-passed vertical accel. The
        // amplitude band excludes free-fall (≈ −1 g), which would otherwise read as a
        // giant "dip" during every ollie.
        let vz = f.aWorldLow.z
        if vz < vertLowPrev {
            falling = true
        } else if falling, vz > vertLowPrev, vertLowPrev < -0.04, vertLowPrev > -0.3 {
            falling = false
            lastVertDipT = f.t
        }
        vertLowPrev = vz

        guard activity == .riding else { return }
        guard f.t - lastPushT >= tuning.pushMinSeparation else { return }

        // Speed uptick over the window ending now.
        guard let now = speedRing.latest, now.t >= f.t - 0.2 else { return }
        var earliest: Double?
        speedRing.forEach(from: f.t - tuning.pushWindow, to: f.t) { _, v in
            if earliest == nil { earliest = v }
        }
        guard let e = earliest else { return }
        let delta = now.value - e
        // Require a FRESH leg-dip (one dip → one push, prevents multi-count on a long
        // sustained speed climb).
        if delta >= tuning.pushSpeedDelta && f.t - lastVertDipT <= 0.8 {
            lastPushT = f.t
            lastVertDipT = -10  // consume the dip
            pushTimes.append(f.t)
        }
    }

    /// Removes pushes that fall inside airborne/drop windows (a landing is not a push).
    func removePushes(overlapping events: [DetectedEvent]) {
        pushTimes.removeAll { t in
            events.contains {
                ($0.kind == .airborne || $0.kind == .drop)
                    && t >= $0.tStart - 0.5 && t <= $0.tEnd + 1.0
            }
        }
    }

    var count: Int { pushTimes.count }

    /// Median inter-push interval → cadence (Hz), nil under 3 pushes.
    var cadenceMean: Double? {
        guard pushTimes.count >= 3 else { return nil }
        var gaps = [Double]()
        for i in 1..<pushTimes.count {
            let gap = pushTimes[i] - pushTimes[i - 1]
            if gap < 5 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return nil }
        gaps.sort()
        return 1.0 / gaps[gaps.count / 2]
    }
}

/// Bail / fall detection, docs/spec/03 §10.
final class BailDetector {
    private let tuning: DetectionTuning
    private let accelClipG: Float

    private struct Candidate {
        var tImpact: Double
        var peakG: Float
        var clipped: Bool
        var tumbleSamples: Int
        var stillnessOK: Bool
    }

    private var candidate: Candidate?
    private var pending: [DetectedEvent] = []
    /// Airborne flights end in big impacts too; the arbiter suppresses bails that overlap a
    /// valid airborne event, but we also gate here on "not preceded by valid flight".
    private var recentFlightEnd = -10.0
    private var stillnessStart: Double?

    init(tuning: DetectionTuning, accelClipG: Float) {
        self.tuning = tuning
        self.accelClipG = accelClipG
    }

    func noteAirborneLanding(at t: Double) {
        recentFlightEnd = t
    }

    func push(frame f: ProcessedFrame, activity: ActivityState) {
        if var c = candidate {
            // Tumble: sustained high rotation after impact.
            if f.t - c.tImpact <= 1.5, f.omegaMag * 180 / .pi > tuning.bailTumbleRateDeg {
                c.tumbleSamples += 1
            }
            // Stillness: band RMS below idle for bailStillnessWindow after the impact.
            if f.t - c.tImpact >= 0.8 {
                if f.bandRMS < tuning.idleRMS {
                    if stillnessStart == nil { stillnessStart = f.t }
                } else {
                    stillnessStart = nil
                }
                if let s = stillnessStart, f.t - s >= tuning.bailStillnessWindow {
                    c.stillnessOK = true
                }
            }
            candidate = c
            if f.t - c.tImpact > tuning.bailStillnessWindow + 1.5 {
                resolve(c, at: f.t)
                candidate = nil
            }
            return
        }

        let bigImpact = f.aRawMag >= tuning.bailImpactG
        let notALanding = f.t - recentFlightEnd > 0.5
        if bigImpact && notALanding && (activity == .riding || activity == .unknown) {
            candidate = Candidate(
                tImpact: f.t, peakG: f.aRawMag,
                clipped: f.aRawMag >= accelClipG * 0.99, tumbleSamples: 0, stillnessOK: false)
            stillnessStart = nil
        }
    }

    private func resolve(_ c: Candidate, at t: Double) {
        let tumble = c.tumbleSamples > 10
        guard c.stillnessOK || tumble else { return }
        // Saturation-duration severity heuristic (02 §4) — internal ranking only.
        let severity = Double(min(c.peakG / accelClipG, 1)) + (tumble ? 0.5 : 0)
            + (c.stillnessOK ? 0.3 : 0)
        pending.append(
            DetectedEvent(
                kind: .bail, tStart: c.tImpact, tEnd: t, confidence: c.stillnessOK ? 0.85 : 0.65,
                metrics: .bail(
                    EventMetrics.Bail(
                        severityScore: severity, tumble: tumble,
                        stillnessAfter: max(0, t - c.tImpact)))))
    }

    func drain() -> [DetectedEvent] {
        defer { pending.removeAll() }
        return pending
    }

    func finalize(at t: Double) -> [DetectedEvent] {
        if let c = candidate {
            resolve(c, at: t)
            candidate = nil
        }
        return drain()
    }
}

/// Barometer + GNSS elevation fusion, docs/spec/03 §11.
final class ElevationFusion {
    private let tuning: DetectionTuning

    private var baroFiltered: Double?
    private var baroAlpha = 0.0
    private var lastBaroT: Double?
    /// Slowly-learned offset from baro-relative to GNSS-absolute altitude.
    private var gnssBias: Double?

    private(set) var ascent = 0.0
    private(set) var descent = 0.0
    private var hysteresisRef: Double?
    private(set) var profile: [(t: Double, altitude: Double)] = []
    private var lastProfileT = -10.0

    init(tuning: DetectionTuning) {
        self.tuning = tuning
    }

    func push(baro: BaroFrame) {
        let dt = lastBaroT.map { baro.sensorTime - $0 } ?? 0.1
        lastBaroT = baro.sensorTime
        // One-pole low-pass at baroLowPassHz.
        let rc = 1.0 / (2 * .pi * tuning.baroLowPassHz)
        let alpha = dt / (rc + dt)
        let rel = Double(baro.relativeAltitude)
        baroFiltered = baroFiltered.map { $0 + alpha * (rel - $0) } ?? rel

        guard let filtered = baroFiltered else { return }
        let absolute = filtered + (gnssBias ?? 0)

        // Ascent/descent with hysteresis.
        if let ref = hysteresisRef {
            let delta = absolute - ref
            if delta >= tuning.elevationHysteresis {
                ascent += delta
                hysteresisRef = absolute
            } else if delta <= -tuning.elevationHysteresis {
                descent += -delta
                hysteresisRef = absolute
            }
        } else {
            hysteresisRef = absolute
        }

        if baro.sensorTime - lastProfileT >= 1.0 {
            lastProfileT = baro.sensorTime
            profile.append((baro.sensorTime, absolute))
        }
    }

    func push(fix: LocationFix) {
        guard !fix.flagged, fix.verticalAccuracy > 0, fix.verticalAccuracy < 15,
            let filtered = baroFiltered
        else { return }
        let observedBias = fix.altitude - filtered
        // Slow complementary anchor: GNSS shapes the absolute level over ~30 s.
        gnssBias = gnssBias.map { $0 + 0.03 * (observedBias - $0) } ?? observedBias
    }

    /// Barometric altitude change over [t1, t2], for the drop cross-check (03 §11).
    func baroDelta(from t1: Double, to t2: Double) -> Double? {
        guard profile.count >= 2 else { return nil }
        func nearest(_ t: Double) -> Double? {
            profile.min(by: { abs($0.t - t) < abs($1.t - t) }).map(\.altitude)
        }
        guard let a1 = nearest(t1), let a2 = nearest(t2) else { return nil }
        return a2 - a1
    }
}
