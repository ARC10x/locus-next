import CoreLocation
import XCTest

final class WalkingRegressionTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)

    private var walkingProfile: DriveProfile {
        var p = DriveProfile()
        p.speedSource = .fixed
        p.units = .kph
        p.fixedSpeed = 5.04
        p.traffic = .none
        p.speedJitter = 0
        p.gpsNoiseMetres = 0
        p.laneOffsetMetres = 0
        p.stopAtJunctions = false
        return p
    }

    func testWalkingReachesTheExactEndAtEverySupportedFixRate() {
        for dt in [0.25, 0.5, 1.0, 2.0] {
            let end = Geo.offset(origin, east: 0, north: 32)
            let plan = RouteSimulator.plan(coordinates: [origin, end], profile: walkingProfile, mode: .walk)
            let walker = DriveWalker(plan: plan, profile: walkingProfile)
            var last: DriveFix?
            for _ in 0..<Int(90 / dt) {
                guard let fix = walker.step(dt: dt) else { break }
                last = fix
            }
            XCTAssertTrue(walker.isFinished, "Walking stalled at dt=\(dt)")
            XCTAssertEqual(last?.distanceRemaining ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(last?.speed ?? -1, 0)
            XCTAssertLessThan(Geo.distance(last?.coordinate ?? origin, end), 0.1)
        }
    }

    func testWalkingDoesNotInheritRandomCarJunctionStops() {
        var p = walkingProfile
        p.stopAtJunctions = true
        p.junctionStopChance = 1
        let corner = Geo.offset(origin, east: 0, north: 150)
        let end = Geo.offset(corner, east: 150, north: 0)
        let plan = RouteSimulator.plan(coordinates: [origin, corner, end], profile: p, mode: .walk)
        XCTAssertEqual(plan.points.filter(\.isStop).count, 1, "Only arrival should stop this walk")
    }

    func testIntermediateStopDwellsAndThenContinues() {
        let p = walkingProfile
        let points = stride(from: 0.0, through: 32.0, by: 8.0).map { distance in
            RoutePlan.Point(coordinate: Geo.offset(origin, east: 0, north: distance),
                            distance: distance, course: 0, limit: 1.4, ceiling: 1.4,
                            isStop: distance == 16 || distance == 32, dwell: distance == 16 ? 3 : 0)
        }
        let walker = DriveWalker(plan: RoutePlan(points: points, totalDistance: 32, usesEstimatedLimits: false), profile: p)
        var stoppedSeconds = 0.0
        for _ in 0..<400 {
            guard let fix = walker.step(dt: 0.25) else { break }
            if fix.isStopped && fix.distanceTravelled == 16 { stoppedSeconds += 0.25 }
        }
        XCTAssertTrue(walker.isFinished)
        XCTAssertGreaterThanOrEqual(stoppedSeconds, 3)
        XCTAssertLessThan(stoppedSeconds, 4)
    }
}
