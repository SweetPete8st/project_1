#if os(iOS) && canImport(CoreMotion)
import CoreLocation
import CoreMotion
import Foundation
import ShredCore

/// Live sensor capture, docs/spec/02. iOS-only; everything downstream of `CaptureFeed`
/// is platform-neutral.
///
/// Sign conversion (see SynthKit.SessionSynthesizer header for the SHRED convention):
/// Core Motion's userAcceleration/raw accelerometer are the NEGATIVE of kinematic
/// acceleration (at rest, raw reads −1 g on the axis pointing away from earth), so:
///   SHRED.userAccel = −CM.userAcceleration
///   SHRED.gravity   =  CM.gravity            (already points toward earth)
///   SHRED.rawAccel  = −CM.acceleration       (preserves raw = user − gravity)
public final class CoreMotionCapture: CaptureSource, @unchecked Sendable {
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue
    private let locationDelegate = LocationDelegateBox()
    private let sampleRate: Double
    private let armedMode: Bool

    private var motionContinuation: AsyncStream<MotionFrame>.Continuation?
    private var rawContinuation: AsyncStream<RawAccelFrame>.Continuation?
    private var locationContinuation: AsyncStream<LocationFix>.Continuation?
    private var baroContinuation: AsyncStream<BaroFrame>.Continuation?
    private var locationTask: Task<Void, Never>?

    /// - Parameters:
    ///   - sampleRate: 100 Hz for sessions; the armed (auto-start) phase uses 50 Hz.
    ///   - armedMode: arming needs motion only — no GPS, no altimeter (battery, 02 §7).
    public init(sampleRate: Double = 100, armedMode: Bool = false) {
        self.sampleRate = sampleRate
        self.armedMode = armedMode
        queue = OperationQueue()
        queue.name = "CaptureKit.MotionDelivery"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public func start() async throws -> CaptureFeed {
        guard motionManager.isDeviceMotionAvailable else { throw CaptureError.motionUnavailable }

        let (motionStream, motionCont) = AsyncStream.makeStream(
            of: MotionFrame.self, bufferingPolicy: .bufferingNewest(1024))
        let (rawStream, rawCont) = AsyncStream.makeStream(
            of: RawAccelFrame.self, bufferingPolicy: .bufferingNewest(1024))
        let (locStream, locCont) = AsyncStream.makeStream(
            of: LocationFix.self, bufferingPolicy: .bufferingNewest(64))
        let (baroStream, baroCont) = AsyncStream.makeStream(
            of: BaroFrame.self, bufferingPolicy: .bufferingNewest(256))
        motionContinuation = motionCont
        rawContinuation = rawCont
        locationContinuation = locCont
        baroContinuation = baroCont

        // Device motion (magnetic-north world frame for absolute yaw; falls back to
        // arbitrary-z if the magnetometer frame is unavailable, degrading stance only).
        motionManager.deviceMotionUpdateInterval = 1.0 / sampleRate
        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical : .xArbitraryZVertical
        motionManager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            let q = motion.attitude.quaternion
            self?.motionContinuation?.yield(
                MotionFrame(
                    sensorTime: motion.timestamp,
                    userAccel: SIMD3(
                        -Float(motion.userAcceleration.x), -Float(motion.userAcceleration.y),
                        -Float(motion.userAcceleration.z)),
                    gravity: SIMD3(
                        Float(motion.gravity.x), Float(motion.gravity.y),
                        Float(motion.gravity.z)),
                    rotationRate: SIMD3(
                        Float(motion.rotationRate.x), Float(motion.rotationRate.y),
                        Float(motion.rotationRate.z)),
                    attitude: Quaternion(
                        w: Float(q.w), x: Float(q.x), y: Float(q.y), z: Float(q.z))))
        }

        if !armedMode {
            // Raw accelerometer in parallel (impact peaks, 02 §2.2).
            motionManager.accelerometerUpdateInterval = 1.0 / sampleRate
            motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                guard let data else { return }
                self?.rawContinuation?.yield(
                    RawAccelFrame(
                        sensorTime: data.timestamp,
                        accel: SIMD3(
                            -Float(data.acceleration.x), -Float(data.acceleration.y),
                            -Float(data.acceleration.z))))
            }

            // Barometer.
            if CMAltimeter.isRelativeAltitudeAvailable() {
                altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, _ in
                    guard let data else { return }
                    self?.baroContinuation?.yield(
                        BaroFrame(
                            sensorTime: ProcessInfo.processInfo.systemUptime,
                            relativeAltitude: data.relativeAltitude.floatValue,
                            pressure: data.pressure.floatValue))
                }
            }

            // Location: modern async sequence (02 §5). Configuration side handled by the
            // shared manager in LocationAuthorization.
            locationDelegate.configureForSession()
            let bootWallDelta = Date().timeIntervalSince1970
                - ProcessInfo.processInfo.systemUptime
            locationTask = Task { [weak self] in
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                        guard !Task.isCancelled else { break }
                        guard let loc = update.location else { continue }
                        let sensorTime = loc.timestamp.timeIntervalSince1970 - bootWallDelta
                        self?.locationContinuation?.yield(
                            LocationFix(
                                sensorTime: sensorTime,
                                latitude: loc.coordinate.latitude,
                                longitude: loc.coordinate.longitude,
                                horizontalAccuracy: loc.horizontalAccuracy,
                                altitude: loc.altitude,
                                verticalAccuracy: loc.verticalAccuracy,
                                speed: loc.speed,
                                speedAccuracy: loc.speedAccuracy,
                                course: loc.course >= 0 ? loc.course * .pi / 180 : -1,
                                courseAccuracy: loc.courseAccuracy * .pi / 180))
                    }
                } catch {
                    // Authorization loss mid-session → engine degrades (06 §8); the
                    // stream simply stops delivering.
                }
            }
        }

        return CaptureFeed(
            motion: motionStream, rawAccel: rawStream, location: locStream, baro: baroStream,
            sampleRate: sampleRate)
    }

    public func stop() async {
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopAccelerometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        locationTask?.cancel()
        locationTask = nil
        motionContinuation?.finish()
        rawContinuation?.finish()
        locationContinuation?.finish()
        baroContinuation?.finish()
        locationDelegate.endSession()
    }
}

/// Owns the CLLocationManager used for configuration + authorization (liveUpdates handles
/// delivery; the manager sets accuracy/background behavior, 02 §5).
final class LocationDelegateBox: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestWhenInUse() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func configureForSession() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
        {
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()  // background lifeline, 04 §6
        }
    }

    func endSession() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }
}
#endif
