#if os(iOS) && canImport(HealthKit)
import Foundation
import HealthKit
import ShredCore

/// HealthKit workout writing, FR-53. Opt-in; failures never surface as session errors.
public actor HealthBridge {
    public static let shared = HealthBridge()
    private let store = HKHealthStore()

    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    public func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let types: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWheelchair),  // closest continuous-distance analog
        ]
        return (try? await store.requestAuthorization(toShare: types, read: [])) != nil
    }

    /// Saves a session as a skating workout with distance + a rough energy estimate
    /// (7 kcal/min active — labeled "est." in UI; refined post-v1 via heart-rate sources).
    public func save(
        start: Date, end: Date, activeDuration: TimeInterval, distanceMeters: Double
    ) async -> Bool {
        guard isAvailable else { return false }
        let config = HKWorkoutConfiguration()
        config.activityType = .skatingSports
        config.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            var samples: [HKSample] = []
            if distanceMeters > 0 {
                samples.append(
                    HKQuantitySample(
                        type: HKQuantityType(.distanceWheelchair),
                        quantity: HKQuantity(unit: .meter(), doubleValue: distanceMeters),
                        start: start, end: end))
            }
            let kcal = activeDuration / 60 * 7
            if kcal > 0 {
                samples.append(
                    HKQuantitySample(
                        type: HKQuantityType(.activeEnergyBurned),
                        quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                        start: start, end: end))
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }
            try await builder.endCollection(at: end)
            return try await builder.finishWorkout() != nil
        } catch {
            return false
        }
    }
}
#endif
