import CoreLocation
import MapKit
import SwiftUI

struct StrollSetupView: View {
    var onStart: () -> Void = {}
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("locus.next.journey.home") private var homeAddress = ""
    @State private var useHome = true
    @State private var minutes = 45.0
    @State private var radius = 1000.0
    @State private var pauseMinutes = 2.0
    @State private var plan: FlightPlan?
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var preparedInput = ""

    private var signature: String {
        let pin = session.pin
        return "\(useHome)|\(homeAddress)|\(minutes)|\(radius)|\(pauseMinutes)|\(pin?.latitude ?? 0)|\(pin?.longitude ?? 0)"
    }

    var body: some View {
        Form {
            Section("Point de départ") {
                Toggle("Depuis mon domicile", isOn: $useHome)
                if useHome { TextField("Adresse du domicile", text: $homeAddress) }
                else { Text("Le repère choisi sur la carte sert de départ.") }
            }
            Section("Promenade sur les chemins") {
                Stepper("Durée souhaitée : \(Int(minutes)) min", value: $minutes, in: 15...180, step: 15)
                Stepper("Rayon maximal : \(Int(radius)) m", value: $radius, in: 250...3000, step: 250)
                Stepper("Pause à chaque étape : \(Int(pauseMinutes)) min", value: $pauseMinutes, in: 0...10)
                Text("Boucle calculée avec les itinéraires piétons Apple Plans. La durée est indicative : la marche conserve son allure et le retour suit les chemins disponibles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(busy ? "Recherche des chemins…" : "Générer une promenade") { generate() }.disabled(busy)
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            if let plan, signature == preparedInput {
                Section("Parcours proposé") {
                    Map { MapPolyline(coordinates: plan.legs.flatMap { $0.track }).stroke(.green, lineWidth: 3) }
                        .frame(height: 280)
                    LabeledContent("Durée calculée, pauses incluses", value: "\(Int(ceil(plan.duration / 60))) min")
                    Button("Démarrer la promenade") {
                        session.startFlight(plan.configuration)
                        if session.isFlying { onStart() } else { error = session.lastError ?? "Vérifiez l’appairage et LocalDevVPN." }
                    }.disabled(session.isRouting || session.isBusy || session.isRecovering)
                }
            }
        }
        .navigationTitle("Promenade en ville")
        .onDisappear { task?.cancel(); busy = false }
    }

    private func generate() {
        let input = signature, address = homeAddress, home = useHome, pin = session.pin
        let target = minutes * 60, radius = radius, pause = pauseMinutes * 60
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let origin: CLLocationCoordinate2D
                if home {
                    guard !address.isEmpty else { throw FlightPlan.Invalid(message: "Renseignez votre domicile.") }
                    origin = try await JourneyBuilder.locate(address)
                } else if let pin { origin = pin }
                else { throw FlightPlan.Invalid(message: "Choisissez un repère sur la carte.") }
                let reach = min(radius * 0.55, max(80, (target - pause * 3) * 1.35 / 7))
                let heading = Double.random(in: 0..<360)
                let targets = [0.0, 120, 240].map { FlightPlan.destination(origin, bearing: heading + $0, metres: reach) } + [origin]
                var stages: [FlightGroundStage] = []
                var start = origin
                var initial: Coordinate2D?
                for (index, destination) in targets.enumerated() {
                    var stage = try await JourneyBuilder.road(from: start, to: destination, mode: .walk, phase: .walk)
                    guard stage.samples.allSatisfy({ Geo.distance(origin, $0.point.clLocation) <= radius }) else {
                        throw FlightPlan.Invalid(message: "Les chemins disponibles sortent du rayon. Augmentez-le ou générez une autre boucle.")
                    }
                    if initial == nil { initial = stage.samples[0].point }
                    if let prior = stages.last?.samples.last?.point {
                        let gap = Geo.distance(prior.clLocation, stage.samples[0].point.clLocation)
                        guard gap <= 20 else { throw FlightPlan.Invalid(message: "Chemins non raccordés. Générez une autre boucle.") }
                        if gap > 0.01 {
                            let delay = max(1, gap / 1.35)
                            for i in stage.samples.indices { stage.samples[i].seconds += delay }
                            stage.samples.insert(FlightGroundSample(point: prior, seconds: 0, speed: 0), at: 0)
                        } else { stage.samples[0].point = prior }
                    }
                    stages.append(stage); start = stage.samples.last!.point.clLocation
                    if pause > 0 && index < 3 { stages.append(.wait(at: Coordinate2D(start), seconds: pause, phase: .walk)) }
                }
                guard let initial, Geo.distance(initial.clLocation, start) <= 20 else {
                    throw FlightPlan.Invalid(message: "Le retour ne rejoint pas le point de départ. Générez une autre boucle.")
                }
                // Short final connection between the two MapKit-snapped endpoints.
                if Geo.distance(initial.clLocation, start) > 0.01 {
                    stages.append(FlightGroundStage(phase: .walk, samples: [
                        FlightGroundSample(point: Coordinate2D(start), seconds: 0, speed: 0),
                        FlightGroundSample(point: initial, seconds: max(1, Geo.distance(initial.clLocation, start) / 1.35), speed: 0)]))
                }
                var config = OrlyDublinScenario.configuration
                config.groundOnly = true; config.groundStages = stages; config.scenarioTitle = "Promenade en ville"
                let result = try FlightPlan(config)
                try Task.checkCancellation()
                guard input == signature else { throw FlightPlan.Invalid(message: "Paramètres modifiés : recalculez la promenade.") }
                plan = result; preparedInput = input
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
