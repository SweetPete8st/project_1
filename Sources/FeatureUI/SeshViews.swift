#if os(iOS) && canImport(SwiftUI)
import SessionEngine
import ShredCore
import SwiftUI

public struct RootView: View {
    @State private var model: AppModel

    public init(model: AppModel? = nil) {
        _model = State(initialValue: model ?? AppModel())
    }

    public var body: some View {
        TabView {
            SeshHomeView()
                .tabItem { Label("Sesh", systemImage: "figure.skating") }
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
            YouView()
                .tabItem { Label("You", systemImage: "trophy") }
        }
        .tint(DS.accent)
        .environment(model)
        .task { await model.onLaunch() }
        .fullScreenCover(
            isPresented: .constant(coverBinding != nil), content: { coverContent })
    }

    private var coverBinding: AppModel.Phase? {
        switch model.phase {
        case .calibrating, .live, .summary: model.phase
        default: nil
        }
    }

    @ViewBuilder private var coverContent: some View {
        switch model.phase {
        case .calibrating:
            CalibrationView()
                .environment(model)
        case .live:
            LiveSessionView()
                .environment(model)
        case .summary(let record):
            NavigationStack {
                SummaryView(record: record)
            }
            .environment(model)
        default:
            EmptyView()
        }
    }
}

public struct SeshHomeView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if model.phase == .armed {
                        armedCard
                    }

                    Checkerboard()
                    Button("Start Sesh") {
                        Task { model.beginCalibrationFlow() }
                    }
                    .buttonStyle(NinetiesButtonStyle(fill: DS.accent, big: true))
                    .padding(.vertical, 6)

                    PocketPicker(selection: $model.defaultPocket)

                    Picker("Stance", selection: $model.defaultStance) {
                        Text("Regular").tag(Stance.regular)
                        Text("Goofy").tag(Stance.goofy)
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: $model.autoStartEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatically detect when I start skating")
                                .foregroundStyle(DS.ink)
                            Text(
                                "Starts the timer at your first push. Uses motion only — no pocket calibration, so stance stats stay off for auto sessions."
                            )
                            .font(.caption)
                            .foregroundStyle(DS.ink.opacity(0.65))
                        }
                    }
                    .padding(12)
                    .sticker(fill: DS.bone, tilt: -0.7)
                    .tint(DS.hotPink)

                    if let error = model.lastError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(DS.warnYellow)
                    }
                }
                .padding()
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("SHRED")
                        .font(DS.shoutFont(30))
                        .foregroundStyle(DS.acid)
                        .rotationEffect(.degrees(-2))
                        .shadow(color: DS.hotPink, radius: 0, x: 2.5, y: 2.5)
                }
            }
        }
    }

    private var armedCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Armed — listening for pushes")
                    .font(DS.shoutFont(15))
                    .foregroundStyle(DS.ink)
                Text("Pocket the phone and push off. The timer backdates to your first push.")
                    .font(.caption)
                    .foregroundStyle(DS.ink.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .sticker(fill: DS.electric, tilt: 0.9)
    }
}

/// 4-position phone-in-pants diagram (06 §2), simplified as a grid.
struct PocketPicker: View {
    @Binding var selection: Pocket

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which pocket?")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(DS.ink.opacity(0.75))
                .textCase(.uppercase)
                .kerning(1.5)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                pocketButton(.frontLeft, "Front left")
                pocketButton(.frontRight, "Front right")
                pocketButton(.backLeft, "Back left")
                pocketButton(.backRight, "Back right")
            }
        }
        .padding(12)
        .sticker(fill: DS.bone, tilt: 0.6)
    }

    private func pocketButton(_ pocket: Pocket, _ label: String) -> some View {
        Button {
            selection = pocket
        } label: {
            Text(label)
                .font(.callout.weight(selection == pocket ? .bold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(DS.ink)
                .background(
                    selection == pocket ? DS.acid : DS.bone.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DS.ink, lineWidth: selection == pocket ? 3 : 1.5))
        }
        .buttonStyle(.plain)
    }
}
#endif
