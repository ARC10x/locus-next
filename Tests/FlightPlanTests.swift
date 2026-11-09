import CoreLocation
import XCTest

final class FlightPlanTests: XCTestCase {
    private func configuration() -> FlightConfiguration {
        var config = FlightConfiguration()
        let departure = CLLocationCoordinate2D(latitude: 48.9, longitude: 2.3)
        let arrival = CLLocationCoordinate2D(latitude: 45.7, longitude: 5.0)
        config.points = [
            Geo.offset(departure, east: -300, north: 300), departure,
            Geo.offset(departure, east: 2000, north: 0), arrival,
            Geo.offset(arrival, east: 2200, north: 0), Geo.offset(arrival, east: 2400, north: 300)
        ].map(Coordinate2D.init)
        return config
    }

    func testEveryAircraftCompletesAllPhasesWithinSpeedLimit() throws {
        for aircraft in AircraftProfile.allCases {
            var config = configuration()
            config.aircraft = aircraft
            config.cruiseKPH = aircraft.cruiseKPH
            let plan = try FlightPlan(config)
            XCTAssertEqual(plan.legs.map(\.phase), [.taxiOut, .alignment, .takeoff, .climb, .cruise, .descent, .approach, .landing, .taxiIn])
            for t in stride(from: 0.0, through: plan.duration, by: 1) {
                let fix = plan.fix(at: t)
                XCTAssertTrue(CLLocationCoordinate2DIsValid(fix.coordinate))
                XCTAssertGreaterThanOrEqual(fix.speed, 0)
                XCTAssertLessThanOrEqual(fix.speed, config.cruiseKPH / 3.6 + 0.001)
                XCTAssertGreaterThanOrEqual(fix.altitude, 0)
                XCTAssertLessThanOrEqual(fix.altitude, config.altitudeMetres)
            }
            let end = plan.fix(at: plan.duration + 10)
            XCTAssertEqual(end.phase, .arrived)
            XCTAssertEqual(end.speed, 0)
            XCTAssertEqual(Geo.distance(end.coordinate, config.points[5].clLocation), 0, accuracy: 0.001)
        }
    }

    func testPhaseBoundariesHaveContinuousPositionAltitudeAndSpeed() throws {
        let plan = try FlightPlan(configuration())
        var time = 0.0
        for leg in plan.legs.dropLast() {
            time += leg.seconds
            let before = plan.fix(at: time - 0.00001), after = plan.fix(at: time + 0.00001)
            XCTAssertLessThan(Geo.distance(before.coordinate, after.coordinate), 0.02)
            XCTAssertEqual(before.speed, after.speed, accuracy: 0.01)
            XCTAssertEqual(before.altitude, after.altitude, accuracy: 0.01)
        }
    }

    func testImposedDurationCannotSlowDownFlightPhases() throws {
        var config = configuration()
        let original = try FlightPlan(config)
        config.durationMinutes = original.duration * 2 / 60
        XCTAssertThrowsError(try FlightPlan(config))
        config.durationMinutes = original.duration / 120
        XCTAssertThrowsError(try FlightPlan(config))
        config.durationMinutes = 0
        let automatic = try FlightPlan(config)
        var elapsed = 0.0
        for leg in automatic.legs {
            if leg.phase == .climb {
                XCTAssertGreaterThanOrEqual(automatic.fix(at: elapsed + 0.01).speed, 78)
            }
            if leg.phase == .cruise {
                let fix = automatic.fix(at: elapsed + leg.seconds / 2)
                XCTAssertEqual(fix.speed * 3.6, config.cruiseKPH, accuracy: 0.001)
                let later = automatic.fix(at: elapsed + leg.seconds / 2 + 1)
                XCTAssertEqual(Geo.distance(fix.coordinate, later.coordinate), fix.speed, accuracy: 0.1)
            }
            elapsed += leg.seconds
        }
    }

    func testRejectsInvalidInputsAndRunways() {
        var config = configuration()
        config.cruiseKPH = .nan
        XCTAssertThrowsError(try FlightPlan(config))
        config = configuration(); config.points.removeLast()
        XCTAssertThrowsError(try FlightPlan(config))
        config = configuration(); config.points[2] = config.points[1]
        XCTAssertThrowsError(try FlightPlan(config))
        config = configuration(); config.points[0].latitude = 91
        XCTAssertThrowsError(try FlightPlan(config))
        config = configuration(); config.cruiseKPH = 1001
        XCTAssertThrowsError(try FlightPlan(config))
        config = configuration(); config.durationMinutes = -.infinity
        XCTAssertThrowsError(try FlightPlan(config))
    }

    func testDateLineUsesShortArcAndBothEndpointsAreExact() {
        let a = CLLocationCoordinate2D(latitude: 10, longitude: 179)
        let b = CLLocationCoordinate2D(latitude: 10, longitude: -179)
        let midpoint = FlightPlan.interpolate(a, b, fraction: 0.5)
        XCTAssertGreaterThan(abs(midpoint.longitude), 179.9)
        XCTAssertEqual(Geo.distance(FlightPlan.interpolate(a, b, fraction: 0), a), 0)
        XCTAssertEqual(Geo.distance(FlightPlan.interpolate(a, b, fraction: 1), b), 0)
    }

    func testTakeoffAndApproachFollowSelectedRunways() throws {
        let config = configuration(), plan = try FlightPlan(config)
        let takeoff = try XCTUnwrap(plan.legs.first { $0.phase == .takeoff })
        let climb = try XCTUnwrap(plan.legs.first { $0.phase == .climb })
        let firstClimbPoints = try XCTUnwrap(climb.path).points
        XCTAssertEqual(Geo.angleDelta(Geo.bearing(from: takeoff.from, to: takeoff.to),
                                     Geo.bearing(from: firstClimbPoints[0], to: firstClimbPoints[1])), 0, accuracy: 0.1)
        let approach = try XCTUnwrap(plan.legs.first { $0.phase == .approach })
        let landing = try XCTUnwrap(plan.legs.first { $0.phase == .landing })
        XCTAssertEqual(Geo.angleDelta(Geo.bearing(from: approach.from, to: approach.to),
                                     Geo.bearing(from: landing.from, to: landing.to)), 0, accuracy: 0.3)
    }

    func testCheckpointRoundTripReconstructsSamePosition() throws {
        let config = configuration(), plan = try FlightPlan(config)
        let checkpoint = FlightCheckpoint(configuration: config, elapsed: plan.duration * 0.6, savedAt: Date())
        let restored = try JSONDecoder().decode(FlightCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        let resumed = try FlightPlan(restored.configuration).fix(at: restored.elapsed)
        XCTAssertEqual(Geo.distance(plan.fix(at: checkpoint.elapsed).coordinate, resumed.coordinate), 0, accuracy: 0.001)
    }

    func testSpeedUnitConversions() {
        XCTAssertEqual(FlightSpeedUnit.kph.value(100), 360)
        XCTAssertEqual(FlightSpeedUnit.knots.value(1852.0 / 3600), 1, accuracy: 0.00001)
        XCTAssertEqual(FlightSpeedUnit.mph.value(0.44704), 1, accuracy: 0.00001)
    }

    func testStartupProbeIsOneBoundedMovementAlongThePlan() throws {
        let plan = try FlightPlan(configuration())
        for elapsed in [0.0, plan.duration * 0.4, plan.duration - 1] {
            let probe = try XCTUnwrap(plan.startupProbe(at: elapsed))
            XCTAssertGreaterThan(probe.elapsed, elapsed)
            XCTAssertLessThanOrEqual(probe.elapsed - elapsed, 15)
            XCTAssertLessThanOrEqual(Geo.distance(plan.fix(at: elapsed).coordinate, probe.coordinate), 5.00001)
            XCTAssertEqual(Geo.distance(plan.fix(at: probe.elapsed).coordinate, probe.coordinate), 0)
        }
        XCTAssertNil(plan.startupProbe(at: plan.duration))
        XCTAssertNil(plan.startupProbe(at: .nan))
        XCTAssertNil(plan.startupProbe(at: -1))
    }

    func testStartupProbeHandlesTerminalOnRunwayWithoutSkippingFarAhead() throws {
        var config = configuration()
        config.points[0] = config.points[1]
        let plan = try FlightPlan(config)
        let probe = try XCTUnwrap(plan.startupProbe(at: 0))
        XCTAssertEqual(probe.phase, .takeoff)
        XCTAssertLessThanOrEqual(Geo.distance(config.points[0].clLocation, probe.coordinate), 5.00001)
    }
}
