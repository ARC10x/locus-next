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
    case waiting, drive, briefing, transfer, boarding, walk
    case taxiOut, alignment, takeoff, climb, cruise, descent, approach, landing, taxiIn, arrived
    var title: String {
        switch self {
        case .waiting: return "Attente au domicile"
        case .drive: return "Trajet vers Orly"
        case .briefing: return "Préparation équipage"
        case .transfer: return "Accès à l’avion"
        case .boarding: return "Préparation à bord"
        case .walk: return "Promenade"
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
    var modelVersion: Int? = 2
    var aircraft: AircraftProfile = .b737
    var cruiseKPH: Double = 840
    var altitudeMetres: Double = 11000
    var durationMinutes: Double = 0 // zero selects the model duration
    // Terminal departure, runway start/end, arrival threshold/end, terminal arrival.
    var points: [Coordinate2D] = []
    var taxiOut: [Coordinate2D]?
    var taxiIn: [Coordinate2D]?
    var airWaypoints: [Coordinate2D]?
    var groundStages: [FlightGroundStage]?
    var scenarioTitle: String?
    var groundOnly: Bool?
    var homeDepartureAt: Date?
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
        var path: FlightPolyline? = nil
        var samples: [FlightGroundSample]? = nil
        var track: [CLLocationCoordinate2D] {
            samples?.map { $0.point.clLocation } ?? path?.points ?? [from, to]
        }
    }
    let configuration: FlightConfiguration
    let legs: [Leg]
    let duration: Double

    /// Consume only the stationary initial wait. Never skip a road or flight leg.
    func elapsedAfterWaiting(_ elapsed: Double, now: Date) -> Double {
        guard let deadline = configuration.homeDepartureAt,
              let first = legs.first, first.phase == .waiting,
              elapsed < first.seconds else { return elapsed }
        return max(elapsed, min(first.seconds, first.seconds - deadline.timeIntervalSince(now)))
    }

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
        let departureVector = Self.destination(p[2], bearing: Geo.bearing(from: p[1], to: p[2]), metres: min(15000, airDistance * 0.15))
        let approach = Self.destination(p[3], bearing: Geo.bearing(from: p[4], to: p[3]), metres: min(15000, airDistance * 0.1))
        let approachVector = Self.destination(p[3], bearing: Geo.bearing(from: p[4], to: p[3]), metres: min(40000, airDistance * 0.18))
        let waypoints = (config.airWaypoints ?? []).map(\.clLocation)
        guard waypoints.count <= 100, waypoints.allSatisfy(CLLocationCoordinate2DIsValid) else {
            throw Invalid(message: "Points de passage aériens invalides.")
        }
        let airPath = FlightPolyline.rounded([p[2], departureVector] + waypoints + [approachVector, approach], trim: min(12000, airDistance * 0.04))
        let climbDistance = min(160000, airPath.length * 0.25)
        let descentStart = airPath.length - min(180000, airPath.length * 0.25)
        let climbPath = airPath.slice(0, climbDistance)
        let cruisePath = airPath.slice(climbDistance, descentStart)
        let descentPath = airPath.slice(descentStart, airPath.length)
        let top = climbPath.points.last!, descent = descentPath.points.first!
        let approachHeight = min(500, Geo.distance(approach, p[3]) / 76 * 5)
        // Short flights cannot plausibly reach long-haul cruising altitude.
        let h = min(config.altitudeMetres, 15 + climbPath.length / ((78 + c) / 2) * 12,
                    approachHeight + descentPath.length / ((c + 80) / 2) * 10)
        var result: [Leg] = []
        func add(_ phase: FlightPhase, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                 _ v0: Double, _ v1: Double, _ h0: Double, _ h1: Double, dwell: Double = 0, path: FlightPolyline? = nil) {
            let length = path?.length ?? Geo.distance(a, b)
            let seconds = dwell > 0 ? dwell : length / max(0.1, (v0 + v1) / 2)
            if seconds > 0.001 {
                result.append(Leg(phase: phase, from: a, to: b, startSpeed: v0, endSpeed: v1,
                                  startAltitude: h0, endAltitude: h1, seconds: seconds, path: path))
            }
        }
        var previous: CLLocationCoordinate2D?
        guard (config.groundStages?.count ?? 0) <= 64 else { throw Invalid(message: "Trop d’étapes terrestres.") }
        for stage in config.groundStages ?? [] {
            guard stage.samples.count >= 2, stage.samples.count <= 86402,
                  stage.samples.first!.seconds == 0, stage.duration > 0, stage.duration <= 172800,
                  stage.samples.allSatisfy({ CLLocationCoordinate2DIsValid($0.point.clLocation) && $0.seconds.isFinite && $0.speed.isFinite && (0...100).contains($0.speed) }),
                  zip(stage.samples, stage.samples.dropFirst()).allSatisfy({ $0.1.seconds > $0.0.seconds }),
                  [.waiting, .drive, .briefing, .transfer, .boarding, .walk].contains(stage.phase) else {
                throw Invalid(message: "Étape terrestre invalide.")
            }
            let first = stage.samples.first!.point.clLocation, last = stage.samples.last!.point.clLocation
            if let previous, Geo.distance(previous, first) > 2 { throw Invalid(message: "Les étapes terrestres ne sont pas raccordées.") }
            result.append(Leg(phase: stage.phase, from: first, to: last, startSpeed: 0, endSpeed: 0,
                              startAltitude: 0, endAltitude: 0, seconds: stage.duration, samples: stage.samples))
            previous = last
        }
        if config.groundOnly == true {
            guard !result.isEmpty else { throw Invalid(message: "Le parcours terrestre est vide.") }
            configuration = config; legs = result; duration = result.reduce(0) { $0 + $1.seconds }
            return
        }
        if let previous, Geo.distance(previous, p[0]) > 2 { throw Invalid(message: "L’accès à l’avion doit rejoindre le stationnement de départ.") }
        func taxi(_ raw: [Coordinate2D]?, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) throws -> FlightPolyline {
            let points = raw?.map(\.clLocation) ?? [from, to]
            guard (2...2000).contains(points.count), points.allSatisfy(CLLocationCoordinate2DIsValid),
                  Geo.distance(points.first!, from) < 2, Geo.distance(points.last!, to) < 2 else {
                throw Invalid(message: "Le roulage doit relier le stationnement et la piste.")
            }
            return FlightPolyline.rounded(points, trim: 12)
        }
        let taxiOut = try taxi(config.taxiOut, from: p[0], to: p[1])
        let taxiIn = try taxi(config.taxiIn, from: p[4], to: p[5])
        add(.taxiOut, p[0], p[1], 0, 0, 0, 0, dwell: max(1, taxiOut.length / 5), path: taxiOut)
        add(.alignment, p[1], p[1], 0, 0, 0, 0, dwell: 10)
        add(.takeoff, p[1], p[2], 0, 78, 0, 15)
        add(.climb, p[2], top, 78, c, 15, h, path: climbPath)
        add(.cruise, top, descent, c, c, h, h, path: cruisePath)
        add(.descent, descent, approach, c, 80, h, approachHeight, path: descentPath)
        add(.approach, approach, p[3], 80, 72, approachHeight, 0)
        add(.landing, p[3], p[4], 72, 0, 0, 0)
        add(.taxiIn, p[4], p[5], 0, 0, 0, 0, dwell: max(1, taxiIn.length / 5), path: taxiIn)
        let minimum = result.reduce(0) { $0 + $1.seconds }
        let requested = config.durationMinutes * 60
        guard requested == 0 || abs(requested - minimum) < 0.001 else {
            throw Invalid(message: "La durée doit être calculée depuis le parcours et les vitesses. Choisissez 0 (automatique), puis démarrez un nouveau vol. Une ancienne sauvegarde avec durée imposée ne peut pas être reprise sans modifier sa progression.")
        }
        configuration = config
        legs = result
        duration = minimum
    }

    /// One bounded first movement can trigger a fresh fix when a stationary
    /// Core Location stream has stopped reporting. Never starts free-running.
    func startupProbe(at elapsed: Double) -> FlightFix? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        let origin = fix(at: elapsed).coordinate
        var low = elapsed, high = min(duration, elapsed + 15)
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if Geo.distance(origin, fix(at: middle).coordinate) <= 5 { low = middle }
            else { high = middle }
        }
        let candidate = fix(at: low)
        guard Geo.distance(origin, candidate.coordinate) >= 0.1 else { return nil }
        return candidate
    }

    func fix(at seconds: Double) -> FlightFix {
        let elapsed = seconds.isFinite ? min(duration, max(0, seconds)) : 0
        if elapsed >= duration {
            return FlightFix(coordinate: legs.last!.to, phase: .arrived, speed: 0, altitude: 0,
                             verticalSpeed: 0, course: 0, elapsed: duration, progress: 1)
        }
        var remaining = elapsed
        for leg in legs {
            if remaining <= leg.seconds {
                let u = remaining / leg.seconds
                if let samples = leg.samples {
                    var low = 1, high = samples.count - 1
                    while low < high {
                        let mid = (low + high) / 2
                        if samples[mid].seconds < remaining { low = mid + 1 } else { high = mid }
                    }
                    let a = samples[low - 1], b = samples[low]
                    let f = max(0, min(1, (remaining - a.seconds) / (b.seconds - a.seconds)))
                    return FlightFix(coordinate: Self.interpolate(a.point.clLocation, b.point.clLocation, fraction: f),
                                     phase: leg.phase, speed: a.speed + (b.speed - a.speed) * f, altitude: 0, verticalSpeed: 0,
                                     course: Geo.bearing(from: a.point.clLocation, to: b.point.clLocation), elapsed: elapsed, progress: elapsed / duration)
                }
                let taxi = leg.phase == .taxiOut || leg.phase == .taxiIn
                // Taxi uses smoothstep position: zero speed at both ends.
                let integral = (leg.startSpeed + leg.endSpeed) / 2
                let fraction = taxi ? u * u * (3 - 2 * u)
                    : (integral > 0 ? (leg.startSpeed * u + 0.5 * (leg.endSpeed - leg.startSpeed) * u * u) / integral : 0)
                let length = leg.path?.length ?? Geo.distance(leg.from, leg.to)
                let speed = taxi ? length / leg.seconds * 6 * u * (1 - u)
                    : leg.startSpeed + (leg.endSpeed - leg.startSpeed) * u
                let path = leg.path ?? FlightPolyline([leg.from, leg.to])
                let distance = length * fraction
                // Rotation starts near the end of the acceleration, never at taxi speed.
                let rotation = max(0, (u - 0.88) / 0.12)
                let altitudeFraction = leg.phase == .takeoff ? rotation * rotation : u
                let verticalFactor = leg.phase == .takeoff ? 2 * rotation / 0.12 : 1
                return FlightFix(coordinate: path.position(distance),
                                 phase: leg.phase, speed: speed,
                                 altitude: leg.startAltitude + (leg.endAltitude - leg.startAltitude) * altitudeFraction,
                                 verticalSpeed: (leg.endAltitude - leg.startAltitude) / leg.seconds * verticalFactor,
                                 course: Geo.bearing(from: path.position(max(0, distance - 5)), to: path.position(min(length, distance + 5))), elapsed: elapsed, progress: elapsed / duration)
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
        if angle < 0.000001 {
            let delta = (b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            let longitude = (a.longitude + delta * f + 540).truncatingRemainder(dividingBy: 360) - 180
            return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f, longitude: longitude)
        }
        let denominator = sin(angle)
        let p = sin((1 - f) * angle) / denominator, q = sin(f * angle) / denominator
        let v = zip(x, y).map { p * $0.0 + q * $0.1 }
        return CLLocationCoordinate2D(latitude: atan2(v[2], hypot(v[0], v[1])) * 180 / .pi,
                                      longitude: atan2(v[1], v[0]) * 180 / .pi)
    }
}
