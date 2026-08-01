import Foundation

/// Pocket the phone rides in, docs/spec/01 FR-20.
public enum Pocket: String, Sendable, Codable, CaseIterable {
    case frontLeft = "FL"
    case frontRight = "FR"
    case backLeft = "BL"
    case backRight = "BR"

    /// +1 when the pocket is on the rider's right side, −1 left. Feeds the stance-angle
    /// sign convention in docs/spec/03 §6.
    public var sideSign: Float {
        switch self {
        case .frontRight, .backRight: 1
        case .frontLeft, .backLeft: -1
        }
    }
}

/// Declared footedness.
public enum Stance: String, Sendable, Codable, CaseIterable {
    case regular
    case goofy

    /// Expected sign of the chest-vs-travel angle σ when riding one's declared stance.
    /// Regular riders (left foot forward) lead with the left shoulder: chest points to the
    /// rider's right of travel → positive σ under the 05 §1 convention. Goofy mirrors.
    public var sigmaSign: Float {
        switch self {
        case .regular: 1
        case .goofy: -1
        }
    }
}

/// Runtime stance classification of a riding interval, FR-22.
public enum StanceClass: String, Sendable, Codable {
    case regular
    case switchStance = "switch"
    case indeterminate
}

/// Coarse activity state, docs/spec/03 §2.
public enum ActivityState: String, Sendable, Codable {
    case unknown
    case riding
    case walking
    case idle
}

/// Result of the pocket-calibration flow, FR-20/21.
public struct CalibrationRecord: Sendable, Codable, Equatable {
    public var pocket: Pocket
    public var declaredStance: Stance
    /// Mean attitude during the standing-still window (device→world).
    public var baselineAttitude: Quaternion
    /// Mean gravity direction in the device frame during the still window.
    public var baselineGravity: SIMD3<Float>
    /// Sample variance of accel magnitude during the window; quality gate input.
    public var stillVariance: Float
    /// Calibration succeeded within FR-21's variance gate.
    public var quality: Quality
    /// Sensor times at which re-pocketing re-baselines occurred (FR-23).
    public var rebaselineTimes: [Double]

    public enum Quality: String, Sendable, Codable {
        case good
        case degraded  // stance analytics disabled for the session
    }

    public init(
        pocket: Pocket, declaredStance: Stance, baselineAttitude: Quaternion,
        baselineGravity: SIMD3<Float>, stillVariance: Float, quality: Quality,
        rebaselineTimes: [Double] = []
    ) {
        self.pocket = pocket
        self.declaredStance = declaredStance
        self.baselineAttitude = baselineAttitude
        self.baselineGravity = baselineGravity
        self.stillVariance = stillVariance
        self.quality = quality
        self.rebaselineTimes = rebaselineTimes
    }
}

/// Measured/queried device capability snapshot stored per session, docs/spec/02 §4.
public struct DeviceCapabilities: Sendable, Codable, Equatable {
    /// Public-API accelerometer clip in g, measured on hardware (M2 exit criterion).
    /// 16 g is the design assumption until measured.
    public var accelClipG: Float
    public var hasBarometer: Bool
    public var hasDualFrequencyGNSS: Bool
    public var deviceModel: String
    public var osVersion: String

    public init(
        accelClipG: Float = 16, hasBarometer: Bool = true, hasDualFrequencyGNSS: Bool = true,
        deviceModel: String = "fixture", osVersion: String = "0"
    ) {
        self.accelClipG = accelClipG
        self.hasBarometer = hasBarometer
        self.hasDualFrequencyGNSS = hasDualFrequencyGNSS
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }
}
