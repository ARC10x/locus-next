import CoreLocation
import Foundation

struct DriveWalkerSnapshot: Codable, Equatable, Sendable {
    var distance: Double
    var speed: Double
    var elapsed: Double
    var dwellRemaining: Double
    var servedStops: [Int]
    var trafficFactor: Double

    func isValid(for plan: RoutePlan) -> Bool {
        [distance, speed, elapsed, dwellRemaining, trafficFactor].allSatisfy(\.isFinite)
            && distance >= 0 && distance <= plan.totalDistance && speed >= 0
            && elapsed >= 0 && dwellRemaining >= 0 && (0.12...1.05).contains(trafficFactor)
            && servedStops.allSatisfy { plan.points.indices.contains($0) }
    }
}

/// Persist the chosen stops as well as geometry: rebuilding a random plan on
/// resume can turn an already-served corner into a new stop.
struct SavedRoutePlan: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        let coordinate: Coordinate2D
        let distance: Double
        let course: Double
        let limit: Double
        let ceiling: Double
        let isStop: Bool
        let dwell: Double
    }
    let points: [Point]
    let totalDistance: Double
    let usesEstimatedLimits: Bool

    init(_ plan: RoutePlan) {
        points = plan.points.map {
            Point(coordinate: Coordinate2D($0.coordinate), distance: $0.distance,
                  course: $0.course, limit: $0.limit, ceiling: $0.ceiling,
                  isStop: $0.isStop, dwell: $0.dwell)
        }
        totalDistance = plan.totalDistance
        usesEstimatedLimits = plan.usesEstimatedLimits
    }

    var restored: RoutePlan? {
        guard points.count >= 2, totalDistance.isFinite, totalDistance > 0,
              points.first?.distance == 0, points.last?.distance == totalDistance else { return nil }
        var previous = -1.0
        for p in points {
            guard CLLocationCoordinate2DIsValid(p.coordinate.clLocation),
                  [p.distance, p.course, p.limit, p.ceiling, p.dwell].allSatisfy(\.isFinite),
                  p.distance > previous, p.ceiling >= 0, p.dwell >= 0 else { return nil }
            previous = p.distance
        }
        return RoutePlan(points: points.map {
            RoutePlan.Point(coordinate: $0.coordinate.clLocation, distance: $0.distance,
                            course: $0.course, limit: $0.limit, ceiling: $0.ceiling,
                            isStop: $0.isStop, dwell: $0.dwell)
        }, totalDistance: totalDistance, usesEstimatedLimits: usesEstimatedLimits)
    }
}
