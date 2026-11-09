import SwiftUI

struct SessionDiagnosticsView: View {
    @EnvironmentObject private var session: SpoofSession
    @StateObject private var diagnostics = SessionDiagnostics.shared
    @State private var exportURL: URL?
    @State private var exportFailed = false

    var body: some View {
        List {
            Section("Simulation") {
                Text(session.status.label)
                if let date = session.lastConfirmedAt {
                    Text("Dernière confirmation : \(date.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("Aucune position confirmée depuis l’ouverture.")
                }
                Text("iOS peut suspendre Locus. Les vérifications et reconnexions reprennent seulement lorsque l’exécution est possible.")
                    .font(.footnote).foregroundStyle(.secondary)
                if session.simulated != nil {
                    Button("Vérifier et reconnecter") { session.retrySimulation() }
                        .disabled(session.isBusy || session.isRecovering)
                }
            }
            Section("Exporter") {
                Button("Préparer les diagnostics") {
                    do { exportURL = try diagnostics.export(); exportFailed = false }
                    catch { exportFailed = true }
                }
                if let exportURL { ShareLink("Partager le journal", item: exportURL) }
                if exportFailed { Text("Impossible de préparer le journal.").foregroundStyle(.red) }
                Text("Le journal exclut les coordonnées, le contenu RPPairing et les secrets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Événements récents") {
                ForEach(diagnostics.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.name)
                        Text(event.at.formatted(date: .abbreviated, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Diagnostic de session")
    }
}
