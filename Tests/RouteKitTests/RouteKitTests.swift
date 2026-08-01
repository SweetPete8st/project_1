import Foundation
import Testing

@testable import RouteKit
import ShredCore

private func fix(t: Double, lat: Double, lon: Double, speed: Double = 3) -> LocationFix {
    LocationFix(
        sensorTime: t, latitude: lat, longitude: lon, horizontalAccuracy: 4, altitude: 650,
        verticalAccuracy: 4, speed: speed, speedAccuracy: 0.3, course: 1.5,
        courseAccuracy: 0.05)
}

@Suite struct RouteKitTests {
    @Test func haversineKnownDistance() {
        // Madrid Sol → Retiro (~1.55 km).
        let d = RouteKit.distance(lat1: 40.4168, lon1: -3.7038, lat2: 40.4153, lon2: -3.6845)
        #expect(abs(d - 1640) < 120)
    }

    @Test func totalDistanceSkipsTeleports() {
        var pts = (0..<10).map { i in
            fix(t: Double(i), lat: 40.0 + Double(i) * 0.00003, lon: -3.7)
        }
        // Teleport: 1 km jump in 1 s must be excluded.
        pts.append(fix(t: 10, lat: 40.01, lon: -3.7))
        let route = RouteKit.route(from: pts)
        let d = RouteKit.totalDistance(route)
        #expect(d > 25 && d < 40)  // 9 × ~3.3 m
    }

    @Test func flaggedAndInaccurateFixesExcluded() {
        var bad = fix(t: 0, lat: 40, lon: -3.7)
        bad.flagged = true
        var wide = fix(t: 1, lat: 40, lon: -3.7)
        wide.horizontalAccuracy = 50
        let route = RouteKit.route(from: [bad, wide, fix(t: 2, lat: 40, lon: -3.7)])
        #expect(route.count == 1)
    }

    @Test func simplifyKeepsEndpointsAndShape() {
        // L-shaped path with dense points.
        var pts = [RouteKit.RoutePoint]()
        for i in 0...100 {
            pts.append(
                .init(
                    sensorTime: Double(i), latitude: 40 + Double(i) * 0.00001, longitude: -3.7,
                    speed: 3))
        }
        for i in 1...100 {
            pts.append(
                .init(
                    sensorTime: Double(100 + i), latitude: 40.001,
                    longitude: -3.7 + Double(i) * 0.00001, speed: 3))
        }
        let simplified = RouteKit.simplify(pts, tolerance: 5)
        #expect(simplified.count < 12)
        #expect(simplified.first == pts.first)
        #expect(simplified.last == pts.last)
    }

    @Test func spotClusteringFindsDwell() {
        var pts = [RouteKit.RoutePoint]()
        // 15 minutes within ~20 m (a spot), then a cruise away.
        for i in 0..<900 {
            pts.append(
                .init(
                    sensorTime: Double(i),
                    latitude: 40 + Double(i % 7) * 0.00002,
                    longitude: -3.7 + Double(i % 5) * 0.00002, speed: 1))
        }
        for i in 0..<300 {
            pts.append(
                .init(
                    sensorTime: Double(900 + i), latitude: 40.0 + 0.0002 + Double(i) * 0.0001,
                    longitude: -3.7, speed: 5))
        }
        let spots = RouteKit.spots(in: pts, radius: 75, minDwell: 600)
        #expect(spots.count == 1)
        #expect(spots[0].dwellSeconds >= 800)
    }
}
