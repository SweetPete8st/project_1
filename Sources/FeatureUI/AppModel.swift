#if os(iOS) && canImport(SwiftUI)
import CaptureKit
import DetectionKit
import Foundation
import Observation
import SessionEngine
import ShredCore
import SwiftUI
import TelemetryStore

#if canImport(HealthKit)
import HealthBridge
#endif

/// App-level state: settings, the engine for the current session/arming phase, and the
/// summary flow. UI observes this; SessionEngine stays the source of truth for lifecycle
/// (04 §5, ADR-0004).
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case idle
        case calibrating
        case armed
        case live
        case summary(SessionRecord)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var liveStats = LiveStats()
    public private(set) var lastError: String?

    // Settings (persisted).
    public var defaultPocket: Pocket {
        didSet { defaults.set(defaultPocket.rawValue, forKey: "pocket") }
    }
    public var defaultStance: Stance {
        didSet { defaults.set(defaultStance.rawValue, forKey: "stance") }
    }
    /// "Automatically detect when I start skating" (auto-start integration).
    public var autoStartEnabled: Bool {
        didSet {
            defaults.set(autoStartEnabled, forKey: "autoStartEnabled")
            Task { await autoStartSettingChanged() }
        }
    }
    public var metricUnits: Bool {
        didSet { defaults.set(metricUnits, forKey: "metric") }
    }
    public var healthSyncEnabled: Bool {
        didSet { defaults.set(healthSyncEnabled, forKey: "health") }
    }
    /// Continual-improvement loop: post-session self-reports + manual calibration export.
    /// Opt-in, off by default, flippable any time.
    public var improveTrackingEnabled: Bool {
        didSet { defaults.set(improveTrackingEnabled, forKey: "improveTracking") }
    }

    private let defaults = UserDefaults.standard
    private var engine: SessionEngine?
    private let storeRoot: URL

    public init() {
        storeRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shred", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: storeRoot, withIntermediateDirectories: true)
        defaultPocket = Pocket(rawValue: defaults.string(forKey: "pocket") ?? "") ?? .frontRight
        defaultStance = Stance(rawValue: defaults.string(forKey: "stance") ?? "") ?? .regular
        autoStartEnabled = defaults.bool(forKey: "autoStartEnabled")
        metricUnits = defaults.object(forKey: "metric") as? Bool
            ?? (Locale.current.measurementSystem == .metric)
        healthSyncEnabled = defaults.bool(forKey: "health")
        improveTrackingEnabled = defaults.bool(forKey: "improveTracking")
    }

    public var archive: SessionArchive { SessionArchive(root: storeRoot) }

    // MARK: - Lifecycle entries

    /// Cold-launch: recover a killed session (FR-4), then re-arm if enabled.
    public func onLaunch() async {
        let recoveryEngine = makeEngine(capture: ScriptedCapture(motionFrames: []))
        if let recovered = try? await recoveryEngine.recoverIfNeeded() {
            phase = .summary(recovered)
        } else if autoStartEnabled {
            await armIfPossible()
        }
    }

    public func beginCalibrationFlow() {
        phase = .calibrating
    }

    /// Called by CalibrationView with its result (or nil after 3 failed attempts, FR-21).
    public func calibrationFinished(_ calibration: CalibrationRecord?) async {
        await startSession(calibration: calibration)
    }

    public func startSession(calibration: CalibrationRecord?) async {
        if let engine, case .armed = await engine.state {
            // Manual start overrides arming on the same engine/feed.
            _ = try? await engine.startSession(calibration: calibration)
            phase = .live
            return
        }
        let engine = makeEngine(capture: CoreMotionCapture(sampleRate: 100))
        self.engine = engine
        do {
            _ = try await engine.startSession(calibration: calibration)
            phase = .live
        } catch {
            lastError = friendlyCaptureError(error)
            phase = .idle
        }
    }

    public func endSession() async {
        guard let engine else { return }
        let record = try? await engine.endSession(rearm: false)
        self.engine = nil
        if let record {
            phase = .summary(record)
            if healthSyncEnabled {
                _ = await HealthBridgeFacade.save(record: record)
            }
        } else {
            phase = .idle
        }
        if autoStartEnabled {
            await armIfPossible()
        }
    }

    public func dismissSummary() {
        if case .summary = phase {
            phase = autoStartArmed ? .armed : .idle
        }
    }

    // MARK: - Auto-start (ADR-0004)

    private var autoStartArmed = false

    private func autoStartSettingChanged() async {
        if autoStartEnabled {
            await armIfPossible()
        } else if let engine, case .armed = await engine.state {
            await engine.disarm()
            self.engine = nil
            autoStartArmed = false
            if phase == .armed { phase = .idle }
        }
    }

    /// Arms detection when legitimately possible (foreground; motion authorized). The
    /// finite background continuation is handled by AutoStartBackgroundService.
    public func armIfPossible() async {
        guard autoStartEnabled, phase == .idle || phase == .armed else { return }
        guard engine == nil else { return }
        let engine = makeEngine(capture: CoreMotionCapture(sampleRate: 50, armedMode: true))
        self.engine = engine
        // Auto-started sessions must upgrade to the full sensor array (GPS background
        // lifeline included) — field session 2026-08-03 lost 120 s without this.
        await engine.setSessionCaptureFactory { CoreMotionCapture(sampleRate: 100) }
        await engine.setStateChangeHandler { [weak self] state in
            Task { @MainActor [weak self] in
                self?.engineStateChanged(state)
            }
        }
        do {
            try await engine.arm()
            autoStartArmed = true
            phase = .armed
            AutoStartBackgroundService.shared.armedStateChanged(armed: true)
        } catch {
            self.engine = nil
            autoStartArmed = false
            lastError = friendlyCaptureError(error)
            phase = .idle
        }
    }

    private func engineStateChanged(_ state: SessionEngine.EngineState) {
        switch state {
        case .active(_, let source):
            // Automatic session began (or manual took over) — flip UI to live.
            if source == .automatic {
                phase = .live
                AutoStartBackgroundService.shared.armedStateChanged(armed: false)
                // Engine has already swapped to the full 100 Hz + GPS capture via the
                // session capture factory (see armIfPossible).
            }
            autoStartArmed = false
        case .armed:
            autoStartArmed = true
        case .idle, .ending:
            break
        }
    }

    private func makeEngine(capture: any CaptureSource) -> SessionEngine {
        let engine = SessionEngine(
            capture: capture, storeRoot: storeRoot, tuning: loadTuning(),
            capabilities: DeviceCapabilities())
        Task {
            await engine.setLiveStatsHandler { [weak self] stats in
                Task { @MainActor [weak self] in
                    self?.liveStats = stats
                }
            }
        }
        return engine
    }

    private func loadTuning() -> DetectionTuning {
        guard let url = Bundle.main.url(forResource: "DetectionTuning", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let tuning = try? DetectionTuning.load(from: data)
        else { return DetectionTuning() }
        return tuning
    }

    private func friendlyCaptureError(_ error: any Error) -> String {
        switch error as? CaptureError {
        case .motionUnavailable, .motionDenied:
            return "Motion access is required to track your session. Enable it in Settings."
        case .locationDenied:
            return "Location is off — sessions will run without route or stance stats."
        default:
            return "Couldn't start the sensors. Try again."
        }
    }
}

/// Thin indirection so FeatureUI compiles without HealthKit in non-app targets.
enum HealthBridgeFacade {
    static func save(record: SessionRecord) async -> Bool {
        #if canImport(HealthKit)
        guard await HealthBridge.shared.requestAuthorization() else { return false }
        return await HealthBridge.shared.save(
            start: record.startedAtWall, end: record.endedAtWall,
            activeDuration: record.summary.activeDuration,
            distanceMeters: record.summary.distance)
        #else
        return false
        #endif
    }
}
#endif
