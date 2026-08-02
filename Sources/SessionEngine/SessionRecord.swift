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
public struct SessionRecord: Sendable, Codable, Identifiable, Equatable {
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
    /// Post-session rider report (opt-in improvement loop); nil when not provided.
    public var selfReport: SessionSelfReport?

    public var duration: Double { endedAtSensor - startedAtSensor }
}

/// Builds the shareable calibration bundle: the session's detection output + the rider's
/// self-report, versioned so replay tooling can regress against it. Raw telemetry chunks
/// travel separately via the full-data export (FR-55) when needed.
public enum CalibrationExport {
    public static func data(for record: SessionRecord) throws -> Data {
        struct Envelope: Codable {
            var format = "shred-calibration-report.v1"
            var exportedAt: Date
            var appVersion: String
            var tuningVersion: String
            var record: SessionRecord
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(
            Envelope(
                exportedAt: Date(), appVersion: record.appVersion,
                tuningVersion: record.tuningVersion, record: record))
    }

    public static func filename(for record: SessionRecord) -> String {
        "shred-calibration-" + record.startedAtWall.formatted(.iso8601.year().month().day())
            + "-" + record.id.uuidString.prefix(8) + ".json"
    }
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

    /// Attaches/replaces the rider's self-report on a saved session.
    @discardableResult
    public func attach(report: SessionSelfReport, to id: UUID) -> SessionRecord? {
        guard var record = load(id: id) else { return nil }
        record.selfReport = report
        try? save(record)
        return record
    }
}
