import CoreLocation
import Foundation

/// Illustrative presets, not certified aircraft performance or live flight data.
enum AircraftProfile: String, CaseIterable, Codable, Identifiable {
    case b737, a320, a350, b777, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .b737: return "Boeing 737-800"
        case .a320: return "Airbus A320"
        case .a350: return "Airbus A350"
        case .b777: return "Boeing 777"
        case .custom: return "Personnalisé"
        }
    }
    var cruiseKPH: Double {
        switch self { case .b737: return 840; case .a320: return 830
        case .a350: return 900; case .b777: return 890; case .custom: return 800 }
    }
}

enum FlightPhase: String, Codable, CaseIterable {
    case taxiOut, alignment, takeoff, climb, cruise, descent, approach, landing, taxiIn, arrived
    var title: String {
        switch self {
        case .taxiOut: return "Roulage départ"
        case .alignment: return "Alignement"
        case .takeoff: return "Décollage"
        case .climb: return "Montée"
        case .cruise: return "Croisière"
        case .descent: return "Descente"
        case .approach: return "Approche finale"
        case .landing: return "Atterrissage"
        case .taxiIn: return "Roulage arrivée"
        case .arrived: return "Arrivée au terminal"
        }
    }
}

enum FlightSpeedUnit: String, CaseIterable, Identifiable {
    case kph = "km/h", mph = "mph", knots = "KTS"
    var id: String { rawValue }
    func value(_ metresPerSecond: Double) -> Double {
        switch self { case .kph: return metresPerSecond * 3.6
        case .mph: return metresPerSecond / 0.44704; case .knots: return metresPerSecond / (1852.0 / 3600.0) }
    }
}

struct FlightConfiguration: Codable, Equatable {
    var aircraft: AircraftProfile = .b737
    var cruiseKPH: Double = 840
    var altitudeMetres: Double = 11000
    var durationMinutes: Double = 0 // zero selects the model duration
    // Terminal departure, runway start/end, arrival threshold/end, terminal arrival.
    var points: [Coordinate2D] = []
    static let pointLabels = ["Terminal départ", "Début piste départ", "Fin piste départ",
                              "Seuil piste arrivée", "Fin piste arrivée", "Terminal arrivée"]
}

struct FlightFix {
    let coordinate: CLLocationCoordinate2D
    let phase: FlightPhase
    let speed: Double
    let altitude: Double
    let verticalSpeed: Double
    let course: Double
    let elapsed: Double
    let progress: Double
}

struct FlightPlan {
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Leg {
        let phase: FlightPhase
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        let startSpeed: Double
        let endSpeed: Double
        let startAltitude: Double
        let endAltitude: Double
        let seconds: Double
    }
    let configuration: FlightConfiguration
    let legs: [Leg]
    let duration: Double
    let timeStretch: Double

    init(_ config: FlightConfiguration) throws {
        guard config.points.count == 6,
              config.points.allSatisfy({ CLLocationCoordinate2DIsValid($0.clLocation) }),
              config.cruiseKPH.isFinite, (300...1000).contains(config.cruiseKPH),
              config.altitudeMetres.isFinite, (1000...13000).contains(config.altitudeMetres),
              config.durationMinutes.isFinite, (0...1440).contains(config.durationMinutes) else {
            throw Invalid(message: "Définissez les six points, une vitesse de 300 à 1 000 km/h et une altitude de 1 000 à 13 000 m.")
        }
        let p = config.points.map(\.clLocation)
        let departureLength = Geo.distance(p[1], p[2])
        let arrivalLength = Geo.distance(p[3], p[4])
        guard (500...6000).contains(departureLength), (500...6000).contains(arrivalLength),
              Geo.distance(p[0], p[1]) <= 15000, Geo.distance(p[4], p[5]) <= 15000,
              (20000...18000000).contains(Geo.distance(p[2], p[3])) else {
            throw Invalid(message: "Choisissez des pistes de 500 m à 6 km, des terminaux à moins de 15 km de leur piste et un vol de 20 à 18 000 km.")
        }
        let c = config.cruiseKPH / 3.6
        let airDistance = Geo.distance(p[2], p[3])
        let top = Self.destination(p[2], bearing: Geo.bearing(from: p[1], to: p[2]), metres: min(160000, airDistance * 0.2))
        let approach = Self.destination(p[3], bearing: Geo.bearing(from: p[4], to: p[3]), metres: min(15000, airDistance * 0.1))
        let descent = Self.interpolate(top, approach, fraction: 0.75)
        let approachHeight = min(500, Geo.distance(approach, p[3]) / 76 * 5)
        // Short flights cannot plausibly reach long-haul cruising altitude.
        let h = min(config.altitudeMetres, 15 + Geo.distance(p[2], top) / ((78 + c) / 2) * 12,
                    approachHeight + Geo.distance(descent, approach) / ((c + 80) / 2) * 10)
        var result: [Leg] = []
        func add(_ phase: FlightPhase, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                 _ v0: Double, _ v1: Double, _ h0: Double, _ h1: Double, dwell: Double = 0) {
            let length = Geo.distance(a, b)
            let seconds = dwell > 0 ? dwell : length / max(0.1, (v0 + v1) / 2)
            if seconds > 0.001 {
                result.append(Leg(phase: phase, from: a, to: b, startSpeed: v0, endSpeed: v1,
                                  startAltitude: h0, endAltitude: h1, seconds: seconds))
            }
        }
        add(.taxiOut, p[0], p[1], 0, 0, 0, 0, dwell: max(1, Geo.distance(p[0], p[1]) / 5))
        add(.alignment, p[1], p[1], 0, 0, 0, 0, dwell: 10)
        add(.takeoff, p[1], p[2], 0, 78, 0, 15)
        add(.climb, p[2], top, 78, c, 15, h)
        add(.cruise, top, descent, c, c, h, h)
        add(.descent, descent, approach, c, 80, h, approachHeight)
        add(.approach, approach, p[3], 80, 72, approachHeight, 0)
        add(.landing, p[3], p[4], 72, 0, 0, 0)
        add(.taxiIn, p[4], p[5], 0, 0, 0, 0, dwell: max(1, Geo.distance(p[4], p[5]) / 5))
        let minimum = result.reduce(0) { $0 + $1.seconds }
        let requested = config.durationMinutes * 60
        guard requested == 0 || requested >= minimum else {
            throw Invalid(message: "Durée trop courte pour cette distance et cette vitesse : minimum \(Int(ceil(minimum / 60))) minutes.")
        }
        configuration = config
        legs = result
        duration = requested > 0 ? requested : minimum
        timeStretch = duration / minimum
    }

    func fix(at seconds: Double) -> FlightFix {
        let elapsed = seconds.isFinite ? min(duration, max(0, seconds)) : 0
        if elapsed >= duration {
            return FlightFix(coordinate: legs.last!.to, phase: .arrived, speed: 0, altitude: 0,
                             verticalSpeed: 0, course: 0, elapsed: duration, progress: 1)
        }
        var remaining = elapsed / timeStretch
        for leg in legs {
            if remaining <= leg.seconds {
                let u = remaining / leg.seconds
                let taxi = leg.phase == .taxiOut || leg.phase == .taxiIn
                // Taxi uses smoothstep position: zero speed at both ends.
                let integral = (leg.startSpeed + leg.endSpeed) / 2
                let fraction = taxi ? u * u * (3 - 2 * u)
                    : (integral > 0 ? (leg.startSpeed * u + 0.5 * (leg.endSpeed - leg.startSpeed) * u * u) / integral : 0)
                let speed = taxi ? Geo.distance(leg.from, leg.to) / leg.seconds * 6 * u * (1 - u)
                    : leg.startSpeed + (leg.endSpeed - leg.startSpeed) * u
                return FlightFix(coordinate: Self.interpolate(leg.from, leg.to, fraction: fraction),
                                 phase: leg.phase, speed: speed / timeStretch,
                                 altitude: leg.startAltitude + (leg.endAltitude - leg.startAltitude) * u,
                                 verticalSpeed: (leg.endAltitude - leg.startAltitude) / (leg.seconds * timeStretch),
                                 course: Geo.bearing(from: leg.from, to: leg.to), elapsed: elapsed, progress: elapsed / duration)
            }
            remaining -= leg.seconds
        }
        return fix(at: duration)
    }

    /// Shortest great-circle arc, including flights crossing the date line.
    static func destination(_ origin: CLLocationCoordinate2D, bearing: Double, metres: Double) -> CLLocationCoordinate2D {
        let lat = origin.latitude * .pi / 180, lon = origin.longitude * .pi / 180
        let heading = bearing * .pi / 180, angle = metres / 6371000
        let newLat = asin(sin(lat) * cos(angle) + cos(lat) * sin(angle) * cos(heading))
        let newLon = lon + atan2(sin(heading) * sin(angle) * cos(lat), cos(angle) - sin(lat) * sin(newLat))
        let degrees = newLon * 180 / .pi
        return CLLocationCoordinate2D(latitude: newLat * 180 / .pi,
                                      longitude: (degrees + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, fraction: Double) -> CLLocationCoordinate2D {
        let f = min(1, max(0, fraction))
        if f == 0 { return a }; if f == 1 { return b }
        func vector(_ p: CLLocationCoordinate2D) -> [Double] {
            let lat = p.latitude * .pi / 180, lon = p.longitude * .pi / 180
            return [cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat)]
        }
        let x = vector(a), y = vector(b)
        let angle = acos(min(1, max(-1, zip(x, y).reduce(0) { $0 + $1.0 * $1.1 })))
        if angle < 0.000001 { return a }
        let denominator = sin(angle)
        let p = sin((1 - f) * angle) / denominator, q = sin(f * angle) / denominator
        let v = zip(x, y).map { p * $0.0 + q * $0.1 }
        return CLLocationCoordinate2D(latitude: atan2(v[2], hypot(v[0], v[1])) * 180 / .pi,
                                      longitude: atan2(v[1], v[0]) * 180 / .pi)
    }
}
