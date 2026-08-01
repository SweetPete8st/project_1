import Foundation
import ShredCore

/// `.shredfix` bundle I/O, docs/spec/08 §2. A fixture is a directory (ADR-0003):
///   <name>.shredfix/
///     meta.json      FixtureMeta
///     truth.json     FixtureTruth
///     motion/  accel/  location/  baro/     — .shredchunk files
public enum FixtureIO {
    public struct Fixture: Sendable {
        public var meta: FixtureMeta
        public var truth: FixtureTruth
        public var motion: [MotionFrame]
        public var rawAccel: [RawAccelFrame]
        public var locations: [LocationFix]
        public var baro: [BaroFrame]

        public init(
            meta: FixtureMeta, truth: FixtureTruth, motion: [MotionFrame],
            rawAccel: [RawAccelFrame], locations: [LocationFix], baro: [BaroFrame]
        ) {
            self.meta = meta
            self.truth = truth
            self.motion = motion
            self.rawAccel = rawAccel
            self.locations = locations
            self.baro = baro
        }
    }

    public static func write(_ fixture: Fixture, to dir: URL) throws {
        let fm = FileManager()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(fixture.meta).write(to: dir.appendingPathComponent("meta.json"))
        try enc.encode(fixture.truth).write(to: dir.appendingPathComponent("truth.json"))

        func writeChunks(_ frames: ChunkCodec.Frames, subdir: String) throws {
            guard frames.count > 0 else { return }
            let d = dir.appendingPathComponent(subdir, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            // Fixtures use a single chunk per stream — 60 s chunking is a production
            // write-path concern; the codec is identical either way.
            let data = try ChunkCodec.encode(
                frames, source: .fixture, sampleRateNominal: fixture.meta.sampleRate,
                wallAnchor: nil)
            try data.write(to: d.appendingPathComponent("000000.shredchunk"))
        }
        try writeChunks(.deviceMotion(fixture.motion), subdir: "motion")
        try writeChunks(.rawAccelerometer(fixture.rawAccel), subdir: "accel")
        try writeChunks(.location(fixture.locations), subdir: "location")
        try writeChunks(.barometer(fixture.baro), subdir: "baro")
    }

    public static func read(from dir: URL) throws -> Fixture {
        let dec = JSONDecoder()
        let meta = try dec.decode(
            FixtureMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
        let truth = try dec.decode(
            FixtureTruth.self, from: Data(contentsOf: dir.appendingPathComponent("truth.json")))

        func readChunks(_ subdir: String) throws -> [ChunkCodec.Decoded] {
            let d = dir.appendingPathComponent(subdir, isDirectory: true)
            guard FileManager().fileExists(atPath: d.path) else { return [] }
            return try FileManager().contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "shredchunk" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { try ChunkCodec.decode(Data(contentsOf: $0)) }
        }

        var motion = [MotionFrame]()
        var accel = [RawAccelFrame]()
        var locations = [LocationFix]()
        var baro = [BaroFrame]()
        for c in try readChunks("motion") {
            if case .deviceMotion(let f) = c.frames { motion += f }
        }
        for c in try readChunks("accel") {
            if case .rawAccelerometer(let f) = c.frames { accel += f }
        }
        for c in try readChunks("location") {
            if case .location(let f) = c.frames { locations += f }
        }
        for c in try readChunks("baro") {
            if case .barometer(let f) = c.frames { baro += f }
        }
        return Fixture(
            meta: meta, truth: truth, motion: motion, rawAccel: accel, locations: locations,
            baro: baro)
    }

    /// Enumerates `*.shredfix` bundle directories under a corpus root.
    public static func list(corpus: URL) throws -> [URL] {
        try FileManager()
            .contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.pathExtension == "shredfix" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
