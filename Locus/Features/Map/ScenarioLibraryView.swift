import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct ScenarioLibraryView: View {
    var candidate: FlightConfiguration? = nil
    var onStart: () -> Void = {}
    @EnvironmentObject private var session: SpoofSession
    @State private var name = "Mon parcours"
    @State private var urls: [URL] = []
    @State private var importer = false
    @State private var selected: ScenarioFile?
    @State private var preview: FlightPlan?
    @State private var error: String?

    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scenarios", isDirectory: true)
    }

    var body: some View {
        Form {
            Section("Ajouter des parcours sans réinstaller") {
                Button("Importer un scénario JSON…") { importer = true }
                Text("Importez un fichier de scénario Locus. Vérifiez la carte avant de le lancer. Les parcours enregistrés démarrent immédiatement, sans reprendre un ancien horaire.")
                    .font(.caption)
                Text("Un export contient les coordonnées du parcours, y compris celles du domicile s’il en fait partie.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            if let candidate {
                Section("Enregistrer ce parcours") {
                    TextField("Nom", text: $name)
                    Button("Ajouter à ma bibliothèque") {
                        do {
                            let file = ScenarioFile(name: name, configuration: candidate)
                            let data = try JSONEncoder().encode(file)
                            try save(data)
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            Section("Mes scénarios") {
                if urls.isEmpty { Text("Aucun scénario enregistré.") }
                ForEach(urls, id: \.self) { url in
                    HStack {
                        Button(url.deletingPathExtension().lastPathComponent) { select(url) }
                        Spacer()
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }.onDelete { indices in
                    do {
                        for index in indices { try FileManager.default.removeItem(at: urls[index]) }
                        selected = nil; preview = nil; reload()
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let selected, let preview {
                Section(selected.name) {
                    Map { MapPolyline(coordinates: preview.legs.flatMap { $0.track }).stroke(.orange, lineWidth: 3) }
                        .frame(height: 280)
                    LabeledContent("Durée", value: "\(Int(ceil(preview.duration / 60))) min")
                    Button("Démarrer ce scénario") {
                        session.startFlight(selected.configuration)
                        if session.isFlying { onStart() } else { error = session.lastError }
                    }.disabled(session.isRouting || session.isBusy || session.isRecovering)
                }
            }
        }
        .navigationTitle("Bibliothèque de parcours")
        .onAppear { reload() }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try save(read(url))
            } catch { self.error = error.localizedDescription }
        }
    }

    private func read(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw FlightPlan.Invalid(message: "Scénario trop volumineux (8 Mo maximum).") }
        return try Data(contentsOf: url)
    }

    private func save(_ data: Data) throws {
        let file = try ScenarioFile.decode(data)
        let validated = try FlightPlan(file.configuration)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = file.name.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" }
        let filename = String(safeName.prefix(70)) + "-" + String(UUID().uuidString.prefix(8)) + ".json"
        try JSONEncoder().encode(file).write(to: folder.appendingPathComponent(filename), options: .atomic)
        selected = file; preview = validated; error = nil; reload()
    }

    private func select(_ url: URL) {
        do {
            let file = try ScenarioFile.decode(read(url))
            let plan = try FlightPlan(file.configuration)
            selected = file; preview = plan; error = nil
        } catch { selected = nil; preview = nil; self.error = error.localizedDescription }
    }

    private func reload() {
        urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
