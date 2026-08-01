import Foundation
import ShredCore

/// Deterministic physically-modeled session generator, docs/spec/08 §2 (synthetic corpus).
///
/// Signal model (self-consistent with DetectionKit's expectations):
///  - `u_world`: dynamic ("user") acceleration in world frame, g, z-up.
///  - attitude = yaw(deviceYaw) ∘ roll(pocketRoll); deviceYaw = chestYaw − pocketMountYaw.
///  - gravity_device = attitude⁻¹ · (0,0,−1); userAccel_device = attitude⁻¹ · u_world;
///    raw_device = userAccel_device − gravity_device  (SHRED sign convention: userAccel is
///    kinematic — +z when accelerating upward — so rest → ‖raw‖ = 1 g, free fall
///    (u = (0,0,−1)) → ‖raw‖ = 0, a +2.4 g pop → ‖raw‖ = 3.4 g).
///  - Chest yaw while riding: φ = −course + sigmaSign·90° (regular) / −course − sigmaSign·90°
///    (switch), the exact inverse of StanceClassifier's σ math.
///
/// The synthesizer is a sequential timeline builder; every segment appends 100 Hz motion +
/// raw frames, 1 Hz GNSS fixes, 4 Hz baro frames, and ground-truth labels.
public final class SessionSynthesizer {
    public let sampleRate: Double
    public let pocket: Pocket
    public let declaredStance: Stance

    var rng: SplitMix64
    let dt: Double

    // Continuous state.
    var t: Double = 100.0  // sensor clock starts non-zero like a real boot clock
    var east: Double = 0
    var north: Double = 0
    var altitude: Double = 0
    var speed: Double = 0
    /// Compass course, radians CW from north.
    var course: Double = 0
    var ridingSwitch = false
    var pocketRoll: Float = 0
    var lastFixT = -10.0
    var lastBaroT = -10.0
    /// Smoothed device yaw so segment transitions don't inject fake yaw-rate spikes.
    var deviceYaw: Float = 0
    var yawInitialized = false
    /// Extra in-flight spin applied on top of the riding yaw (during ollie rotation).
    var spinOffset: Float = 0

    // Outputs.
    public private(set) var motion: [MotionFrame] = []
    public private(set) var rawAccel: [RawAccelFrame] = []
    public private(set) var fixes: [LocationFix] = []
    public private(set) var baro: [BaroFrame] = []
    public private(set) var truthEvents: [FixtureTruth.TruthEvent] = []
    public private(set) var truthStance: [StanceInterval] = []
    public private(set) var truthPushCount = 0
    public private(set) var trueTopSpeed: Double = 0
    public private(set) var trueDescent: Double = 0

    /// Chest-vs-device mount offsets; must mirror StanceClassifier.pocketMountYaw.
    public static func pocketMountYaw(_ pocket: Pocket) -> Float {
        switch pocket {
        case .frontLeft: Float(15.0 * .pi / 180)
        case .frontRight: Float(-15.0 * .pi / 180)
        case .backLeft: Float(170.0 * .pi / 180)
        case .backRight: Float(-170.0 * .pi / 180)
        }
    }

    public init(
        seed: UInt64, pocket: Pocket = .frontRight, declaredStance: Stance = .regular,
        sampleRate: Double = 100
    ) {
        self.rng = SplitMix64(seed: seed)
        self.pocket = pocket
        self.declaredStance = declaredStance
        self.sampleRate = sampleRate
        self.dt = 1 / sampleRate
    }

    // MARK: - Frame emission core

    /// Target chest yaw for current riding config.
    private func chestYaw() -> Float {
        let beta = -Float(course)
        let sign = declaredStance.sigmaSign
        return ridingSwitch ? beta - sign * (.pi / 2) : beta + sign * (.pi / 2)
    }

    private func targetDeviceYaw() -> Float {
        chestYaw() - Self.pocketMountYaw(pocket) + spinOffset
    }

    /// Emits one 100 Hz step given world dynamic accel `u` (g) and vibration amplitude.
    func step(
        u: SIMD3<Float>, vibration: Float, gpsValid: Bool = true, freeFall: Bool = false,
        extraOmega: SIMD3<Float> = .zero, yawBlend: Float = 0.08
    ) {
        t += dt

        // Blend device yaw toward target (rate-limited turn, no fake spikes).
        let target = targetDeviceYaw()
        if !yawInitialized {
            deviceYaw = target
            yawInitialized = true
        } else {
            deviceYaw += wrapAngle(target - deviceYaw) * yawBlend
        }
        let yawNoise = Float(rng.gaussian()) * 0.01
        let attitude = Quaternion(yaw: deviceYaw + yawNoise)
            * Quaternion(axis: SIMD3(1, 0, 0), angle: pocketRoll)
        let inv = attitude.conjugate

        // Vibration: band-limited (≈10–22 Hz) multi-axis texture while rolling.
        var uu = u
        if vibration > 0 {
            let phase1 = Float(t * 2 * .pi * 13.0)
            let phase2 = Float(t * 2 * .pi * 19.0)
            let n = Float(rng.gaussian())
            uu.x += vibration * (0.6 * sin(phase1 + n) + Float(rng.gaussian()) * 0.4)
            uu.y += vibration * (0.5 * sin(phase2) + Float(rng.gaussian()) * 0.4)
            uu.z += vibration * (0.7 * sin(phase1 * 1.31) + Float(rng.gaussian()) * 0.5)
        }
        uu.x += Float(rng.gaussian()) * 0.006
        uu.y += Float(rng.gaussian()) * 0.006
        uu.z += Float(rng.gaussian()) * 0.008

        let gravityWorld = SIMD3<Float>(0, 0, -1)
        let userDevice = inv.act(uu)
        var gravityDevice = inv.act(gravityWorld)
        var rawDevice = userDevice - gravityDevice
        if freeFall {
            // In true free fall the accelerometer reads ~0 regardless of frame math.
            rawDevice = SIMD3<Float>(
                Float(rng.gaussian()) * 0.03, Float(rng.gaussian()) * 0.03,
                Float(rng.gaussian()) * 0.03)
            gravityDevice = inv.act(gravityWorld)  // fusion keeps its gravity estimate
        }

        // Rotation rate: yaw change + extra (tumble/spin), device frame ≈ world z for our
        // yaw-dominant attitudes.
        let yawRate = Float(sampleRate) * wrapAngle(target - deviceYaw) * yawBlend
        let omega = SIMD3<Float>(
            Float(rng.gaussian()) * 0.02 + extraOmega.x,
            Float(rng.gaussian()) * 0.02 + extraOmega.y,
            yawRate + Float(rng.gaussian()) * 0.02 + extraOmega.z)

        motion.append(
            MotionFrame(
                sensorTime: t, userAccel: userDevice, gravity: gravityDevice,
                rotationRate: omega, attitude: attitude))
        rawAccel.append(RawAccelFrame(sensorTime: t, accel: rawDevice))

        // Advance ground track.
        east += speed * sin(course) * dt
        north += speed * cos(course) * dt
        trueTopSpeed = max(trueTopSpeed, speed)

        emitFixIfDue(valid: gpsValid)
        emitBaroIfDue()
    }

    private func emitFixIfDue(valid: Bool) {
        guard valid, t - lastFixT >= 1.0 else { return }
        lastFixT = t
        let meterPerDegLat = 111_320.0
        let lat0 = 40.4168, lon0 = -3.7038
        let lat = lat0 + (north + rng.gaussian() * 1.5) / meterPerDegLat
        let lon = lon0 + (east + rng.gaussian() * 1.5) / (meterPerDegLat * cos(lat0 * .pi / 180))
        fixes.append(
            LocationFix(
                sensorTime: t, latitude: lat, longitude: lon,
                horizontalAccuracy: 3 + abs(rng.gaussian()) * 2,
                altitude: 650 + altitude + rng.gaussian() * 2,
                verticalAccuracy: 3 + abs(rng.gaussian()),
                speed: max(0, speed + rng.gaussian() * 0.15),
                speedAccuracy: 0.3,
                course: speed > 0.3 ? wrapCourse(course + rng.gaussian() * 0.03) : -1,
                courseAccuracy: 5 * .pi / 180))
    }

    private func emitBaroIfDue() {
        guard t - lastBaroT >= 0.25 else { return }
        lastBaroT = t
        baro.append(
            BaroFrame(
                sensorTime: t,
                relativeAltitude: Float(altitude + rng.gaussian() * 0.04),
                pressure: Float(101.3 - altitude * 0.012)))
    }

    private func wrapCourse(_ c: Double) -> Double {
        var v = c.truncatingRemainder(dividingBy: 2 * .pi)
        if v < 0 { v += 2 * .pi }
        return v
    }

    // MARK: - Segments

    /// Still on the board (calibration baseline / idle break).
    public func stand(_ duration: Double) {
        speed = 0
        for _ in 0..<Int(duration * sampleRate) {
            step(u: .zero, vibration: 0)
        }
    }

    /// Cruise at constant speed. Records a truth stance interval while GPS course is valid.
    public func ride(
        _ duration: Double, speed: Double, bearingDeg: Double, asSwitch: Bool = false,
        gpsValid: Bool = true, recordStance: Bool = true
    ) {
        self.ridingSwitch = asSwitch
        let targetCourse = bearingDeg * .pi / 180
        let start = t
        self.speed = speed
        for _ in 0..<Int(duration * sampleRate) {
            // Ease course toward target (carve, not teleport).
            let d = wrapAngleD(targetCourse - course)
            course = course + d * min(1, 2.0 * dt)
            step(u: .zero, vibration: 0.06, gpsValid: gpsValid)
        }
        if recordStance && gpsValid {
            truthStance.append(
                StanceInterval(
                    tStart: start, tEnd: t,
                    stance: asSwitch ? .switchStance : .regular, meanSigma: 0))
        }
    }

    /// Accelerating run with `pushes` kick strokes from `from` to `to` m/s.
    public func pushRun(
        _ duration: Double, from: Double, to: Double, bearingDeg: Double, pushes: Int
    ) {
        ridingSwitch = false
        course = bearingDeg * .pi / 180
        let start = t
        let n = Int(duration * sampleRate)
        let pushInterval = duration / Double(pushes + 1)
        var nextPush = pushInterval * 0.5
        var pushPhase = -1.0  // <0: none; else seconds into the push
        speed = from
        let g = 9.80665
        for i in 0..<n {
            let elapsed = Double(i) * dt
            if pushPhase < 0, elapsed >= nextPush, pushes > 0, truthPushCountLocal < pushes {
                pushPhase = 0
                nextPush += pushInterval
            }
            var u = SIMD3<Float>.zero
            if pushPhase >= 0 {
                if pushPhase < 0.25 {
                    u.z += -0.09  // leg dip while the pushing foot unloads
                } else if pushPhase < 0.75 {
                    let a = (to - from) / (Double(pushes) * 0.5)  // burst accel m/s²
                    speed = min(to, speed + a * dt)
                    u.x += Float(a / g * sin(course))
                    u.y += Float(a / g * cos(course))
                } else {
                    pushPhase = -1
                    truthPushCountLocal += 1
                }
                if pushPhase >= 0 { pushPhase += dt }
            }
            step(u: u, vibration: 0.06)
        }
        truthPushCount += truthPushCountLocal
        truthPushCountLocal = 0
        truthStance.append(
            StanceInterval(tStart: start, tEnd: t, stance: .regular, meanSigma: 0))
    }

    private var truthPushCountLocal = 0

    /// Ollie (or air): pop spike → ballistic flight → landing spike, optional spin.
    public func ollie(airtime: Double, rotationDeg: Float = 0, landPeakG: Float = 4.5) {
        // 0.4 s pre-roll.
        for _ in 0..<Int(0.4 * sampleRate) {
            step(u: .zero, vibration: 0.06)
        }
        let tPop = t
        // Pop: 30 ms sharp upward spike.
        for i in 0..<Int(0.03 * sampleRate).clampedMin(2) {
            let amp: Float = i == 0 ? 2.4 : 1.9
            step(u: SIMD3(0, 0, amp), vibration: 0)
        }
        // Flight.
        let flightFrames = Int(airtime * sampleRate)
        let spinPerFrame = rotationDeg * .pi / 180 / Float(flightFrames)
        for _ in 0..<flightFrames {
            spinOffset += spinPerFrame
            step(
                u: SIMD3(0, 0, -1), vibration: 0, freeFall: true,
                extraOmega: SIMD3(0, 0, 0), yawBlend: 1.0)
        }
        let tLand = t
        // Landing: 40 ms decaying spike.
        for i in 0..<Int(0.04 * sampleRate).clampedMin(3) {
            let amp = landPeakG * (i == 0 ? 1.0 : (i == 1 ? 0.7 : 0.4))
            step(u: SIMD3(0.1, 0, amp), vibration: 0.02)
        }
        // Post-roll.
        for _ in 0..<Int(0.5 * sampleRate) {
            step(u: .zero, vibration: 0.06)
        }
        // A 180 leaves the rider riding the other way round: fold the spin into the
        // steady-state by flipping switch and clearing the offset it created.
        if abs(abs(rotationDeg) - 180) < 30 {
            ridingSwitch.toggle()
            spinOffset = 0
        } else if abs(rotationDeg) >= 300 {
            spinOffset = 0
        }
        truthEvents.append(
            FixtureTruth.TruthEvent(
                kind: .airborne, tStart: tPop, tEnd: tLand + 0.15, airtime: airtime,
                rotationDegrees: rotationDeg))
    }

    /// Roll off a ledge: no pop, free fall, landing; terrain drops by `height` meters.
    public func drop(height: Double, landPeakG: Float = 6.0) {
        let g = 9.80665
        let airtime = (2 * height / g).squareRoot()
        for _ in 0..<Int(0.3 * sampleRate) {
            step(u: .zero, vibration: 0.06)
        }
        let tUp = t
        for _ in 0..<Int(airtime * sampleRate) {
            step(u: SIMD3(0, 0, -1), vibration: 0, freeFall: true)
        }
        altitude -= height
        trueDescent += height
        let tLand = t
        for i in 0..<Int(0.04 * sampleRate).clampedMin(3) {
            let amp = landPeakG * (i == 0 ? 1.0 : (i == 1 ? 0.7 : 0.4))
            step(u: SIMD3(0, 0, amp), vibration: 0.02)
        }
        for _ in 0..<Int(0.5 * sampleRate) {
            step(u: .zero, vibration: 0.06)
        }
        truthEvents.append(
            FixtureTruth.TruthEvent(
                kind: .drop, tStart: tUp, tEnd: tLand + 0.15, airtime: airtime))
    }

    /// Hard braking; `slide: true` adds the 90° yaw swing + lateral signature (powerslide).
    public func brake(from: Double, to: Double, duration: Double, slide: Bool) {
        let g = 9.80665
        let start = t
        let a = (to - from) / duration  // negative
        let n = Int(duration * sampleRate)
        speed = from
        let slideYaw: Float = slide ? (.pi / 2) : 0
        for i in 0..<n {
            speed = max(to, speed + a * dt)
            var u = SIMD3<Float>(
                Float(a / g * sin(course)), Float(a / g * cos(course)), 0)
            if slide {
                let progress = Float(i) / Float(n)
                // Board swings out over the first 40% of the slide.
                spinOffset = slideYaw * min(1, progress / 0.4)
                // Lateral (perpendicular) shudder.
                let perp = SIMD3<Float>(Float(cos(course)), -Float(sin(course)), 0)
                u += perp * (0.45 + Float(rng.gaussian()) * 0.05)
            }
            step(u: u, vibration: slide ? 0.09 : 0.06, yawBlend: slide ? 0.5 : 0.08)
        }
        if slide {
            spinOffset = 0
        }
        truthEvents.append(
            FixtureTruth.TruthEvent(
                kind: slide ? .powerslide : .decel, tStart: start, tEnd: t))
    }

    /// Downhill stretch: constant speed, altitude falls by `descent` meters.
    public func hill(_ duration: Double, speed: Double, bearingDeg: Double, descent: Double) {
        ridingSwitch = false
        course = bearingDeg * .pi / 180
        self.speed = speed
        let start = t
        let n = Int(duration * sampleRate)
        for _ in 0..<n {
            altitude -= descent / Double(n)
            step(u: .zero, vibration: 0.07)
        }
        trueDescent += descent
        truthStance.append(
            StanceInterval(tStart: start, tEnd: t, stance: .regular, meanSigma: 0))
    }

    /// Walking interlude: 2 Hz vertical bob, low vibration.
    public func walk(_ duration: Double, bearingDeg: Double) {
        course = bearingDeg * .pi / 180
        speed = 1.4
        for i in 0..<Int(duration * sampleRate) {
            let phase = Double(i) * dt * 2 * .pi * 2.0
            let u = SIMD3<Float>(0, 0, Float(sin(phase)) * 0.14)
            step(u: u, vibration: 0.004)
        }
        speed = 0
    }

    /// Idle break (sitting/standing off the board).
    public func idle(_ duration: Double) {
        speed = 0
        for _ in 0..<Int(duration * sampleRate) {
            step(u: .zero, vibration: 0.002)
        }
    }

    /// Phone re-pocketed at a different roll angle mid-idle (FR-23 trigger).
    public func repocket(rollDeg: Float) {
        idle(1.0)
        // Fumble: a second of hand motion.
        for _ in 0..<Int(1.0 * sampleRate) {
            let u = SIMD3<Float>(
                Float(rng.gaussian()) * 0.3, Float(rng.gaussian()) * 0.3,
                Float(rng.gaussian()) * 0.3)
            pocketRoll += Float(rng.gaussian()) * 0.05
            step(u: u, vibration: 0)
        }
        pocketRoll = rollDeg * .pi / 180
        idle(6.0)
    }

    /// Slam: hard impact, tumble, then stillness.
    public func bail(stillness: Double) {
        let start = t
        speed = 0
        // Impact: 2 frames at high g.
        step(u: SIMD3(3, 2, 7), vibration: 0)
        step(u: SIMD3(2, 1, 4), vibration: 0)
        // Tumble ~0.8 s.
        for _ in 0..<Int(0.8 * sampleRate) {
            let u = SIMD3<Float>(
                Float(rng.gaussian()) * 0.8, Float(rng.gaussian()) * 0.8,
                Float(rng.gaussian()) * 0.8)
            step(u: u, vibration: 0, extraOmega: SIMD3(9, 7, 8))
        }
        idle(stillness)
        truthEvents.append(FixtureTruth.TruthEvent(kind: .bail, tStart: start, tEnd: t))
    }

    // MARK: - Output

    public func fixture(name: String, notes: String = "") -> FixtureIOPayload {
        FixtureIOPayload(
            meta: FixtureMeta(
                name: name, pocket: pocket, declaredStance: declaredStance,
                sampleRate: sampleRate, notes: notes),
            truth: FixtureTruth(
                events: truthEvents, stanceIntervals: truthStance, pushCount: truthPushCount,
                topSpeed: trueTopSpeed, totalDescent: trueDescent),
            motion: motion, rawAccel: rawAccel, locations: fixes, baro: baro)
    }

    private func wrapAngleD(_ a: Double) -> Double {
        var r = a.truncatingRemainder(dividingBy: 2 * .pi)
        if r <= -.pi { r += 2 * .pi }
        if r > .pi { r -= 2 * .pi }
        return r
    }
}

/// Mirror of FixtureIO.Fixture without importing TelemetryStore here (kept dependency-light);
/// FixtureWriter bridges.
public struct FixtureIOPayload: Sendable {
    public var meta: FixtureMeta
    public var truth: FixtureTruth
    public var motion: [MotionFrame]
    public var rawAccel: [RawAccelFrame]
    public var locations: [LocationFix]
    public var baro: [BaroFrame]
}

/// Deterministic RNG (SplitMix64) with a Box-Muller gaussian. Date/entropy-free by design.
public struct SplitMix64 {
    var state: UInt64
    private var spareGaussian: Double?

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func gaussian() -> Double {
        if let s = spareGaussian {
            spareGaussian = nil
            return s
        }
        var u1 = uniform()
        if u1 < 1e-12 { u1 = 1e-12 }
        let u2 = uniform()
        let mag = (-2 * Foundation.log(u1)).squareRoot()
        spareGaussian = mag * sin(2 * .pi * u2)
        return mag * cos(2 * .pi * u2)
    }
}

extension Int {
    func clampedMin(_ m: Int) -> Int { Swift.max(self, m) }
}
