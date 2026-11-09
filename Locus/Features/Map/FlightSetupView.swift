import SwiftUI

struct FlightSetupView: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var configuration: FlightConfiguration {
        var value = session.flightConfiguration
        value.points = session.flightPoints.compactMap { $0 }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Avion") {
                    Picker("Profil", selection: $session.flightConfiguration.aircraft) {
                        ForEach(AircraftProfile.allCases) { aircraft in Text(aircraft.title).tag(aircraft) }
                    }
                    .onChange(of: session.flightConfiguration.aircraft) { _, aircraft in
                        session.flightConfiguration.cruiseKPH = aircraft.cruiseKPH
                    }
                    Text("Profils illustratifs modifiables, sans performances aéronautiques certifiées.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Vitesse sol de croisière", value: "\(Int(session.flightConfiguration.cruiseKPH)) km/h")
                    Slider(value: $session.flightConfiguration.cruiseKPH, in: 300...1000, step: 10)
                    LabeledContent("Altitude simulée", value: "\(Int(session.flightConfiguration.altitudeMetres)) m")
                    Slider(value: $session.flightConfiguration.altitudeMetres, in: 1000...13000, step: 100)
                    Text("L’altitude est réduite pour les vols courts. Altitude et vitesse verticale restent des valeurs du scénario : seule la position horizontale est transmise au moteur Developer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Pistes et terminaux") {
                    Button("Proposer un vol depuis ma position simulée vers le repère") {
                        guard let start = session.simulated, let end = session.pin,
                              Geo.distance(start, end) >= 30000 else {
                            error = "Fixez d’abord une position de départ, puis choisissez sur la carte un repère d’arrivée à au moins 30 km."
                            return
                        }
                        let bearing = Geo.bearing(from: start, to: end)
                        let runwayStart = FlightPlan.destination(start, bearing: bearing, metres: 300)
                        let runwayEnd = FlightPlan.destination(runwayStart, bearing: bearing, metres: 2000)
                        let arrivalEnd = FlightPlan.destination(end, bearing: bearing + 180, metres: 300)
                        let threshold = FlightPlan.destination(arrivalEnd, bearing: bearing + 180, metres: 2200)
                        session.flightPoints = [start, runwayStart, runwayEnd, threshold, arrivalEnd, end]
                            .map { Optional(Coordinate2D($0)) }
                        error = nil
                    }
                    .disabled(session.isFlying)
                    Text("Cette proposition crée des pistes fictives orientées vers la destination. Pour utiliser des pistes réelles, remplacez les points ci-dessous en vous aidant de la carte.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Placez un repère sur la carte, revenez dans Vol et affectez-le au point voulu. Répétez pour les six points, dans le sens de déplacement. Les pistes et le roulage sont définis manuellement.")
                        .font(.footnote)
                    ForEach(0..<6, id: \.self) { index in
                        VStack(alignment: .leading) {
                            Text(FlightConfiguration.pointLabels[index]).font(.headline)
                            if let point = session.flightPoints[index] {
                                Text(String(format: "%.5f, %.5f", point.latitude, point.longitude))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Utiliser le repère de la carte") {
                                if let pin = session.pin { session.flightPoints[index] = Coordinate2D(pin) }
                            }
                            .disabled(session.pin == nil || session.isFlying)
                        }
                    }
                    Button("Retour à la carte") { dismiss() }
                }
                Section("Durée") {
                    TextField("Minutes (0 = automatique)", value: $session.flightConfiguration.durationMinutes,
                              format: .number)
                        .keyboardType(.decimalPad)
                    Text("Une durée plus longue ralentit la progression de façon cohérente. Une durée dépassant la vitesse maximale est refusée. Le parcours aérien suit un arc entre les pistes, sans données de vol réelles.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let plan = try? FlightPlan(configuration) {
                        LabeledContent("Durée prévue", value: "\(Int(ceil(plan.duration / 60))) min")
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("Démarrer le vol simulé") {
                        do {
                            _ = try FlightPlan(configuration)
                            error = nil
                            session.startFlight(configuration)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(session.isBusy || session.isRecovering || session.isFlying)
                    if let saved = session.savedFlight, !session.isFlying {
                        Button("Reprendre le vol sauvegardé (\(Int(saved.elapsed / 60)) min)") {
                            session.resumeFlightCheckpoint()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Simulation de vol")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() } } }
        }
    }
}

struct FlightHUDView: View {
    @EnvironmentObject private var session: SpoofSession
    @AppStorage("locus.next.flight.speedUnit") private var unit: FlightSpeedUnit = .kph

    var body: some View {
        if let fix = session.flightFix {
            VStack(spacing: 8) {
                HStack {
                    Label(fix.phase.title, systemImage: "airplane")
                    Spacer()
                    Text(session.flightConfiguration.aircraft.title).font(.caption)
                }
                ProgressView(value: fix.progress)
                HStack {
                    Text("Sol : \(Int(unit.value(fix.speed))) \(unit.rawValue)")
                    Spacer()
                    Text("Altitude simulée : \(Int(fix.altitude)) m")
                }.font(.caption).monospacedDigit()
                HStack {
                    Text(String(format: "V/S : %+.1f m/s · Cap %.0f°", fix.verticalSpeed, fix.course))
                    Spacer()
                    Picker("Vitesse sol", selection: $unit) {
                        ForEach(FlightSpeedUnit.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }.font(.caption)
                if session.isFlying {
                    HStack {
                        Button(session.isFlightPaused ? "Reprendre" : "Pause") { session.toggleFlightPause() }
                        Spacer()
                        Button("Rester ici") { session.holdPosition() }
                    }
                } else if session.savedFlight != nil {
                    Button("Reprendre le vol sauvegardé") { session.resumeFlightCheckpoint() }
                }
                if let issue = session.verificationIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
                Text(session.status.label).font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}
