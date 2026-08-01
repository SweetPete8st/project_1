import Foundation
import DetectionKit
import ShredCore
import TelemetryStore

/// Fixture replay + scoring, docs/spec/08 §3. Also usable as a library by tests.
public enum Replay {
    // MARK: - Running

    /// Derives the calibration SessionEngine would produce from the fixture's opening
    /// still window (mean gravity + attitude over seconds 1–4).
    public static func deriveCalibration(_ fixture: FixtureIO.Fixture) -> CalibrationRecord? {
        let t0 = fixture.motion.first?.sensorTime ?? 0
        let window = fixture.motion.filter { $0.sensorTime > t0 + 1 && $0.sensorTime < t0 + 4 }
        guard window.count > 50 else { return nil }
        var g = SIMD3<Float>.zero
        for f in window { g += f.gravity }
        g /= Float(window.count)
        let mags = window.map { $0.userAccel.shredLength }
        let mean = mags.reduce(0, +) / Float(mags.count)
        let variance = mags.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(mags.count)
        return CalibrationRecord(
            pocket: fixture.meta.pocket, declaredStance: fixture.meta.declaredStance,
            baselineAttitude: window[window.count / 2].attitude, baselineGravity: g,
            stillVariance: variance,
            quality: variance <= DetectionTuning().calibrationStillMaxVariance ? .good : .degraded)
    }

    public static func run(
        fixture: FixtureIO.Fixture, tuning: DetectionTuning = DetectionTuning(),
        assumeRiding: Bool = false
    ) -> DetectionResult {
        let pipeline = DetectionPipeline(
            tuning: tuning, sampleRate: fixture.meta.sampleRate,
            calibration: deriveCalibration(fixture),
            capabilities: DeviceCapabilities(), assumeRiding: assumeRiding)
        // Merge streams in time order, motion driving the clock.
        var fixIdx = 0
        var baroIdx = 0
        var rawIdx = 0
        for m in fixture.motion {
            while rawIdx < fixture.rawAccel.count,
                fixture.rawAccel[rawIdx].sensorTime <= m.sensorTime
            {
                pipeline.push(raw: fixture.rawAccel[rawIdx])
                rawIdx += 1
            }
            while fixIdx < fixture.locations.count,
                fixture.locations[fixIdx].sensorTime <= m.sensorTime
            {
                pipeline.push(fix: fixture.locations[fixIdx])
                fixIdx += 1
            }
            while baroIdx < fixture.baro.count, fixture.baro[baroIdx].sensorTime <= m.sensorTime {
                pipeline.push(baro: fixture.baro[baroIdx])
                baroIdx += 1
            }
            pipeline.push(motion: m)
        }
        return pipeline.finalize()
    }

    // MARK: - Scoring

    public struct KindScore: Codable, Sendable {
        public var truePositives = 0
        public var falsePositives = 0
        public var falseNegatives = 0
        public var precision: Double {
            let d = truePositives + falsePositives
            return d == 0 ? 1 : Double(truePositives) / Double(d)
        }
        public var recall: Double {
            let d = truePositives + falseNegatives
            return d == 0 ? 1 : Double(truePositives) / Double(d)
        }
    }

    public struct FixtureScore: Codable, Sendable {
        public var name = ""
        public var kinds: [String: KindScore] = [:]
        public var airtimeErrors: [Double] = []
        public var rotationCorrect = 0
        public var rotationTotal = 0
        public var stanceCorrectTime: Double = 0
        public var stanceEvaluatedTime: Double = 0
        public var pushTruth: Int?
        public var pushDetected = 0
        public var topSpeedTruth: Double?
        public var topSpeedDetected: Double = 0
        public var descentTruth: Double?
        public var descentDetected: Double = 0
    }

    public struct CorpusReport: Codable, Sendable {
        public var fixtures: [FixtureScore] = []
        public var kinds: [String: KindScore] = [:]
        public var airtimeMAE: Double = 0
        public var rotationAccuracy: Double = 1
        public var stanceAccuracy: Double = 1
        public var tuningDescription = ""
    }

    /// Matches events to truth by kind + time overlap (±0.5 s slack).
    public static func score(
        fixture: FixtureIO.Fixture, result: DetectionResult
    ) -> FixtureScore {
        var s = FixtureScore()
        s.name = fixture.meta.name
        let slack = 0.5

        // Kinds under evaluation. `impact` events are informational (every landing has one
        // inside its airborne event); `rotationOnly` not yet scored.
        let scored: [EventKind] = [.airborne, .drop, .powerslide, .decel, .bail]
        var matchedDetected = Set<UUID>()

        for kind in scored {
            var ks = KindScore()
            let truths = fixture.truth.events.filter { $0.kind == kind }
            let detected = result.events.filter { $0.kind == kind }
            for truth in truths {
                let match = detected.first { d in
                    !matchedDetected.contains(d.id)
                        && d.tStart - slack < truth.tEnd && truth.tStart - slack < d.tEnd
                }
                if let m = match {
                    matchedDetected.insert(m.id)
                    ks.truePositives += 1
                    // Airtime + rotation quality on matched airborne events.
                    if let truthAir = truth.airtime {
                        let detAir: Double? = switch m.metrics {
                        case .airborne(let a): a.airtime
                        case .drop(let d): d.airborne.airtime
                        default: nil
                        }
                        if let da = detAir {
                            s.airtimeErrors.append(abs(da - truthAir))
                        }
                    }
                    if let truthRot = truth.rotationDegrees {
                        let detRot: Float? = switch m.metrics {
                        case .airborne(let a): a.rotationDegrees
                        case .drop(let d): d.airborne.rotationDegrees
                        default: nil
                        }
                        if let dr = detRot {
                            s.rotationTotal += 1
                            if bucket(truthRot) == bucket(dr) { s.rotationCorrect += 1 }
                        }
                    }
                } else {
                    ks.falseNegatives += 1
                }
            }
            ks.falsePositives = detected.filter { !matchedDetected.contains($0.id) }.count
            s.kinds[kind.rawValue] = ks
        }

        // Stance: sample truth intervals at 2 Hz, compare to detected intervals.
        for truth in fixture.truth.stanceIntervals {
            var t = truth.tStart + 0.25
            while t < truth.tEnd {
                s.stanceEvaluatedTime += 0.5
                let det = result.stanceIntervals.first { t >= $0.tStart && t < $0.tEnd }
                if let d = det, d.stance == truth.stance {
                    s.stanceCorrectTime += 0.5
                }
                t += 0.5
            }
        }

        s.pushTruth = fixture.truth.pushCount
        s.pushDetected = result.pushCount
        s.topSpeedTruth = fixture.truth.topSpeed
        s.topSpeedDetected = result.topSpeed
        s.descentTruth = fixture.truth.totalDescent
        s.descentDetected = result.descent
        return s
    }

    static func bucket(_ deg: Float) -> RotationBucket {
        let a = abs(deg)
        if a < 60 { return .none }
        if a >= 145 && a <= 215 { return .half }
        if a >= 325 && a <= 395 { return .full }
        return .partial
    }

    public static func aggregate(_ scores: [FixtureScore]) -> CorpusReport {
        var r = CorpusReport()
        r.fixtures = scores
        var allAirtimeErrors = [Double]()
        var rotC = 0
        var rotT = 0
        var stanceC = 0.0
        var stanceE = 0.0
        for s in scores {
            for (k, v) in s.kinds {
                var agg = r.kinds[k] ?? KindScore()
                agg.truePositives += v.truePositives
                agg.falsePositives += v.falsePositives
                agg.falseNegatives += v.falseNegatives
                r.kinds[k] = agg
            }
            allAirtimeErrors += s.airtimeErrors
            rotC += s.rotationCorrect
            rotT += s.rotationTotal
            stanceC += s.stanceCorrectTime
            stanceE += s.stanceEvaluatedTime
        }
        r.airtimeMAE =
            allAirtimeErrors.isEmpty
            ? 0 : allAirtimeErrors.reduce(0, +) / Double(allAirtimeErrors.count)
        r.rotationAccuracy = rotT == 0 ? 1 : Double(rotC) / Double(rotT)
        r.stanceAccuracy = stanceE == 0 ? 1 : stanceC / stanceE
        return r
    }

    /// M2 synthetic gates (docs/spec/09 M2). Returns failure descriptions, empty = pass.
    public static func checkSyntheticGates(_ r: CorpusReport) -> [String] {
        var failures = [String]()
        func gate(_ kind: String, precision: Double, recall: Double) {
            guard let k = r.kinds[kind] else { return }
            if k.precision < precision {
                failures.append(
                    "\(kind) precision \(fmt(k.precision)) < \(precision) "
                        + "(TP \(k.truePositives) FP \(k.falsePositives))")
            }
            if k.recall < recall {
                failures.append(
                    "\(kind) recall \(fmt(k.recall)) < \(recall) "
                        + "(TP \(k.truePositives) FN \(k.falseNegatives))")
            }
        }
        gate("airborne", precision: 0.95, recall: 0.95)
        gate("drop", precision: 0.9, recall: 0.9)
        gate("powerslide", precision: 0.9, recall: 0.9)
        gate("decel", precision: 0.85, recall: 0.85)
        gate("bail", precision: 0.9, recall: 0.9)
        if r.airtimeMAE > 0.015 {
            failures.append("airtime MAE \(Int(r.airtimeMAE * 1000))ms > 15ms")
        }
        if r.rotationAccuracy < 0.9 {
            failures.append("rotation bucket accuracy \(fmt(r.rotationAccuracy)) < 0.9")
        }
        if r.stanceAccuracy < 0.95 {
            failures.append("stance accuracy \(fmt(r.stanceAccuracy)) < 0.95")
        }
        return failures
    }

    static func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

    public static func renderTable(_ r: CorpusReport) -> String {
        var out = "kind        prec   recall  TP  FP  FN\n"
        for kind in ["airborne", "drop", "powerslide", "decel", "bail"] {
            guard let k = r.kinds[kind] else { continue }
            out += String(
                format: "%-10s  %.3f  %.3f  %3d %3d %3d\n", (kind as NSString).utf8String!,
                k.precision, k.recall, k.truePositives, k.falsePositives, k.falseNegatives)
        }
        out += String(format: "airtime MAE: %.0f ms\n", r.airtimeMAE * 1000)
        out += String(format: "rotation bucket accuracy: %.3f\n", r.rotationAccuracy)
        out += String(format: "stance time accuracy: %.3f\n", r.stanceAccuracy)
        return out
    }
}
