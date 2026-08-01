import Foundation
import Testing

import CaptureKit
import DetectionKit
@testable import SessionEngine
import ShredCore
import SynthKit
import TelemetryStore

private func tempRoot() -> URL {
    let url = FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager().createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSynthSession() -> SessionSynthesizer {
    let s = SessionSynthesizer(seed: 777, pocket: .frontRight, declaredStance: .regular)
    s.stand(6)
    s.ride(8, speed: 3.0, bearingDeg: 90)
    s.ollie(airtime: 0.4)
    s.ride(5, speed: 3.0, bearingDeg: 90)
    return s
}

@Suite struct ManualSessionTests {
    @Test func manualLifecycleProducesSavedRecord() async throws {
        let root = tempRoot()
        defer { try? FileManager().removeItem(at: root) }
        let synth = makeSynthSession()
        let capture = ScriptedCapture(
            motionFrames: synth.motion, rawFrames: synth.rawAccel, fixes: synth.fixes,
            baroFrames: synth.baro)
        let engine = SessionEngine(capture: capture, storeRoot: root)
        let calibration = CalibrationRecord(
            pocket: .frontRight, declaredStance: .regular, baselineAttitude: .identity,
            baselineGravity: SIMD3(0, 0, -1), stillVariance: 0.001, quality: .good)

        let id = try await engine.startSession(calibration: calibration)
        await engine.waitForFeedEnd()
        let record = try await engine.endSession()

        #expect(record != nil)
        #expect(record?.id == id)
        #expect(record?.startSource == .manual)
        #expect(record?.state == .saved)
        #expect((record?.summary.eventCounts[.airborne] ?? 0) == 1)
        #expect((record?.summary.distance ?? 0) > 20)
        // Persisted and listable.
        let listed = await engine.sessionArchive.list()
        #expect(listed.count == 1)
        let state = await engine.state
        #expect(state == .idle)
    }

    @Test func duplicateStartReturnsSameSession() async throws {
        let root = tempRoot()
        defer { try? FileManager().removeItem(at: root) }
        let synth = makeSynthSession()
        let capture = ScriptedCapture(motionFrames: synth.motion, rawFrames: synth.rawAccel)
        let engine = SessionEngine(capture: capture, storeRoot: root)
        let a = try await engine.startSession(calibration: nil)
        let b = try await engine.startSession(calibration: nil)
        #expect(a == b)
        _ = try await engine.endSession()
    }
}

@Suite struct AutoStartIntegrationTests {
    @Test func armedPushingStartsBackdatedAutomaticSession() async throws {
        let root = tempRoot()
        defer { try? FileManager().removeItem(at: root) }
        // 50 Hz pushing stream (detector's native rate), then quiet tail so the feed ends.
        let stream = AutoStartScenarios.skatePushing(seed: 60, pushes: 8)
        let capture = ScriptedCapture(motionFrames: stream.frames, sampleRate: 50)
        let engine = SessionEngine(capture: capture, storeRoot: root)

        try await engine.arm()
        await engine.waitForFeedEnd()
        let record = try await engine.endSession()

        #expect(record != nil)
        #expect(record?.startSource == .automatic)
        #expect(record?.autoStart != nil)
        #expect((record?.autoStart?.detectedPushCount ?? 0) >= 4)
        #expect((record?.autoStart?.confidence ?? 0) >= 0.68)
        // Backdated: session sensor-start ≈ first push, several pushes before confirm.
        if let r = record {
            #expect(abs(r.startedAtSensor - stream.truePushTimes[0]) < 0.5)
        }
        // Placement-independent contract: no calibration → no stance claims.
        #expect(record?.pocket == nil)
        #expect(record?.declaredStance == nil)
        #expect(record?.summary.stanceRegular == 0)
        #expect(record?.summary.stanceSwitch == 0)
        #expect(record?.summary.degradations.contains(.calibrationDegraded) == true)
    }

    @Test func walkingWhileArmedNeverStartsASession() async throws {
        let root = tempRoot()
        defer { try? FileManager().removeItem(at: root) }
        let stream = AutoStartScenarios.walking(seed: 61, duration: 60)
        let capture = ScriptedCapture(motionFrames: stream.frames, sampleRate: 50)
        let engine = SessionEngine(capture: capture, storeRoot: root)
        try await engine.arm()
        await engine.waitForFeedEnd()
        let state = await engine.state
        #expect(state == .armed)
        await engine.disarm()
        let after = await engine.state
        #expect(after == .idle)
        let listed = await engine.sessionArchive.list()
        #expect(listed.isEmpty)
    }

    @Test func manualStartWhileArmedOverridesCleanly() async throws {
        let root = tempRoot()
        defer { try? FileManager().removeItem(at: root) }
        let stream = AutoStartScenarios.skatePushing(seed: 62, pushes: 8)
        let capture = ScriptedCapture(motionFrames: stream.frames, sampleRate: 50)
        let engine = SessionEngine(capture: capture, storeRoot: root)
        try await engine.arm()
        // Immediately start manually — detector must be dead, exactly one session results.
        let id = try await engine.startSession(calibration: nil)
        await engine.waitForFeedEnd()
        let record = try await engine.endSession()
        #expect(record?.id == id)
        #expect(record?.startSource == .manual)
        let listed = await engine.sessionArchive.list()
        #expect(listed.count == 1)
    }

    @Test func continuedPushingAfterAutoStartDoesNotDuplicate() async throws {
        let root = tempRoot()
        defer { try? FileManager().removeItem(at: root) }
        let stream = AutoStartScenarios.skatePushing(seed: 63, pushes: 20)
        let capture = ScriptedCapture(motionFrames: stream.frames, sampleRate: 50)
        let engine = SessionEngine(capture: capture, storeRoot: root)
        try await engine.arm()
        await engine.waitForFeedEnd()
        _ = try await engine.endSession()
        let listed = await engine.sessionArchive.list()
        #expect(listed.count == 1)
    }
}

@Suite struct RecoveryTests {
    @Test func killMidSessionRecoversFromChunks() async throws {
        let root = tempRoot()
        defer { try? FileManager().removeItem(at: root) }
        let synth = makeSynthSession()
        let sessionID = UUID()

        // Simulate a dead session: chunks + stale checkpoint on disk, no clean record.
        let store = ChunkStore(root: root)
        _ = try await store.write(
            session: sessionID, index: 0, frames: .deviceMotion(synth.motion),
            source: .iphone, sampleRateNominal: 100, wallAnchor: Date())
        _ = try await store.write(
            session: sessionID, index: 0, frames: .rawAccelerometer(synth.rawAccel),
            source: .iphone, sampleRateNominal: 100, wallAnchor: Date())
        _ = try await store.write(
            session: sessionID, index: 0, frames: .location(synth.fixes), source: .iphone,
            sampleRateNominal: 1, wallAnchor: Date())
        var anchors = ClockAnchors()
        anchors.record(sensorTime: synth.motion.first!.sensorTime, wallClock: Date())
        try CheckpointStore(root: root).save(
            SessionCheckpoint(
                sessionID: sessionID, state: .active,
                startedAtSensorTime: synth.motion.first!.sensorTime, startedAtWall: Date(),
                lastSensorTime: synth.motion.last!.sensorTime, calibration: nil,
                clockAnchors: anchors, updatedAt: Date()))

        let engine = SessionEngine(
            capture: ScriptedCapture(motionFrames: []), storeRoot: root)
        let recovered = try await engine.recoverIfNeeded()
        #expect(recovered != nil)
        #expect(recovered?.state == .savedRecovered)
        #expect(recovered?.summary.degradations.contains(.recoveredSession) == true)
        #expect((recovered?.summary.eventCounts[.airborne] ?? 0) == 1)
        // Second call is a no-op (checkpoint cleared).
        let again = try await engine.recoverIfNeeded()
        #expect(again == nil)
    }
}
