import Foundation
import ShredCore
import TelemetryStore

/// The M1 synthetic corpus, docs/spec/09 M1: clean ollies across airtimes, drops, 180/360,
/// powerslides, walking, re-pocket, GPS dropout, clipped impact — every detector has at
/// least one fixture exercising it and one tempting it to false-positive.
public enum ScenarioCatalog {
    public static func buildAll() -> [FixtureIOPayload] {
        var out: [FixtureIOPayload] = []

        // 1–6: clean ollies at graduated airtimes, mixed pockets/stances.
        let airtimes: [(Double, Pocket, Stance)] = [
            (0.15, .frontRight, .regular), (0.25, .frontLeft, .regular),
            (0.35, .frontRight, .goofy), (0.45, .backRight, .regular),
            (0.60, .frontLeft, .goofy), (0.80, .backLeft, .regular),
        ]
        for (i, (airtime, pocket, stance)) in airtimes.enumerated() {
            let s = SessionSynthesizer(
                seed: UInt64(1000 + i), pocket: pocket, declaredStance: stance)
            s.stand(6)
            s.ride(8, speed: 3.0, bearingDeg: 90)
            s.ollie(airtime: airtime)
            s.ride(6, speed: 3.0, bearingDeg: 90)
            s.ollie(airtime: airtime * 0.9)
            s.ride(5, speed: 3.0, bearingDeg: 90)
            out.append(
                s.fixture(
                    name: String(format: "ollie-%03dms-%@", Int(airtime * 1000),
                                 pocket.rawValue),
                    notes: "two clean ollies, airtime \(airtime)s"))
        }

        // 7: ten-ollie line (field-protocol shape, 08 §5).
        do {
            let s = SessionSynthesizer(seed: 2000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.ride(5, speed: 2.8, bearingDeg: 45)
            for k in 0..<10 {
                s.ollie(airtime: 0.2 + Double(k % 5) * 0.08)
                s.ride(3, speed: 2.8, bearingDeg: 45)
            }
            out.append(s.fixture(name: "ollie-line-x10", notes: "10 ollies, varied airtime"))
        }

        // 8: frontside/backside 180s and a 360.
        do {
            let s = SessionSynthesizer(seed: 3000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.ride(6, speed: 3.2, bearingDeg: 180)
            s.ollie(airtime: 0.42, rotationDeg: 180)
            s.ride(5, speed: 3.2, bearingDeg: 180, asSwitch: true)
            s.ollie(airtime: 0.40, rotationDeg: -180)
            s.ride(5, speed: 3.2, bearingDeg: 180)
            s.ollie(airtime: 0.55, rotationDeg: 360)
            s.ride(5, speed: 3.2, bearingDeg: 180)
            out.append(s.fixture(name: "spins-180-360", notes: "FS 180, BS 180 back, 360"))
        }

        // 9: drops (0.8 m and 1.5 m) with barometer confirmation.
        do {
            let s = SessionSynthesizer(seed: 4000, pocket: .frontLeft, declaredStance: .regular)
            s.stand(6)
            s.ride(6, speed: 2.5, bearingDeg: 270)
            s.drop(height: 0.8)
            s.ride(6, speed: 2.5, bearingDeg: 270)
            s.drop(height: 1.5, landPeakG: 8)
            s.ride(4, speed: 2.5, bearingDeg: 270)
            out.append(s.fixture(name: "drops-baro", notes: "0.8m and 1.5m ledge drops"))
        }

        // 10: powerslides vs plain braking (classification separation).
        do {
            let s = SessionSynthesizer(seed: 5000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.ride(6, speed: 6.0, bearingDeg: 0)
            s.brake(from: 6, to: 1.5, duration: 1.2, slide: true)
            s.ride(6, speed: 6.0, bearingDeg: 0)
            s.brake(from: 6, to: 2.0, duration: 1.4, slide: false)
            s.ride(5, speed: 5.0, bearingDeg: 0)
            s.brake(from: 5, to: 0.8, duration: 1.0, slide: true)
            s.ride(4, speed: 3.0, bearingDeg: 0)
            out.append(s.fixture(name: "slides-vs-brakes", notes: "2 powerslides, 1 footbrake"))
        }

        // 11: push runs (cadence + count).
        do {
            let s = SessionSynthesizer(seed: 6000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.pushRun(10, from: 0.8, to: 4.0, bearingDeg: 90, pushes: 6)
            s.ride(8, speed: 4.0, bearingDeg: 90)
            s.pushRun(8, from: 3.0, to: 5.5, bearingDeg: 90, pushes: 4)
            s.ride(5, speed: 5.5, bearingDeg: 90)
            out.append(s.fixture(name: "push-runs", notes: "10 pushes total"))
        }

        // 12: walking interlude between rides — the classic false-positive trap.
        do {
            let s = SessionSynthesizer(seed: 7000, pocket: .frontLeft, declaredStance: .goofy)
            s.stand(6)
            s.ride(8, speed: 3.0, bearingDeg: 120)
            s.ollie(airtime: 0.3)
            s.ride(4, speed: 3.0, bearingDeg: 120)
            s.walk(15, bearingDeg: 120)  // stairs/jogging texture must yield zero events
            s.ride(8, speed: 3.0, bearingDeg: 120)
            s.ollie(airtime: 0.35)
            s.ride(4, speed: 3.0, bearingDeg: 120)
            out.append(s.fixture(name: "walking-trap", notes: "walking must not create events"))
        }

        // 13: switch riding split (stance donut ground truth).
        do {
            let s = SessionSynthesizer(seed: 8000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.ride(20, speed: 3.5, bearingDeg: 60)
            s.ride(12, speed: 3.5, bearingDeg: 60, asSwitch: true)
            s.ride(10, speed: 3.5, bearingDeg: 240)
            s.ride(8, speed: 3.5, bearingDeg: 240, asSwitch: true)
            out.append(
                s.fixture(name: "stance-split", notes: "30s regular / 20s switch, two bearings"))
        }

        // 14: goofy rider stance split (sign symmetry check).
        do {
            let s = SessionSynthesizer(seed: 8500, pocket: .backLeft, declaredStance: .goofy)
            s.stand(6)
            s.ride(15, speed: 3.0, bearingDeg: 300)
            s.ride(15, speed: 3.0, bearingDeg: 300, asSwitch: true)
            out.append(s.fixture(name: "stance-goofy-backpocket", notes: "goofy, back pocket"))
        }

        // 15: re-pocket mid-session → stance goes honest-indeterminate (FR-23).
        do {
            let s = SessionSynthesizer(seed: 9000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.ride(15, speed: 3.0, bearingDeg: 90)
            s.repocket(rollDeg: 55)
            s.ride(15, speed: 3.0, bearingDeg: 90, recordStance: false)
            // Post-repocket riding is truth-indeterminate.
            let postStart = s.motion.last!.sensorTime - 15
            out.append(contentsOf: [] as [FixtureIOPayload])  // keep builder flow linear
            var f = s.fixture(name: "repocket", notes: "roll change 55° mid-idle")
            f.truth.stanceIntervals.append(
                StanceInterval(
                    tStart: postStart, tEnd: s.motion.last!.sensorTime,
                    stance: .indeterminate, meanSigma: 0))
            out.append(f)
        }

        // 16: GPS dropout tunnel — inertial-only stretch, no speed/stance claims inside.
        do {
            let s = SessionSynthesizer(seed: 10000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.ride(10, speed: 4.0, bearingDeg: 0)
            s.ride(12, speed: 4.0, bearingDeg: 0, gpsValid: false, recordStance: false)
            s.ollie(airtime: 0.3)  // detection must still work without GPS
            s.ride(3, speed: 4.0, bearingDeg: 0, gpsValid: false, recordStance: false)
            s.ride(10, speed: 4.0, bearingDeg: 0)
            out.append(s.fixture(name: "gps-dropout", notes: "ollie inside GPS gap"))
        }

        // 17: clipped impact — landing beyond the 16 g public clip.
        do {
            let s = SessionSynthesizer(seed: 11000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.ride(6, speed: 3.0, bearingDeg: 90)
            s.drop(height: 2.2, landPeakG: 17.5)  // synth exceeds clip; capture clamps
            s.ride(5, speed: 3.0, bearingDeg: 90)
            out.append(s.fixture(name: "clipped-impact", notes: "landing peak beyond clip"))
        }

        // 18: bail with tumble and stillness → bail event, no fake trick.
        do {
            let s = SessionSynthesizer(seed: 12000, pocket: .frontLeft, declaredStance: .regular)
            s.stand(6)
            s.ride(8, speed: 5.0, bearingDeg: 45)
            s.bail(stillness: 8)
            s.ride(6, speed: 2.5, bearingDeg: 45)
            out.append(s.fixture(name: "bail", notes: "slam + tumble + 8s stillness"))
        }

        // 19: downhill run — elevation + validated top speed.
        do {
            let s = SessionSynthesizer(seed: 13000, pocket: .frontRight, declaredStance: .regular)
            s.stand(6)
            s.hill(25, speed: 9.0, bearingDeg: 200, descent: 18)
            s.brake(from: 9, to: 2, duration: 2.0, slide: true)
            s.ride(6, speed: 2.0, bearingDeg: 200)
            out.append(s.fixture(name: "downhill", notes: "18m descent, 9 m/s, slide at bottom"))
        }

        // 20: full mixed session — the everything fixture.
        do {
            let s = SessionSynthesizer(seed: 14000, pocket: .frontRight, declaredStance: .regular)
            s.stand(8)
            s.pushRun(8, from: 0.5, to: 3.5, bearingDeg: 90, pushes: 5)
            s.ride(8, speed: 3.5, bearingDeg: 90)
            s.ollie(airtime: 0.35)
            s.ride(5, speed: 3.5, bearingDeg: 90)
            s.ollie(airtime: 0.5, rotationDeg: 180)
            s.ride(6, speed: 3.5, bearingDeg: 90, asSwitch: true)
            s.idle(20)
            s.walk(10, bearingDeg: 180)
            s.ride(8, speed: 4.5, bearingDeg: 180)
            s.drop(height: 1.0)
            s.ride(5, speed: 4.5, bearingDeg: 180)
            s.brake(from: 4.5, to: 1, duration: 1.2, slide: true)
            s.ride(5, speed: 3.0, bearingDeg: 180)
            out.append(s.fixture(name: "mixed-session", notes: "the works"))
        }

        return out
    }

    /// Writes the corpus to `<root>/<name>.shredfix` bundles.
    public static func writeAll(to root: URL) throws -> [String] {
        var names = [String]()
        for payload in buildAll() {
            let fixture = FixtureIO.Fixture(
                meta: payload.meta, truth: payload.truth, motion: payload.motion,
                rawAccel: payload.rawAccel, locations: payload.locations, baro: payload.baro)
            try FixtureIO.write(
                fixture, to: root.appendingPathComponent("\(payload.meta.name).shredfix"))
            names.append(payload.meta.name)
        }
        return names
    }
}
