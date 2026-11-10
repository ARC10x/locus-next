import CoreLocation
import Foundation

/// What an app on this phone actually receives from Core Location right now.
///
/// Locus sets a location; this reads it back the way any other app would, so
/// "did it work?" has an answer that doesn't depend on Locus' own opinion. The
/// part worth reading is `sourceInformation`: iOS itself marks a fix as
/// simulated when it comes from the developer location service.
///
/// Reads only. Nothing here changes what is reported.
@MainActor
final class LocationProbe: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProbe()

    struct Reading: Equatable {
        var coordinate: CLLocationCoordinate2D
        var horizontalAccuracy: CLLocationAccuracy
        var verticalAccuracy: CLLocationAccuracy
        var altitude: CLLocationDistance
        var speed: CLLocationSpeed
        var course: CLLocationDirection
        var timestamp: Date
        /// `nil` when iOS gives no source information for this fix.
        var isSimulatedBySoftware: Bool?
        var isProducedByAccessory: Bool?

        static func == (lhs: Reading, rhs: Reading) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.timestamp == rhs.timestamp
        }
    }

    @Published private(set) var reading: Reading?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isRunning = false
    @Published private(set) var lastCallbackAt: Date?
    @Published private(set) var lastErrorCode: Int?
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    private var lastRefreshUptime = -Double.infinity

    private let manager = CLLocationManager()

    private override init() {
        authorization = .notDetermined
        super.init()
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        // Foreground only: this is a readout, not a reason to keep the radios up.
        manager.allowsBackgroundLocationUpdates = false
    }

    /// How many views are showing the readout. The map chip and the sheet both
    /// use it, and closing the sheet mustn't freeze the chip underneath.
    private var users = 0
    private var sessionMonitoring = false
    private var backgroundSession: CLBackgroundActivitySession?

    var supportsBackgroundExecution: Bool {
        sessionMonitoring && isRunning &&
            (authorization == .authorizedAlways || authorization == .authorizedWhenInUse)
    }

    func monitorSession(_ enabled: Bool) {
        guard sessionMonitoring != enabled else { return }
        sessionMonitoring = enabled
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = !enabled
        manager.showsBackgroundLocationIndicator = enabled
        if enabled {
            backgroundSession = CLBackgroundActivitySession()
            start()
            SessionDiagnostics.shared.record("Session de localisation en arrière-plan ouverte")
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
            stop()
        }
    }

    func start() {
        users += 1
        guard !isRunning else { return }
        isRunning = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        users = max(0, users - 1)
        guard isRunning, users == 0 else { return }
        isRunning = false
        manager.stopUpdatingLocation()
    }

    /// Restart only our reader, not the developer transport or simulated point.
    /// requestLocation() is ignored while continuous updates are running.
    func refresh() {
        guard sessionMonitoring, isRunning,
              ProcessInfo.processInfo.systemUptime - lastRefreshUptime >= 15 else { return }
        lastRefreshUptime = ProcessInfo.processInfo.systemUptime
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
        SessionDiagnostics.shared.record("Écoute Core Location relancée sans déconnecter le moteur")
    }

    var diagnosticSummary: String {
        let age: String
        if let timestamp = reading?.timestamp {
            let seconds = Date().timeIntervalSince(timestamp)
            age = seconds.isFinite ? String(format: "%.0f s", seconds) : "invalide"
        } else { age = "aucune lecture" }
        let source = reading?.isSimulatedBySoftware.map { $0 ? "simulée" : "réelle" } ?? "inconnue"
        return "Core Location: âge=\(age), source=\(source), autorisation=\(authorization.rawValue), précision \(accuracyAuthorization == .fullAccuracy ? "complète" : "réduite"), écoute=\(isRunning)"
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let source = location.sourceInformation
        let reading = Reading(
            coordinate: location.coordinate,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            altitude: location.altitude,
            speed: location.speed,
            course: location.course,
            timestamp: location.timestamp,
            isSimulatedBySoftware: source?.isSimulatedBySoftware,
            isProducedByAccessory: source?.isProducedByAccessory
        )
        Task { @MainActor in
            self.lastCallbackAt = Date()
            self.lastErrorCode = nil
            self.reading = reading
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            self.authorization = status
            self.accuracyAuthorization = accuracy
            SessionDiagnostics.shared.record("Autorisation Core Location: \(status.rawValue), précision \(accuracy == .fullAccuracy ? "complète" : "réduite")")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor in
            self.lastErrorCode = code
            SessionDiagnostics.shared.record("Core Location: erreur code \(code)")
        }
    }
}
