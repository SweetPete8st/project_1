import Foundation
import DetectionKit
import RouteKit
import ShredCore

/// How a session came to exist (auto-start integration, ADR-0004).
public enum StartSource: String, Sendable, Codable {
    case manual
    case automatic
}

/// Metadata carried by an automatic start — placement-independent by contract.
public struct AutoStartMetadata: Sendable, Codable, Equatable {
    public var confidence: Double
    public var detectedPushCount: Int
    public var estimatedPushesPerMinute: Double

    public init(confidence: Double, detectedPushCount: Int, estimatedPushesPerMinute: Double) {
        self.confidence = confidence
        self.detectedPushCount = detectedPushCount
        self.estimatedPushesPerMinute = estimatedPushesPerMinute
    }
}

/// The persisted outcome of a session (ADR-0005: JSON archive; SwiftData mirror is a later
/// milestone). Everything the summary screen renders comes from here.
public struct SessionRecord: Sendable, Codable, Identifiable {
    public var id: UUID
    public var state: SessionState
    public var startSource: StartSource
    public var autoStart: AutoStartMetadata?
    public var startedAtWall: Date
    public var endedAtWall: Date
    public var startedAtSensor: Double
    public var endedAtSensor: Double
    public var pocket: Pocket?
    public var declaredStance: Stance?
    public var calibrationQuality: CalibrationRecord.Quality?
    public var summary: SessionSummaryStats
    public var events: [DetectedEvent]
    public var stanceIntervals: [StanceInterval]
    public var activityIntervals: [ActivityInterval]
    public var route: [RouteKit.RoutePoint]
    public var speedSeries: [DetectionResult.SpeedSample]
    public var gForceEnvelope: [DetectionResult.GForceSample]
    public var clockAnchors: ClockAnchors
    public var appVersion: String
    public var tuningVersion: String

    public var duration: Double { endedAtSensor - startedAtSensor }
}

/// JSON-file session persistence: `Sessions/<uuid>.json` + newest-first index.
public struct SessionArchive: Sendable {
    public let root: URL
    private var dir: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    public init(root: URL) {
        self.root = root
    }

    public func save(_ record: SessionRecord) throws {
        try FileManager().createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(record)
        try data.write(to: dir.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
    }

    public func load(id: UUID) -> SessionRecord? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json"))
        else { return nil }
        return try? dec.decode(SessionRecord.self, from: data)
    }

    public func list() -> [SessionRecord] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard
            let files = try? FileManager().contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAtWall > $1.startedAtWall }
    }

    public func delete(id: UUID) {
        try? FileManager().removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
    }
}
