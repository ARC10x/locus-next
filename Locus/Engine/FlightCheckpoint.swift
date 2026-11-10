import Foundation

struct FlightCheckpoint: Codable {
    let configuration: FlightConfiguration
    let elapsed: Double
    let savedAt: Date
    private static let key = "locus.next.flight.checkpoint.v1"
    static func load() -> FlightCheckpoint? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.configuration.modelVersion == 2,
              let plan = try? FlightPlan(value.configuration),
              value.elapsed.isFinite, (0...plan.duration).contains(value.elapsed) else { return nil }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
