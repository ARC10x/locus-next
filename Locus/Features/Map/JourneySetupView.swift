import CoreLocation
import MapKit
import SwiftUI

@MainActor
enum JourneyBuilder {
    static func locate(_ address: String) async throws -> CLLocationCoordinate2D {
        let results = try await CLGeocoder().geocodeAddressString(address)
        guard let location = results.first?.location else {
            throw FlightPlan.Invalid(message: "Adresse introuvable. Précisez la rue, la ville et le pays.")
        }
        return location.coordinate
    }

    /// Uses the existing driving model, including braking for corners and junctions.
    static func trace(_ route: BuiltRoute, mode: TravelMode, phase: FlightPhase) async throws -> FlightGroundStage {
        var profile = FunPlan.profile(speed: 1.35, trip: .chill, mode: mode, units: .kph, keepScreenOn: true, buzz: false)
        profile.timeScale = 1
        let plan = RouteSimulator.plan(coordinates: route.coordinates, profile: profile, mode: mode,
                                       routeExpectedSpeed: route.expectedSpeed, roads: route.roads)
        guard !plan.isEmpty else { throw RouteBuilderError.noRoute }
        let walker = DriveWalker(plan: plan, profile: profile)
        var samples = [FlightGroundSample(point: Coordinate2D(walker.currentFix.coordinate), seconds: 0, speed: 0)]
        for second in 1...43200 {
            try Task.checkCancellation()
            guard let fix = walker.step(dt: 1) else { break }
            samples.append(FlightGroundSample(point: Coordinate2D(fix.coordinate), seconds: Double(second), speed: fix.speed))
            if walker.isFinished { break }
            if second % 300 == 0 { await Task.yield() }
        }
        guard walker.isFinished, samples.count > 1 else {
            throw FlightPlan.Invalid(message: "Le trajet terrestre dépasse douze heures ou ne peut pas être parcouru.")
        }
        return FlightGroundStage(phase: phase, samples: samples)
    }

    static func road(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: TravelMode, phase: FlightPhase) async throws -> FlightGroundStage {
        let routes = try await RouteBuilder.roadRoutes(from: from, to: to, mode: mode, alternatives: false)
        guard let route = routes.first else { throw RouteBuilderError.noRoute }
        return try await trace(route, mode: mode, phase: phase)
    }

    static func estimatedAccess(from: Coordinate2D, to: Coordinate2D, minutes: Double) -> FlightGroundStage {
        // Not a public pedestrian route through a restricted apron. Explicitly estimated.
        let a = from.clLocation, b = to.clLocation
        let corner = CLLocationCoordinate2D(latitude: b.latitude, longitude: a.longitude)
        let path = FlightPolyline.rounded([a, corner, b], trim: 20)
        let duration = max(minutes * 60, path.length / 1.35 * 1.5)
        let count = Int(ceil(duration))
        return FlightGroundStage(phase: .transfer, samples: (0...count).map { i in
            let t = Double(i) / Double(count)
            return FlightGroundSample(point: Coordinate2D(path.position(path.length * t * t * (3 - 2 * t))),
                                      seconds: Double(i), speed: path.length / Double(count) * 6 * t * (1 - t))
        })
    }
}

struct JourneySetupView: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("locus.next.journey.home") private var homeAddress = ""
    @AppStorage("locus.next.journey.hour") private var hour = 8
    @AppStorage("locus.next.journey.minute") private var minute = 0
    @AppStorage("locus.next.journey.preparation") private var preparation = 45.0
    @AppStorage("locus.next.journey.boarding") private var boarding = 25.0
    @AppStorage("locus.next.journey.margin") private var margin = 15.0
    @State private var stages: [FlightGroundStage] = []
    @State private var schedule: JourneySchedule?
    @State private var plan: FlightPlan?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var preparedInput = ""

    private var signature: String { "\(homeAddress)|\(hour)|\(minute)|\(preparation)|\(boarding)|\(margin)" }
    private var current: Bool { plan != nil && preparedInput == signature }

    var body: some View {
        Form {
            Section("Domicile") {
                TextField("Adresse complète à Troyes", text: $homeAddress)
                    .textContentType(.fullStreetAddress)
                Text("Mémorisée sur cet iPhone. Le géocodage et le trajet routier utilisent Apple Plans ; aucune API aéronautique payante.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Orly → Dublin · équipage") {
                Text("Siège Transavia : 7 avenue de l’Union, Cœur d’Orly. Avion : Boeing 737-800.")
                Stepper("Départ stationnement : \(String(format: "%02d:%02d", hour, minute))", value: $hour, in: 0...23)
                Stepper("Minutes : \(minute)", value: $minute, in: 0...55, step: 5)
                Text("Horaire fictif quotidien, heure de Paris. Le prochain départ laissant assez de temps pour toutes les étapes est retenu. Aucun horaire Transavia ni retard réel n’est consulté.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Préparation équipage : \(Int(preparation)) min", value: $preparation, in: 10...180, step: 5)
                Stepper("Préparation à bord : \(Int(boarding)) min", value: $boarding, in: 10...90, step: 5)
                Stepper("Marge à l’aéroport : \(Int(margin)) min", value: $margin, in: 0...90, step: 5)
            }
            Section {
                Button(busy ? "Calcul du scénario…" : "Préparer et afficher le parcours") { prepare() }
                    .disabled(busy || homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                if !current && plan != nil { Text("Paramètres modifiés : recalculez le scénario.").foregroundStyle(.orange) }
            }
            if current, let schedule, let plan {
                Section("Prochain scénario · heure de Paris") {
                    LabeledContent("Départ du domicile", value: formatted(schedule.leaveHome))
                    LabeledContent("Arrivée au siège", value: formatted(schedule.airport))
                    LabeledContent("Préparation à bord", value: formatted(schedule.board))
                    LabeledContent("Départ du stationnement", value: formatted(schedule.departure))
                    LabeledContent("Durée après départ du domicile", value: "\(Int(ceil(plan.duration / 60))) min")
                }
                Section("Vérifier le parcours") {
                    Map {
                        MapPolyline(coordinates: plan.legs.flatMap { $0.track }).stroke(.orange, lineWidth: 3)
                        Marker("Domicile", coordinate: stages[0].samples[0].point.clLocation)
                        Marker("Orly", coordinate: plan.configuration.points[0].clLocation)
                        Marker("Dublin", coordinate: plan.configuration.points[5].clLocation)
                    }.frame(height: 280)
                    Text("Pistes : Orly 25 → Dublin 28L. Accès équipage et roulages illustratifs, non vérifiés sur tous les taxiways. Trajectoire aérienne fictive avec virages arrondis ; aucune procédure ATC réelle reproduite.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Démarrer le scénario complet") { launch() }
                        .disabled(session.isBusy || session.isRecovering || session.isRouting)
                    Text("La simulation se place au domicile et attend l’heure prévue. Une pause ou une suspension iOS décale la suite : aucun rattrapage par téléportation. Pause, arrêt et reprise restent disponibles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Voyage équipage")
        .onDisappear { task?.cancel(); busy = false }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.timeZone = TimeZone(identifier: "Europe/Paris"); f.dateFormat = "EEE d MMM · HH:mm"
        return f.string(from: date)
    }

    private func prepare() {
        let input = signature, address = homeAddress
        let prep = preparation, board = boarding, margin = margin, hour = hour, minute = minute
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let home = try await JourneyBuilder.locate(address)
                let crew = try await JourneyBuilder.locate(OrlyDublinScenario.crewAddress)
                let road = try await JourneyBuilder.road(from: home, to: crew, mode: .drive, phase: .drive)
                var config = OrlyDublinScenario.configuration
                let crewPoint = road.samples.last!.point
                let access = JourneyBuilder.estimatedAccess(from: crewPoint, to: config.points[0], minutes: 20)
                let phases = [road, FlightGroundStage.wait(at: crewPoint, seconds: (prep + margin) * 60, phase: .briefing),
                              access, FlightGroundStage.wait(at: config.points[0], seconds: board * 60, phase: .boarding)]
                let dates = try JourneySchedule.next(now: Date(), hour: hour, minute: minute, road: road.duration,
                    preparation: prep * 60, transfer: access.duration, boarding: board * 60, margin: margin * 60)
                config.groundStages = phases; config.scenarioTitle = "Équipage · Orly → Dublin · simulé"
                let result = try FlightPlan(config)
                try Task.checkCancellation()
                guard input == signature else { throw FlightPlan.Invalid(message: "Paramètres modifiés pendant le calcul. Relancez la préparation.") }
                stages = phases; schedule = dates; plan = result; preparedInput = input
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func launch() {
        guard current, let plan, let schedule else { return }
        guard schedule.leaveHome > Date() else {
            error = "L’heure de départ prévue est passée. Recalculez le prochain scénario."; return
        }
        var config = plan.configuration
        let wait = FlightGroundStage.wait(at: stages[0].samples[0].point,
            seconds: schedule.leaveHome.timeIntervalSinceNow, phase: .waiting)
        config.groundStages = [wait] + stages
        session.startFlight(config)
        if session.isFlying { dismiss() } else { error = session.lastError ?? "Vérifiez l’appairage et LocalDevVPN." }
    }
}
