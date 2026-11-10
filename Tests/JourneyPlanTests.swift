import CoreLocation
import XCTest

final class JourneyPlanTests: XCTestCase {
    func testReturnFlightAndHomeStagesAreContinuous() throws {
        var config = OrlyDublinScenario.returnConfiguration
        let stand = config.points[5]
        let home = Coordinate2D(Geo.offset(stand.clLocation, east: 300, north: 0))
        config.arrivalGroundStages = [.wait(at: stand, seconds: 60, phase: .transfer),
            FlightGroundStage(phase: .drive, samples: [
                FlightGroundSample(point: stand, seconds: 0, speed: 0),
                FlightGroundSample(point: home, seconds: 120, speed: 0)])]
        let plan = try FlightPlan(config)
        XCTAssertEqual(plan.legs.last?.phase, .drive)
        XCTAssertLessThan(Geo.distance(plan.fix(at: plan.duration).coordinate, home.clLocation), 0.01)
        for (a, b) in zip(plan.legs, plan.legs.dropFirst()) {
            XCTAssertLessThan(Geo.distance(a.to, b.from), 2)
        }
        XCTAssertEqual(config.points.first, OrlyDublinScenario.configuration.points.last)
    }

    func testReturnRejectsDisconnectedHomeStages() {
        var config = OrlyDublinScenario.returnConfiguration
        config.arrivalGroundStages = [.wait(at: config.points[0], seconds: 60, phase: .transfer)]
        XCTAssertThrowsError(try FlightPlan(config))
    }

    func testScenarioImportRoundTripClearsOldSchedule() throws {
        var config = OrlyDublinScenario.configuration
        config.homeDepartureAt = Date()
        config.groundStages = [.wait(at: config.points[0], seconds: 60, phase: .waiting)]
        let file = ScenarioFile(name: "Orly Dublin", configuration: config)
        let decoded = try ScenarioFile.decode(JSONEncoder().encode(file))
        XCTAssertNil(decoded.configuration.homeDepartureAt)
        XCTAssertEqual(decoded.configuration.groundStages?.count, 0)
        XCTAssertEqual(decoded.name, "Orly Dublin")
        XCTAssertNoThrow(try FlightPlan(decoded.configuration))
    }

    func testScenarioRejectsUnknownVersionInvalidGeometryAndOversize() throws {
        var file = ScenarioFile(name: "Test", configuration: OrlyDublinScenario.configuration)
        file.formatVersion = 99
        XCTAssertThrowsError(try ScenarioFile.decode(JSONEncoder().encode(file)))
        file.formatVersion = 1
        file.configuration.points = []
        XCTAssertThrowsError(try ScenarioFile.decode(JSONEncoder().encode(file)))
        XCTAssertThrowsError(try ScenarioFile.decode(Data(repeating: 32, count: 8_000_001)))
    }

    func testScheduledWaitUsesDeadlineWithoutSkippingMovement() throws {
        var config = OrlyDublinScenario.configuration
        let now = Date(timeIntervalSince1970: 10000)
        config.homeDepartureAt = now.addingTimeInterval(60)
        config.groundStages = [.wait(at: config.points[0], seconds: 120, phase: .waiting)]
        let plan = try FlightPlan(config)
        XCTAssertEqual(plan.elapsedAfterWaiting(10, now: now), 60)
        XCTAssertEqual(plan.elapsedAfterWaiting(10, now: now.addingTimeInterval(3600)), 120)
        XCTAssertEqual(plan.elapsedAfterWaiting(130, now: now.addingTimeInterval(3600)), 130)
        XCTAssertEqual(plan.elapsedAfterWaiting(70, now: now.addingTimeInterval(-3600)), 70)
        let restored = try JSONDecoder().decode(FlightConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.homeDepartureAt, config.homeDepartureAt)
    }

    func testLegacyWaitKeepsItsSavedElapsedTime() throws {
        var config = OrlyDublinScenario.configuration
        config.groundStages = [.wait(at: config.points[0], seconds: 120, phase: .waiting)]
        let plan = try FlightPlan(config)
        XCTAssertEqual(plan.elapsedAfterWaiting(10, now: Date()), 10)
    }

    func testSubmetreInterpolationMovesAlongWalkingAndTaxiCurves() {
        let a = CLLocationCoordinate2D(latitude: 48.7, longitude: 2.3)
        let b = Geo.offset(a, east: 1, north: 0)
        let middle = FlightPlan.interpolate(a, b, fraction: 0.5)
        XCTAssertEqual(Geo.distance(a, middle), Geo.distance(a, b) / 2, accuracy: 0.01)
    }
    func testRotationDoesNotLiftAircraftAtTaxiSpeed() throws {
        let plan = try FlightPlan(OrlyDublinScenario.configuration)
        var time = 0.0
        for leg in plan.legs {
            if leg.phase == .takeoff {
                let early = plan.fix(at: time + leg.seconds * 0.5)
                XCTAssertEqual(early.altitude, 0)
                XCTAssertEqual(early.verticalSpeed, 0)
                let late = plan.fix(at: time + leg.seconds * 0.98)
                XCTAssertGreaterThan(late.altitude, 0)
                XCTAssertGreaterThan(late.speed, 70)
            }
            time += leg.seconds
        }
    }

    func testLongFlightsDoNotSpendAQuarterOfTheRouteClimbing() throws {
        var config = OrlyDublinScenario.configuration
        config.taxiIn = nil
        config.points[3] = OrlyDublinScenario.coordinate(40.64, -73.78)
        config.points[4] = Coordinate2D(FlightPlan.destination(config.points[3].clLocation, bearing: 275, metres: 3000))
        config.points[5] = Coordinate2D(FlightPlan.destination(config.points[4].clLocation, bearing: 0, metres: 300))
        let plan = try FlightPlan(config)
        let climb = try XCTUnwrap(plan.legs.first { $0.phase == .climb })
        XCTAssertLessThan(climb.seconds, 1800)
        XCTAssertLessThanOrEqual(climb.path!.length, 160001)
    }

    func testPresetHasCurvedAirPathAndGeographicRunwayEndpoints() throws {
        let config = OrlyDublinScenario.configuration, plan = try FlightPlan(config)
        let cruise = try XCTUnwrap(plan.legs.first { $0.phase == .cruise })
        XCTAssertGreaterThan(try XCTUnwrap(cruise.path).points.count, 40)
        XCTAssertGreaterThan(cruise.path!.length, Geo.distance(cruise.from, cruise.to))
        for phase in [FlightPhase.taxiOut, .taxiIn] {
            XCTAssertGreaterThan(try XCTUnwrap(plan.legs.first { $0.phase == phase }?.path).points.count, 20)
        }
        var clock = 0.0
        for leg in plan.legs.dropLast() {
            clock += leg.seconds
            let a = plan.fix(at: clock - 0.00001), b = plan.fix(at: clock + 0.00001)
            XCTAssertLessThan(Geo.distance(a.coordinate, b.coordinate), 0.02)
            XCTAssertEqual(a.altitude, b.altitude, accuracy: 0.01)
        }
    }

    func testScheduleChoosesNextFeasibleDepartureInParisTime() throws {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-11-09T06:00:00Z")! // 07:00 Paris
        let result = try JourneySchedule.next(now: now, hour: 8, minute: 0, road: 7200,
            preparation: 2700, transfer: 1200, boarding: 1500, margin: 900)
        XCTAssertEqual(result.departure, formatter.date(from: "2026-11-10T07:00:00Z")!)
        XCTAssertGreaterThan(result.leaveHome, now)
        XCTAssertEqual(result.airport.timeIntervalSince(result.leaveHome), 7200)
        XCTAssertEqual(result.departure.timeIntervalSince(result.board), 1500)
        XCTAssertThrowsError(try JourneySchedule.next(now: now, hour: 24, minute: 0, road: 0,
            preparation: 0, transfer: 0, boarding: 0, margin: 0))
    }

    func testScheduleCrossesDaylightSavingWithoutFixed24HourArithmetic() throws {
        let f = ISO8601DateFormatter()
        let result = try JourneySchedule.next(now: f.date(from: "2027-03-27T22:00:00Z")!, hour: 8, minute: 0,
            road: 3600, preparation: 1800, transfer: 600, boarding: 900, margin: 0)
        XCTAssertEqual(result.departure, f.date(from: "2027-03-28T06:00:00Z")!)
    }

    func testGroundStagesRoundTripAndRejectGapsOrInvalidTimes() throws {
        var config = OrlyDublinScenario.configuration
        let stand = config.points[0]
        config.groundStages = [.wait(at: stand, seconds: 120, phase: .boarding)]
        let original = try FlightPlan(config)
        let restored = try FlightPlan(JSONDecoder().decode(FlightConfiguration.self, from: JSONEncoder().encode(config)))
        XCTAssertEqual(restored.duration, original.duration)
        XCTAssertEqual(restored.fix(at: 60).phase, .boarding)
        config.groundStages![0].samples[1].seconds = 0
        XCTAssertThrowsError(try FlightPlan(config))
        config.groundStages = [.wait(at: config.points[5], seconds: 120, phase: .boarding)]
        XCTAssertThrowsError(try FlightPlan(config))
        config.groundOnly = true
        let walk = try FlightPlan(config)
        XCTAssertEqual(walk.duration, 120)
        XCTAssertEqual(walk.fix(at: 121).phase, .arrived)
        XCTAssertEqual(Geo.distance(walk.fix(at: 121).coordinate, config.points[5].clLocation), 0)
    }
}
