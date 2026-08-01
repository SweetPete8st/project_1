#if os(iOS) && canImport(SwiftUI)
import SessionEngine
import ShredCore
import SwiftUI

/// History tab, 06 §7 (v1: session list; calendar heat + DailyAggregates follow post-M4).
public struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [SessionRecord] = []

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "Your first sesh will live here", systemImage: "skateboard",
                        description: Text("Hit Start Sesh and go skate."))
                } else {
                    List(sessions) { record in
                        NavigationLink {
                            SummaryView(record: record)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        record.startedAtWall.formatted(
                                            date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                    Text(sessionSubtitle(record))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if record.startSource == .automatic {
                                    Image(systemName: "wand.and.stars")
                                        .foregroundStyle(DS.accent)
                                        .accessibilityLabel("Auto-started")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .onAppear { sessions = model.archive.list() }
        }
    }

    private func sessionSubtitle(_ record: SessionRecord) -> String {
        let airs = (record.summary.eventCounts[.airborne] ?? 0)
            + (record.summary.eventCounts[.drop] ?? 0)
        return
            "\(Format.duration(record.duration)) · \(Format.distance(record.summary.distance, metric: model.metricUnits)) · \(airs) airs"
    }
}

/// You tab: PR wall + settings entry, 06 §7.
public struct YouView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [SessionRecord] = []

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10
                    ) {
                        StatTile("Sessions", "\(sessions.count)")
                        StatTile("Total time", Format.duration(totalDuration))
                        StatTile(
                            "Best air", bestAirtime.map { Format.airtime($0) } ?? "—",
                            accent: true)
                        StatTile(
                            "Top speed",
                            topSpeed.map { Format.speed($0, metric: model.metricUnits) } ?? "—",
                            accent: true)
                        StatTile("Total airs", "\(totalAirs)")
                        StatTile("Total pushes", "\(totalPushes)")
                    }
                }
                .padding()
            }
            .navigationTitle("You")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear { sessions = model.archive.list() }
        }
    }

    private var totalDuration: Double { sessions.reduce(0) { $0 + $1.duration } }
    private var totalPushes: Int { sessions.reduce(0) { $0 + $1.summary.pushCount } }
    private var totalAirs: Int {
        sessions.reduce(0) {
            $0 + ($1.summary.eventCounts[.airborne] ?? 0) + ($1.summary.eventCounts[.drop] ?? 0)
        }
    }
    private var topSpeed: Double? {
        sessions.filter(\.summary.topSpeedValidated).map(\.summary.topSpeed).max()
    }
    private var bestAirtime: Double? {
        sessions.flatMap(\.events)
            .compactMap { event -> Double? in
                switch event.metrics {
                case .airborne(let a): a.airtime
                case .drop(let d): d.airborne.airtime
                default: nil
                }
            }
            .max()
    }
}

/// Settings, 06 §9.
public struct SettingsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model
        Form {
            Section("Session defaults") {
                Picker("Pocket", selection: $model.defaultPocket) {
                    ForEach(Pocket.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Stance", selection: $model.defaultStance) {
                    Text("Regular").tag(Stance.regular)
                    Text("Goofy").tag(Stance.goofy)
                }
                Toggle("Auto-detect skating", isOn: $model.autoStartEnabled)
            }
            Section("Units") {
                Picker("Units", selection: $model.metricUnits) {
                    Text("Metric").tag(true)
                    Text("Imperial").tag(false)
                }
            }
            Section {
                Toggle("Save workouts to Health", isOn: $model.healthSyncEnabled)
            } footer: {
                Text("Sessions count toward your rings as skating workouts.")
            }
            Section {
                Text("All telemetry stays on this iPhone. No account, no cloud, no analytics.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Settings")
    }
}
#endif
