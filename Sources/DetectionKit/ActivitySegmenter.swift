import Foundation
import ShredCore

/// Riding / walking / idle segmentation, docs/spec/03 §2. Evaluated at 2 Hz over windowed
/// features; enter conditions must hold `stateHold` seconds before a transition commits.
/// Riding gates every downstream detector (the #1 false-positive killer).
final class ActivitySegmenter {
    private let tuning: DetectionTuning
    private let evalInterval = 0.5  // 2 Hz
    /// Envelope decimation derived from the capture rate (hardcoding broke 100 Hz input:
    /// stride lags must be computed at the ACTUAL envelope rate).
    private let envStride: Int
    private let envRate: Double

    private(set) var state: ActivityState = .unknown
    private(set) var intervals: [ActivityInterval] = []

    private var stateSince: Double?
    private var candidate: ActivityState = .unknown
    private var candidateSince: Double?
    private var lastEval: Double?

    // Feature inputs.
    private var latestSpeed: Double = 0
    private var latestSpeedTime: Double = -1
    // Vertical-bob peak times for walking cadence (1–2.5 Hz periodicity).
    private var bobPeakTimes: [Double] = []
    private var lastVertLow: Float = 0
    private var vertRising = false
    // Gait envelope ring (|rawMag − 1|, decimated to ~30 Hz, ~3 s) for stride
    // autocorrelation — the walking-vs-rolling discriminator (real-data driven).
    private var envRing: [Float] = []
    private var envDecimate = 0
    /// 2 Hz history of gait ρ for the per-event veto.
    private var rhoHistory = SampleRing(capacity: 240)

    init(tuning: DetectionTuning, sampleRate: Double) {
        self.tuning = tuning
        self.envStride = max(1, Int((sampleRate / 30.0).rounded()))
        self.envRate = sampleRate / Double(self.envStride)
    }

    func push(speed: Double, at t: Double) {
        latestSpeed = speed
        latestSpeedTime = t
    }

    func push(frame: ProcessedFrame) {
        trackBob(frame)
        trackEnvelope(frame)
        guard lastEval == nil || frame.t - lastEval! >= evalInterval else { return }
        lastEval = frame.t
        evaluate(frame)
    }

    private func trackEnvelope(_ f: ProcessedFrame) {
        envDecimate += 1
        if envDecimate % envStride == 0 {
            envRing.append(abs(f.aRawMag - 1))
            let cap = Int(3.0 * envRate)
            if envRing.count > cap {
                envRing.removeFirst(envRing.count - cap)
            }
        }
    }

    /// Peak normalized autocorrelation of the impact envelope over the stride-lag band,
    /// plus the envelope RMS. Walking: ρ ≈ 0.5–0.8 at ~1 s lag. Rolling: ρ < 0.3.
    private func gaitPeriodicity() -> (rho: Float, rms: Float) {
        let n = envRing.count
        guard n >= Int(2.0 * envRate) else { return (0, 0) }
        let mean = envRing.reduce(0, +) / Float(n)
        let centered = envRing.map { $0 - mean }
        var energy: Float = 0
        for v in centered { energy += v * v }
        guard energy > 1e-6 else { return (0, 0) }
        let rms = (energy / Float(n)).squareRoot()
        var best: Float = 0
        let lagLo = Int(tuning.gaitLagMin * envRate)
        let lagHi = min(Int(tuning.gaitLagMax * envRate), n - Int(0.5 * envRate))
        guard lagHi > lagLo else { return (0, rms) }
        for lag in lagLo...lagHi {
            var acc: Float = 0
            for i in 0..<(n - lag) {
                acc += centered[i] * centered[i + lag]
            }
            let rho = acc / energy
            if rho > best { best = rho }
        }
        return (best, rms)
    }

    /// Walking produces a 1–2.5 Hz vertical bob; count rising-edge peaks of the low-passed
    /// vertical world accel above a small amplitude.
    private func trackBob(_ f: ProcessedFrame) {
        let v = f.aWorldLow.z
        if v > lastVertLow {
            vertRising = true
        } else if vertRising && v < lastVertLow && lastVertLow > 0.05 {
            vertRising = false
            bobPeakTimes.append(f.t)
            if bobPeakTimes.count > 16 { bobPeakTimes.removeFirst() }
        }
        lastVertLow = v
    }

    private func cadenceHz(at t: Double) -> Double {
        let recent = bobPeakTimes.filter { t - $0 <= 3.0 }
        guard recent.count >= 3, let first = recent.first, let last = recent.last, last > first
        else { return 0 }
        return Double(recent.count - 1) / (last - first)
    }

    private func evaluate(_ f: ProcessedFrame) {
        let speedFresh = latestSpeedTime >= 0 && f.t - latestSpeedTime < 3
        let speed = speedFresh ? latestSpeed : -1
        let cadence = cadenceHz(at: f.t)
        let (gaitRho, envRMS) = gaitPeriodicity()
        rhoHistory.push(t: f.t, value: Double(gaitRho))
        // Real walking defeats the band-RMS test (heel strikes are broadband impulses);
        // stride periodicity is the reliable tell, with GNSS speed as an override.
        let periodicGait =
            gaitRho >= tuning.gaitPeriodicityMin && envRMS >= tuning.gaitEnvelopeRMSMin
            && (speed < 0 || speed < tuning.walkingMaxSpeed)

        let target: ActivityState
        if periodicGait {
            target = .walking
        } else if f.bandRMS > tuning.vibrationRidingRMS
            && (speed < 0 || speed > tuning.idleMaxSpeed)
        {
            target = .riding
        } else if cadence > tuning.walkingCadenceHz && f.bandRMS < tuning.vibrationRidingRMS / 2 {
            target = .walking  // gentle-gait fallback (low-impulse walkers)
        } else if f.bandRMS < tuning.idleRMS && (speed < 0 || speed < tuning.idleMaxSpeed) {
            target = .idle
        } else {
            target = state == .unknown ? .idle : state  // ambiguous: hold current
        }

        if target != candidate {
            candidate = target
            candidateSince = f.t
        }
        if candidate != state, let since = candidateSince, f.t - since >= tuning.stateHold {
            closeInterval(at: since)
            state = candidate
            stateSince = since
        }
    }

    private func closeInterval(at t: Double) {
        if let since = stateSince, state != .unknown {
            intervals.append(ActivityInterval(tStart: since, tEnd: t, state: state))
        }
    }

    func finalize(at t: Double) -> [ActivityInterval] {
        closeInterval(at: t)
        stateSince = t
        return intervals
    }

    /// Median gait ρ over a window — the per-event walking veto (docs: real-session
    /// calibration 2026-08-01).
    func gaitRhoMedian(from: Double, to: Double) -> Double {
        rhoHistory.median(from: from, to: to) ?? 0
    }

    func gaitRhoMax(from: Double, to: Double) -> Double {
        rhoHistory.max(from: from, to: to) ?? 0
    }

    /// Was the rider in `state` (by committed segmentation) at time `t`? Used by detectors
    /// that need to gate on the state at event time rather than current state.
    func stateAt(_ t: Double) -> ActivityState {
        for i in intervals where t >= i.tStart && t < i.tEnd {
            return i.state
        }
        if let since = stateSince, t >= since { return state }
        return .unknown
    }
}
