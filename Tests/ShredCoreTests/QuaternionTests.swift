import Foundation
import Testing

@testable import ShredCore

@Suite struct QuaternionTests {
    @Test func identityActsAsNoop() {
        let v = SIMD3<Float>(1, 2, 3)
        let r = Quaternion.identity.act(v)
        #expect(abs(r.x - 1) < 1e-6 && abs(r.y - 2) < 1e-6 && abs(r.z - 3) < 1e-6)
    }

    @Test func yawRotationActsOnXAxis() {
        // +90° yaw about z takes x̂ to ŷ.
        let q = Quaternion(yaw: .pi / 2)
        let r = q.act(SIMD3<Float>(1, 0, 0))
        #expect(abs(r.x) < 1e-5)
        #expect(abs(r.y - 1) < 1e-5)
        #expect(abs(q.yaw - .pi / 2) < 1e-5)
    }

    @Test func compositionMatchesAngleSum() {
        let a = Quaternion(yaw: 0.3)
        let b = Quaternion(yaw: 0.5)
        #expect(abs((b * a).yaw - 0.8) < 1e-5)
    }

    @Test func angleBetweenOrientations() {
        let a = Quaternion(yaw: 0.2)
        let b = Quaternion(yaw: 1.0)
        #expect(abs(a.angle(to: b) - 0.8) < 1e-4)
    }

    @Test func wrapAngleStaysInRange() {
        // Exactly ±π is a knife-edge under Float rounding; either sign of π is valid.
        #expect(abs(abs(wrapAngle(3 * .pi)) - .pi) < 1e-5)
        #expect(abs(abs(wrapAngle(-3 * .pi)) - .pi) < 1e-5)
        #expect(abs(wrapAngle(0.5) - 0.5) < 1e-6)
    }
}

@Suite struct ClockAnchorTests {
    @Test func piecewiseConversionUsesNearestAnchorBefore() {
        var anchors = ClockAnchors()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        anchors.record(sensorTime: 100, wallClock: t0)
        anchors.record(sensorTime: 700, wallClock: t0.addingTimeInterval(600.5))  // 0.5s drift
        let w1 = anchors.wallClock(for: 150)!
        #expect(abs(w1.timeIntervalSince(t0) - 50) < 1e-9)
        let w2 = anchors.wallClock(for: 710)!
        #expect(abs(w2.timeIntervalSince(t0) - 610.5) < 1e-9)
    }
}

@Suite struct TuningTests {
    @Test func partialJSONKeepsDefaults() throws {
        let json = #"{"popAccelThreshold": 2.0, "unknownFutureKey": 42}"#.data(using: .utf8)!
        let t = try DetectionTuning.load(from: json)
        #expect(t.popAccelThreshold == 2.0)
        #expect(t.landAccelThreshold == DetectionTuning().landAccelThreshold)
    }

    @Test func roundTrips() throws {
        var t = DetectionTuning()
        t.airtimeMax = 2.0
        let data = try JSONEncoder().encode(t)
        let back = try DetectionTuning.load(from: data)
        #expect(back == t)
    }
}
