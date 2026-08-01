import Foundation
import ShredCore
import TelemetryStore

/// Converts a `shred-web-recording.v1` JSON (docs/recorder) into a `.shredfix` bundle so
/// real phone sessions replay through the native pipeline.
///
/// Web → SHRED mapping (verified against the 2026-08-01 iPhone session):
///  - W3C accelerationIncludingGravity is +9.81 on the up axis at rest — the same sign as
///    SHRED's raw convention (raw = user − gravity), so raw = ag/g directly.
///  - user = a/g (kinematic, matches SHRED).
///  - gravity = user − raw (≈ (a − ag)/g), toward earth. ✓
///  - rotationRate: W3C alpha=z, beta=x, gamma=y in deg/s → device (x,y,z) rad/s.
///  - Attitude: tilt-only quaternion from the gravity direction (web pages get no compass
///    quaternion) → magnitude/vertical detectors work; stance/rotation are marked off.
public enum WebRecordingImport {
    public static func run(inputPath: String, outputPath: String) throws {
        let g = 9.80665
        let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["format"] as? String == "shred-web-recording.v1",
            let motionRows = root["motion"] as? [[Any]]
        else {
            throw NSError(
                domain: "WebImport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "not a shred-web-recording.v1 file"])
        }
        let gpsRows = root["gps"] as? [[Any]] ?? []

        func num(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            return nil
        }

        var motion = [MotionFrame]()
        var raw = [RawAccelFrame]()
        motion.reserveCapacity(motionRows.count)
        let tBase = 100.0  // keep sensor clocks positive/typical
        for row in motionRows {
            guard row.count >= 10, let t = num(row[0]) else { continue }
            let ag = SIMD3<Float>(
                Float((num(row[1]) ?? 0) / g), Float((num(row[2]) ?? 0) / g),
                Float((num(row[3]) ?? 0) / g))
            let user = SIMD3<Float>(
                Float((num(row[4]) ?? 0) / g), Float((num(row[5]) ?? 0) / g),
                Float((num(row[6]) ?? 0) / g))
            let gravity = user - ag
            let rot = SIMD3<Float>(
                Float((num(row[8]) ?? 0) * .pi / 180),   // beta  → x
                Float((num(row[9]) ?? 0) * .pi / 180),   // gamma → y
                Float((num(row[7]) ?? 0) * .pi / 180))   // alpha → z
            let attitude = tiltAttitude(gravityDevice: gravity)
            motion.append(
                MotionFrame(
                    sensorTime: tBase + t, userAccel: user, gravity: gravity,
                    rotationRate: rot, attitude: attitude))
            raw.append(RawAccelFrame(sensorTime: tBase + t, accel: ag))
        }
        guard motion.count > 60 else {
            throw NSError(
                domain: "WebImport", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "too few motion samples"])
        }
        let duration = motion.last!.sensorTime - motion.first!.sensorTime
        let rate = Double(motion.count) / max(duration, 0.01)

        var fixes = [LocationFix]()
        for row in gpsRows {
            guard row.count >= 8, let t = num(row[0]), let lat = num(row[1]),
                let lon = num(row[2])
            else { continue }
            let speed = num(row[6]) ?? -1
            let heading = num(row[7]) ?? -1
            fixes.append(
                LocationFix(
                    sensorTime: tBase + t, latitude: lat, longitude: lon,
                    horizontalAccuracy: num(row[3]) ?? 10,
                    altitude: num(row[4]) ?? 0, verticalAccuracy: num(row[5]) ?? -1,
                    speed: speed, speedAccuracy: speed >= 0 ? 0.5 : -1,
                    course: heading >= 0 ? heading * .pi / 180 : -1,
                    courseAccuracy: heading >= 0 ? 0.15 : -1))
        }

        let name = URL(fileURLWithPath: outputPath).deletingPathExtension().lastPathComponent
        let fixture = FixtureIO.Fixture(
            meta: FixtureMeta(
                name: name, device: "web-recorder", pocket: .frontRight,
                declaredStance: .regular, sampleRate: rate,
                notes: "imported shred-web-recording.v1; tilt-only attitude (no compass): "
                    + "stance/rotation metrics not meaningful", synthetic: false),
            truth: FixtureTruth(events: []),  // unlabeled — label after video review
            motion: motion, rawAccel: raw, locations: fixes, baro: [])
        try FixtureIO.write(fixture, to: URL(fileURLWithPath: outputPath))
        print(
            "imported \(motion.count) motion samples (\(String(format: "%.1f", rate)) Hz, "
                + "\(String(format: "%.1f", duration))s), \(fixes.count) fixes → \(outputPath)")
    }

    /// Quaternion (device→world, yaw 0) aligning measured device gravity to world (0,0,−1).
    static func tiltAttitude(gravityDevice: SIMD3<Float>) -> Quaternion {
        let len = gravityDevice.shredLength
        guard len > 0.01 else { return .identity }
        let gd = gravityDevice / len
        let target = SIMD3<Float>(0, 0, -1)
        let dot = max(-1, min(1, gd.x * target.x + gd.y * target.y + gd.z * target.z))
        let angle = Foundation.acos(dot)
        if angle < 0.0001 { return .identity }
        var axis = SIMD3<Float>(
            gd.y * target.z - gd.z * target.y,
            gd.z * target.x - gd.x * target.z,
            gd.x * target.y - gd.y * target.x)
        let axisLen = axis.shredLength
        if axisLen < 0.0001 {
            axis = SIMD3<Float>(1, 0, 0)  // antiparallel: flip about x
        } else {
            axis /= axisLen
        }
        return Quaternion(axis: axis, angle: angle).normalized
    }
}
