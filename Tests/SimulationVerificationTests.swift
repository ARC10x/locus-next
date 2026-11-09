import CoreLocation
import XCTest

final class SimulationVerificationTests: XCTestCase {
    let position = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)
    let sentAt = Date(timeIntervalSince1970: 1_000)

    func testAcknowledgementAloneDoesNotConfirmSimulation() {
        var evidence = SimulationVerification()
        evidence.sent(position, at: sentAt)
        XCTAssertFalse(evidence.isFresh(at: sentAt))
    }

    func testRejectsCachedRealImpreciseAndFutureFixes() {
        for (offset, accuracy, source) in [(-1.0, 5.0, true), (1, -1, true),
                                          (1, 500, true), (1, 5, false), (30, 5, true)] {
            var evidence = SimulationVerification()
            evidence.sent(position, at: sentAt)
            XCTAssertFalse(evidence.observe(coordinate: position, timestamp: sentAt.addingTimeInterval(offset),
                                             accuracy: accuracy, simulated: source, now: sentAt.addingTimeInterval(2)))
        }
    }

    func testConfirmationExpiresAndCannotCrossSessions() {
        var evidence = SimulationVerification()
        evidence.sent(position, at: sentAt)
        XCTAssertTrue(evidence.observe(coordinate: position, timestamp: sentAt.addingTimeInterval(1),
                                       accuracy: 5, simulated: true, now: sentAt.addingTimeInterval(1)))
        XCTAssertTrue(evidence.isFresh(at: sentAt.addingTimeInterval(2)))
        XCTAssertFalse(evidence.isFresh(at: sentAt.addingTimeInterval(12)))
        evidence.reset()
        XCTAssertFalse(evidence.observe(coordinate: position, timestamp: sentAt.addingTimeInterval(2),
                                        accuracy: 5, simulated: true, now: sentAt.addingTimeInterval(2)))
    }

    func testUnrelatedSimulatedPositionDoesNotConfirm() {
        var evidence = SimulationVerification()
        evidence.sent(position, at: sentAt)
        XCTAssertFalse(evidence.observe(coordinate: Geo.offset(position, east: 500, north: 0),
                                        timestamp: sentAt.addingTimeInterval(1), accuracy: 5,
                                        simulated: true, now: sentAt.addingTimeInterval(1)))
    }
}
