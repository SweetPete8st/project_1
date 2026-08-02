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
                .font(DS.statFont(72))
                .foregroundStyle(DS.acid)
                .rotationEffect(.degrees(-2))
                .shadow(color: DS.hotPink.opacity(0.8), radius: 0, x: 3, y: 3)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(
                    "Speed", Format.speed(model.liveStats.currentSpeed, metric: model.metricUnits),
                    accent: true, index: 0)
                StatTile("Airs", "\(model.liveStats.airborneCount)", index: 1)
                StatTile("Pushes", "\(model.liveStats.pushCount)", index: 2)
                StatTile("Impacts", "\(model.liveStats.impactCount)", index: 3)
            }

            if let last = model.liveStats.lastEvent {
                Text(lastEventLabel(last))
                    .font(DS.shoutFont(16))
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .sticker(fill: DS.acid, tilt: 1.5)
            }
            Checkerboard()

            Spacer()

            Button("End Sesh") {
                confirmEnd = true
            }
            .buttonStyle(NinetiesButtonStyle(fill: DS.hotPink))
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
