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
    // OurAirports runway endpoints and OpenStreetMap taxiway geometry; fictional stand selection.
    static var configuration: FlightConfiguration {
        var value = FlightConfiguration()
        let departure = coordinate(48.7274017334, 2.4020700455) // Orly 25
        let departureEnd = coordinate(48.7193984985, 2.3585898876)
        let arrival = coordinate(53.4203, -6.25058) // Dublin 28L
        let arrivalEnd = coordinate(53.42243, -6.29007)
        let stand = departureTaxi[0]
        let destination = arrivalTaxi.last!
        value.points = [stand, departure, departureEnd, arrival, arrivalEnd, destination]
        value.taxiOut = departureTaxi
        value.taxiIn = arrivalTaxi
        value.airWaypoints = [coordinate(49.15, 1.20), coordinate(49.70, -0.65),
                              coordinate(50.55, -2.10), coordinate(51.65, -3.60),
                              coordinate(52.65, -4.35), coordinate(53.37, -5.25)]
        return value
    }
    // Derived from OpenStreetMap contributors, ODbL, 2026-11-09.
    // Airport-internal taxi routing is illustrative, not an ATC clearance.
    static let departureTaxi: [Coordinate2D] = [
        coordinate(48.7250641, 2.3668667),
        coordinate(48.725141, 2.3672793),
        coordinate(48.7252752, 2.3679995),
        coordinate(48.7255247, 2.3693382),
        coordinate(48.7256965, 2.3702631),
        coordinate(48.7258919, 2.3713376),
        coordinate(48.7259322, 2.3715449),
        coordinate(48.7259803, 2.3718088),
        coordinate(48.7260281, 2.3720711),
        coordinate(48.7261166, 2.3725561),
        coordinate(48.7262867, 2.3734796),
        coordinate(48.7263887, 2.3740337),
        coordinate(48.7264895, 2.3745809),
        coordinate(48.7267814, 2.3761491),
        coordinate(48.7269054, 2.3768153),
        coordinate(48.7269608, 2.3771045),
        coordinate(48.7270107, 2.3773816),
        coordinate(48.727149, 2.3781499),
        coordinate(48.7273088, 2.3790208),
        coordinate(48.7273213, 2.3790886),
        coordinate(48.7274437, 2.3797431),
        coordinate(48.7276193, 2.3806952),
        coordinate(48.7277695, 2.3815195),
        coordinate(48.7278318, 2.3818612),
        coordinate(48.7281277, 2.3834495),
        coordinate(48.7282029, 2.3838686),
        coordinate(48.7282455, 2.3841404),
        coordinate(48.7282676, 2.3843457),
        coordinate(48.7282802, 2.384487),
        coordinate(48.7282854, 2.3845452),
        coordinate(48.7284413, 2.3869147),
        coordinate(48.728504, 2.3878991),
        coordinate(48.7285306, 2.388356),
        coordinate(48.7288036, 2.3925996),
        coordinate(48.728932, 2.3945962),
        coordinate(48.7289331, 2.3946241),
        coordinate(48.7290133, 2.3958578),
        coordinate(48.7291248, 2.3976204),
        coordinate(48.7292218, 2.3992482),
        coordinate(48.7292186, 2.3993752),
        coordinate(48.7291962, 2.3995032),
        coordinate(48.7291522, 2.3996248),
        coordinate(48.7289643, 2.4000753),
        coordinate(48.7286071, 2.4009133),
        coordinate(48.7284237, 2.4013346),
        coordinate(48.7283417, 2.4014497),
        coordinate(48.7282437, 2.4015281),
        coordinate(48.7278061, 2.4017157),
        coordinate(48.7277245, 2.4017294),
        coordinate(48.7276429, 2.4017193),
        coordinate(48.7275661, 2.4016848),
        coordinate(48.7275023, 2.401643),
        coordinate(48.7274017334, 2.4020700455)
    ]
    static let arrivalTaxi: [Coordinate2D] = [
        coordinate(53.42243, -6.29007),
        coordinate(53.4224306, -6.290075),
        coordinate(53.4224565, -6.2902513),
        coordinate(53.4224893, -6.2903639),
        coordinate(53.4225183, -6.2904329),
        coordinate(53.4225494, -6.2904851),
        coordinate(53.4225949, -6.290546),
        coordinate(53.4226476, -6.2905896),
        coordinate(53.4227068, -6.2906237),
        coordinate(53.4227737, -6.2906404),
        coordinate(53.423185, -6.2907206),
        coordinate(53.4233094, -6.2907448),
        coordinate(53.4234113, -6.2907566),
        coordinate(53.4234914, -6.2907463),
        coordinate(53.4235481, -6.2907289),
        coordinate(53.4236075, -6.290705),
        coordinate(53.4236741, -6.2906654),
        coordinate(53.4237407, -6.2906143),
        coordinate(53.4238075, -6.2905444),
        coordinate(53.4238631, -6.2904821),
        coordinate(53.4239088, -6.290414),
        coordinate(53.4239519, -6.290335),
        coordinate(53.4239948, -6.2902432),
        coordinate(53.4240313, -6.290151),
        coordinate(53.4240585, -6.2900631),
        coordinate(53.4240821, -6.2899757),
        coordinate(53.4241038, -6.2898699),
        coordinate(53.4241203, -6.2897551),
        coordinate(53.4241286, -6.2896426),
        coordinate(53.4241316, -6.2895327),
        coordinate(53.4241263, -6.2893664),
        coordinate(53.4240357, -6.2877965),
        coordinate(53.4238226, -6.2838631),
        coordinate(53.4238171, -6.2837551),
        coordinate(53.423759, -6.282622),
        coordinate(53.4237145, -6.2818514),
        coordinate(53.4236441, -6.2805862),
        coordinate(53.4236352, -6.2804245),
        coordinate(53.4234882, -6.2777479),
        coordinate(53.4231241, -6.2711187),
        coordinate(53.4231073, -6.270809),
        coordinate(53.4230652, -6.2700501),
        coordinate(53.4230438, -6.2696861),
        coordinate(53.4229596, -6.2681222),
        coordinate(53.4228292, -6.265728),
        coordinate(53.4228147, -6.2654608),
        coordinate(53.4227532, -6.2643292),
        coordinate(53.4227377, -6.2640855),
        coordinate(53.422735, -6.2640377),
        coordinate(53.4227066, -6.2635252),
        coordinate(53.4226669, -6.2627749),
        coordinate(53.4226777, -6.2625185),
        coordinate(53.4226878, -6.262351),
        coordinate(53.42271, -6.2621543),
        coordinate(53.4227291, -6.2620114),
        coordinate(53.4227689, -6.2617885),
        coordinate(53.4228039, -6.2616437),
        coordinate(53.4228738, -6.2613903),
        coordinate(53.4229166, -6.2612619),
        coordinate(53.4229809, -6.2610922),
        coordinate(53.4230384, -6.2609587),
        coordinate(53.4231036, -6.2608206),
        coordinate(53.4232287, -6.2606038),
        coordinate(53.4233025, -6.2604754),
        coordinate(53.4242839, -6.2587987),
        coordinate(53.4247931, -6.2579313),
        coordinate(53.4253584, -6.2569624),
        coordinate(53.4254583, -6.2568626),
        coordinate(53.4255117, -6.2568335),
        coordinate(53.425568, -6.2568115),
        coordinate(53.4256125, -6.2568048),
        coordinate(53.425667, -6.2568053),
        coordinate(53.4257443, -6.2568223),
        coordinate(53.4258076, -6.256859),
        coordinate(53.4260884, -6.2570629),
        coordinate(53.4264731, -6.2573378),
        coordinate(53.4266166, -6.257451),
        coordinate(53.4268035, -6.2575731),
        coordinate(53.4268703, -6.2576328),
        coordinate(53.4269068, -6.2576768),
        coordinate(53.4269445, -6.2577518),
        coordinate(53.4269746, -6.2578779),
        coordinate(53.4270078, -6.2585412)
    ]

}


extension OrlyDublinScenario {
    /// Fictional reciprocal runway use: Dublin 10R → Orly 07.
    static var returnConfiguration: FlightConfiguration {
        var value = configuration
        value.points = Array(value.points.reversed())
        value.taxiOut = configuration.taxiIn.map { Array($0.reversed()) }
        value.taxiIn = configuration.taxiOut.map { Array($0.reversed()) }
        value.airWaypoints = configuration.airWaypoints.map { Array($0.reversed()) }
        value.scenarioTitle = "Dublin → Orly → domicile · simulé"
        return value
    }
}


/// Versioned, data-only route exchange. Never executes code or starts a route on import.
struct ScenarioFile: Codable {
    var formatVersion = 1
    var name: String
    var configuration: FlightConfiguration

    init(name: String, configuration: FlightConfiguration) {
        self.name = name
        self.configuration = configuration
        self.configuration.homeDepartureAt = nil
        if self.configuration.groundStages?.first?.phase == .waiting {
            self.configuration.groundStages?.removeFirst()
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8_000_000 else { throw FlightPlan.Invalid(message: "Scénario trop volumineux (8 Mo maximum).") }
        var file = try JSONDecoder().decode(Self.self, from: data)
        guard file.formatVersion == 1, file.configuration.modelVersion == 2,
              (1...120).contains(file.name.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
            throw FlightPlan.Invalid(message: "Format ou nom de scénario incompatible.")
        }
        file = Self(name: file.name, configuration: file.configuration)
        _ = try FlightPlan(file.configuration)
        return file
    }
}
