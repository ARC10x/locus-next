import CoreLocation
import XCTest

final class RouteCheckpointTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)

    private var profile: DriveProfile {
        var p = DriveProfile()
        p.speedSource = .fixed
        p.fixedSpeed = 5.04
        p.units = .kph
        p.speedJitter = 0
        p.gpsNoiseMetres = 0
        p.laneOffsetMetres = 0
        p.traffic = .none
        return p
    }

    private var plan: RoutePlan {
        let points = stride(from: 0.0, through: 32.0, by: 8.0).map { d in
            RoutePlan.Point(coordinate: Geo.offset(origin, east: d, north: 0), distance: d,
                            course: 90, limit: 1.4, ceiling: 1.4,
                            isStop: d == 16 || d == 32, dwell: d == 16 ? 4 : 0)
        }
        return RoutePlan(points: points, totalDistance: 32, usesEstimatedLimits: false)
    }

    func testRestoreDuringDwellKeepsRemainingWaitAndServedStops() throws {
        let walker = DriveWalker(plan: plan, profile: profile)
        for _ in 0..<100 {
            _ = walker.step(dt: 0.25)
            if walker.snapshot.dwellRemaining > 0 { break }
        }
        XCTAssertGreaterThan(walker.snapshot.dwellRemaining, 0)
        _ = walker.step(dt: 0.25)
        let decoded = try JSONDecoder().decode(DriveWalkerSnapshot.self, from: JSONEncoder().encode(walker.snapshot))
        let restored = DriveWalker(plan: plan, profile: profile, snapshot: decoded)
        XCTAssertEqual(restored.snapshot, walker.snapshot)
        for _ in 0..<200 {
            let a = walker.step(dt: 0.25)
            let b = restored.step(dt: 0.25)
            XCTAssertEqual(a?.distanceTravelled, b?.distanceTravelled)
            XCTAssertEqual(a?.elapsed, b?.elapsed)
            XCTAssertEqual(a?.isStopped, b?.isStopped)
        }
        XCTAssertTrue(restored.isFinished)
    }

    func testChosenStopsAndDirectionSurviveSerialization() throws {
        let saved = SavedRoutePlan(plan.reversed())
        let decoded = try JSONDecoder().decode(SavedRoutePlan.self, from: JSONEncoder().encode(saved))
        let restored = try XCTUnwrap(decoded.restored)
        XCTAssertEqual(SavedRoutePlan(restored), saved)
    }

    func testInvalidSnapshotFallsBackToSafeStartDistance() {
        let invalid = DriveWalkerSnapshot(distance: 1000, speed: -1, elapsed: 0,
                                          dwellRemaining: 0, servedStops: [100], trafficFactor: 1)
        XCTAssertFalse(invalid.isValid(for: plan))
        let walker = DriveWalker(plan: plan, profile: profile, startDistance: 8, snapshot: invalid)
        XCTAssertEqual(walker.snapshot.distance, 8)
        XCTAssertEqual(walker.snapshot.speed, 0)
    }

    func testExistingResumeFileStillLoadsWithoutNextFields() throws {
        let legacy = """
        {"routeName":"Walk","coordinates":[{"latitude":48.85,"longitude":2.35},{"latitude":48.851,"longitude":2.35}],
         "expectedTravelTime":80,"distance":111,"roads":[],"overrides":[],"travelled":4,"lap":1,"savedAt":760000000}
        """
        let state = try JSONDecoder().decode(RouteResumeState.self, from: Data(legacy.utf8))
        XCTAssertNil(state.scenarioID)
        XCTAssertNil(state.walkerSnapshot)
        XCTAssertTrue(state.isWorthResuming, "Short interrupted walks must remain resumable")
    }

    func testFullCheckpointKeepsModeProfileLapAndPause() throws {
        var state = RouteResumeState(routeName: "Walk", coordinates: plan.points.map(\.coordinate).codable,
                                     expectedTravelTime: 30, distance: 32, overrides: [], travelled: 16,
                                     lap: 2, profileID: profile.id)
        state.scenarioID = UUID()
        state.travelMode = .walk
        state.profileSnapshot = profile
        state.planSnapshot = SavedRoutePlan(plan)
        state.paused = true
        let restored = try JSONDecoder().decode(RouteResumeState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }
}
