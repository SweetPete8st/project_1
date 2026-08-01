import Foundation
import ShredCore

/// Sensor stream abstraction, docs/spec/04 §3. SessionEngine consumes a `CaptureFeed`;
/// implementations: `CoreMotionCapture` (iOS, in CoreMotionCapture.swift) and
/// `ScriptedCapture` (tests/replay, below). This seam is what keeps the engine testable
/// with no hardware (NFR-8).
public struct CaptureFeed: Sendable {
    public var motion: AsyncStream<MotionFrame>
    public var rawAccel: AsyncStream<RawAccelFrame>
    public var location: AsyncStream<LocationFix>
    public var baro: AsyncStream<BaroFrame>
    /// Nominal device-motion rate, Hz.
    public var sampleRate: Double

    public init(
        motion: AsyncStream<MotionFrame>, rawAccel: AsyncStream<RawAccelFrame>,
        location: AsyncStream<LocationFix>, baro: AsyncStream<BaroFrame>, sampleRate: Double
    ) {
        self.motion = motion
        self.rawAccel = rawAccel
        self.location = location
        self.baro = baro
        self.sampleRate = sampleRate
    }
}

public protocol CaptureSource: Sendable {
    /// Starts sensors and returns the live feed. Idempotent per session.
    func start() async throws -> CaptureFeed
    func stop() async
}

public enum CaptureError: Error, Equatable {
    case motionUnavailable
    case motionDenied
    case locationDenied
    case deliveryStalled
}

/// Scripted capture for tests and replay: yields pre-built frame arrays, optionally paced.
/// Unpaced (default) delivers as fast as the consumer drains — a 3 h session replays in
/// seconds (NFR-8, 08 §6 performance target).
public struct ScriptedCapture: CaptureSource {
    public let motionFrames: [MotionFrame]
    public let rawFrames: [RawAccelFrame]
    public let fixes: [LocationFix]
    public let baroFrames: [BaroFrame]
    public let sampleRate: Double

    public init(
        motionFrames: [MotionFrame], rawFrames: [RawAccelFrame] = [],
        fixes: [LocationFix] = [], baroFrames: [BaroFrame] = [], sampleRate: Double = 100
    ) {
        self.motionFrames = motionFrames
        self.rawFrames = rawFrames
        self.fixes = fixes
        self.baroFrames = baroFrames
        self.sampleRate = sampleRate
    }

    public func start() async throws -> CaptureFeed {
        CaptureFeed(
            motion: stream(motionFrames),
            rawAccel: stream(rawFrames),
            location: stream(fixes),
            baro: stream(baroFrames),
            sampleRate: sampleRate)
    }

    public func stop() async {}

    private func stream<T: Sendable>(_ items: [T]) -> AsyncStream<T> {
        AsyncStream { continuation in
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }
}
