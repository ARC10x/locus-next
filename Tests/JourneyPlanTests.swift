import CoreLocation
import XCTest

final class JourneyPlanTests: XCTestCase {
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
