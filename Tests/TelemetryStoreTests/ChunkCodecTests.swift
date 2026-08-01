import Foundation
import Testing

@testable import ShredCore
@testable import TelemetryStore

private func randomMotionFrames(count: Int, seed: UInt64 = 42) -> [MotionFrame] {
    var rng = SplitMix64(seed: seed)
    var t = 1000.0
    return (0..<count).map { _ in
        t += 0.01 + Double(rng.next() % 100) * 1e-6  // jittered ~100 Hz
        return MotionFrame(
            sensorTime: t,
            userAccel: SIMD3(rng.f(), rng.f(), rng.f()),
            gravity: SIMD3(0, 0, -1),
            rotationRate: SIMD3(rng.f(), rng.f(), rng.f()),
            attitude: Quaternion(yaw: rng.f()).normalized)
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func f() -> Float { Float(next() % 2000) / 1000 - 1 }
}

@Suite struct ChunkCodecTests {
    @Test func motionRoundTripPreservesFramesWithinMicrosecond() throws {
        let frames = randomMotionFrames(count: 500)
        let data = try ChunkCodec.encode(
            .deviceMotion(frames), source: .fixture, sampleRateNominal: 100, wallAnchor: Date())
        let decoded = try ChunkCodec.decode(data)
        #expect(!decoded.recoveredTail)
        guard case .deviceMotion(let out) = decoded.frames else {
            Issue.record("wrong stream kind")
            return
        }
        #expect(out.count == frames.count)
        for (a, b) in zip(frames, out) {
            #expect(abs(a.sensorTime - b.sensorTime) < 2e-6)  // FR-15 alignment budget
            #expect(a.userAccel == b.userAccel)
            #expect(a.attitude == b.attitude)
        }
    }

    @Test func locationRoundTrip() throws {
        let fixes = (0..<30).map { i in
            LocationFix(
                sensorTime: 1000 + Double(i), latitude: 40.4168 + Double(i) * 1e-5,
                longitude: -3.7038, horizontalAccuracy: 3.5, altitude: 650.2,
                verticalAccuracy: 4, speed: 3.2, speedAccuracy: 0.4, course: 1.2,
                courseAccuracy: 0.1, flagged: i % 7 == 0)
        }
        let data = try ChunkCodec.encode(
            .location(fixes), source: .iphone, sampleRateNominal: 1, wallAnchor: nil)
        guard case .location(let out) = try ChunkCodec.decode(data).frames else {
            Issue.record("wrong stream kind")
            return
        }
        #expect(out.count == fixes.count)
        #expect(abs(out[3].latitude - fixes[3].latitude) < 1e-12)  // f64 exact
        #expect(out[0].flagged && !out[1].flagged)
        #expect(abs(out[5].speed - 3.2) < 1e-6)
    }

    @Test func tornChunkRecoversScanForward() throws {
        let frames = randomMotionFrames(count: 200)
        var data = try ChunkCodec.encode(
            .deviceMotion(frames), source: .fixture, sampleRateNominal: 100, wallAnchor: nil)
        // Simulate a crash mid-write: drop the footer and the last 3.5 frames.
        let cut = ChunkCodec.footerSize + Int(3.5 * 56)
        data = data.prefix(data.count - cut)
        let decoded = try ChunkCodec.decode(Data(data))
        #expect(decoded.recoveredTail)
        guard case .deviceMotion(let out) = decoded.frames else {
            Issue.record("wrong stream kind")
            return
        }
        #expect(out.count == 196)  // 200 - 4 (3 whole + 1 partial frame lost)
        #expect(abs(out[0].sensorTime - frames[0].sensorTime) < 2e-6)
    }

    @Test func corruptHeaderRejected() throws {
        let frames = randomMotionFrames(count: 10)
        var data = try ChunkCodec.encode(
            .deviceMotion(frames), source: .fixture, sampleRateNominal: 100, wallAnchor: nil)
        data[8] ^= 0xFF  // flip a byte inside the CRC-protected header region
        #expect(throws: ChunkCodec.CodecError.badHeaderCRC) { _ = try ChunkCodec.decode(data) }
    }

    @Test func emptyChunkRejected() {
        #expect(throws: ChunkCodec.CodecError.emptyChunk) {
            _ = try ChunkCodec.encode(
                .deviceMotion([]), source: .fixture, sampleRateNominal: 100, wallAnchor: nil)
        }
    }

    @Test func crc32MatchesKnownVector() {
        // "123456789" → 0xCBF43926 (IEEE 802.3 check value)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite struct ChunkStoreTests {
    @Test func writeReadAcrossChunks() async throws {
        let tmp = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager().removeItem(at: tmp) }
        let store = ChunkStore(root: tmp)
        let session = UUID()
        let all = randomMotionFrames(count: 300)
        try await store.write(
            session: session, index: 0, frames: .deviceMotion(Array(all[0..<150])),
            source: .iphone, sampleRateNominal: 100, wallAnchor: Date())
        try await store.write(
            session: session, index: 1, frames: .deviceMotion(Array(all[150...])),
            source: .iphone, sampleRateNominal: 100, wallAnchor: Date())
        let result = try await store.readAll(session: session, kind: .deviceMotion)
        #expect(result.chunks.count == 2)
        #expect(!result.anyRecovered)
        let total = result.chunks.reduce(0) { $0 + $1.frames.count }
        #expect(total == 300)
    }
}

@Suite struct CheckpointTests {
    @Test func checkpointRoundTrip() throws {
        let tmp = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager().removeItem(at: tmp) }
        let store = CheckpointStore(root: tmp)
        var anchors = ClockAnchors()
        anchors.record(sensorTime: 5, wallClock: Date(timeIntervalSince1970: 1_700_000_000))
        let cp = SessionCheckpoint(
            sessionID: UUID(), state: .active, startedAtSensorTime: 5,
            startedAtWall: Date(timeIntervalSince1970: 1_700_000_000), lastSensorTime: 99,
            calibration: nil, clockAnchors: anchors, updatedAt: Date())
        try store.save(cp)
        let loaded = store.load()
        #expect(loaded?.sessionID == cp.sessionID)
        #expect(loaded?.state == .active)
        store.clear()
        #expect(store.load() == nil)
    }
}
