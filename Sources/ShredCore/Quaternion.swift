import Foundation

/// Portable unit quaternion (w + xi + yj + zk). Replaces Apple-only `simd_quatf` so
/// DetectionKit stays Linux-buildable (ADR-0002). World frame is right-handed, z-up;
/// yaw is rotation about world z, positive counterclockwise, per docs/spec/05 §1.
public struct Quaternion: Sendable, Codable, Equatable {
    public var w: Float
    public var x: Float
    public var y: Float
    public var z: Float

    public init(w: Float, x: Float, y: Float, z: Float) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    public init(axis: SIMD3<Float>, angle: Float) {
        let n = axis / max(Quaternion.length(axis), .leastNormalMagnitude)
        let h = angle / 2
        let s = sin(h)
        self.init(w: cos(h), x: n.x * s, y: n.y * s, z: n.z * s)
    }

    /// Intrinsic yaw-pitch-roll (z-y-x) construction.
    public init(yaw: Float, pitch: Float = 0, roll: Float = 0) {
        let cy = cos(yaw / 2), sy = sin(yaw / 2)
        let cp = cos(pitch / 2), sp = sin(pitch / 2)
        let cr = cos(roll / 2), sr = sin(roll / 2)
        self.init(
            w: cr * cp * cy + sr * sp * sy,
            x: sr * cp * cy - cr * sp * sy,
            y: cr * sp * cy + sr * cp * sy,
            z: cr * cp * sy - sr * sp * cy)
    }

    public var norm: Float { (w * w + x * x + y * y + z * z).squareRoot() }

    public var normalized: Quaternion {
        let n = norm
        guard n > .leastNormalMagnitude else { return .identity }
        return Quaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public var conjugate: Quaternion { Quaternion(w: w, x: -x, y: -y, z: -z) }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    /// Rotates a vector by this quaternion (device→world when this is the attitude).
    public func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let qv = SIMD3<Float>(x, y, z)
        let t = 2 * Quaternion.cross(qv, v)
        return v + w * t + Quaternion.cross(qv, t)
    }

    /// Yaw about world z extracted from the full rotation (radians, wrapped (−π, π]).
    public var yaw: Float {
        atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
    }

    /// Total rotation angle between two orientations, radians in [0, π].
    public func angle(to other: Quaternion) -> Float {
        let d = (conjugate * other).normalized
        return 2 * atan2(SIMD3<Float>(d.x, d.y, d.z).shredLength, abs(d.w))
    }

    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x)
    }

    static func length(_ v: SIMD3<Float>) -> Float { v.shredLength }
}

extension SIMD3<Float> {
    /// Euclidean norm. Named to avoid colliding with simd on Apple platforms.
    public var shredLength: Float { (x * x + y * y + z * z).squareRoot() }
}

/// Wraps an angle to (−π, π].
public func wrapAngle(_ a: Float) -> Float {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r <= -.pi { r += 2 * .pi }
    if r > .pi { r -= 2 * .pi }
    return r
}
