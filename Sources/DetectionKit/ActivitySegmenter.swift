import Foundation
import ShredCore

/// Riding / walking / idle segmentation, docs/spec/03 §2. Evaluated at 2 Hz over windowed
/// features; enter conditions must hold `stateHold` seconds before a transition commits.
/// Riding gates every downstream detector (the #1 false-positive killer).
final class ActivitySegmenter {
    private let tuning: DetectionTuning
    private let evalInterval = 0.5  // 2 Hz

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

    init(tuning: DetectionTuning) {
        self.tuning = tuning
    }

    func push(speed: Double, at t: Double) {
        latestSpeed = speed
        latestSpeedTime = t
    }

    func push(frame: ProcessedFrame) {
        trackBob(frame)
        guard lastEval == nil || frame.t - lastEval! >= evalInterval else { return }
        lastEval = frame.t
        evaluate(frame)
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

        let target: ActivityState
        if f.bandRMS > tuning.vibrationRidingRMS && (speed < 0 || speed > tuning.idleMaxSpeed) {
            target = .riding
        } else if cadence > tuning.walkingCadenceHz && f.bandRMS < tuning.vibrationRidingRMS / 2 {
            target = .walking
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
