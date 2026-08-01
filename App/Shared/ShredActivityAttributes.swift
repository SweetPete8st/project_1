#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity contract shared by the app and the widget extension (both targets include
/// this file — see project.yml). Session stats on the Lock Screen / Dynamic Island, 06 §4.
public struct ShredActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var elapsed: TimeInterval
        public var speedMetersPerSecond: Double
        public var airCount: Int
        public var lastEventLabel: String?
        public var autoPaused: Bool

        public init(
            elapsed: TimeInterval, speedMetersPerSecond: Double, airCount: Int,
            lastEventLabel: String?, autoPaused: Bool
        ) {
            self.elapsed = elapsed
            self.speedMetersPerSecond = speedMetersPerSecond
            self.airCount = airCount
            self.lastEventLabel = lastEventLabel
            self.autoPaused = autoPaused
        }
    }

    public var sessionID: UUID
    public var startedAt: Date

    public init(sessionID: UUID, startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}
#endif
