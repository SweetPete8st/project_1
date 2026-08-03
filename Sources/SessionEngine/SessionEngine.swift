import Foundation
import CaptureKit
import DetectionKit
import RouteKit
import ShredCore
import TelemetryStore

/// The single source of truth for session lifecycle, docs/spec/04 §5 + auto-start
/// integration (ADR-0004). One engine, two entry paths:
///
///   Manual:    `startSession(calibration:)`              — full telemetry incl. stance.
///   Automatic: `arm()` → push rhythm confirmed → session — placement-independent subset
///              (no CalibrationRecord ⇒ stance analytics are structurally off).
///
/// Duplicate-start prevention: any start request while a session is active is a no-op that
/// reports the existing session. Manual start while armed cleanly overrides arming.
public actor SessionEngine {
    public enum EngineState: Sendable, Equatable {
        case idle
        /// Auto-start listening (FR: "Automatically detect when I start skating").
        case armed
        case active(sessionID: UUID, startSource: StartSource)
        case ending
    }

    public private(set) var state: EngineState = .idle

    // Dependencies. `capture` is swapped on automatic start: the armed phase runs a
    // lightweight motion-only source, but a session needs the full sensor array — above
    // all the GPS background lifeline (field session 2026-08-03: a pocketed auto-started
    // session was suspended on screen lock and lost 120 s of telemetry).
    private var capture: any CaptureSource
    private var sessionCaptureFactory: (@Sendable () -> any CaptureSource)?
    private let chunkStore: ChunkStore
    private let checkpointStore: CheckpointStore
    private let archive: SessionArchive
    private let tuning: DetectionTuning
    private let autoStartConfig: AutoStartConfig
    private let capabilities: DeviceCapabilities
    /// Injected clock (Date.init is fine in production; tests inject fixed dates).
    private let now: @Sendable () -> Date

    // Live session state.
    private var pipeline: DetectionPipeline?
    private var autoDetector: AutoStartDetector?
    private var sessionID: UUID?
    private var startSource: StartSource = .manual
    private var autoMetadata: AutoStartMetadata?
    private var calibration: CalibrationRecord?
    private var startedAtSensor: Double = 0
    private var startedAtWall = Date.distantPast
    private var lastSensorTime: Double = 0
    private var clockAnchors = ClockAnchors()
    private var fixes: [LocationFix] = []
    private var liveStats = LiveStats()
    private var consumeTask: Task<Void, Never>?
    private var feedSampleRate: Double = 100

    // Armed-phase ring buffer (~12 s) so an automatic start can backfill telemetry from
    // the first push, not just backdate the timer.
    private var armedRing: [MotionFrame] = []
    private var armedRawRing: [RawAccelFrame] = []
    private var armedRingCapacity = 1200

    // Chunked persistence.
    private var motionBuffer: [MotionFrame] = []
    private var rawBuffer: [RawAccelFrame] = []
    private var baroBuffer: [BaroFrame] = []
    private var chunkIndex: [StreamKind: Int] = [:]
    private var locationFlushedCount = 0
    private var lastChunkFlush: Double = 0
    private var lastCheckpoint: Double = 0

    /// UI observation hook (throttled to ≤ 2 Hz upstream by the stats reducer cadence).
    public var onLiveStats: (@Sendable (LiveStats) -> Void)?
    public var onStateChange: (@Sendable (EngineState) -> Void)?

    public init(
        capture: any CaptureSource,
        storeRoot: URL,
        tuning: DetectionTuning = DetectionTuning(),
        autoStartConfig: AutoStartConfig = AutoStartConfig(),
        capabilities: DeviceCapabilities = DeviceCapabilities(),
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.capture = capture
        self.chunkStore = ChunkStore(root: storeRoot)
        self.checkpointStore = CheckpointStore(root: storeRoot)
        self.archive = SessionArchive(root: storeRoot)
        self.tuning = tuning
        self.autoStartConfig = autoStartConfig
        self.capabilities = capabilities
        self.now = now
    }

    public func setLiveStatsHandler(_ handler: (@Sendable (LiveStats) -> Void)?) {
        onLiveStats = handler
    }

    public func setStateChangeHandler(_ handler: (@Sendable (EngineState) -> Void)?) {
        onStateChange = handler
    }

    /// Factory for the full-capture source a session should run on. Consulted whenever a
    /// session starts while the engine holds a lighter capture (armed auto-start phase).
    public func setSessionCaptureFactory(_ factory: (@Sendable () -> any CaptureSource)?) {
        sessionCaptureFactory = factory
    }

    private func transition(_ new: EngineState) {
        state = new
        onStateChange?(new)
    }

    // MARK: - Arming (automatic start)

    /// Arms passive push-rhythm detection. No-op if a session is active.
    public func arm() async throws {
        guard case .idle = state else { return }
        autoDetector = AutoStartDetector(config: autoStartConfig)
        armedRing.removeAll(keepingCapacity: true)
        armedRawRing.removeAll(keepingCapacity: true)
        transition(.armed)
        try await startConsuming()
    }

    /// Cancels arming without starting a session.
    public func disarm() async {
        guard case .armed = state else { return }
        consumeTask?.cancel()
        consumeTask = nil
        await capture.stop()
        autoDetector = nil
        transition(.idle)
    }

    // MARK: - Session start

    /// Manual start (FR-1). While armed, overrides arming cleanly and reuses the running
    /// capture feed.
    @discardableResult
    public func startSession(calibration: CalibrationRecord?) async throws -> UUID {
        if case .active(let id, _) = state { return id }  // duplicate prevention
        let wasArmed = (state == .armed)
        autoDetector = nil
        if wasArmed {
            // Tear down the armed lightweight capture and come up on the full array.
            guard let feed = await restartCaptureForSession() else {
                transition(.idle)
                throw CaptureError.motionUnavailable
            }
            let id = beginSession(
                source: .manual, calibration: calibration, startSensorTime: nil, auto: nil)
            consume(feed: feed)
            return id
        }
        let id = beginSession(
            source: .manual, calibration: calibration, startSensorTime: nil, auto: nil)
        try await startConsuming()
        return id
    }

    /// Stops whatever capture is running, swaps in the session-grade source (when a
    /// factory is configured), and returns its live feed.
    private func restartCaptureForSession() async -> CaptureFeed? {
        consumeTask?.cancel()
        consumeTask = nil
        await capture.stop()
        if let factory = sessionCaptureFactory {
            capture = factory()
        }
        guard let feed = try? await capture.start() else { return nil }
        feedSampleRate = feed.sampleRate
        return feed
    }

    /// Automatic start from a confirmed detection — backdated to the first push. Runs the
    /// capture upgrade first so the session gets the full sensor array + GPS lifeline.
    private func completeAutomaticStart(_ detection: AutoStartDetection) async {
        guard case .armed = state else { return }  // duplicate/late-event prevention
        guard let feed = await restartCaptureForSession() else {
            transition(.idle)
            return
        }
        _ = beginSession(
            source: .automatic, calibration: nil, startSensorTime: detection.firstPushTime,
            auto: AutoStartMetadata(
                confidence: detection.confidence,
                detectedPushCount: detection.pushCount,
                estimatedPushesPerMinute: detection.estimatedPushesPerMinute))
        // Backfill: replay the armed ring from the first push into the fresh pipeline so
        // telemetry (pushes, g-envelope, speed) covers the backdated span too.
        let ring = armedRing.filter { $0.sensorTime >= detection.firstPushTime - 0.5 }
        let rawRing = armedRawRing.filter { $0.sensorTime >= detection.firstPushTime - 0.5 }
        armedRing.removeAll(keepingCapacity: false)
        armedRawRing.removeAll(keepingCapacity: false)
        var rawIdx = 0
        for m in ring {
            while rawIdx < rawRing.count, rawRing[rawIdx].sensorTime <= m.sensorTime {
                ingest(raw: rawRing[rawIdx])
                rawIdx += 1
            }
            ingest(motion: m)
        }
        consume(feed: feed)
    }

    private func beginSession(
        source: StartSource, calibration: CalibrationRecord?, startSensorTime: Double?,
        auto: AutoStartMetadata?
    ) -> UUID {
        let id = UUID()
        sessionID = id
        startSource = source
        autoMetadata = auto
        self.calibration = calibration
        pipeline = DetectionPipeline(
            tuning: tuning, sampleRate: feedSampleRate, calibration: calibration,
            capabilities: capabilities)
        fixes.removeAll()
        motionBuffer.removeAll()
        rawBuffer.removeAll()
        baroBuffer.removeAll()
        chunkIndex = [:]
        locationFlushedCount = 0
        liveStats = LiveStats()

        let wall = now()
        let sensorNow = lastSensorTime
        // Backdate: sensor start = first push; wall start shifts by the same delta.
        let sensorStart = startSensorTime ?? sensorNow
        startedAtSensor = sensorStart
        startedAtWall = wall.addingTimeInterval(sensorStart - max(sensorNow, sensorStart))
        clockAnchors = ClockAnchors()
        clockAnchors.record(sensorTime: max(sensorNow, sensorStart), wallClock: wall)
        transition(.active(sessionID: id, startSource: source))
        persistCheckpoint(force: true)
        return id
    }

    // MARK: - Feed consumption

    private func startConsuming() async throws {
        guard consumeTask == nil else { return }
        let feed = try await capture.start()
        feedSampleRate = feed.sampleRate
        consume(feed: feed)
    }

    private func consume(feed: CaptureFeed) {
        guard consumeTask == nil else { return }
        // Strong capture is safe: endSession/disarm cancel this task, releasing the cycle.
        let engine = self
        consumeTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await frame in feed.motion {
                        if Task.isCancelled { break }
                        await engine.ingest(motion: frame)
                    }
                }
                group.addTask {
                    for await frame in feed.rawAccel {
                        if Task.isCancelled { break }
                        await engine.ingest(raw: frame)
                    }
                }
                group.addTask {
                    for await fix in feed.location {
                        if Task.isCancelled { break }
                        await engine.ingest(fix: fix)
                    }
                }
                group.addTask {
                    for await frame in feed.baro {
                        if Task.isCancelled { break }
                        await engine.ingest(baro: frame)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private var armedFrameToggle = false

    func ingest(motion frame: MotionFrame) {
        lastSensorTime = max(lastSensorTime, frame.sensorTime)

        switch state {
        case .armed:
            armedRing.append(frame)
            if armedRing.count > armedRingCapacity {
                armedRing.removeFirst(armedRing.count - armedRingCapacity)
            }
            // Detector is specified at ~50 Hz; halve a 100 Hz feed (battery + spec parity).
            armedFrameToggle.toggle()
            if feedSampleRate < 75 || armedFrameToggle {
                if let detection = autoDetector?.push(motion: frame).detection {
                    autoDetector = nil  // no further detections while the upgrade runs
                    Task { await self.completeAutomaticStart(detection) }
                }
            }
        case .active:
            ingestActive(motion: frame)
        case .idle, .ending:
            break
        }
    }

    private func ingestActive(motion frame: MotionFrame) {
        guard let pipeline else { return }
        // Manual start can precede the first delivered frame (sensor clock unknown until
        // now): anchor the session to the first frame.
        if startedAtSensor == 0 {
            startedAtSensor = frame.sensorTime
            clockAnchors.record(sensorTime: frame.sensorTime, wallClock: now())
        }
        pipeline.push(motion: frame)
        motionBuffer.append(frame)
        maybeFlushChunks(at: frame.sensorTime)
        maybeCheckpoint(at: frame.sensorTime)
        updateLiveStats(at: frame.sensorTime, pipeline: pipeline)
    }

    func ingest(raw frame: RawAccelFrame) {
        switch state {
        case .armed:
            armedRawRing.append(frame)
            if armedRawRing.count > armedRingCapacity {
                armedRawRing.removeFirst(armedRawRing.count - armedRingCapacity)
            }
        case .active:
            pipeline?.push(raw: frame)
            rawBuffer.append(frame)
        default:
            break
        }
    }

    func ingest(fix: LocationFix) {
        lastSensorTime = max(lastSensorTime, fix.sensorTime)
        guard case .active = state, let pipeline else { return }
        var gated = fix
        // Quality gate (02 §5): flag rather than drop.
        if fix.horizontalAccuracy > 20 || fix.horizontalAccuracy < 0 || fix.speedAccuracy < 0 {
            gated.flagged = true
        }
        pipeline.push(fix: gated)
        fixes.append(gated)
    }

    func ingest(baro frame: BaroFrame) {
        guard case .active = state, let pipeline else { return }
        pipeline.push(baro: frame)
        baroBuffer.append(frame)
    }

    // MARK: - Live stats (≤ 2 Hz)

    private var lastStatsEmit = 0.0

    private func updateLiveStats(at t: Double, pipeline: DetectionPipeline) {
        guard t - lastStatsEmit >= 0.5 else { return }
        lastStatsEmit = t
        liveStats.sessionElapsed = t - startedAtSensor
        liveStats.currentSpeed = pipeline.currentSpeed
        liveStats.topSpeed = max(liveStats.topSpeed, pipeline.currentSpeed)
        liveStats.activity = pipeline.currentActivity
        liveStats.pushCount = pipeline.pushCount
        let events = pipeline.drainEvents()
        liveStats.airborneCount = events.filter { $0.kind == .airborne || $0.kind == .drop }
            .count
        liveStats.impactCount = events.filter { $0.kind == .impact }.count
        liveStats.lastEvent = events.last
        onLiveStats?(liveStats)
    }

    // MARK: - Persistence during session

    private func maybeFlushChunks(at t: Double) {
        if lastChunkFlush == 0 { lastChunkFlush = t }
        guard t - lastChunkFlush >= 60 else { return }
        lastChunkFlush = t
        flushBuffers()
    }

    private func flushBuffers() {
        guard let id = sessionID else { return }
        let wall = clockAnchors.wallClock(for: lastSensorTime)
        func write(_ frames: ChunkCodec.Frames, kind: StreamKind) {
            guard frames.count > 0 else { return }
            let index = chunkIndex[kind, default: 0]
            chunkIndex[kind] = index + 1
            let store = chunkStore
            let rate = feedSampleRate
            Task {
                _ = try? await store.write(
                    session: id, index: index, frames: frames, source: .iphone,
                    sampleRateNominal: rate, wallAnchor: wall)
            }
        }
        write(.deviceMotion(motionBuffer), kind: .deviceMotion)
        write(.rawAccelerometer(rawBuffer), kind: .rawAccelerometer)
        write(.barometer(baroBuffer), kind: .barometer)
        if fixes.count > locationFlushedCount {
            write(.location(Array(fixes[locationFlushedCount...])), kind: .location)
            locationFlushedCount = fixes.count
        }
        motionBuffer.removeAll(keepingCapacity: true)
        rawBuffer.removeAll(keepingCapacity: true)
        baroBuffer.removeAll(keepingCapacity: true)
    }

    private func maybeCheckpoint(at t: Double) {
        guard t - lastCheckpoint >= 30 else { return }
        persistCheckpoint(force: false)
        lastCheckpoint = t
    }

    private func persistCheckpoint(force: Bool) {
        guard let id = sessionID else { return }
        let cp = SessionCheckpoint(
            sessionID: id, state: .active, startedAtSensorTime: startedAtSensor,
            startedAtWall: startedAtWall, lastSensorTime: lastSensorTime,
            calibration: calibration, clockAnchors: clockAnchors, updatedAt: now())
        try? checkpointStore.save(cp)
    }

    // MARK: - Ending

    /// Ends the session, finalizes detection, persists the record. Re-arms afterwards if
    /// `rearm` (the "auto-detect" setting is on and the user ended from the summary).
    public func endSession(rearm: Bool = false) async throws -> SessionRecord? {
        guard case .active = state, let id = sessionID, let pipeline else {
            if case .armed = state, !rearm {
                await disarm()
            }
            return nil
        }
        transition(.ending)
        consumeTask?.cancel()
        consumeTask = nil
        await capture.stop()
        flushBuffers()

        let result = pipeline.finalize()
        var summary = SessionSummaryStats()
        let riding = result.activityIntervals.filter { $0.state == .riding }
        let idleTime = result.activityIntervals.filter { $0.state == .idle }
            .reduce(0.0) { $0 + ($1.tEnd - $1.tStart) }
        summary.activeDuration = riding.reduce(0.0) { $0 + ($1.tEnd - $1.tStart) }
        summary.idleDuration = idleTime
        let route = RouteKit.route(from: fixes)
        summary.distance = RouteKit.totalDistance(route)
        summary.topSpeed = result.topSpeed
        summary.topSpeedValidated = result.topSpeedValidated
        summary.stanceRegular = result.stanceTime.regular
        summary.stanceSwitch = result.stanceTime.switchStance
        summary.stanceIndeterminate = result.stanceTime.indeterminate
        summary.ascent = result.ascent
        summary.descent = result.descent
        summary.pushCount = result.pushCount
        summary.pushCadenceMean = result.pushCadenceMean
        var counts = [EventKind: Int]()
        for e in result.events { counts[e.kind, default: 0] += 1 }
        summary.eventCounts = counts
        if calibration == nil {
            summary.degradations.append(.calibrationDegraded)
        }

        let record = SessionRecord(
            id: id, state: .saved, startSource: startSource, autoStart: autoMetadata,
            startedAtWall: startedAtWall,
            endedAtWall: clockAnchors.wallClock(for: lastSensorTime) ?? now(),
            startedAtSensor: startedAtSensor, endedAtSensor: lastSensorTime,
            pocket: calibration?.pocket, declaredStance: calibration?.declaredStance,
            calibrationQuality: calibration?.quality, summary: summary,
            events: result.events, stanceIntervals: result.stanceIntervals,
            activityIntervals: result.activityIntervals,
            route: RouteKit.simplify(route),
            speedSeries: result.speedSeries, gForceEnvelope: result.gForceEnvelope,
            clockAnchors: clockAnchors, appVersion: "1.0.0",
            tuningVersion: DetectorVersion.current)
        try archive.save(record)
        checkpointStore.clear()

        self.pipeline = nil
        sessionID = nil
        autoMetadata = nil
        transition(.idle)
        if rearm {
            try? await arm()
        }
        return record
    }

    /// FR-4 cold-launch recovery: a stale checkpoint means the app died mid-session.
    /// Chunked telemetry is replayed through a fresh pipeline and saved as `recovered`.
    public func recoverIfNeeded() async throws -> SessionRecord? {
        guard case .idle = state, let cp = checkpointStore.load() else { return nil }
        defer { checkpointStore.clear() }
        let motion = try await chunkStore.readAll(session: cp.sessionID, kind: .deviceMotion)
        guard !motion.chunks.isEmpty else { return nil }
        let raw = try await chunkStore.readAll(session: cp.sessionID, kind: .rawAccelerometer)
        let loc = try await chunkStore.readAll(session: cp.sessionID, kind: .location)
        let baro = try await chunkStore.readAll(session: cp.sessionID, kind: .barometer)

        let pipeline = DetectionPipeline(
            tuning: tuning, sampleRate: feedSampleRate, calibration: cp.calibration,
            capabilities: capabilities)
        var allFixes = [LocationFix]()
        var rawFrames = [RawAccelFrame]()
        for c in raw.chunks {
            if case .rawAccelerometer(let f) = c.frames { rawFrames += f }
        }
        for c in loc.chunks {
            if case .location(let f) = c.frames { allFixes += f }
        }
        var baroFrames = [BaroFrame]()
        for c in baro.chunks {
            if case .barometer(let f) = c.frames { baroFrames += f }
        }
        var rawIdx = 0
        var fixIdx = 0
        var baroIdx = 0
        var lastT = cp.lastSensorTime
        for c in motion.chunks {
            guard case .deviceMotion(let frames) = c.frames else { continue }
            for m in frames {
                while rawIdx < rawFrames.count, rawFrames[rawIdx].sensorTime <= m.sensorTime {
                    pipeline.push(raw: rawFrames[rawIdx])
                    rawIdx += 1
                }
                while fixIdx < allFixes.count, allFixes[fixIdx].sensorTime <= m.sensorTime {
                    pipeline.push(fix: allFixes[fixIdx])
                    fixIdx += 1
                }
                while baroIdx < baroFrames.count, baroFrames[baroIdx].sensorTime <= m.sensorTime {
                    pipeline.push(baro: baroFrames[baroIdx])
                    baroIdx += 1
                }
                pipeline.push(motion: m)
                lastT = max(lastT, m.sensorTime)
            }
        }
        let result = pipeline.finalize()
        var summary = SessionSummaryStats()
        summary.degradations = [.recoveredSession, .motionGap]
        let route = RouteKit.route(from: allFixes)
        summary.distance = RouteKit.totalDistance(route)
        summary.topSpeed = result.topSpeed
        summary.topSpeedValidated = result.topSpeedValidated
        summary.pushCount = result.pushCount
        var counts = [EventKind: Int]()
        for e in result.events { counts[e.kind, default: 0] += 1 }
        summary.eventCounts = counts

        let record = SessionRecord(
            id: cp.sessionID, state: .savedRecovered, startSource: .manual, autoStart: nil,
            startedAtWall: cp.startedAtWall,
            endedAtWall: cp.clockAnchors.wallClock(for: lastT) ?? cp.updatedAt,
            startedAtSensor: cp.startedAtSensorTime, endedAtSensor: lastT,
            pocket: cp.calibration?.pocket, declaredStance: cp.calibration?.declaredStance,
            calibrationQuality: cp.calibration?.quality, summary: summary,
            events: result.events, stanceIntervals: result.stanceIntervals,
            activityIntervals: result.activityIntervals, route: RouteKit.simplify(route),
            speedSeries: result.speedSeries, gForceEnvelope: result.gForceEnvelope,
            clockAnchors: cp.clockAnchors, appVersion: "1.0.0",
            tuningVersion: DetectorVersion.current)
        try archive.save(record)
        return record
    }

    /// Test/diagnostic access.
    public var currentLiveStats: LiveStats { liveStats }
    public var sessionArchive: SessionArchive { archive }
    /// Waits for the consume task to drain (scripted feeds finish; live feeds don't).
    public func waitForFeedEnd() async {
        await consumeTask?.value
    }
}
