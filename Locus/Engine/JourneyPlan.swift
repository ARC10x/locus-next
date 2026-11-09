import CoreLocation
import Foundation

/// Distance-parameterized path. Rounded corners preserve runway endpoints.
struct FlightPolyline {
    let points: [CLLocationCoordinate2D]
    let distances: [Double]
    var length: Double { distances.last ?? 0 }
    init(_ points: [CLLocationCoordinate2D]) {
        self.points = points
        var distances = [0.0]
        for i in 1..<max(1, points.count) {
            distances.append(distances.last! + Geo.distance(points[i - 1], points[i]))
        }
        self.distances = distances
    }
    func position(_ distance: Double) -> CLLocationCoordinate2D {
        guard let first = points.first else { return CLLocationCoordinate2D() }
        if distance <= 0 { return first }
        if distance >= length { return points.last! }
        var low = 1, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if distances[mid] < distance { low = mid + 1 } else { high = mid }
        }
        let span = distances[low] - distances[low - 1]
        return FlightPlan.interpolate(points[low - 1], points[low], fraction: span > 0 ? (distance - distances[low - 1]) / span : 0)
    }
    func slice(_ start: Double, _ end: Double) -> FlightPolyline {
        var result = [position(start)]
        for i in points.indices where distances[i] > start && distances[i] < end { result.append(points[i]) }
        result.append(position(end))
        return FlightPolyline(result)
    }
    static func rounded(_ points: [CLLocationCoordinate2D], trim: Double) -> FlightPolyline {
        guard points.count > 2 else { return FlightPolyline(points) }
        var result = [points[0]]
        for i in 1..<(points.count - 1) {
            let a = points[i - 1], b = points[i], c = points[i + 1]
            let incoming = Geo.distance(a, b), outgoing = Geo.distance(b, c)
            guard incoming > 0.1, outgoing > 0.1 else { continue }
            let amount = min(trim, min(incoming, outgoing) * 0.4)
            let entry = FlightPlan.interpolate(b, a, fraction: amount / incoming)
            let exit = FlightPlan.interpolate(b, c, fraction: amount / outgoing)
            result.append(entry)
            for step in 1...40 {
                let t = Double(step) / 40
                let left = FlightPlan.interpolate(entry, b, fraction: t)
                let right = FlightPlan.interpolate(b, exit, fraction: t)
                result.append(FlightPlan.interpolate(left, right, fraction: t))
            }
        }
        result.append(points.last!)
        return FlightPolyline(result)
    }
}

struct FlightGroundSample: Codable, Equatable {
    var point: Coordinate2D
    var seconds: Double
    var speed: Double
}

struct FlightGroundStage: Codable, Equatable {
    var phase: FlightPhase
    var samples: [FlightGroundSample]
    var duration: Double { samples.last?.seconds ?? 0 }
    static func wait(at point: Coordinate2D, seconds: Double, phase: FlightPhase) -> Self {
        Self(phase: phase, samples: [FlightGroundSample(point: point, seconds: 0, speed: 0),
                                    FlightGroundSample(point: point, seconds: max(1, seconds), speed: 0)])
    }
}

/// Daily fictional departure, expressed in Paris time, independent of phone timezone.
struct JourneySchedule {
    let leaveHome: Date
    let airport: Date
    let board: Date
    let departure: Date
    static func next(now: Date, hour: Int, minute: Int, road: Double, preparation: Double,
                     transfer: Double, boarding: Double, margin: Double) throws -> Self {
        let intervals = [road, preparation, transfer, boarding, margin]
        guard (0...23).contains(hour), (0...59).contains(minute),
              intervals.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 86400 }) else {
            throw FlightPlan.Invalid(message: "Horaires ou durées invalides.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let lead = intervals.reduce(0, +)
        guard let departure = calendar.nextDate(after: now.addingTimeInterval(lead),
            matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime,
            repeatedTimePolicy: .first) else { throw FlightPlan.Invalid(message: "Horaire introuvable.") }
        let leave = departure.addingTimeInterval(-lead)
        return Self(leaveHome: leave, airport: leave.addingTimeInterval(road),
                    board: departure.addingTimeInterval(-boarding), departure: departure)
    }
}

/// Fixed geographic demo, not an operating airline schedule or ATC clearance.
enum OrlyDublinScenario {
    static let crewAddress = "Transavia France, 7 avenue de l’Union, 94310 Orly, France"
    static func coordinate(_ lat: Double, _ lon: Double) -> Coordinate2D {
        Coordinate2D(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }
    // OurAirports runway endpoints; illustrative apron/taxi paths must be labelled as such.
    static var configuration: FlightConfiguration {
        var value = FlightConfiguration()
        let departure = coordinate(48.7274017334, 2.4020700455) // Orly 25
        let departureEnd = coordinate(48.7193984985, 2.3585898876)
        let arrival = coordinate(53.4203, -6.25058) // Dublin 28L
        let arrivalEnd = coordinate(53.42243, -6.29007)
        let stand = coordinate(48.7250, 2.3670)
        let destination = coordinate(53.4262, -6.2588)
        value.points = [stand, departure, departureEnd, arrival, arrivalEnd, destination]
        value.taxiOut = [stand, coordinate(48.7244, 2.3710), coordinate(48.7256, 2.3800),
                         coordinate(48.7281, 2.3970), coordinate(48.7280, 2.4024), departure]
        value.taxiIn = [arrivalEnd, coordinate(53.4230, -6.2900), coordinate(53.4253, -6.2840),
                        coordinate(53.4243, -6.2670), coordinate(53.4253, -6.2610), destination]
        value.airWaypoints = [coordinate(49.15, 1.20), coordinate(49.70, -0.65),
                              coordinate(50.55, -2.10), coordinate(51.65, -3.60),
                              coordinate(52.65, -4.35), coordinate(53.37, -5.25)]
        return value
    }
}
