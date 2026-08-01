#if canImport(ActivityKit) && canImport(WidgetKit)
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ShredWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShredLiveActivityWidget()
    }
}

struct ShredLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShredActivityAttributes.self) { context in
            // Lock Screen banner.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.autoPaused ? "Chilling — auto-paused" : "SHRED — live")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        Date(
                            timeIntervalSinceNow: -context.state.elapsed),
                        style: .timer
                    )
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(context.state.airCount) airs")
                        .font(.headline)
                    if let last = context.state.lastEventLabel {
                        Text(last)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(
                        Date(timeIntervalSinceNow: -context.state.elapsed), style: .timer
                    )
                    .font(.title2.bold())
                    .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.airCount) airs")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let last = context.state.lastEventLabel {
                        Text(last)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } compactLeading: {
                Image(systemName: "skateboard")
            } compactTrailing: {
                Text(
                    Date(timeIntervalSinceNow: -context.state.elapsed), style: .timer
                )
                .monospacedDigit()
                .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "skateboard")
            }
        }
    }
}
#endif
