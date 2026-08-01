#if os(iOS) && canImport(SwiftUI)
import ShredCore
import SwiftUI

/// In-app live screen, 06 §4 (rarely watched — the Live Activity is the primary surface).
public struct LiveSessionView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmEnd = false

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Text(activityLabel)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(Format.duration(model.liveStats.sessionElapsed))
                .font(DS.statFont(64))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(
                    "Speed", Format.speed(model.liveStats.currentSpeed, metric: model.metricUnits),
                    accent: true)
                StatTile("Airs", "\(model.liveStats.airborneCount)")
                StatTile("Pushes", "\(model.liveStats.pushCount)")
                StatTile("Impacts", "\(model.liveStats.impactCount)")
            }

            if let last = model.liveStats.lastEvent {
                Text(lastEventLabel(last))
                    .font(.callout.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(DS.accent.opacity(0.2), in: Capsule())
            }

            Spacer()

            Button(role: .destructive) {
                confirmEnd = true
            } label: {
                Text("End Sesh")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .confirmationDialog("End this sesh?", isPresented: $confirmEnd) {
                Button("End Sesh", role: .destructive) {
                    Task { await model.endSession() }
                }
            }
        }
        .padding(24)
    }

    private var activityLabel: String {
        switch model.liveStats.activity {
        case .riding: "Riding"
        case .walking: "Walking"
        case .idle: "Chilling — auto-paused"
        case .unknown: "Live"
        }
    }

    private func lastEventLabel(_ event: DetectedEvent) -> String {
        switch event.metrics {
        case .airborne(let a):
            let rot = a.rotationBucket == .none ? "" : " \(a.rotationBucket.rawValue)°"
            return "Air!\(rot) \(Format.airtime(a.airtime))"
        case .drop(let d):
            return "Drop! \(Format.airtime(d.airborne.airtime))"
        case .powerslide:
            return "Powerslide!"
        case .decel:
            return "Hard stop"
        case .impact(let i):
            return "Impact \(Format.gForce(i.peakG, clipped: i.clipped))"
        case .bail:
            return "Shake it off 🤕"
        case .rotationOnly(let r):
            return "\(Int(abs(r.rotationDegrees)))° pivot"
        }
    }
}
#endif
