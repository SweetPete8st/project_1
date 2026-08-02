#if os(iOS) && canImport(SwiftUI)
import SwiftUI

/// 90s-skate design language: xerox-zine sticker-bomb on grip-tape black. Acid colors,
/// hard offset shadows (photocopy, not blur), chunky black borders, everything slightly
/// tilted like a hand-slapped sticker. Contrast stays AA: black type on acid fills.
public enum DS {
    // The 90s deck palette.
    public static let accent = Color(red: 1.0, green: 0.42, blue: 0.08)      // safety orange
    public static let acid = Color(red: 0.78, green: 1.0, blue: 0.0)         // acid green
    public static let hotPink = Color(red: 1.0, green: 0.18, blue: 0.53)     // hot magenta
    public static let electric = Color(red: 0.0, green: 0.9, blue: 1.0)      // electric cyan
    public static let bone = Color(red: 0.96, green: 0.94, blue: 0.88)       // sticker paper
    public static let ink = Color(red: 0.05, green: 0.05, blue: 0.06)        // xerox ink
    public static let confirmGreen = Color(red: 0.28, green: 0.85, blue: 0.42)
    public static let warnYellow = Color(red: 1.0, green: 0.8, blue: 0.2)

    public static func statFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .rounded).italic()
    }

    public static func shoutFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black).italic()
    }

    public static let cardBackground = Color(.secondarySystemGroupedBackground)

    /// Sticker fills cycle so a grid looks slap-bombed, not uniform.
    public static func stickerFill(_ index: Int) -> Color {
        [bone, acid, electric, bone, hotPink, bone][index % 6]
    }

    public static func stickerTilt(_ index: Int) -> Double {
        [-1.6, 1.1, -0.8, 1.8, -1.2, 0.7][index % 6]
    }
}

/// Hand-slapped sticker treatment: hard border, offset photocopy shadow, slight tilt.
struct StickerStyle: ViewModifier {
    var fill: Color = DS.bone
    var tilt: Double = -1.2

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.ink, lineWidth: 3))
            .shadow(color: DS.ink.opacity(0.9), radius: 0, x: 4, y: 4)
            .rotationEffect(.degrees(tilt))
    }
}

extension View {
    func sticker(fill: Color = DS.bone, tilt: Double = -1.2) -> some View {
        modifier(StickerStyle(fill: fill, tilt: tilt))
    }
}

/// Chunky 90s slab button: acid fill, black border, hard shadow, shouty caps.
public struct NinetiesButtonStyle: ButtonStyle {
    var fill: Color
    var big: Bool

    public init(fill: Color = DS.accent, big: Bool = false) {
        self.fill = fill
        self.big = big
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(big ? DS.shoutFont(26) : DS.shoutFont(16))
            .textCase(.uppercase)
            .foregroundStyle(DS.ink)
            .padding(.vertical, big ? 22 : 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.ink, lineWidth: 3.5))
            .shadow(
                color: DS.ink.opacity(0.9), radius: 0,
                x: configuration.isPressed ? 1 : 5, y: configuration.isPressed ? 1 : 5)
            .offset(
                x: configuration.isPressed ? 3 : 0, y: configuration.isPressed ? 3 : 0)
            .rotationEffect(.degrees(-0.6))
    }
}

/// Vans-checkerboard strip — the 90s divider.
public struct Checkerboard: View {
    var squares: Int = 24
    var height: CGFloat = 12

    public init(squares: Int = 24, height: CGFloat = 12) {
        self.squares = squares
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let side = geo.size.width / CGFloat(squares)
            HStack(spacing: 0) {
                ForEach(0..<squares, id: \.self) { i in
                    VStack(spacing: 0) {
                        Rectangle().fill(i.isMultiple(of: 2) ? DS.bone : DS.ink)
                        Rectangle().fill(i.isMultiple(of: 2) ? DS.ink : DS.bone)
                    }
                    .frame(width: side)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
    }
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

/// Stat tile, sticker-bombed. `index` cycles fill + tilt so grids look hand-slapped.
public struct StatTile: View {
    let label: String
    let value: String
    var accent = false
    var index = 0

    public init(_ label: String, _ value: String, accent: Bool = false, index: Int = 0) {
        self.label = label
        self.value = value
        self.accent = accent
        self.index = index
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .heavy))
                .textCase(.uppercase)
                .foregroundStyle(DS.ink.opacity(0.75))
                .kerning(1.5)
            Text(value)
                .font(DS.statFont(24))
                .foregroundStyle(accent ? DS.hotPink : DS.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .sticker(
            fill: accent ? DS.acid : DS.stickerFill(index), tilt: DS.stickerTilt(index))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
#endif
