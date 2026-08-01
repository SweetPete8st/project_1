import Foundation
import ShredCore

/// `.shredchunk` binary codec, docs/spec/05 §4. Little-endian, append-only friendly.
/// Layout:
///   Header (64 B):
///     0  "SHRD"                     16 frameCount u32
///     4  version u16                20 sensorTimeFirst f64
///     6  streamKind u8              28 wallAnchor f64 (unix s, 0 = none)
///     7  source u8                  36 reserved (24 B zeros)
///     8  sampleRateNominal f32      60 crc32(bytes 0..<60)
///    12  unit u8, 13 pad u8
///    14  frameSize u16
///   Frames: frameSize-byte records; first field u32 delta-µs from previous frame
///           (first frame: delta from sensorTimeFirst, i.e. 0).
///   Footer (16 B): frameCount u32 | crc32(payload) | reserved u32 | "DRHS"
public enum ChunkCodec {
    public static let version: UInt16 = 1
    public static let headerSize = 64
    public static let footerSize = 16
    static let magic: [UInt8] = Array("SHRD".utf8)
    static let footerMagic: [UInt8] = Array("DRHS".utf8)
    /// Deltas above this are considered corrupt during torn-tail recovery (10 s).
    static let maxPlausibleDeltaMicros: UInt32 = 10_000_000

    public enum Unit: UInt8 { case g = 0, meters = 1, mixed = 2 }

    public enum CodecError: Error, Equatable {
        case badMagic
        case unsupportedVersion(UInt16)
        case badHeaderCRC
        case badStreamKind(UInt8)
        case truncatedHeader
        case frameSizeMismatch(expected: Int, found: Int)
        case emptyChunk
        case nonMonotonicTimestamps
    }

    public enum Frames: Sendable, Equatable {
        case deviceMotion([MotionFrame])
        case rawAccelerometer([RawAccelFrame])
        case location([LocationFix])
        case barometer([BaroFrame])

        public var kind: StreamKind {
            switch self {
            case .deviceMotion: .deviceMotion
            case .rawAccelerometer: .rawAccelerometer
            case .location: .location
            case .barometer: .barometer
            }
        }

        public var count: Int {
            switch self {
            case .deviceMotion(let f): f.count
            case .rawAccelerometer(let f): f.count
            case .location(let f): f.count
            case .barometer(let f): f.count
            }
        }

        public var firstSensorTime: Double? {
            switch self {
            case .deviceMotion(let f): f.first?.sensorTime
            case .rawAccelerometer(let f): f.first?.sensorTime
            case .location(let f): f.first?.sensorTime
            case .barometer(let f): f.first?.sensorTime
            }
        }
    }

    public static func frameSize(for kind: StreamKind) -> Int {
        switch kind {
        case .deviceMotion: 56
        case .rawAccelerometer: 16
        case .location: 64
        case .barometer: 12
        }
    }

    static func unit(for kind: StreamKind) -> Unit {
        switch kind {
        case .deviceMotion, .rawAccelerometer: .g
        case .location, .barometer: .mixed
        }
    }

    // MARK: - Encode

    public static func encode(
        _ frames: Frames, source: StreamSource, sampleRateNominal: Double, wallAnchor: Date?
    ) throws -> Data {
        guard frames.count > 0, let t0 = frames.firstSensorTime else { throw CodecError.emptyChunk }
        let kind = frames.kind
        let fsize = frameSize(for: kind)

        var payload = Data(capacity: frames.count * fsize)
        var previous = t0
        func putDelta(_ t: Double, into d: inout Data) throws {
            let delta = t - previous
            guard delta >= 0 else { throw CodecError.nonMonotonicTimestamps }
            d.appendLE(UInt32((delta * 1_000_000).rounded()))
            previous = t
        }

        switch frames {
        case .deviceMotion(let list):
            for f in list {
                try putDelta(f.sensorTime, into: &payload)
                payload.appendVec3(f.userAccel)
                payload.appendVec3(f.gravity)
                payload.appendVec3(f.rotationRate)
                payload.appendLE(f.attitude.w)
                payload.appendLE(f.attitude.x)
                payload.appendLE(f.attitude.y)
                payload.appendLE(f.attitude.z)
            }
        case .rawAccelerometer(let list):
            for f in list {
                try putDelta(f.sensorTime, into: &payload)
                payload.appendVec3(f.accel)
            }
        case .location(let list):
            for f in list {
                try putDelta(f.sensorTime, into: &payload)
                payload.appendLE(f.latitude.bitPattern)
                payload.appendLE(f.longitude.bitPattern)
                payload.appendLE(f.altitude.bitPattern)
                payload.appendLE(Float(f.horizontalAccuracy))
                payload.appendLE(Float(f.verticalAccuracy))
                payload.appendLE(Float(f.speed))
                payload.appendLE(Float(f.speedAccuracy))
                payload.appendLE(Float(f.course))
                payload.appendLE(Float(f.courseAccuracy))
                payload.append(f.flagged ? 1 : 0)
                payload.append(contentsOf: [0, 0, 0])  // pad
                payload.appendLE(UInt64(0))  // reserved
            }
        case .barometer(let list):
            for f in list {
                try putDelta(f.sensorTime, into: &payload)
                payload.appendLE(f.relativeAltitude)
                payload.appendLE(f.pressure)
            }
        }

        var header = Data(capacity: headerSize)
        header.append(contentsOf: magic)
        header.appendLE(version)
        header.append(kind.rawValue)
        header.append(source.rawValue)
        header.appendLE(Float(sampleRateNominal))
        header.append(unit(for: kind).rawValue)
        header.append(0)
        header.appendLE(UInt16(fsize))
        header.appendLE(UInt32(frames.count))
        header.appendLE(t0.bitPattern)
        header.appendLE((wallAnchor?.timeIntervalSince1970 ?? 0).bitPattern)
        header.append(contentsOf: [UInt8](repeating: 0, count: 24))
        header.appendLE(CRC32.checksum(header))

        var footer = Data(capacity: footerSize)
        footer.appendLE(UInt32(frames.count))
        footer.appendLE(CRC32.checksum(payload))
        footer.appendLE(UInt32(0))
        footer.append(contentsOf: footerMagic)

        return header + payload + footer
    }

    // MARK: - Decode

    public struct Decoded: Sendable {
        public var frames: Frames
        public var source: StreamSource
        public var sampleRateNominal: Double
        public var wallAnchor: Date?
        /// True when the footer was missing/corrupt and the tail was recovered by scanning
        /// (torn write after a crash, docs/spec/05 §4).
        public var recoveredTail: Bool
    }

    public static func decode(_ data: Data) throws -> Decoded {
        guard data.count >= headerSize else { throw CodecError.truncatedHeader }
        let header = data.prefix(headerSize)
        guard Array(header.prefix(4)) == magic else { throw CodecError.badMagic }
        let ver: UInt16 = header.loadLE(at: 4)
        guard ver == version else { throw CodecError.unsupportedVersion(ver) }
        let storedHeaderCRC: UInt32 = header.loadLE(at: 60)
        guard CRC32.checksum(header.prefix(60)) == storedHeaderCRC else {
            throw CodecError.badHeaderCRC
        }
        guard let kind = StreamKind(rawValue: header[header.startIndex + 6]) else {
            throw CodecError.badStreamKind(header[header.startIndex + 6])
        }
        let source = StreamSource(rawValue: header[header.startIndex + 7]) ?? .fixture
        let rate: Float = header.loadLE(at: 8)
        let fsize = Int(header.loadLE(at: 14) as UInt16)
        guard fsize == frameSize(for: kind) else {
            throw CodecError.frameSizeMismatch(expected: frameSize(for: kind), found: fsize)
        }
        let declaredCount = Int(header.loadLE(at: 16) as UInt32)
        let t0 = Double(bitPattern: header.loadLE(at: 20))
        let wallRaw = Double(bitPattern: header.loadLE(at: 28))
        let wallAnchor = wallRaw == 0 ? nil : Date(timeIntervalSince1970: wallRaw)

        let body = data.dropFirst(headerSize)
        var frameData = body
        var recovered = false

        // Validate footer; on failure, scan-forward recover the tail.
        let footerOK: Bool = {
            guard body.count >= declaredCount * fsize + footerSize else { return false }
            let footer = body.suffix(footerSize)
            guard Array(footer.suffix(4)) == footerMagic else { return false }
            let payload = body.prefix(declaredCount * fsize)
            let payloadCRC: UInt32 = footer.loadLE(at: 4)
            return CRC32.checksum(payload) == payloadCRC
                && (footer.loadLE(at: 0) as UInt32) == UInt32(declaredCount)
        }()

        let usableCount: Int
        if footerOK {
            usableCount = declaredCount
            frameData = body.prefix(declaredCount * fsize)
        } else {
            recovered = true
            var valid = 0
            while (valid + 1) * fsize <= body.count {
                let off = valid * fsize
                let delta: UInt32 = body.loadLE(at: off)
                if delta > maxPlausibleDeltaMicros && valid > 0 { break }
                valid += 1
            }
            usableCount = min(valid, declaredCount == 0 ? valid : max(declaredCount, valid))
            frameData = body.prefix(usableCount * fsize)
        }
        guard usableCount > 0 else { throw CodecError.emptyChunk }

        var t = t0
        func readDelta(_ off: Int) -> Double {
            let d: UInt32 = frameData.loadLE(at: off)
            t += Double(d) / 1_000_000
            return t
        }

        let frames: Frames
        switch kind {
        case .deviceMotion:
            var list = [MotionFrame]()
            list.reserveCapacity(usableCount)
            for i in 0..<usableCount {
                let o = i * fsize
                let time = readDelta(o)
                list.append(
                    MotionFrame(
                        sensorTime: time,
                        userAccel: frameData.loadVec3(at: o + 4),
                        gravity: frameData.loadVec3(at: o + 16),
                        rotationRate: frameData.loadVec3(at: o + 28),
                        attitude: Quaternion(
                            w: frameData.loadLE(at: o + 40), x: frameData.loadLE(at: o + 44),
                            y: frameData.loadLE(at: o + 48), z: frameData.loadLE(at: o + 52))))
            }
            frames = .deviceMotion(list)
        case .rawAccelerometer:
            var list = [RawAccelFrame]()
            list.reserveCapacity(usableCount)
            for i in 0..<usableCount {
                let o = i * fsize
                let time = readDelta(o)
                list.append(RawAccelFrame(sensorTime: time, accel: frameData.loadVec3(at: o + 4)))
            }
            frames = .rawAccelerometer(list)
        case .location:
            var list = [LocationFix]()
            list.reserveCapacity(usableCount)
            for i in 0..<usableCount {
                let o = i * fsize
                let time = readDelta(o)
                list.append(
                    LocationFix(
                        sensorTime: time,
                        latitude: Double(bitPattern: frameData.loadLE(at: o + 4)),
                        longitude: Double(bitPattern: frameData.loadLE(at: o + 12)),
                        horizontalAccuracy: Double(frameData.loadLE(at: o + 28) as Float),
                        altitude: Double(bitPattern: frameData.loadLE(at: o + 20)),
                        verticalAccuracy: Double(frameData.loadLE(at: o + 32) as Float),
                        speed: Double(frameData.loadLE(at: o + 36) as Float),
                        speedAccuracy: Double(frameData.loadLE(at: o + 40) as Float),
                        course: Double(frameData.loadLE(at: o + 44) as Float),
                        courseAccuracy: Double(frameData.loadLE(at: o + 48) as Float),
                        flagged: frameData[frameData.startIndex + o + 52] == 1))
            }
            frames = .location(list)
        case .barometer:
            var list = [BaroFrame]()
            list.reserveCapacity(usableCount)
            for i in 0..<usableCount {
                let o = i * fsize
                let time = readDelta(o)
                list.append(
                    BaroFrame(
                        sensorTime: time,
                        relativeAltitude: frameData.loadLE(at: o + 4),
                        pressure: frameData.loadLE(at: o + 8)))
            }
            frames = .barometer(list)
        }

        return Decoded(
            frames: frames, source: source, sampleRateNominal: Double(rate),
            wallAnchor: wallAnchor, recoveredTail: recovered)
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: Float) { appendLE(v.bitPattern) }

    mutating func appendVec3(_ v: SIMD3<Float>) {
        appendLE(v.x)
        appendLE(v.y)
        appendLE(v.z)
    }

    func loadLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { dest in
            let start = startIndex + offset
            _ = copyBytes(to: dest, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    func loadLE(at offset: Int) -> Float {
        Float(bitPattern: loadLE(at: offset))
    }

    func loadVec3(at offset: Int) -> SIMD3<Float> {
        SIMD3<Float>(loadLE(at: offset), loadLE(at: offset + 4), loadLE(at: offset + 8))
    }
}

/// Portable CRC-32 (IEEE 802.3, zlib-compatible), docs/spec/05 §4 integrity.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
