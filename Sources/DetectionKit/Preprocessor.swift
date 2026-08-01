import Foundation
import ShredCore

/// One preprocessed 100 Hz frame, docs/spec/03 §1. Everything downstream consumes this.
struct ProcessedFrame {
    var t: Double
    /// User (gravity-removed) acceleration rotated to world frame, g.
    var aWorld: SIMD3<Float>
    /// Low-passed world acceleration (6 Hz), g — body dynamics.
    var aWorldLow: SIMD3<Float>
    /// ‖userAccel‖, g.
    var aMag: Float
    /// ‖raw accel‖, g (gravity included → ~1 g at rest, ~0 in free fall).
    var aRawMag: Float
    /// d/dt of aRawMag, g/s.
    var jerk: Float
    /// 8–25 Hz band RMS of aMag over 500 ms — rolling-vibration signature.
    var bandRMS: Float
    /// Unwrapped world yaw, radians (continuous across ±π).
    var yawUnwrapped: Float
    /// World-frame yaw rate, rad/s.
    var yawRate: Float
    /// ‖rotationRate‖, rad/s.
    var omegaMag: Float
    /// Gravity direction in device frame (unit).
    var gravityDir: SIMD3<Float>
}

/// Incremental preprocessor: pair device-motion and raw-accel streams, produce
/// `ProcessedFrame`s. Raw accel is matched to motion frames by nearest-time (the two
/// streams are delivered at the same nominal rate; drift beyond one frame period is
/// tolerated by holding the latest raw sample).
final class Preprocessor {
    let sampleRate: Double
    private let tuning: DetectionTuning

    private var lowPass: [Cascade]
    /// Per-axis band filters: filtering the magnitude would rectify zero-mean vibration
    /// (doubling its frequency out of band); filter axes, then take the magnitude.
    private var band: [Cascade]
    private var bandRMS: RunningRMS
    private var lastRawMag: Float?
    private var lastRawTime: Double?
    private var pendingRaw: [RawAccelFrame] = []
    private var lastYaw: Float?
    private var yawAccum: Float = 0

    init(tuning: DetectionTuning, sampleRate: Double) {
        self.tuning = tuning
        self.sampleRate = sampleRate
        self.lowPass = [
            Cascade.lowPass4(cutoffHz: tuning.lowPassCutoffHz, sampleRate: sampleRate),
            Cascade.lowPass4(cutoffHz: tuning.lowPassCutoffHz, sampleRate: sampleRate),
            Cascade.lowPass4(cutoffHz: tuning.lowPassCutoffHz, sampleRate: sampleRate),
        ]
        self.band = (0..<3).map { _ in
            Cascade.bandPass(
                lowHz: tuning.vibrationBandLowHz, highHz: tuning.vibrationBandHighHz,
                sampleRate: sampleRate)
        }
        self.bandRMS = RunningRMS(windowSamples: Int(tuning.bandRMSWindow * sampleRate))
    }

    func push(raw: RawAccelFrame) {
        pendingRaw.append(raw)
        // Bound memory if motion stalls (04 §7 watchdog owns restarts). Generous bound:
        // concurrent delivery can run the raw stream well ahead of motion.
        let cap = Int(sampleRate) * 10
        if pendingRaw.count > cap {
            pendingRaw.removeFirst(pendingRaw.count - cap)
        }
    }

    func push(motion: MotionFrame) -> ProcessedFrame {
        // Rotate to world.
        let aWorld = motion.attitude.act(motion.userAccel)
        let omegaWorld = motion.attitude.act(motion.rotationRate)

        // Nearest raw accel at or before this motion frame (hold-last on gaps).
        // Degraded fallback reconstructs raw from the fused streams (raw = user − gravity,
        // SHRED sign convention — see SynthKit.SessionSynthesizer header).
        var rawMag: Float = (motion.userAccel - motion.gravity).shredLength
        while let first = pendingRaw.first, first.sensorTime <= motion.sensorTime + 0.5 / sampleRate {
            lastRawMag = first.accel.shredLength
            lastRawTime = first.sensorTime
            pendingRaw.removeFirst()
        }
        // Use the paired raw sample only while it's fresh; a stale hold (raw stream lagging
        // or running ahead under concurrent delivery) is worse than the reconstruction.
        if let m = lastRawMag, let t = lastRawTime, motion.sensorTime - t <= 3.0 / sampleRate {
            rawMag = m
        }

        // Jerk on the raw magnitude, frame cadence.
        var jerk: Float = 0
        if let prev = previousRawMag {
            jerk = Float((Double(rawMag - prev)) * sampleRate)
        }
        previousRawMag = rawMag
        previousRawTime = motion.sensorTime

        // Filters.
        let low = SIMD3<Float>(
            Float(lowPass[0].process(Double(aWorld.x))),
            Float(lowPass[1].process(Double(aWorld.y))),
            Float(lowPass[2].process(Double(aWorld.z))))
        let bx = band[0].process(Double(motion.userAccel.x))
        let by = band[1].process(Double(motion.userAccel.y))
        let bz = band[2].process(Double(motion.userAccel.z))
        let bandSample = (bx * bx + by * by + bz * bz).squareRoot()
        let rms = Float(bandRMS.push(bandSample))

        // Yaw unwrap. Seeded with the absolute (magnetic-referenced) yaw so consumers get
        // continuous absolute yaw, not first-frame-relative (stance math needs absolute).
        let yaw = motion.attitude.yaw
        if let last = lastYaw {
            yawAccum += wrapAngle(yaw - last)
        } else {
            yawAccum = yaw
        }
        lastYaw = yaw

        return ProcessedFrame(
            t: motion.sensorTime,
            aWorld: aWorld,
            aWorldLow: low,
            aMag: motion.userAccel.shredLength,
            aRawMag: rawMag,
            jerk: jerk,
            bandRMS: rms,
            yawUnwrapped: yawAccum,
            yawRate: omegaWorld.z,
            omegaMag: motion.rotationRate.shredLength,
            gravityDir: normalize(motion.gravity))
    }

    private var previousRawMag: Float?
    private var previousRawTime: Double?

    private func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = v.shredLength
        return l > .leastNormalMagnitude ? v / l : SIMD3(0, 0, -1)
    }
}
