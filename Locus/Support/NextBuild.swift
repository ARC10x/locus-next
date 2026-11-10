import Foundation

enum NextBuild {
    /// Set only by the separate development build configuration.
    static var usesExternalTunnel: Bool {
        Bundle.main.object(forInfoDictionaryKey: "LocusNextExternalTunnel") as? Bool ?? false
    }
}
