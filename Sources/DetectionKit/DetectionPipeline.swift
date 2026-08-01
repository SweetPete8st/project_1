import Foundation
import ShredCore

/// Everything the pipeline produced for a session.
public struct DetectionResult: Sendable {
    public var events: [DetectedEvent]
    public var activityIntervals: [ActivityInterval]
    public var stanceIntervals: [StanceInterval]
    public var calibration: CalibrationRecord?
    public var pushCount: Int
    public var pushCadenceMean: Double?
    public var topSpeed: Double
    public var topSpeedValidated: Bool
    public var ascent: Double
    public var descent: Double
    public var speedSeries: [SpeedSample]
    public var gForceEnvelope: [GForceSample]
    public var stanceTime: StanceTime

    public struct SpeedSample: Sendable, Codable, Equatable {
        public var t: Double
        public var v: Double
    }

    public struct GForceSample: Sendable, Codable, Equatable {
        public var t: Double
        public var peakG: Float
    }

    public struct StanceTime: Sendable, Codable, Equatable {
        public var regular: Double = 0
        public var switchStance: Double = 0
        public var indeterminate: Double = 0
        public init() {}
    }
}

/// Facade over the whole detection stack, docs/spec/03. Pure & incremental: push frames in
/// any interleaving (per-stream monotonic), then `finalize()`. Frame-push (not batch) so
/// events surface within NFR-4's 3 s; `drainEvents()` mid-session feeds the Live Activity.
public final class DetectionPipeline {
    public let tuning: DetectionTuning
    public let sampleRate: Double

    private let preprocessor: Preprocessor
    private let segmenter: ActivitySegmenter
    private let airborne: AirborneDetector
    private let impacts: ImpactDetector
    private let stance: StanceClassifier
    private let speed: SpeedFusion
    private let pushes: PushDetector
    private let bail: BailDetector
    private let elevation: ElevationFusion

    private var collected: [DetectedEvent] = []
    private var lastT: Double = 0
    private var firstT: Double?

    public init(
        tuning: DetectionTuning = DetectionTuning(),
        sampleRate: Double = 100,
        calibration: CalibrationRecord? = nil,
        capabilities: DeviceCapabilities = DeviceCapabilities()
    ) {
        self.tuning = tuning
        self.sampleRate = sampleRate
        self.preprocessor = Preprocessor(tuning: tuning, sampleRate: sampleRate)
        self.segmenter = ActivitySegmenter(tuning: tuning)
        self.airborne = AirborneDetector(
            tuning: tuning, sampleRate: sampleRate, accelClipG: capabilities.accelClipG,
            stance: calibration?.declaredStance)
        self.impacts = ImpactDetector(tuning: tuning, accelClipG: capabilities.accelClipG)
        self.stance = StanceClassifier(tuning: tuning, calibration: calibration)
        self.speed = SpeedFusion(tuning: tuning, sampleRate: sampleRate)
        self.pushes = PushDetector(tuning: tuning, sampleRate: sampleRate)
        self.bail = BailDetector(tuning: tuning, accelClipG: capabilities.accelClipG)
        self.elevation = ElevationFusion(tuning: tuning)
    }

    public func push(raw: RawAccelFrame) {
        preprocessor.push(raw: raw)
    }

    public func push(motion: MotionFrame) {
        let f = preprocessor.push(motion: motion)
        lastT = f.t
        if firstT == nil { firstT = f.t }

        segmenter.push(speed: speed.currentSpeed, at: f.t)
        segmenter.push(frame: f)
        let activity = segmenter.state

        airborne.push(frame: f, activity: activity)
        impacts.push(frame: f)
        stance.push(frame: f, activity: activity)
        speed.push(frame: f, activity: activity)
        pushes.push(speed: speed.currentSpeed, at: f.t)
        pushes.push(frame: f, activity: activity)
        bail.push(frame: f, activity: activity)

        let airs = airborne.drain()
        for a in airs {
            bail.noteAirborneLanding(at: a.tEnd)
        }
        collected += airs
        collected += impacts.drain()
        collected += speed.drain()
        collected += bail.drain()
    }

    public func push(fix: LocationFix) {
        stance.push(fix: fix)
        speed.push(fix: fix)
        elevation.push(fix: fix)
    }

    public func push(baro: BaroFrame) {
        elevation.push(baro: baro)
    }

    /// Arbitrated events so far (live view). Cheap enough at session scale.
    public func drainEvents() -> [DetectedEvent] {
        EventArbiter.arbitrate(collected, tuning: tuning)
    }

    public var currentActivity: ActivityState { segmenter.state }
    public var currentSpeed: Double { speed.currentSpeed }
    public var pushCount: Int { pushes.count }

    public func finalize() -> DetectionResult {
        collected += airborne.finalize()
        collected += impacts.finalize(at: lastT)
        collected += speed.finalize(at: lastT)
        collected += bail.finalize(at: lastT)
        let activity = segmenter.finalize(at: lastT)
        let (rawStanceIntervals, calibration) = stance.finalize(at: lastT)

        var events = EventArbiter.arbitrate(collected, tuning: tuning)
        pushes.removePushes(overlapping: events)

        // Drop cross-check (03 §11): barometer step within slack confirms + measures drops.
        for i in events.indices where events[i].kind == .drop {
            if case .drop(var d) = events[i].metrics {
                if let delta = elevation.baroDelta(
                    from: events[i].tStart - tuning.baroDropCrossCheckSlack,
                    to: events[i].tEnd + tuning.baroDropCrossCheckSlack), delta < -0.5
                {
                    d.baroDropHeight = -delta
                    events[i].metrics = .drop(d)
                    events[i].confidence = min(1, events[i].confidence + 0.15)
                }
            }
        }

        // Vote latency compensation: the first stance interval inside each riding span is
        // backdated to the riding start — the classifier had no contrary evidence there,
        // it simply hadn't accumulated votes yet.
        var stanceIntervals = rawStanceIntervals
        for r in activity where r.state == .riding {
            guard
                let idx = stanceIntervals.indices.first(where: {
                    stanceIntervals[$0].tStart >= r.tStart - 0.5
                        && stanceIntervals[$0].tStart < r.tEnd
                })
            else { continue }
            let precededInSameSpan = stanceIntervals.contains {
                $0.tEnd > r.tStart && $0.tEnd <= stanceIntervals[idx].tStart
            }
            if !precededInSameSpan && stanceIntervals[idx].tStart - r.tStart < 5 {
                stanceIntervals[idx].tStart = r.tStart
            }
        }

        // Stance time attribution = stance intervals ∩ riding intervals (03 §6 output).
        var stanceTime = DetectionResult.StanceTime()
        let riding = activity.filter { $0.state == .riding }
        for s in stanceIntervals {
            var overlap = 0.0
            for r in riding {
                overlap += max(0, min(s.tEnd, r.tEnd) - max(s.tStart, r.tStart))
            }
            switch s.stance {
            case .regular: stanceTime.regular += overlap
            case .switchStance: stanceTime.switchStance += overlap
            case .indeterminate: stanceTime.indeterminate += overlap
            }
        }
        // Riding time not covered by any stance interval is indeterminate too.
        let ridingTotal = riding.reduce(0.0) { $0 + ($1.tEnd - $1.tStart) }
        let attributed = stanceTime.regular + stanceTime.switchStance + stanceTime.indeterminate
        if ridingTotal > attributed {
            stanceTime.indeterminate += ridingTotal - attributed
        }

        return DetectionResult(
            events: events,
            activityIntervals: activity,
            stanceIntervals: stanceIntervals,
            calibration: calibration,
            pushCount: pushes.count,
            pushCadenceMean: pushes.cadenceMean,
            topSpeed: speed.topSpeed,
            topSpeedValidated: speed.topSpeedValidated,
            ascent: elevation.ascent,
            descent: elevation.descent,
            speedSeries: speed.speedSeries.map { .init(t: $0.t, v: $0.v) },
            gForceEnvelope: impacts.envelope.map { .init(t: $0.t, peakG: $0.peakG) },
            stanceTime: stanceTime)
    }
}
