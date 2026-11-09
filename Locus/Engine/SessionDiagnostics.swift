import CoreLocation
import Combine
import Foundation
import Network

/// Only allowlisted event names and technical states belong here. No pairing
/// contents, API keys, coordinates, network names or raw error descriptions.
@MainActor
final class SessionDiagnostics: ObservableObject {
    static let shared = SessionDiagnostics()
    struct Event: Codable, Identifiable {
        let id: UUID
        let at: Date
        let name: String
    }
    @Published private(set) var events: [Event] = []
    private let monitor = NWPathMonitor()
    private let diskQueue = DispatchQueue(label: "locus.next.diagnostics")
    private var lastPath = ""

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = Array(saved.suffix(200))
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi"
                : path.usesInterfaceType(.cellular) ? "cellulaire" : "autre"
            let summary = "Réseau: \(kind), \(path.status == .satisfied ? "disponible" : "indisponible"), IPv4=\(path.supportsIPv4), IPv6=\(path.supportsIPv6)"
            Task { @MainActor in
                guard let self, summary != self.lastPath else { return }
                self.lastPath = summary
                self.record(summary)
            }
        }
        monitor.start(queue: DispatchQueue(label: "locus.next.network"))
    }

    func record(_ event: String) {
        events.append(Event(id: UUID(), at: Date(), name: event))
        if events.count > 200 { events.removeFirst(events.count - 200) }
        guard let data = try? JSONEncoder().encode(events) else { return }
        let url = Self.fileURL
        diskQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func export() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Next-diagnostics.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: url, options: .atomic)
        return url
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Locus/session-diagnostics.json")
    }
}

struct HeldPositionRecord: Codable {
    let coordinate: Coordinate2D
    let savedAt: Date
    private static let key = "locus.next.heldPosition.v1"

    static func save(_ coordinate: CLLocationCoordinate2D) {
        let record = HeldPositionRecord(coordinate: Coordinate2D(coordinate), savedAt: Date())
        if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load() -> HeldPositionRecord? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder().decode(Self.self, from: data),
              CLLocationCoordinate2DIsValid(record.coordinate.clLocation) else { return nil }
        return record
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
