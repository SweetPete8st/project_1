import Foundation
import ShredCore

/// Regular-vs-switch stance classification, docs/spec/03 §6.
///
/// Body facing φ is estimated as device yaw plus a per-pocket mount offset: the phone rides
/// a thigh in a known pocket, so its yaw tracks the rider's chest bearing up to a roughly
/// constant offset. The offsets below are the design constants shared with FixtureSynth;
/// the M2 field gate refines them from recorded data (they only need to be accurate to
/// ±50° given the σ buckets).
///
/// σ = wrap(φ − β) where β is the GNSS travel bearing. For the declared stance, σ near
/// +sigmaSign·90° reads as that stance; near −sigmaSign·90° reads as switch.
final class StanceClassifier {
    private let tuning: DetectionTuning
    private var calibration: CalibrationRecord?

    /// Chest bearing minus device yaw per pocket, radians (see FixtureSynth.pocketMountYaw).
    static func pocketMountYaw(_ pocket: Pocket) -> Float {
        switch pocket {
        case .frontLeft: Float(15.0 * .pi / 180)
        case .frontRight: Float(-15.0 * .pi / 180)
        case .backLeft: Float(170.0 * .pi / 180)
        case .backRight: Float(-170.0 * .pi / 180)
        }
    }

    private(set) var intervals: [StanceInterval] = []
    private var votes: [(t: Double, cls: StanceClass, sigma: Float)] = []
    private var current: StanceClass?
    private var currentStart: Double?
    private var sigmaSum: Float = 0
    private var sigmaCount: Int = 0
    private var flipStreak: [StanceClass] = []
    /// Time of the first vote in the current run of agreeing votes — flips and interval
    /// opens are backdated here so window/hysteresis latency doesn't shave real time off.
    private var runStart: Double?
    private var lastVoteT = -1.0

    // Latest course/heading inputs.
    private var latestCourse: Double = -1
    private var latestCourseT = -1.0

    // Re-pocket detection (FR-23). A re-pocket permanently changes the gravity direction,
    // so we watch for the NEW orientation to become stable — not for a return to baseline.
    private var gravityDeparted = false
    private var departureT = 0.0
    private var stableSince: Double?
    private var stableRef: SIMD3<Float>?
    private var repocketed = false

    init(tuning: DetectionTuning, calibration: CalibrationRecord?) {
        self.tuning = tuning
        self.calibration = calibration
    }

    func push(fix: LocationFix) {
        guard !fix.flagged, fix.course >= 0 else { return }
        latestCourse = fix.course
        latestCourseT = fix.sensorTime
    }

    func push(frame f: ProcessedFrame, activity: ActivityState) {
        guard let cal = calibration, cal.quality == .good else { return }
        detectRepocket(f, activity: activity)

        // 1 Hz voting while riding with a fresh course.
        guard activity == .riding,
            f.t - lastVoteT >= 1.0,
            latestCourseT > 0, f.t - latestCourseT < 3
        else { return }
        lastVoteT = f.t

        let cls: StanceClass
        var sigma: Float = 0
        if repocketed {
            // Unknown new mount orientation → honest indeterminate (03 §6.5).
            cls = .indeterminate
        } else {
            // β is compass course (clockwise from north); world yaw is CCW → negate.
            let beta = -Float(latestCourse)
            let phi = f.yawUnwrapped.truncatingRemainder(dividingBy: 2 * .pi)
                + Self.pocketMountYaw(cal.pocket)
            sigma = wrapAngle(phi - beta)
            let deg = sigma * 180 / .pi * cal.declaredStance.sigmaSign
            if deg >= tuning.stanceSigmaMinDeg && deg <= tuning.stanceSigmaMaxDeg {
                cls = .regular
            } else if deg <= -tuning.stanceSigmaMinDeg && deg >= -tuning.stanceSigmaMaxDeg {
                cls = .switchStance
            } else {
                cls = .indeterminate
            }
        }
        votes.append((f.t, cls, sigma))
        votes.removeAll { f.t - $0.t > tuning.stanceVoteWindow }
        commitVote(at: f.t)
    }

    private func commitVote(at t: Double) {
        guard let last = votes.last else { return }

        // Track the run of identical raw votes (for backdating).
        if votes.count < 2 || votes[votes.count - 2].cls != last.cls {
            runStart = last.t
        }

        // Majority over the window.
        var counts: [StanceClass: Int] = [:]
        for v in votes { counts[v.cls, default: 0] += 1 }
        guard let (winner, _) = counts.max(by: { $0.value < $1.value }) else { return }

        if current == nil {
            current = winner
            // Backdate to the start of the agreeing vote run (or this vote).
            currentStart = winner == last.cls ? (runStart ?? t) : t
            sigmaSum = 0
            sigmaCount = 0
        }
        if winner != current {
            flipStreak.append(winner)
            if flipStreak.count >= tuning.stanceFlipVotes
                && flipStreak.suffix(tuning.stanceFlipVotes).allSatisfy({ $0 == winner })
            {
                let boundary = runStart ?? t
                close(at: boundary)
                current = winner
                currentStart = boundary
                flipStreak.removeAll()
            }
        } else {
            flipStreak.removeAll()
        }
        if last.cls == current {
            sigmaSum += last.sigma
            sigmaCount += 1
        }
    }

    private func detectRepocket(_ f: ProcessedFrame, activity: ActivityState) {
        guard let cal = calibration else { return }
        let dotV = dot(f.gravityDir, normalizeV(cal.baselineGravity))
        let angle = acos(max(-1, min(1, dotV))) * 180 / .pi
        let departed = angle > tuning.repocketGravityDeg

        if !gravityDeparted {
            if departed && (activity == .idle || activity == .walking || activity == .unknown) {
                gravityDeparted = true
                departureT = f.t
                stableSince = nil
                stableRef = nil
            }
            return
        }

        // Departed: wait for the new orientation to hold still for repocketStableWindow.
        if let ref = stableRef {
            let refAngle = acos(max(-1, min(1, dot(f.gravityDir, ref)))) * 180 / .pi
            if refAngle > 8 {
                stableRef = f.gravityDir
                stableSince = f.t
            } else if let s = stableSince, f.t - s >= tuning.repocketStableWindow {
                gravityDeparted = false
                repocketed = true
                calibration?.rebaselineTimes.append(f.t)
                calibration?.baselineGravity = f.gravityDir
                close(at: departureT)
                current = nil
                currentStart = nil
                votes.removeAll()
            }
        } else {
            stableRef = f.gravityDir
            stableSince = f.t
        }
    }

    private func close(at t: Double) {
        if let c = current, let start = currentStart, t > start {
            let mean = sigmaCount > 0 ? sigmaSum / Float(sigmaCount) : 0
            intervals.append(StanceInterval(tStart: start, tEnd: t, stance: c, meanSigma: mean))
        }
        sigmaSum = 0
        sigmaCount = 0
    }

    func finalize(at t: Double) -> (intervals: [StanceInterval], calibration: CalibrationRecord?) {
        close(at: t)
        current = nil
        return (intervals, calibration)
    }

    private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private func normalizeV(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = v.shredLength
        return l > .leastNormalMagnitude ? v / l : SIMD3(0, 0, -1)
    }
}
