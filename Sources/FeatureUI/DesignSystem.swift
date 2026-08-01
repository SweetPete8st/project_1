#if os(iOS) && canImport(SwiftUI)
import SwiftUI

/// "Telemetry deck" design language, docs/spec/06: dark-first, big mono digits,
/// grip-tape black + safety orange. All colors semantic; light mode supported.
public enum DS {
    public static let accent = Color(red: 1.0, green: 0.42, blue: 0.08)  // safety orange
    public static let confirmGreen = Color(red: 0.28, green: 0.85, blue: 0.42)
    public static let warnYellow = Color(red: 1.0, green: 0.8, blue: 0.2)

    public static func statFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    public static let cardBackground = Color(.secondarySystemGroupedBackground)
}

public enum Format {
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    public static func speed(_ mps: Double, metric: Bool) -> String {
        metric
            ? String(format: "%.1f km/h", mps * 3.6)
            : String(format: "%.1f mph", mps * 2.23694)
    }

    public static func distance(_ meters: Double, metric: Bool) -> String {
        if metric {
            return meters >= 1000
                ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
        }
        let miles = meters / 1609.344
        return miles >= 0.1
            ? String(format: "%.2f mi", miles) : String(format: "%.0f ft", meters * 3.28084)
    }

    public static func height(_ meters: Double, metric: Bool) -> String {
        metric
            ? String(format: "%.0f cm", meters * 100)
            : String(format: "%.0f in", meters * 39.3701)
    }

    public static func gForce(_ g: Float, clipped: Bool) -> String {
        clipped ? String(format: "≥%.0f g", g) : String(format: "%.1f g", g)
    }

    public static func airtime(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }
}

/// Stat tile used across live + summary screens.
public struct StatTile: View {
    let label: String
    let value: String
    var accent = false

    public init(_ label: String, _ value: String, accent: Bool = false) {
        self.label = label
        self.value = value
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(DS.statFont(24))
                .foregroundStyle(accent ? DS.accent : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DS.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
#endif
