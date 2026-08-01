import Foundation

/// Every detection threshold, centralized per docs/spec/03 preamble. Values are the spec's
/// initial numbers; tuning changes go through the replay harness metric diff (08 §3), never
/// ad-hoc edits at call sites. All durations seconds, accelerations g, angles radians,
/// rates rad/s, speeds m/s unless suffixed otherwise.
public struct DetectionTuning: Sendable, Codable, Equatable {
    // ── Preprocessing (03 §1) ──────────────────────────────────────────────
    public var lowPassCutoffHz: Double = 6
    public var vibrationBandLowHz: Double = 8
    public var vibrationBandHighHz: Double = 25
    public var bandRMSWindow: Double = 0.5
    public var ringBufferSeconds: Double = 4

    // ── Activity segmentation (03 §2) ──────────────────────────────────────
    public var vibrationRidingRMS: Float = 0.035
    public var idleRMS: Float = 0.012
    public var ridingMinSpeed: Double = 1.2
    public var idleMaxSpeed: Double = 0.5
    public var walkingCadenceHz: Double = 1.4
    public var stateHold: Double = 2.0
    public var autoPauseIdle: Double = 90
    /// Gait discrimination (real-session 2026-08-01: walking heel strikes are broadband
    /// impulses that defeat the band-RMS test; stride periodicity is the reliable tell).
    /// Normalized envelope autocorrelation peak in the stride-lag band ≥ this → walking.
    public var gaitPeriodicityMin: Float = 0.40
    /// Envelope RMS floor for the gait test (impulses must actually be present).
    public var gaitEnvelopeRMSMin: Float = 0.08
    /// Stride lag search band, seconds.
    public var gaitLagMin: Double = 0.35
    public var gaitLagMax: Double = 1.3
    /// GNSS overrides gait: above this speed it isn't walking (m/s).
    public var walkingMaxSpeed: Double = 2.2
    /// Per-event gait veto: airborne/drop/impact events whose surrounding ±2 s has median
    /// gait ρ ≥ this are walking artifacts (pocket slap), not tricks. Real-data calibrated:
    /// skating ρ p75 ≈ 0.28, walking median ≈ 0.46.
    public var gaitVetoRho: Float = 0.33

    // ── Airborne detection (03 §3) ─────────────────────────────────────────
    public var popJerkThreshold: Float = 90  // g/s on raw magnitude
    public var popAccelThreshold: Float = 1.8
    public var flightAccelThreshold: Float = 0.45
    public var flightMinDuration: Double = 0.09
    public var popToFlightMaxGap: Double = 0.25
    public var dropFlightMinDuration: Double = 0.18
    public var landAccelThreshold: Float = 2.2
    public var landJerkThreshold: Float = 60
    /// Soft-landing path (real 60 Hz data, 2026-08-01 session): leaving the free-fall band
    /// above this opens a provisional landing…
    public var landExitThreshold: Float = 1.1
    /// …which must reach this peak within landingPeakWindow to confirm (else discarded).
    public var landConfirmG: Float = 1.35
    public var landingPeakWindow: Double = 0.25
    public var airtimeMin: Double = 0.12
    public var airtimeMax: Double = 1.2
    public var postLandingRideCheck: Double = 1.0
    public var unconfirmedBelowConfidence: Double = 0.6

    // ── Impacts (03 §4) ────────────────────────────────────────────────────
    public var impactThresholdG: Float = 6
    public var impactSeparation: Double = 0.3
    public var clipFraction: Float = 0.99

    // ── Rotation (03 §5) ───────────────────────────────────────────────────
    public var rotationNoneMaxDeg: Float = 60
    public var rotationHalfMinDeg: Float = 145
    public var rotationHalfMaxDeg: Float = 215
    public var rotationFullMinDeg: Float = 325
    public var rotationFullMaxDeg: Float = 395
    public var pivotRotationMinDeg: Float = 160
    public var pivotRotationWindow: Double = 0.7

    // ── Stance (03 §6) ─────────────────────────────────────────────────────
    public var stanceSigmaMinDeg: Float = 40
    public var stanceSigmaMaxDeg: Float = 140
    public var stanceVoteWindow: Double = 5
    public var stanceFlipVotes: Int = 3
    public var calibrationStillMaxVariance: Float = 0.004  // g² on accel magnitude
    public var repocketGravityDeg: Float = 35
    public var repocketStableWindow: Double = 5

    // ── Speed / decel / powerslide (03 §7) ─────────────────────────────────
    public var kalmanProcessNoise: Double = 0.8   // (m/s²)² accel random walk
    public var kalmanFallbackMeasurementStd: Double = 0.7
    public var topSpeedGNSSAgreement: Double = 1.5
    public var decelThreshold: Double = -2.5
    public var decelMinDuration: Double = 0.4
    public var slideYawRateDeg: Float = 120
    public var slideLateralG: Float = 0.35
    public var slideOverlapSlack: Double = 0.3

    // ── Pushes (03 §9) ─────────────────────────────────────────────────────
    public var pushSpeedDelta: Double = 0.3
    public var pushWindow: Double = 1.0
    public var pushMinSeparation: Double = 0.6

    // ── Bail (03 §10) ──────────────────────────────────────────────────────
    public var bailImpactG: Float = 6
    public var bailTumbleRateDeg: Float = 400
    public var bailTumbleDuration: Double = 0.5
    public var bailStillnessWindow: Double = 3
    public var bailNotifyStillness: Double = 30

    // ── Elevation (03 §11) ─────────────────────────────────────────────────
    public var elevationHysteresis: Double = 1.5
    public var baroLowPassHz: Double = 0.5
    public var baroDropCrossCheckSlack: Double = 2

    public init() {}

    /// Loads tuning from JSON, tolerating unknown keys (forward compat, 04 §8) and missing
    /// keys (defaults above).
    public static func load(from data: Data) throws -> DetectionTuning {
        try JSONDecoder().decode(DetectionTuning.self, from: data)
    }

    // Custom decoding: every key optional so partial tuning files work.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var t = DetectionTuning()
        func f<V: Decodable>(_ key: CodingKeys, _ into: inout V) {
            if let v = (try? c.decodeIfPresent(V.self, forKey: key)) ?? nil { into = v }
        }
        f(.lowPassCutoffHz, &t.lowPassCutoffHz)
        f(.vibrationBandLowHz, &t.vibrationBandLowHz)
        f(.vibrationBandHighHz, &t.vibrationBandHighHz)
        f(.bandRMSWindow, &t.bandRMSWindow)
        f(.ringBufferSeconds, &t.ringBufferSeconds)
        f(.vibrationRidingRMS, &t.vibrationRidingRMS)
        f(.idleRMS, &t.idleRMS)
        f(.ridingMinSpeed, &t.ridingMinSpeed)
        f(.idleMaxSpeed, &t.idleMaxSpeed)
        f(.walkingCadenceHz, &t.walkingCadenceHz)
        f(.stateHold, &t.stateHold)
        f(.autoPauseIdle, &t.autoPauseIdle)
        f(.gaitPeriodicityMin, &t.gaitPeriodicityMin)
        f(.gaitEnvelopeRMSMin, &t.gaitEnvelopeRMSMin)
        f(.gaitLagMin, &t.gaitLagMin)
        f(.gaitLagMax, &t.gaitLagMax)
        f(.walkingMaxSpeed, &t.walkingMaxSpeed)
        f(.gaitVetoRho, &t.gaitVetoRho)
        f(.popJerkThreshold, &t.popJerkThreshold)
        f(.popAccelThreshold, &t.popAccelThreshold)
        f(.flightAccelThreshold, &t.flightAccelThreshold)
        f(.flightMinDuration, &t.flightMinDuration)
        f(.popToFlightMaxGap, &t.popToFlightMaxGap)
        f(.dropFlightMinDuration, &t.dropFlightMinDuration)
        f(.landAccelThreshold, &t.landAccelThreshold)
        f(.landJerkThreshold, &t.landJerkThreshold)
        f(.landExitThreshold, &t.landExitThreshold)
        f(.landConfirmG, &t.landConfirmG)
        f(.landingPeakWindow, &t.landingPeakWindow)
        f(.airtimeMin, &t.airtimeMin)
        f(.airtimeMax, &t.airtimeMax)
        f(.postLandingRideCheck, &t.postLandingRideCheck)
        f(.unconfirmedBelowConfidence, &t.unconfirmedBelowConfidence)
        f(.impactThresholdG, &t.impactThresholdG)
        f(.impactSeparation, &t.impactSeparation)
        f(.clipFraction, &t.clipFraction)
        f(.rotationNoneMaxDeg, &t.rotationNoneMaxDeg)
        f(.rotationHalfMinDeg, &t.rotationHalfMinDeg)
        f(.rotationHalfMaxDeg, &t.rotationHalfMaxDeg)
        f(.rotationFullMinDeg, &t.rotationFullMinDeg)
        f(.rotationFullMaxDeg, &t.rotationFullMaxDeg)
        f(.pivotRotationMinDeg, &t.pivotRotationMinDeg)
        f(.pivotRotationWindow, &t.pivotRotationWindow)
        f(.stanceSigmaMinDeg, &t.stanceSigmaMinDeg)
        f(.stanceSigmaMaxDeg, &t.stanceSigmaMaxDeg)
        f(.stanceVoteWindow, &t.stanceVoteWindow)
        f(.stanceFlipVotes, &t.stanceFlipVotes)
        f(.calibrationStillMaxVariance, &t.calibrationStillMaxVariance)
        f(.repocketGravityDeg, &t.repocketGravityDeg)
        f(.repocketStableWindow, &t.repocketStableWindow)
        f(.kalmanProcessNoise, &t.kalmanProcessNoise)
        f(.kalmanFallbackMeasurementStd, &t.kalmanFallbackMeasurementStd)
        f(.topSpeedGNSSAgreement, &t.topSpeedGNSSAgreement)
        f(.decelThreshold, &t.decelThreshold)
        f(.decelMinDuration, &t.decelMinDuration)
        f(.slideYawRateDeg, &t.slideYawRateDeg)
        f(.slideLateralG, &t.slideLateralG)
        f(.slideOverlapSlack, &t.slideOverlapSlack)
        f(.pushSpeedDelta, &t.pushSpeedDelta)
        f(.pushWindow, &t.pushWindow)
        f(.pushMinSeparation, &t.pushMinSeparation)
        f(.bailImpactG, &t.bailImpactG)
        f(.bailTumbleRateDeg, &t.bailTumbleRateDeg)
        f(.bailTumbleDuration, &t.bailTumbleDuration)
        f(.bailStillnessWindow, &t.bailStillnessWindow)
        f(.bailNotifyStillness, &t.bailNotifyStillness)
        f(.elevationHysteresis, &t.elevationHysteresis)
        f(.baroLowPassHz, &t.baroLowPassHz)
        f(.baroDropCrossCheckSlack, &t.baroDropCrossCheckSlack)
        self = t
    }
}
