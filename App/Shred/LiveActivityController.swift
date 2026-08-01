#if canImport(ActivityKit)
import ActivityKit
import FeatureUI
import Foundation
import ShredCore

/// Starts/updates/ends the session Live Activity from AppModel state (04 §6: updates from
/// within the app process, ≤ 1 update/3 s).
@MainActor
final class LiveActivityController {
    private let model: AppModel
    private var activity: Activity<ShredActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var observationTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sync()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sync() {
        switch model.phase {
        case .live:
            let stats = model.liveStats
            if activity == nil,
                ActivityAuthorizationInfo().areActivitiesEnabled
            {
                let attributes = ShredActivityAttributes(sessionID: UUID(), startedAt: Date())
                activity = try? Activity.request(
                    attributes: attributes,
                    content: .init(state: state(from: stats), staleDate: nil))
                lastUpdate = Date()
            } else if let activity, Date().timeIntervalSince(lastUpdate) >= 3 {
                lastUpdate = Date()
                let content = ActivityContent(state: state(from: stats), staleDate: nil)
                Task { await activity.update(content) }
            }
        default:
            if let activity {
                self.activity = nil
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    private func state(from stats: LiveStats) -> ShredActivityAttributes.ContentState {
        var label: String?
        if let last = stats.lastEvent {
            switch last.metrics {
            case .airborne(let a):
                label = "Air \(String(format: "%.2f", a.airtime))s"
            case .drop:
                label = "Drop!"
            case .powerslide:
                label = "Powerslide!"
            default:
                label = nil
            }
        }
        return .init(
            elapsed: stats.sessionElapsed,
            speedMetersPerSecond: stats.currentSpeed,
            airCount: stats.airborneCount,
            lastEventLabel: label,
            autoPaused: stats.activity == .idle)
    }
}
#endif
