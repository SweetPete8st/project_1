import Foundation

/// Detected event kinds, docs/spec/05 §2. `push` is aggregated (count/cadence), individual
/// pushes are not timeline events; see docs/spec/03 §9.
public enum EventKind: String, Sendable, Codable, CaseIterable {
    case airborne
    case drop
    case impact
    case decel
    case powerslide
    case bail
    case rotationOnly
}

/// Airborne rotation bucket, FR-32.
public enum RotationBucket: String, Sendable, Codable {
    case none  // |Δψ| < 60°
    case half = "180"
    case full = "360"
    case partial
}

public enum SpinDirection: String, Sendable, Codable {
    case frontside
    case backside
}

/// Kind-specific metric payloads, docs/spec/05 §5. One enum with associated values keeps
/// this exhaustively switchable; encodes as {"kind": ..., ...fields}.
public enum EventMetrics: Sendable, Codable, Equatable {
    case airborne(Airborne)
    case drop(Drop)
    case impact(Impact)
    case decel(Decel)
    case powerslide(Powerslide)
    case bail(Bail)
    case rotationOnly(RotationOnly)

    public struct Airborne: Sendable, Codable, Equatable {
        public var airtime: Double
        public var airtimeUncertainty: Double
        /// Ballistic estimate h = g·T²/8, FR-31. Meters.
        public var estHeight: Double
        public var landingPeakG: Float
        public var landingClipped: Bool
        public var rotationDegrees: Float
        public var rotationBucket: RotationBucket
        public var direction: SpinDirection?
        public var hadPop: Bool

        public init(
            airtime: Double, airtimeUncertainty: Double, estHeight: Double, landingPeakG: Float,
            landingClipped: Bool, rotationDegrees: Float, rotationBucket: RotationBucket,
            direction: SpinDirection?, hadPop: Bool
        ) {
            self.airtime = airtime
            self.airtimeUncertainty = airtimeUncertainty
            self.estHeight = estHeight
            self.landingPeakG = landingPeakG
            self.landingClipped = landingClipped
            self.rotationDegrees = rotationDegrees
            self.rotationBucket = rotationBucket
            self.direction = direction
            self.hadPop = hadPop
        }
    }

    public struct Drop: Sendable, Codable, Equatable {
        public var airborne: Airborne
        /// Barometer-measured drop height when the cross-check confirmed (03 §11). Meters.
        public var baroDropHeight: Double?
        public init(airborne: Airborne, baroDropHeight: Double?) {
            self.airborne = airborne
            self.baroDropHeight = baroDropHeight
        }
    }

    public struct Impact: Sendable, Codable, Equatable {
        public var peakG: Float
        public var clipped: Bool
        public var jerkPeak: Float
        /// Overlapping event this impact belongs to (a landing's ollie), 03 §4.
        public var contextEventID: UUID?
        public init(peakG: Float, clipped: Bool, jerkPeak: Float, contextEventID: UUID?) {
            self.peakG = peakG
            self.clipped = clipped
            self.jerkPeak = jerkPeak
            self.contextEventID = contextEventID
        }
    }

    public struct Decel: Sendable, Codable, Equatable {
        /// Speed shed over the event, m/s (positive).
        public var deltaV: Double
        /// Peak deceleration, m/s² (positive magnitude).
        public var peakDecel: Double
        public var duration: Double
        public init(deltaV: Double, peakDecel: Double, duration: Double) {
            self.deltaV = deltaV
            self.peakDecel = peakDecel
            self.duration = duration
        }
    }

    public struct Powerslide: Sendable, Codable, Equatable {
        public var decel: Decel
        public var slideAngleDegrees: Float
        public var yawPeakRate: Float
        public init(decel: Decel, slideAngleDegrees: Float, yawPeakRate: Float) {
            self.decel = decel
            self.slideAngleDegrees = slideAngleDegrees
            self.yawPeakRate = yawPeakRate
        }
    }

    public struct Bail: Sendable, Codable, Equatable {
        /// Internal ranking only — never rendered as a g number (02 §4).
        public var severityScore: Double
        public var tumble: Bool
        public var stillnessAfter: Double
        public init(severityScore: Double, tumble: Bool, stillnessAfter: Double) {
            self.severityScore = severityScore
            self.tumble = tumble
            self.stillnessAfter = stillnessAfter
        }
    }

    public struct RotationOnly: Sendable, Codable, Equatable {
        public var rotationDegrees: Float
        public var window: Double
        public init(rotationDegrees: Float, window: Double) {
            self.rotationDegrees = rotationDegrees
            self.window = window
        }
    }
}

/// A detected, arbitrated timeline event (value type; persistence wraps this, 05 §2).
public struct DetectedEvent: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var kind: EventKind
    public var tStart: Double
    public var tEnd: Double
    public var confidence: Double
    public var metrics: EventMetrics
    public var detectorVersion: String

    public init(
        id: UUID = UUID(), kind: EventKind, tStart: Double, tEnd: Double, confidence: Double,
        metrics: EventMetrics, detectorVersion: String = DetectorVersion.current
    ) {
        self.id = id
        self.kind = kind
        self.tStart = tStart
        self.tEnd = tEnd
        self.confidence = confidence
        self.metrics = metrics
        self.detectorVersion = detectorVersion
    }
}

public enum DetectorVersion {
    public static let current = "1.0.0"
}

/// A classified stance span, FR-22.
public struct StanceInterval: Sendable, Codable, Equatable {
    public var tStart: Double
    public var tEnd: Double
    public var stance: StanceClass
    /// Mean chest-vs-travel angle over the span, radians.
    public var meanSigma: Float

    public init(tStart: Double, tEnd: Double, stance: StanceClass, meanSigma: Float) {
        self.tStart = tStart
        self.tEnd = tEnd
        self.stance = stance
        self.meanSigma = meanSigma
    }
}

/// An activity span from the segmenter, 03 §2.
public struct ActivityInterval: Sendable, Codable, Equatable {
    public var tStart: Double
    public var tEnd: Double
    public var state: ActivityState

    public init(tStart: Double, tEnd: Double, state: ActivityState) {
        self.tStart = tStart
        self.tEnd = tEnd
        self.state = state
    }
}
