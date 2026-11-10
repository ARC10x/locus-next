import CoreLocation
import MapKit
import SwiftUI

struct ReturnJourneyView: View {
    var onStart: () -> Void = {}
    @EnvironmentObject private var session: SpoofSession
    @AppStorage("locus.next.journey.home") private var homeAddress = ""
    @State private var plan: FlightPlan?
    @State private var preparedAddress = ""
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Retour à la maison") {
                TextField("Adresse du domicile", text: $homeAddress)
                Text("Dublin 10R → Orly 07, puis sortie équipage et trajet routier. Départ immédiat après préparation du parcours. Pistes et trajet aérien simulés, sans affectation ATC réelle.")
                    .font(.caption)
                Button(busy ? "Calcul du retour…" : "Préparer le retour") { prepare() }
                    .disabled(busy || homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            if let plan, preparedAddress == homeAddress {
                Section("Vérifier le parcours") {
                    Map { MapPolyline(coordinates: plan.legs.flatMap { $0.track }).stroke(.orange, lineWidth: 3) }
                        .frame(height: 280)
                    LabeledContent("Durée totale", value: "\(Int(ceil(plan.duration / 60))) min")
                    Text("Sortie de l’avion : 15 minutes. Accès au véhicule estimé. Route calculée par Apple Plans.")
                    NavigationLink("Enregistrer ou partager ce retour") {
                        ScenarioLibraryView(candidate: plan.configuration, onStart: onStart)
                    }
                    Button("Démarrer Dublin → Orly → domicile") {
                        session.startFlight(plan.configuration)
                        if session.isFlying { onStart() } else { error = session.lastError }
                    }.disabled(session.isRouting || session.isBusy || session.isRecovering)
                }
            }
        }
        .navigationTitle("Dublin → domicile")
        .onDisappear { task?.cancel(); busy = false }
    }

    private func prepare() {
        let address = homeAddress
        busy = true; error = nil; plan = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let home = try await JourneyBuilder.locate(address)
                let crew = try await JourneyBuilder.locate(OrlyDublinScenario.crewAddress)
                let road = try await JourneyBuilder.road(from: crew, to: home, mode: .drive, phase: .drive)
                var config = OrlyDublinScenario.returnConfiguration
                config.arrivalGroundStages = [
                    .wait(at: config.points[5], seconds: 900, phase: .transfer),
                    JourneyBuilder.estimatedAccess(from: config.points[5], to: road.samples[0].point, minutes: 20), road]
                let result = try FlightPlan(config)
                try Task.checkCancellation()
                guard address == homeAddress else { throw FlightPlan.Invalid(message: "Adresse modifiée : recalculez le retour.") }
                plan = result; preparedAddress = address
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
