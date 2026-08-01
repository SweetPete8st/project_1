import Foundation
import ShredCore

/// Motion-stream generators for auto-start detector validation (positives + the negative
/// controls the integration brief requires: walking, jogging, stairs-ish, vehicle,
/// hand-fumbling). Each scenario runs at 50 Hz with an arbitrary fixed pocket orientation —
/// the detector must be placement-independent, so tests sweep random attitudes.
public enum AutoStartScenarios {
    public struct Stream {
        public var frames: [MotionFrame]
        /// Sensor times of true push impulse centers (empty for negatives).
        public var truePushTimes: [Double]
    }

    public static func makeAttitude(_ rng: inout SplitMix64) -> Quaternion {
        (Quaternion(yaw: Float(rng.uniform() * 2 * .pi))
            * Quaternion(axis: SIMD3(1, 0, 0), angle: Float(rng.uniform() * 2 * .pi))
            * Quaternion(axis: SIMD3(0, 1, 0), angle: Float(rng.uniform() * .pi)))
            .normalized
    }

    static func frames(
        seed: UInt64, duration: Double, rate: Double, attitude: Quaternion?,
        uWorld: (Double, inout SplitMix64) -> SIMD3<Float>
    ) -> [MotionFrame] {
        var rng = SplitMix64(seed: seed)
        let att = attitude ?? makeAttitude(&rng)
        let inv = att.conjugate
        let gravityDevice = inv.act(SIMD3(0, 0, -1))
        var out = [MotionFrame]()
        out.reserveCapacity(Int(duration * rate))
        let dt = 1 / rate
        var t = 50.0
        for i in 0..<Int(duration * rate) {
            t += dt
            var u = uWorld(Double(i) * dt, &rng)
            u.x += Float(rng.gaussian()) * 0.01
            u.y += Float(rng.gaussian()) * 0.01
            u.z += Float(rng.gaussian()) * 0.012
            out.append(
                MotionFrame(
                    sensorTime: t, userAccel: inv.act(u), gravity: gravityDevice,
                    rotationRate: SIMD3(
                        Float(rng.gaussian()) * 0.05, Float(rng.gaussian()) * 0.05,
                        Float(rng.gaussian()) * 0.05),
                    attitude: att))
        }
        return out
    }

    /// Push impulse train: raised-cosine horizontal pulses (0.25 s wide) at a cadence,
    /// with a small vertical component and inter-push coasting noise.
    public static func skatePushing(
        seed: UInt64, pushes: Int, interval: Double = 1.1, peakG: Double = 0.35,
        rate: Double = 50, attitude: Quaternion? = nil, leadIn: Double = 3,
        doubleBump: Bool = false
    ) -> Stream {
        let duration = leadIn + Double(pushes) * interval + 3
        var pushTimes = [Double]()
        for k in 0..<pushes {
            pushTimes.append(leadIn + Double(k) * interval)
        }
        let f = frames(seed: seed, duration: duration, rate: rate, attitude: attitude) {
            t, rng in
            var u = SIMD3<Float>.zero
            for p in pushTimes {
                let center = p + 0.125
                let x = (t - center) / 0.125
                if abs(x) < 1 {
                    let env = Float(0.5 * (1 + cos(.pi * x)))
                    u.x += Float(peakG) * env
                    u.z += 0.06 * env
                }
                if doubleBump {
                    let x2 = (t - center - 0.18) / 0.06
                    if abs(x2) < 1 {
                        u.x += Float(peakG) * 0.7 * Float(0.5 * (1 + cos(.pi * x2)))
                    }
                }
            }
            u.x += Float(rng.gaussian()) * 0.015
            return u
        }
        // Frame sensor times start at 50 + dt: report true push centers on that clock.
        let t0 = 50.0
        return Stream(frames: f, truePushTimes: pushTimes.map { $0 + 0.125 + t0 })
    }

    /// Walking: mostly-vertical 2 Hz bob.
    public static func walking(
        seed: UInt64, duration: Double = 40, rate: Double = 50, attitude: Quaternion? = nil
    ) -> Stream {
        let f = frames(seed: seed, duration: duration, rate: rate, attitude: attitude) {
            t, _ in
            SIMD3(
                Float(sin(t * 2 * .pi * 2.0 + 1.3)) * 0.05,
                0,
                Float(sin(t * 2 * .pi * 2.0)) * 0.16)
        }
        return Stream(frames: f, truePushTimes: [])
    }

    /// Jogging: strong vertical strikes at ~2.8 Hz with some horizontal shake.
    public static func jogging(
        seed: UInt64, duration: Double = 40, rate: Double = 50, attitude: Quaternion? = nil
    ) -> Stream {
        let f = frames(seed: seed, duration: duration, rate: rate, attitude: attitude) {
            t, rng in
            let phase = t * 2.8
            let strike = Float(max(0, sin(phase * 2 * .pi)))
            return SIMD3(
                Float(rng.gaussian()) * 0.06 + 0.10 * strike,
                Float(rng.gaussian()) * 0.05,
                0.5 * strike * strike + Float(rng.gaussian()) * 0.05)
        }
        return Stream(frames: f, truePushTimes: [])
    }

    /// Car ride: slow horizontal sway + irregular road bumps (mostly vertical).
    public static func carRide(
        seed: UInt64, duration: Double = 60, rate: Double = 50, attitude: Quaternion? = nil
    ) -> Stream {
        var bumpRng = SplitMix64(seed: seed &+ 99)
        var bumps = [Double]()
        var tb = 2.0
        while tb < duration {
            tb += 1.5 + bumpRng.uniform() * 5
            bumps.append(tb)
        }
        let f = frames(seed: seed, duration: duration, rate: rate, attitude: attitude) {
            t, rng in
            var u = SIMD3<Float>(
                Float(sin(t * 2 * .pi * 0.4)) * 0.08,
                Float(sin(t * 2 * .pi * 0.23 + 0.7)) * 0.06,
                0)
            for b in bumps where abs(t - b) < 0.08 {
                u.z += Float(0.35 * (1 - abs(t - b) / 0.08)) * (rng.uniform() > 0.5 ? 1 : -1)
            }
            return u
        }
        return Stream(frames: f, truePushTimes: [])
    }

    /// Picking the phone up / fumbling by hand: bursty multi-axis noise.
    public static func handFumble(
        seed: UInt64, duration: Double = 20, rate: Double = 50, attitude: Quaternion? = nil
    ) -> Stream {
        let f = frames(seed: seed, duration: duration, rate: rate, attitude: attitude) {
            t, rng in
            let burst = sin(t * 0.9) > 0.4 ? 1.0 : 0.15
            return SIMD3(
                Float(rng.gaussian() * 0.18 * burst),
                Float(rng.gaussian() * 0.18 * burst),
                Float(rng.gaussian() * 0.2 * burst))
        }
        return Stream(frames: f, truePushTimes: [])
    }
}
