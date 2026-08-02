import Foundation

/// Rider's post-session report — the fuel for the continual-improvement loop
/// (docs/integration/continual-improvement.md). Strictly opt-in: captured only when the
/// "Help improve tracking" setting is on AND the rider fills it in; leaves the phone only
/// when the rider taps share.
public struct SessionSelfReport: Sendable, Codable, Equatable {
    public var olliesAttempted: Int?
    public var olliesLanded: Int?
    public var bails: Int?
    /// 1–5: how accurate did the live stats feel?
    public var accuracyFeel: Int?
    /// Free-form: "lots of tic-tacs, dropped 3 curbs, last ollie was the best" — exactly
    /// the narrations that drove the first tuning rounds.
    public var notes: String
    public var createdAt: Date

    public init(
        olliesAttempted: Int? = nil, olliesLanded: Int? = nil, bails: Int? = nil,
        accuracyFeel: Int? = nil, notes: String = "", createdAt: Date = Date()
    ) {
        self.olliesAttempted = olliesAttempted
        self.olliesLanded = olliesLanded
        self.bails = bails
        self.accuracyFeel = accuracyFeel
        self.notes = notes
        self.createdAt = createdAt
    }
}
