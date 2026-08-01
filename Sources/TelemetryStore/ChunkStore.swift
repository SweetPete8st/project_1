import Foundation
import ShredCore

/// On-disk telemetry layout, docs/spec/05 §4:
///   <root>/Telemetry/<sessionID>/<stream>/<index>.shredchunk
/// Writes are temp-file + atomic rename; a crash can only tear the newest chunk, which the
/// codec recovers scan-forward.
public struct ChunkRef: Sendable, Codable, Equatable {
    public var stream: StreamKind
    public var index: Int
    public var crc32: UInt32
    public var frameCount: Int
    public var sensorTimeFirst: Double

    public init(
        stream: StreamKind, index: Int, crc32: UInt32, frameCount: Int, sensorTimeFirst: Double
    ) {
        self.stream = stream
        self.index = index
        self.crc32 = crc32
        self.frameCount = frameCount
        self.sensorTimeFirst = sensorTimeFirst
    }
}

public actor ChunkStore {
    public let root: URL
    private let fm = FileManager()

    public init(root: URL) {
        self.root = root
    }

    public static func streamDirName(_ kind: StreamKind) -> String {
        switch kind {
        case .deviceMotion: "motion"
        case .rawAccelerometer: "accel"
        case .location: "location"
        case .barometer: "baro"
        }
    }

    private func streamDir(session: UUID, kind: StreamKind) -> URL {
        root
            .appendingPathComponent("Telemetry", isDirectory: true)
            .appendingPathComponent(session.uuidString, isDirectory: true)
            .appendingPathComponent(Self.streamDirName(kind), isDirectory: true)
    }

    @discardableResult
    public func write(
        session: UUID, index: Int, frames: ChunkCodec.Frames, source: StreamSource,
        sampleRateNominal: Double, wallAnchor: Date?
    ) throws -> ChunkRef {
        let dir = streamDir(session: session, kind: frames.kind)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try ChunkCodec.encode(
            frames, source: source, sampleRateNominal: sampleRateNominal, wallAnchor: wallAnchor)
        let final = dir.appendingPathComponent(String(format: "%06d.shredchunk", index))
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        _ = try? fm.removeItem(at: final)
        try fm.moveItem(at: tmp, to: final)
        return ChunkRef(
            stream: frames.kind, index: index, crc32: CRC32.checksum(data),
            frameCount: frames.count, sensorTimeFirst: frames.firstSensorTime ?? 0)
    }

    public struct ReadResult: Sendable {
        public var chunks: [ChunkCodec.Decoded]
        /// Any chunk needed torn-tail recovery — surface a "partial data" badge (05 §4).
        public var anyRecovered: Bool
    }

    /// Reads all chunks of a stream in index order, recovering torn tails.
    public func readAll(session: UUID, kind: StreamKind) throws -> ReadResult {
        let dir = streamDir(session: session, kind: kind)
        guard fm.fileExists(atPath: dir.path) else { return ReadResult(chunks: [], anyRecovered: false) }
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "shredchunk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out = [ChunkCodec.Decoded]()
        var recovered = false
        for f in files {
            let data = try Data(contentsOf: f)
            let decoded = try ChunkCodec.decode(data)
            recovered = recovered || decoded.recoveredTail
            out.append(decoded)
        }
        return ReadResult(chunks: out, anyRecovered: recovered)
    }

    /// Deletes continuous streams, keeping nothing — used by 30-day compaction (NFR-3);
    /// event snippets live outside these stream dirs.
    public func deleteStreams(session: UUID) throws {
        let dir = root
            .appendingPathComponent("Telemetry", isDirectory: true)
            .appendingPathComponent(session.uuidString, isDirectory: true)
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }
}

/// Durable session checkpoint (FR-4), JSON + atomic write.
public struct CheckpointStore: Sendable {
    public let url: URL

    public init(root: URL) {
        self.url = root.appendingPathComponent("session-checkpoint.json")
    }

    public func save(_ checkpoint: SessionCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: url, options: .atomic)
    }

    public func load() -> SessionCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionCheckpoint.self, from: data)
    }

    public func clear() {
        try? FileManager().removeItem(at: url)
    }
}
