import CoreLocation
import Foundation

/// Evidence from Core Location is separate from an acknowledged DVT command.
/// Pure value state so stale, inaccurate and unrelated fixes are testable.
struct SimulationVerification {
    struct Command {
        let coordinate: CLLocationCoordinate2D
        let sentAt: Date
    }

    static let freshness: TimeInterval = 10
    private(set) var commands: [Command] = []
    private(set) var confirmedAt: Date?

    mutating func reset() {
        commands.removeAll()
        confirmedAt = nil
    }

    mutating func sent(_ coordinate: CLLocationCoordinate2D, at date: Date) {
        commands.removeAll { date.timeIntervalSince($0.sentAt) > Self.freshness }
        commands.append(Command(coordinate: coordinate, sentAt: date))
        if commands.count > 80 { commands.removeFirst(commands.count - 80) }
    }

    @discardableResult
    mutating func observe(coordinate: CLLocationCoordinate2D, timestamp: Date,
                          accuracy: Double, simulated: Bool?, now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        guard age >= -1, age <= Self.freshness,
              accuracy.isFinite, accuracy >= 0, accuracy <= 100,
              simulated == true else { return false }
        // A callback can lag a moving route. Compare it to commands preceding
        // that fix, never a future command or a coordinate from another session.
        let matches = commands.contains { command in
            let lag = timestamp.timeIntervalSince(command.sentAt)
            return lag >= 0 && lag <= Self.freshness
                && Geo.distance(command.coordinate, coordinate) <= max(15, accuracy)
        }
        guard matches else { return false }
        confirmedAt = max(confirmedAt ?? .distantPast, timestamp)
        return true
    }

    func isFresh(at now: Date) -> Bool {
        guard let confirmedAt else { return false }
        return (0...Self.freshness).contains(now.timeIntervalSince(confirmedAt))
    }
}

enum RecoverySchedule {
    /// Target offsets from detection; attempts never overlap. A slow attempt
    /// may make a later target impossible, in which case it starts afterwards.
    static let offsets: [TimeInterval] = [0, 5, 15]
}
