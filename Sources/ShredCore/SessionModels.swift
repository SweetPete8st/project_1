import Foundation

/// Session lifecycle, docs/spec/04 §5.
public enum SessionState: String, Sendable, Codable {
    case idle
    case calibrating
    case active
    case autoPaused
    case ending
    case summarizing
    case saved
    case savedRecovered
    case recovering
    case discarded
}

public enum DegradationFlag: String, Sendable, Codable {
    case motionGap
    case locationDenied
    case preciseLocationOff
    case altimeterUnavailable
    case thermalRawDropped
    case calibrationDegraded
    case recoveredSession
    case frameDropBudgetExceeded
}

/// Live snapshot published to UI/Live Activity at ≤ 2 Hz (04 §4).
public struct LiveStats: Sendable, Codable, Equatable {
    public var sessionElapsed: Double = 0
    public var activeElapsed: Double = 0
    public var currentSpeed: Double = 0
    public var topSpeed: Double = 0
    public var distance: Double = 0
    public var airborneCount: Int = 0
    public var impactCount: Int = 0
    public var pushCount: Int = 0
    public var activity: ActivityState = .unknown
    public var lastEvent: DetectedEvent?

    public init() {}
}

/// Immutable end-of-session rollup, feeds the summary screen and DailyAggregates.
public struct SessionSummaryStats: Sendable, Codable, Equatable {
    public var activeDuration: Double = 0
    public var idleDuration: Double = 0
    public var distance: Double = 0
    public var topSpeed: Double = 0
    public var topSpeedValidated: Bool = false
    public var stanceRegular: Double = 0
    public var stanceSwitch: Double = 0
    public var stanceIndeterminate: Double = 0
    public var ascent: Double = 0
    public var descent: Double = 0
    public var pushCount: Int = 0
    public var pushCadenceMean: Double? = nil
    public var frameDropRatio: Double = 0
    public var degradations: [DegradationFlag] = []
    public var eventCounts: [EventKind: Int] = [:]

    public init() {}
}

/// Durable mid-session checkpoint for kill recovery, FR-4 / 04 §5.
public struct SessionCheckpoint: Sendable, Codable, Equatable {
    public var sessionID: UUID
    public var state: SessionState
    public var startedAtSensorTime: Double
    public var startedAtWall: Date
    public var lastSensorTime: Double
    public var calibration: CalibrationRecord?
    public var clockAnchors: ClockAnchors
    public var updatedAt: Date

    public init(
        sessionID: UUID, state: SessionState, startedAtSensorTime: Double, startedAtWall: Date,
        lastSensorTime: Double, calibration: CalibrationRecord?, clockAnchors: ClockAnchors,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.state = state
        self.startedAtSensorTime = startedAtSensorTime
        self.startedAtWall = startedAtWall
        self.lastSensorTime = lastSensorTime
        self.calibration = calibration
        self.clockAnchors = clockAnchors
        self.updatedAt = updatedAt
    }
}

// MARK: - Fixture corpus types (docs/spec/08 §2)

/// `meta.json` inside a `.shredfix` bundle directory (ADR-0003: directory, not zip).
public struct FixtureMeta: Sendable, Codable, Equatable {
    public var name: String
    public var device: String
    public var pocket: Pocket
    public var declaredStance: Stance
    public var sampleRate: Double
    public var notes: String
    public var synthetic: Bool

    public init(
        name: String, device: String = "FixtureSynth", pocket: Pocket, declaredStance: Stance,
        sampleRate: Double = 100, notes: String = "", synthetic: Bool = true
    ) {
        self.name = name
        self.device = device
        self.pocket = pocket
        self.declaredStance = declaredStance
        self.sampleRate = sampleRate
        self.notes = notes
        self.synthetic = synthetic
    }
}

/// `truth.json` — labeled ground truth a fixture asserts against.
public struct FixtureTruth: Sendable, Codable, Equatable {
    public struct TruthEvent: Sendable, Codable, Equatable {
        public var kind: EventKind
        public var tStart: Double
        public var tEnd: Double
        /// Exact modeled airtime for airborne events.
        public var airtime: Double?
        public var rotationDegrees: Float?
        public init(
            kind: EventKind, tStart: Double, tEnd: Double, airtime: Double? = nil,
            rotationDegrees: Float? = nil
        ) {
            self.kind = kind
            self.tStart = tStart
            self.tEnd = tEnd
            self.airtime = airtime
            self.rotationDegrees = rotationDegrees
        }
    }

    public var events: [TruthEvent]
    public var stanceIntervals: [StanceInterval]
    public var pushCount: Int?
    public var topSpeed: Double?
    public var totalDescent: Double?

    public init(
        events: [TruthEvent], stanceIntervals: [StanceInterval] = [], pushCount: Int? = nil,
        topSpeed: Double? = nil, totalDescent: Double? = nil
    ) {
        self.events = events
        self.stanceIntervals = stanceIntervals
        self.pushCount = pushCount
        self.topSpeed = topSpeed
        self.totalDescent = totalDescent
    }
}
