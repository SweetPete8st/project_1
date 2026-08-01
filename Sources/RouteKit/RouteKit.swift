import Foundation
import ShredCore

/// Route analytics, docs/spec/01 FR-45..47. Pure geodesy — MapKit rendering lives in
/// FeatureUI; spots' reverse geocoding lives in the iOS layer.
public enum RouteKit {
    public struct RoutePoint: Sendable, Codable, Equatable {
        public var sensorTime: Double
        public var latitude: Double
        public var longitude: Double
        public var speed: Double

        public init(sensorTime: Double, latitude: Double, longitude: Double, speed: Double) {
            self.sensorTime = sensorTime
            self.latitude = latitude
            self.longitude = longitude
            self.speed = speed
        }
    }

    /// Meters between two coordinates (haversine).
    public static func distance(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double
    ) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a =
            sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Builds the route from quality-gated fixes; drops flagged/inaccurate ones (02 §5).
    public static func route(from fixes: [LocationFix]) -> [RoutePoint] {
        fixes.filter { !$0.flagged && $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 20 }
            .map {
                RoutePoint(
                    sensorTime: $0.sensorTime, latitude: $0.latitude, longitude: $0.longitude,
                    speed: max(0, $0.speed))
            }
    }

    /// Total path length in meters, skipping implausible jumps (> 30 m/s between fixes).
    public static func totalDistance(_ route: [RoutePoint]) -> Double {
        guard route.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<route.count {
            let a = route[i - 1]
            let b = route[i]
            let d = distance(
                lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
            let dt = b.sensorTime - a.sensorTime
            if dt > 0, d / dt < 30 {
                total += d
            }
        }
        return total
    }

    /// Douglas-Peucker polyline simplification (tolerance meters) for map rendering.
    public static func simplify(_ route: [RoutePoint], tolerance: Double = 4) -> [RoutePoint] {
        guard route.count > 2 else { return route }
        var keep = [Bool](repeating: false, count: route.count)
        keep[0] = true
        keep[route.count - 1] = true
        var stack = [(0, route.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            var maxDist = 0.0
            var maxIdx = lo
            for i in (lo + 1)..<hi {
                let d = perpendicularDistance(route[i], route[lo], route[hi])
                if d > maxDist {
                    maxDist = d
                    maxIdx = i
                }
            }
            if maxDist > tolerance {
                keep[maxIdx] = true
                stack.append((lo, maxIdx))
                stack.append((maxIdx, hi))
            }
        }
        return route.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    static func perpendicularDistance(_ p: RoutePoint, _ a: RoutePoint, _ b: RoutePoint)
        -> Double
    {
        // Local flat-earth projection around `a`.
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(a.latitude * .pi / 180)
        let px = (p.longitude - a.longitude) * mLon
        let py = (p.latitude - a.latitude) * mLat
        let bx = (b.longitude - a.longitude) * mLon
        let by = (b.latitude - a.latitude) * mLat
        let len2 = bx * bx + by * by
        guard len2 > 0 else { return (px * px + py * py).squareRoot() }
        let t = max(0, min(1, (px * bx + py * by) / len2))
        let dx = px - t * bx
        let dy = py - t * by
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Spots (FR-47)

    public struct SpotCluster: Sendable, Codable, Equatable {
        public var centerLatitude: Double
        public var centerLongitude: Double
        public var radius: Double
        public var dwellSeconds: Double
    }

    /// Dwell-zone clustering: contiguous stretches where the rider stays within `radius`
    /// meters of a running centroid for at least `minDwell` seconds.
    public static func spots(
        in route: [RoutePoint], radius: Double = 75, minDwell: Double = 600
    ) -> [SpotCluster] {
        guard !route.isEmpty else { return [] }
        var clusters = [SpotCluster]()
        var centerLat = route[0].latitude
        var centerLon = route[0].longitude
        var count = 1.0
        var start = route[0].sensorTime
        var last = start

        func flush() {
            if last - start >= minDwell {
                clusters.append(
                    SpotCluster(
                        centerLatitude: centerLat, centerLongitude: centerLon, radius: radius,
                        dwellSeconds: last - start))
            }
        }

        for p in route.dropFirst() {
            let d = distance(
                lat1: centerLat, lon1: centerLon, lat2: p.latitude, lon2: p.longitude)
            if d <= radius {
                // Running centroid.
                count += 1
                centerLat += (p.latitude - centerLat) / count
                centerLon += (p.longitude - centerLon) / count
                last = p.sensorTime
            } else {
                flush()
                centerLat = p.latitude
                centerLon = p.longitude
                count = 1
                start = p.sensorTime
                last = start
            }
        }
        flush()
        return clusters
    }
}
