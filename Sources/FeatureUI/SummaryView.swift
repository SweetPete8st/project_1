#if os(iOS) && canImport(SwiftUI)
import Charts
import MapKit
import SessionEngine
import ShredCore
import SwiftUI

/// Session summary — the payoff screen, 06 §5.
public struct SummaryView: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord

    public init(record: SessionRecord) {
        self.record = record
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                degradationBanner
                header
                if !record.route.isEmpty {
                    map
                }
                highlights
                if hasStanceData {
                    StanceDonut(summary: record.summary)
                }
                speedChart
                SessionReportCard(record: record)
                timeline
            }
            .padding()
        }
        .navigationTitle(record.startedAtWall.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.dismissSummary() }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var degradationBanner: some View {
        if record.state == .savedRecovered {
            Label(
                "Recovered session — some data may be missing.",
                systemImage: "exclamationmark.triangle")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(DS.warnYellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        } else if record.startSource == .automatic {
            Label(
                "Auto-started at your first push (\(Int((record.autoStart?.confidence ?? 0) * 100))% confidence). Stance stats need a calibrated start.",
                systemImage: "wand.and.stars")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(DS.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var header: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile("Duration", Format.duration(record.duration))
            StatTile(
                "Active", Format.duration(record.summary.activeDuration))
            StatTile(
                "Distance", Format.distance(record.summary.distance, metric: model.metricUnits))
            StatTile(
                "Top speed",
                Format.speed(record.summary.topSpeed, metric: model.metricUnits)
                    + (record.summary.topSpeedValidated ? "" : " ⚠︎"),
                accent: true)
        }
    }

    private var map: some View {
        Map {
            MapPolyline(
                coordinates: record.route.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
            )
            .stroke(DS.accent, lineWidth: 4)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false)
    }

    private var hasStanceData: Bool {
        record.summary.stanceRegular + record.summary.stanceSwitch
            + record.summary.stanceIndeterminate > 0
    }

    private var highlights: some View {
        let airs = record.events.compactMap { event -> EventMetrics.Airborne? in
            switch event.metrics {
            case .airborne(let a): a
            case .drop(let d): d.airborne
            default: nil
            }
        }
        let bestAir = airs.max { $0.airtime < $1.airtime }
        let biggestImpact = airs.max { $0.landingPeakG < $1.landingPeakG }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            if let best = bestAir {
                StatTile(
                    "Best air",
                    "\(Format.airtime(best.airtime)) · est. \(Format.height(best.estHeight, metric: model.metricUnits))"
                )
            }
            if let impact = biggestImpact {
                StatTile(
                    "Biggest landing",
                    Format.gForce(impact.landingPeakG, clipped: impact.landingClipped))
            }
            StatTile("Airs", "\((record.summary.eventCounts[.airborne] ?? 0) + (record.summary.eventCounts[.drop] ?? 0))")
            StatTile("Pushes", "\(record.summary.pushCount)")
        }
    }

    @ViewBuilder private var speedChart: some View {
        if record.speedSeries.count > 5 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Chart(record.speedSeries, id: \.t) { sample in
                    LineMark(
                        x: .value("Time", sample.t - record.startedAtSensor),
                        y: .value(
                            "Speed",
                            model.metricUnits ? sample.v * 3.6 : sample.v * 2.23694))
                    .foregroundStyle(DS.accent)
                    .interpolationMethod(.monotone)
                }
                .frame(height: 140)
            }
            .padding(12)
            .background(DS.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if record.events.isEmpty {
                // 06 §10: a trickless cruise must never feel broken.
                Text(
                    "No airs today — \(Format.distance(record.summary.distance, metric: model.metricUnits)) cruised 🛹"
                )
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
            ForEach(record.events) { event in
                NavigationLink(value: event.id) {
                    EventRow(event: event, sessionStart: record.startedAtSensor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(DS.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .navigationDestination(for: UUID.self) { id in
            if let event = record.events.first(where: { $0.id == id }) {
                EventDetailView(event: event, record: record)
            }
        }
    }
}

struct EventRow: View {
    let event: DetectedEvent
    let sessionStart: Double

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(DS.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                    .opacity(event.confidence >= 0.6 ? 1 : 0.6)
                Text("+\(Format.duration(event.tStart - sessionStart))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if event.confidence < 0.6 {
                Text("unconfirmed?")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(.secondary, lineWidth: 0.5))
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch event.kind {
        case .airborne: "arrow.up.forward"
        case .drop: "arrow.down.forward"
        case .impact: "burst"
        case .decel, .powerslide: "arrow.down.to.line"
        case .bail: "figure.fall"
        case .rotationOnly: "arrow.trianglehead.2.clockwise"
        }
    }

    private var title: String {
        switch event.metrics {
        case .airborne(let a):
            let rot = a.rotationBucket == .none ? "Air" : "\(a.rotationBucket.rawValue)° \(a.direction?.rawValue ?? "")"
            return "\(rot) · \(Format.airtime(a.airtime))"
        case .drop(let d):
            return "Drop · \(Format.airtime(d.airborne.airtime))"
        case .powerslide(let p):
            return "Powerslide · \(Int(p.slideAngleDegrees))°"
        case .decel(let d):
            return "Hard stop · −\(String(format: "%.1f", d.peakDecel)) m/s²"
        case .impact(let i):
            return "Impact · \(Format.gForce(i.peakG, clipped: i.clipped))"
        case .bail:
            return "Bail"
        case .rotationOnly(let r):
            return "Pivot · \(Int(abs(r.rotationDegrees)))°"
        }
    }
}

struct StanceDonut: View {
    let summary: SessionSummaryStats

    var body: some View {
        let total = max(
            summary.stanceRegular + summary.stanceSwitch + summary.stanceIndeterminate, 1)
        VStack(alignment: .leading, spacing: 6) {
            Text("Stance")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Chart {
                SectorMark(
                    angle: .value("Regular", summary.stanceRegular / total),
                    innerRadius: .ratio(0.6))
                .foregroundStyle(DS.accent)
                SectorMark(
                    angle: .value("Switch", summary.stanceSwitch / total),
                    innerRadius: .ratio(0.6))
                .foregroundStyle(DS.confirmGreen)
                SectorMark(
                    angle: .value("Unclear", summary.stanceIndeterminate / total),
                    innerRadius: .ratio(0.6))
                .foregroundStyle(Color(.tertiarySystemFill))
            }
            .frame(height: 140)
            HStack(spacing: 16) {
                legend("Regular", Format.duration(summary.stanceRegular), DS.accent)
                legend("Switch", Format.duration(summary.stanceSwitch), DS.confirmGreen)
                legend(
                    "Unclear", Format.duration(summary.stanceIndeterminate),
                    Color(.tertiarySystemFill))
            }
            Text("Fakie can read as switch — pocket sensing can't always tell them apart.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(DS.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func legend(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(value)")
                .font(.caption)
        }
    }
}

struct EventDetailView: View {
    let event: DetectedEvent
    let record: SessionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EventRow(event: event, sessionStart: record.startedAtSensor)
                Text(
                    "Confidence \(Int(event.confidence * 100))% · detector v\(event.detectorVersion)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                // FR-38/39: snippet visualization + confirm/reclassify land with the
                // labeled-data flywheel milestone (M5); detail shows metrics for now.
                metricsBlock
            }
            .padding()
        }
        .navigationTitle("Event")
    }

    private var airborneMetrics: EventMetrics.Airborne? {
        switch event.metrics {
        case .airborne(let a): a
        case .drop(let d): d.airborne
        default: nil
        }
    }

    @ViewBuilder private var metricsBlock: some View {
        if let air = airborneMetrics {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile("Airtime", Format.airtime(air.airtime))
                StatTile("Est. height", String(format: "%.0f cm", air.estHeight * 100))
                StatTile(
                    "Landing",
                    Format.gForce(air.landingPeakG, clipped: air.landingClipped))
                StatTile("Rotation", "\(Int(air.rotationDegrees))°")
            }
        }
    }
}
#endif
