#if os(iOS) && canImport(SwiftUI)
import SessionEngine
import ShredCore
import SwiftUI

/// Post-session rider report — the opt-in continual-improvement loop
/// (docs/integration/continual-improvement.md). Appears on the summary screen only when
/// "Help improve tracking" is enabled; sharing is always a manual, explicit action.
struct SessionReportCard: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    @State private var showSheet = false
    @State private var savedRecord: SessionRecord?

    var current: SessionRecord { savedRecord ?? record }

    var body: some View {
        if model.improveTrackingEnabled {
            VStack(alignment: .leading, spacing: 10) {
                if let report = current.selfReport {
                    Label(
                        reportSummary(report),
                        systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    HStack {
                        Button("Edit report") { showSheet = true }
                            .buttonStyle(.bordered)
                        if let data = try? CalibrationExport.data(for: current) {
                            ShareLink(
                                item: CalibrationFile(
                                    data: data,
                                    name: CalibrationExport.filename(for: current)),
                                preview: SharePreview("SHRED calibration report")
                            ) {
                                Label("Send for calibration", systemImage: "arrow.up.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Text("How'd the sesh actually go?")
                        .font(.headline)
                    Text(
                        "Your report (ollie counts, what the app got wrong) tunes detection for how YOU skate. Shared only when you hit send."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Report session") { showSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DS.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .sheet(isPresented: $showSheet) {
                SelfReportSheet(record: current) { report in
                    savedRecord = model.archive.attach(report: report, to: current.id)
                }
            }
        }
    }

    private func reportSummary(_ r: SessionSelfReport) -> String {
        var bits = [String]()
        if let a = r.olliesAttempted, let l = r.olliesLanded {
            bits.append("\(l)/\(a) ollies")
        }
        if let b = r.bails, b > 0 { bits.append("\(b) bails") }
        if let f = r.accuracyFeel { bits.append("accuracy \(f)/5") }
        return bits.isEmpty ? "Report saved" : "Reported: " + bits.joined(separator: " · ")
    }
}

/// Wraps export data for ShareLink as a named JSON file.
struct CalibrationFile: Transferable {
    let data: Data
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { file in
            file.data
        }
        .suggestedFileName { $0.name }
    }
}

struct SelfReportSheet: View {
    let record: SessionRecord
    let onSave: (SessionSelfReport) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var attempted: Int
    @State private var landed: Int
    @State private var bails: Int
    @State private var feel: Int
    @State private var notes: String

    init(record: SessionRecord, onSave: @escaping (SessionSelfReport) -> Void) {
        self.record = record
        self.onSave = onSave
        let existing = record.selfReport
        let detectedAirs =
            (record.summary.eventCounts[.airborne] ?? 0)
            + (record.summary.eventCounts[.drop] ?? 0)
        _attempted = State(initialValue: existing?.olliesAttempted ?? detectedAirs)
        _landed = State(initialValue: existing?.olliesLanded ?? detectedAirs)
        _bails = State(initialValue: existing?.bails ?? 0)
        _feel = State(initialValue: existing?.accuracyFeel ?? 3)
        _notes = State(initialValue: existing?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ollies") {
                    Stepper("Attempted: \(attempted)", value: $attempted, in: 0...200)
                    Stepper("Landed: \(landed)", value: $landed, in: 0...attempted)
                    Text(
                        "App counted \((record.summary.eventCounts[.airborne] ?? 0) + (record.summary.eventCounts[.drop] ?? 0)) airs"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Bails") {
                    Stepper("Bails: \(bails)", value: $bails, in: 0...50)
                }
                Section("How accurate did the live stats feel?") {
                    Picker("Accuracy", selection: $feel) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("What happened out there?") {
                    TextField(
                        "e.g. lots of tic-tacs, dropped 3 curbs, last ollie was the best",
                        text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                }
            }
            .navigationTitle("Session report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            SessionSelfReport(
                                olliesAttempted: attempted, olliesLanded: landed,
                                bails: bails, accuracyFeel: feel, notes: notes))
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
