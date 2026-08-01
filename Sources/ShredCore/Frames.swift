import Foundation

/// Frame types per docs/spec/05 §3. Timestamps are sensor-clock seconds (since boot on
/// device, since t=0 in fixtures); wall-clock conversion goes through `ClockAnchors`.
/// Acceleration streams are in g (Core Motion native unit, 05 §1); rotation rate rad/s.

public enum StreamKind: UInt8, Sendable, Codable, CaseIterable {
    case deviceMotion = 1
    case rawAccelerometer = 2
    case location = 3
    case barometer = 4
}

public enum StreamSource: UInt8, Sendable, Codable {
    case iphone = 1
    case watch = 2  // reserved, docs/spec/02 §3
    case fixture = 3
}

public struct MotionFrame: Sendable, Codable, Equatable {
    public var sensorTime: Double
    /// Gravity-removed user acceleration, device frame, g.
    public var userAccel: SIMD3<Float>
    /// Unit-ish gravity direction, device frame, g.
    public var gravity: SIMD3<Float>
    /// Bias-corrected rotation rate, device frame, rad/s.
    public var rotationRate: SIMD3<Float>
    /// Device→world attitude (xMagneticNorthZVertical).
    public var attitude: Quaternion

    public init(
        sensorTime: Double, userAccel: SIMD3<Float>, gravity: SIMD3<Float>,
        rotationRate: SIMD3<Float>, attitude: Quaternion
    ) {
        self.sensorTime = sensorTime
        self.userAccel = userAccel
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.attitude = attitude
    }
}

public struct RawAccelFrame: Sendable, Codable, Equatable {
    public var sensorTime: Double
    /// Raw (gravity-included) acceleration, device frame, g.
    public var accel: SIMD3<Float>

    public init(sensorTime: Double, accel: SIMD3<Float>) {
        self.sensorTime = sensorTime
        self.accel = accel
    }
}

public struct LocationFix: Sendable, Codable, Equatable {
    public var sensorTime: Double
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy radius, m. Negative = invalid.
    public var horizontalAccuracy: Double
    public var altitude: Double
    public var verticalAccuracy: Double
    /// Ground speed m/s. Negative = invalid.
    public var speed: Double
    public var speedAccuracy: Double
    /// Course over ground, radians from true north, positive clockwise. Negative = invalid.
    public var course: Double
    public var courseAccuracy: Double
    /// Set by CaptureKit per docs/spec/02 §5 quality gate; detection ignores flagged fixes.
    public var flagged: Bool

    public init(
        sensorTime: Double, latitude: Double, longitude: Double, horizontalAccuracy: Double,
        altitude: Double, verticalAccuracy: Double, speed: Double, speedAccuracy: Double,
        course: Double, courseAccuracy: Double, flagged: Bool = false
    ) {
        self.sensorTime = sensorTime
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.flagged = flagged
    }
}

public struct BaroFrame: Sendable, Codable, Equatable {
    public var sensorTime: Double
    /// Relative altitude since altimeter start, m.
    public var relativeAltitude: Float
    /// kPa.
    public var pressure: Float

    public init(sensorTime: Double, relativeAltitude: Float, pressure: Float) {
        self.sensorTime = sensorTime
        self.relativeAltitude = relativeAltitude
        self.pressure = pressure
    }
}

/// Piecewise sensor-clock → wall-clock anchoring, docs/spec/02 §6.
public struct ClockAnchors: Sendable, Codable, Equatable {
    public struct Anchor: Sendable, Codable, Equatable {
        public var sensorTime: Double
        public var wallClock: Date
        public init(sensorTime: Double, wallClock: Date) {
            self.sensorTime = sensorTime
            self.wallClock = wallClock
        }
    }

    public private(set) var anchors: [Anchor]

    public init(anchors: [Anchor] = []) {
        self.anchors = anchors.sorted { $0.sensorTime < $1.sensorTime }
    }

    public mutating func record(sensorTime: Double, wallClock: Date) {
        anchors.append(Anchor(sensorTime: sensorTime, wallClock: wallClock))
        anchors.sort { $0.sensorTime < $1.sensorTime }
    }

    /// Converts using the nearest anchor at or before `sensorTime` (else the first).
    public func wallClock(for sensorTime: Double) -> Date? {
        guard !anchors.isEmpty else { return nil }
        let anchor = anchors.last(where: { $0.sensorTime <= sensorTime }) ?? anchors[0]
        return anchor.wallClock.addingTimeInterval(sensorTime - anchor.sensorTime)
    }
}
