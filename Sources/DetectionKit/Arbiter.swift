import Foundation
import ShredCore

/// Event arbitration & timeline assembly, docs/spec/03 §12.
/// Overlap resolution order: Bail > Airborne/Drop > Powerslide > Decel > Impact.
/// Landing impacts are absorbed into their airborne event (context attach, no duplicate row).
enum EventArbiter {
    static func arbitrate(_ raw: [DetectedEvent], tuning: DetectionTuning) -> [DetectedEvent] {
        var events = raw.sorted { $0.tStart < $1.tStart }

        func overlaps(_ a: DetectedEvent, _ b: DetectedEvent, slack: Double = 0) -> Bool {
            a.tStart - slack < b.tEnd && b.tStart - slack < a.tEnd
        }

        // 1. Bail wins any overlap conflict (03 §10: never label bails as tricks).
        let bails = events.filter { $0.kind == .bail }
        events.removeAll { e in
            e.kind != .bail && bails.contains { overlaps($0, e, slack: 0.3) }
        }

        // 2. Landing impacts attach to their airborne/drop event.
        let airs = events.filter { $0.kind == .airborne || $0.kind == .drop }
        var absorbed = Set<UUID>()
        for i in events.indices {
            guard events[i].kind == .impact,
                case .impact(var m) = events[i].metrics
            else { continue }
            if let host = airs.first(where: { air in
                events[i].tStart >= air.tEnd - tuning.landingPeakWindow - 0.25
                    && events[i].tStart <= air.tEnd + 0.1
            }) ?? airs.first(where: { overlaps($0, events[i]) }) {
                m.contextEventID = host.id
                events[i].metrics = .impact(m)
                absorbed.insert(events[i].id)
            }
        }
        events.removeAll { absorbed.contains($0.id) }

        // 3. Powerslide absorbs its plain-decel twin (same window).
        let slides = events.filter { $0.kind == .powerslide }
        events.removeAll { e in
            e.kind == .decel && slides.contains { overlaps($0, e, slack: tuning.slideOverlapSlack) }
        }

        // 4. Rotation-only pivots overlapping a powerslide are the slide's rotation.
        events.removeAll { e in
            e.kind == .rotationOnly && slides.contains { overlaps($0, e, slack: 0.3) }
        }

        return events.sorted { $0.tStart < $1.tStart }
    }
}
