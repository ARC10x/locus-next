import Combine
import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications
import AVFoundation

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case verifying
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Simulation confirmée"
        case .verifying: return "Vérification en attente"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

/// Live state of the joystick, for its readout.
struct JoystickTelemetry: Equatable {
    var speed: CLLocationSpeed = 0
    /// Degrees clockwise from north; `nil` when the stick is centred.
    var course: CLLocationDirection?
    /// Metres covered since the joystick was switched on.
    var distance: CLLocationDistance = 0
    var isMoving: Bool { speed > 0.05 }
}

/// What a finished drive amounted to.
///
/// The numbers were all being computed and none of them were ever shown: the
/// HUD went away and that was the end of it. `tripEconomy` in particular had a
/// consumption slider, a toggle, and nowhere at all to appear.
struct TripSummary: Identifiable, Equatable {
    let id = UUID()
    var routeName: String
    var distance: CLLocationDistance
    /// Seconds of simulated time — what the drive would have taken in the world.
    var simulatedSeconds: TimeInterval
    /// Seconds you actually waited, which differs whenever the time scale isn't 1×.
    var wallClockSeconds: TimeInterval
    var laps: Int
    var profileName: String
    /// How it was covered. Kept on the trip rather than read off the session,
    /// so the summary of a drive still reads as a drive after the mode is
    /// switched with the card still up — and so a walk never reports litres of
    /// petrol burnt.
    var mode: TravelMode = .drive

    var averageSpeed: CLLocationSpeed {
        simulatedSeconds > 1 ? distance / simulatedSeconds : 0
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    /// A short confirmation for something that worked.
    ///
    /// Failures get an alert; successes shouldn't — a teleport that lands is
    /// not worth a modal — but they were getting nothing at all, on a screen
    /// where the pin was already sitting where you asked for it.
    @Published private(set) var toast: String?
    @Published var isBusy = false
    @Published var joystickActive = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    /// The active driving profile — a working copy of whichever one is selected
    /// in `profiles`. Views bind straight to it; every change is written back to
    /// the named list, so there is no save step to forget.
    @Published var drive: DriveProfile {
        didSet {
            guard drive != oldValue else { return }
            profiles.update(drive)
            // Covers the "keep the screen on" toggle being flipped mid-drive,
            // and switching to a profile that answers it differently.
            refreshIdleTimer()
        }
    }

    /// Parameters to drive with instead of `drive`, while something other than
    /// the Pro sheet is in charge of them.
    ///
    /// Fun mode sets this to the profile behind its four chips and clears it on
    /// the way out. Everything that reads driving parameters reads
    /// `activeProfile`, so a Fun-mode drive never writes to — or is shaped by —
    /// the named profiles someone tuned in Pro mode. Nil is the whole of the
    /// old behaviour.
    @Published var profileOverride: DriveProfile? {
        didSet {
            guard profileOverride != oldValue else { return }
            refreshIdleTimer()
        }
    }

    /// The parameters in force: whatever has taken charge, else the selected
    /// profile.
    var activeProfile: DriveProfile { profileOverride ?? drive }

    /// How fast the joystick moves, when a dial rather than a profile is
    /// setting it. Nil leaves `joystickTopSpeed` exactly as it was.
    @Published var joystickSpeed: CLLocationSpeed?

    /// Named driving profiles. Switching between them beats retuning thirty
    /// parameters every time the kind of journey changes.
    let profiles: DriveProfileStore

    /// Saved routes, and where an interrupted one got to.
    let routeStore = RouteStore()

    /// Non-nil while a route is playing.
    @Published private(set) var telemetry: DriveTelemetry?
    /// Non-nil while the joystick is on. The route HUD's smaller sibling: the
    /// joystick moved you at a speed you set and never showed you either it or
    /// how far you'd gone.
    @Published private(set) var joystick: JoystickTelemetry?
    @Published private(set) var isRoutePaused = false
    /// Countdown before the first fix, when `drive.startDelaySeconds` is set.
    @Published private(set) var routeCountdown: Int?
    /// Set when a drive reaches its end, cleared when the summary is dismissed.
    @Published var lastTrip: TripSummary?
    /// Whether the direct engine has been seen to move the location — see
    /// `DirectSimulationCheck`. Checked once per launch, on the first teleport.
    @Published private(set) var directCheck: DirectCheckResult = .notRun

    /// Kept so the summary can report wall-clock time, which is not the same as
    /// simulated time whenever the scale isn't 1×.
    private var routeStartedAt: Date?
    private var lastRouteName = "Route"

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    /// Bumped whenever a route starts or is cancelled. A finishing task only
    /// tears down shared state if it is still the current one — otherwise
    /// restarting a route would have the outgoing task clear the incoming
    /// route's telemetry a moment after it began.
    private var routeGeneration = 0
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private var toastTask: Task<Void, Never>?
    private let locationKeeper = BackgroundKeepAlive()
    /// The engine the location currently set was set through, so Stop clears
    /// it with the same one. `nil` when nothing is set.
    private var activeBackend: LocationBackend?
    /// Whether the last fix sent carried a speed. The direct engine hands
    /// `locationd` a whole `CLLocation`, and `locationd` keeps replaying the
    /// last one — so a joystick let go or a drive stopped mid-route has to say
    /// "stationary" once, or every app goes on reading 50 km/h from a phone
    /// that has stopped.
    private var lastFixWasMoving = false
    /// Where the time zone was last asked to follow. A drive asks again only
    /// once it has gone far enough to be somewhere else.
    private var timeZoneAnchor: CLLocationCoordinate2D?
    /// The keeper is paused in the background when nothing needs it — see
    /// `sceneDidEnterBackground`.
    private var keeperPausedForBackground = false
    private let directChecker = DirectSimulationCheck()

    /// Kept rather than built per fix: a generator is an object with a Taptic
    /// Engine connection behind it, and making one for every buzz is both an
    /// allocation and the reason `prepare()` exists.
    private let limitHaptic = UIImpactFeedbackGenerator(style: .rigid)
    /// Whether the last fix was over the limit, so the haptic fires on the
    /// crossing — which is what `hapticOnLimitChange` says it does. It was
    /// firing on *every* fix while over the limit instead: four buzzes a second
    /// for as long as you were speeding, which is a battery drain and, on a
    /// motorway stretch, several thousand of them.
    private var wasOverLimit = false

    /// Reverse-geocodes the pin so coordinates aren't the only thing on screen.
    /// Owned here rather than by a view so a starred favourite can be named
    /// after the place instead of its latitude.
    let places = PlaceResolver()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    private var cancellables = Set<AnyCancellable>()
    @Published private(set) var lastConfirmedAt: Date?
    @Published private(set) var verificationIssue: String?
    private var lastRejectionLog: SimulationVerification.Rejection?
    @Published private(set) var isRecovering = false
    @Published private(set) var isChangingDestination = false
    @Published var flightConfiguration = FlightConfiguration()
    @Published var flightPoints: [Coordinate2D?] = Array(repeating: nil, count: 6)
    @Published private(set) var flightFix: FlightFix?
    @Published private(set) var flightPath: [CLLocationCoordinate2D] = []
    @Published private(set) var isFlightPaused = false
    @Published private(set) var savedFlight = FlightCheckpoint.load()
    private var flightTask: Task<Void, Never>?
    private var flightGeneration = 0
    private var currentFlightPlan: FlightPlan?
    private var verification = SimulationVerification()
    private var commandGeneration = 0
    private var commandInFlight = false
    private var isStopping = false
    private var recoveryTask: Task<Void, Never>?
    private var backgroundBudgetExpired = false
    private var backgroundTaskRequested = false
    private var failureNotified = false
    private var lastEvidenceLog = Date.distantPast
    private var currentResumeState: RouteResumeState?
    private var ownsResumeProfileOverride = false
    private var monitoringStartedAt = Date.distantFuture

    /// Shared so App Intents — which run in this process but outside the view
    /// hierarchy — can reach the same session the UI is showing.
    static let shared = SpoofSession()

    init() {
        // Built locally first: `drive` is a working copy of the store's active
        // profile, and Swift wants every stored property set before `self` is
        // touched.
        let store = DriveProfileStore()
        profiles = store
        drive = store.active
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)

        // The store keeps routes; it doesn't know how to name a place. Handed
        // the geocoder here so a saved route can say where it runs between.
        routeStore.nameResolver = { await PlaceNamer.shared.name(for: $0) }

        // Nested ObservableObjects don't propagate: views watching the session
        // would never redraw when an address resolves or a profile is renamed.
        for nested in [
            places.objectWillChange,
            profiles.objectWillChange,
            routeStore.objectWillChange,
        ] as [ObservableObjectPublisher] {
            nested
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // The direct engine's simulation outlives the app. Opening on "Not
        // Spoofing" over a phone that is still somewhere else would leave no
        // Stop button to end it.
        if LocationBackend.current == .direct, let record = DirectSimulationRecord.load() {
            simulated = record.coordinate
            pin = record.coordinate
            status = .verifying
            activeBackend = .direct
            timeZoneAnchor = record.coordinate
        }
        if simulated == nil, let record = HeldPositionRecord.load() {
            simulated = record.coordinate.clLocation
            pin = simulated
            status = .verifying
        }
        LocationProbe.shared.$reading
            .sink { [weak self] reading in
                if let reading { self?.observe(reading) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in SessionDiagnostics.shared.record("Changement de route audio détecté; cause de perte non déterminée") }
            .store(in: &cancellables)
        SessionDiagnostics.shared.record("Ouverture de Locus Next; état à vérifier")
    }

    /// Holds the display awake while there is something moving on it.
    ///
    /// Called from every place that starts or ends a drive or the joystick, and
    /// again when the profile's toggle changes — iOS resets this on its own when
    /// the app is backgrounded, so it costs nothing to set more often than
    /// strictly needed and everything to set it less.
    private func refreshIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = activeProfile.keepScreenAwake && (isRouting || joystickActive)
    }

    /// Shows `message` briefly, replacing whatever was there. Cancelling the
    /// previous timer matters: two teleports in a row would otherwise have the
    /// first one's timer clear the second one's message early.
    func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// Switches the active profile, replacing the live working copy.
    func selectProfile(_ id: UUID) {
        guard let profile = profiles.profile(id) else { return }
        clearResumeProfileOverride()
        profiles.select(id)
        drive = profile
    }

    /// Sets the pin from a deliberate action — a map tap, a search result, a
    /// favourite — and asks what's there.
    ///
    /// Separate from assigning `pin` because `apply` rewrites `pin` on every
    /// simulated fix; routing that through a geocoder would mean a request per
    /// second for the length of a route.
    func setPin(_ coordinate: CLLocationCoordinate2D?) {
        pin = coordinate
        places.resolve(coordinate)
    }

    /// The address of the pin, when one has been resolved for where it is now.
    var pinAddress: String? { places.address(for: pin) }

    /// The address of the fix currently being simulated.
    var simulatedAddress: String? { places.address(for: simulated) }

    var isSpoofing: Bool {
        if simulated != nil { return true }
        if status.isDropped { return true }
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        if case .verifying = status { return true }
        return false
    }

    var isRouting: Bool { routeTask != nil || flightTask != nil }
    var isFlying: Bool { flightTask != nil }

    /// The engine a teleport would use right now.
    var backend: LocationBackend { LocationBackend.current }

    /// Why a teleport can't happen right now, or `nil` if it can — short of
    /// the tunnel, which `prepareTunnel` raises on demand. The direct engine
    /// needs nothing at all; otherwise the method chosen in Settings decides
    /// (a pairing file, the trusted certificate, or both).
    func readinessProblem(pairing: PairingStore) -> String? {
        guard backend == .tunnel else { return nil }
        return SpoofBackend.current.readinessProblem(pairing: pairing)
    }

    /// For callers that report rather than act, like the Siri intents.
    func canSpoof(pairing: PairingStore) -> Bool {
        readinessProblem(pairing: pairing) == nil
    }

    private func isReady(_ pairing: PairingStore) -> Bool {
        guard let problem = readinessProblem(pairing: pairing) else { return true }
        lastError = problem
        return false
    }

    // MARK: - Teleport

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard !isStopping, isReady(pairing) else { return }
        cancelRoute(settle: false)
        stopJoystick(settle: false)
        invalidateCommands()
        let generation = commandGeneration
        setPin(coordinate)
        Task { [weak self] in
            guard let self else { return }
            guard await self.prepareTunnel() else { return }
            guard generation == self.commandGeneration, !self.isStopping else { return }
            await self.apply(coordinate, pairing: pairing, markRecent: true, interactive: true)
        }
    }

    /// Clears the simulated location.
    ///
    /// Kicks the work off and returns, so the Stop button doesn't sit pressed
    /// while the engine tears the session down. `isBusy` covers the gap.
    func stop(pairing: PairingStore) {
        Task { [weak self] in
            await self?.stopAndWait(pairing: pairing)
        }
    }

    /// The same, awaited. For callers that report an outcome — the Siri intent
    /// shouldn't say "back to your real location" before it is.
    func stopAndWait(pairing: PairingStore) async {
        guard !isStopping else { return }
        isStopping = true
        invalidateCommands()
        // No settling here: a "stationary" fix sent on the way out could land
        // after the clear and put the location straight back.
        cancelRoute(settle: false)
        stopJoystick(settle: false)
        stopResend()
        stopHealth()
        isBusy = true
        while commandInFlight { try? await Task.sleep(nanoseconds: 50_000_000) }
        // Cleared through whichever engine set it — the Settings switch is
        // locked while spoofing, but a location restored from a previous launch
        // was set by the direct engine whatever the switch says now.
        let engine = activeBackend ?? backend
        let result: Result<Void, LocationEngineError>
        switch engine {
        case .direct:
            result = await DirectLocationEngine.clear()
        case .tunnel:
            // Clearing the developer service needs the tunnel, and reconnects
            // over it if the old session is gone — so bring it back first if
            // it dropped.
            if SpoofBackend.current.usesDeveloper {
                await prepareTunnel()
            }
            result = await LocationEngine.clear(
                pairingPath: pairing.hasPairingFile ? pairing.pairingPath : nil,
                deviceIP: TunnelConfig.targetIP
            )
        }
        finishStop(result, engine: engine)
        isStopping = false
    }

    private func finishStop(_ result: Result<Void, LocationEngineError>, engine: LocationBackend) {
        isBusy = false
        switch result {
        case .success:
            let wasNetwork = engine == .tunnel && SpoofBackend.current.usesNetwork && simulated != nil
            simulated = nil
            status = .idle
            activeBackend = nil
            verification.reset()
            LocationProbe.shared.monitorSession(false)
            HeldPositionRecord.clear()
            SessionDiagnostics.shared.record("Arrêt demandé accepté par le moteur")
            lastFixWasMoving = false
            if engine == .direct { DirectSimulationRecord.clear() }
            // Back to the real place, so back to its time zone.
            timeZoneAnchor = nil
            TimeZoneFollower.requestUpdate()
            endBackground()
            if wasNetwork {
                // iOS keeps the positions it was given until it next asks.
                flash("Stopped — turn Location Services off and on to get your real location back")
            }
            // Keep location updates running so the map puck / locate button
            // can return to the real GPS fix (not the leftover pin).
            locationKeeper.start()
        case .failure(let error):
            lastError = error.localizedDescription
            status = .dropped(error.localizedDescription)
            postDropNotification(error.localizedDescription)
        }
    }

    /// Network mode keeps going without the app: the extension holds the
    /// coordinate. On launch, pick that spoof back up instead of showing "not
    /// spoofing" over one that is still in force.
    func adoptNetworkSpoofIfRunning(pairing: PairingStore) async {
        // A direct-engine spoof restored at launch is already showing.
        guard backend == .tunnel, SpoofBackend.current.usesNetwork, status == .idle, simulated == nil,
              let running = await NetworkSpoofer.shared.adoptRunning() else { return }
        let coordinate = CLLocationCoordinate2D(latitude: running.latitude, longitude: running.longitude)
        simulated = coordinate
        setPin(coordinate)
        status = .verifying
        beginBackground()
        startResend(pairing: pairing)
        startHealth(pairing: pairing)
    }

    /// Best-known real device coordinate (not the teleport pin).
    ///
    /// CoreLocation reports WGS-84; the map is GCJ-02 in mainland China, so the
    /// fix is moved into map space before anything draws or starts from it.
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate.map { MapDatumMode.current.fromWGS84($0) }
    }

    /// Sends the location being simulated again, through the same path a
    /// teleport takes. For settings that change what a fix *says* — altitude,
    /// the China map offset — so they take effect now rather than on the next
    /// teleport. Left alone while something is moving: the next fix is a
    /// fraction of a second away anyway.
    func reapplyCurrentLocation() {
        guard isSpoofing, !isRouting, !joystickActive, let here = simulated else { return }
        let generation = commandGeneration
        Task { [weak self] in
            guard let self, generation == self.commandGeneration else { return }
            await self.apply(here, pairing: PairingStore.shared, markRecent: false)
        }
    }

    /// Adds bookmarks from Geranium or Mika's LocSim to favourites, skipping
    /// any spot already starred. Returns how many were new.
    @discardableResult
    func importLegacyBookmarks(_ bookmarks: [LegacyBookmarks.Bookmark]) -> Int {
        var added = 0
        // Reversed because each new favourite goes on top: this way the list
        // ends up in the order the other app kept it.
        for bookmark in bookmarks.reversed() {
            // Both apps stored what they handed `locationd`: WGS-84. Favourites
            // are kept in map space, like everything else the map touches.
            let wgs = CLLocationCoordinate2D(latitude: bookmark.latitude, longitude: bookmark.longitude)
            let coordinate = MapDatumMode.current.fromWGS84(wgs)
            guard !isFavorite(coordinate) else { continue }
            _ = addFavorite(name: bookmark.name, coordinate: coordinate)
            added += 1
        }
        return added
    }

    /// Asks CoreLocation whether the direct engine's location took.
    ///
    /// The entitlement can be present and `locationd` still not listen, and
    /// nothing in `CLSimulationManager`'s API would say so. Rather than leave
    /// that to be discovered in Maps, a "not taking" verdict says it here and
    /// points at the tunnel, which works regardless of how Locus was installed.
    func checkDirectSimulation() {
        guard activeBackend == .direct, let here = simulated else {
            directCheck = .notRun
            return
        }
        directCheck = .checking
        let wire = MapDatumMode.current.toWGS84(here)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.directChecker.verify(wire)
            // Stopped, or moved on to the tunnel, while the check ran.
            guard self.activeBackend == .direct || result == .working else {
                self.directCheck = .notRun
                return
            }
            self.directCheck = result
            if result == .notTaking, !self.isRouting, !self.joystickActive {
                self.lastError = "iOS is still reporting your real location. This copy of Locus holds the location-simulation entitlement, "
                    + "but locationd isn’t accepting it here. Settings → Location → turn off “Set the location directly” to use the developer tunnel instead."
            }
        }
    }

    // MARK: - App lifecycle

    /// The keeper's background location updates are what keep a tunnel session
    /// alive behind the lock screen. The direct engine's simulation needs no
    /// keeping alive, so when nothing is moving there is no reason to keep the
    /// GPS and the app running in the background for it.
    func sceneDidEnterBackground() {
        checkpointRoute()
        checkpointFlight()
        SessionDiagnostics.shared.record("Passage en arrière-plan; exécution soumise à iOS")
        guard backend.persistsOnItsOwn, !isRouting, !joystickActive else { return }
        locationKeeper.stop()
        keeperPausedForBackground = true
    }

    func sceneWillEnterForeground() {
        backgroundBudgetExpired = false
        endBackground()
        backgroundTaskRequested = false
        SessionDiagnostics.shared.record("Retour au premier plan; nouvelle vérification")
        if keeperPausedForBackground {
            keeperPausedForBackground = false
            locationKeeper.start()
        }
        if simulated != nil, !verification.isFresh(at: Date()) {
            status = .verifying
            refreshVerification()
            // Refresh the existing session first. Missing callbacks while
            // locked do not justify tearing down a working developer channel.
            reapplyCurrentLocation()
        }
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    /// Brings Locus' own tunnel up if it isn't already, so a teleport doesn't
    /// fail with "could not open the developer tunnel" when one tap could have
    /// fixed it. Silent when the tunnel is already reachable.
    ///
    /// Returns `false` only when there is no usable tunnel *and* none can be
    /// raised — a sideloaded build without the VPN entitlement, LiveContainer,
    /// or a refused configuration. The caller stops there rather than letting
    /// the location engine fail several layers down with an error that blames
    /// the wrong thing.
    @discardableResult
    private func prepareTunnel() async -> Bool {
        // The direct engine talks to `locationd` from this process. There is
        // no tunnel to raise, and raising one anyway would be a VPN prompt for
        // nothing.
        guard backend.needsTunnel else { return true }

        let controller = TunnelController.shared
        if NextBuild.usesExternalTunnel {
            // Never create, replace or stop LocalDevVPN's configuration.
            let reachable = await controller.probe()
            SessionDiagnostics.shared.record(reachable
                ? "LocalDevVPN: connexion TCP Developer réussie"
                : "LocalDevVPN: connexion TCP Developer impossible (avant appairage)")
            if !reachable {
                lastError = "Le service Developer ne répond pas via LocalDevVPN (10.7.0.1:49152). Vérifiez que LocalDevVPN est actif. Si cela arrive uniquement en 5G, essayez une initialisation en Wi-Fi, puis exportez les diagnostics après le passage en réseau mobile."
                SessionDiagnostics.shared.record("Service Developer inaccessible via LocalDevVPN")
            }
            return reachable
        }

        // Network mode brings its own tunnel up inside `NetworkSpoofer.set`, and
        // only Locus' own will do — pointing someone at LocalDevVPN here would
        // be pointing them at something that can't help.
        if SpoofBackend.current == .network { return true }

        if controller.autoConnect {
            if await controller.ensureConnected() { return true }
        } else if TunnelController.loopbackReachable {
            return true
        }

        guard !TunnelController.loopbackReachable else { return true }

        if let blocker = controller.blocker ?? TunnelController.staticBlocker {
            // The explanation sheet says all of this properly, with the button
            // that fixes it — an alert on top would just be the same words twice.
            NotificationCenter.default.post(name: .locusShowTunnelTrouble, object: blocker)
            return false
        }

        lastError = "The tunnel to \(TunnelConfig.targetIP) isn’t up. Start it from the status bar, or connect the LocalDevVPN app."
        return false
    }

    // MARK: - Joystick

    func startJoystick(pairing: PairingStore) {
        guard !isStopping, isReady(pairing) else { return }
        let start = simulated ?? pin ?? realCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        cancelRoute(settle: false)
        let generation = commandGeneration
        Task { [weak self] in
            guard let self else { return }
            guard await self.prepareTunnel() else { return }
            guard generation == self.commandGeneration, !self.isStopping else { return }
            guard await self.apply(start, pairing: pairing, markRecent: false, interactive: true),
                  await self.waitForConfirmation(generation: generation) else { return }
            self.joystickActive = true
            self.joystick = JoystickTelemetry()
            self.refreshIdleTimer()
            self.joystickTimer?.invalidate()
            self.joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.tickJoystick(pairing: pairing)
                }
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    /// - Parameter settle: report the location as stationary once the stick is
    ///   gone. Off when something else is about to send a fix of its own.
    func stopJoystick(settle: Bool = true) {
        if joystickActive { invalidateCommands() }
        joystickActive = false
        joystickVector = .zero
        joystick = nil
        joystickTimer?.invalidate()
        joystickTimer = nil
        refreshIdleTimer()
        if settle { settleMotion() }
    }

    /// Sends the current spot again with no speed, if the last fix had one.
    ///
    /// Only the direct engine carries speed and heading at all; the developer
    /// service takes coordinates and nothing else, so there is nothing to undo.
    private func settleMotion() {
        guard lastFixWasMoving, activeBackend == .direct, let here = simulated else { return }
        lastFixWasMoving = false
        let generation = commandGeneration
        Task { [weak self] in
            guard let self, generation == self.commandGeneration,
                  self.simulated != nil, !self.isRouting, !self.joystickActive else { return }
            await self.apply(here, pairing: PairingStore.shared, markRecent: false, motion: .stationary)
        }
    }

    /// Top speed the joystick moves at. A fixed speed set for routes is an
    /// explicit "go this fast" and applies here too; otherwise the travel mode
    /// decides, as before.
    ///
    /// `joystickSpeed` beats both. Fun mode's Move dial is a speed *for
    /// walking around*, and tying it to the profile made it change when a trip
    /// on the next tab switched the travel mode to driving.
    private var joystickTopSpeed: CLLocationSpeed {
        if let joystickSpeed { return max(0.3, joystickSpeed) }
        return activeProfile.speedSource == .fixed
            ? max(0.3, activeProfile.fixedSpeedMetresPerSecond)
            : travelMode.baseSpeed
    }

    private func tickJoystick(pairing: PairingStore) async {
        guard joystickActive, !commandInFlight, !isRecovering, !isStopping,
              verification.isFresh(at: Date()), let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)

        // Stick centred: still report, so the readout says "stopped" instead of
        // freezing on the last speed it happened to be moving at.
        guard magnitude > 0.08 else {
            joystick?.speed = 0
            joystick?.course = nil
            // Released: one stationary fix, so apps stop reading the last speed.
            if lastFixWasMoving || Date().timeIntervalSince(verification.commands.last?.sentAt ?? .distantPast) >= 5 {
                await apply(current, pairing: pairing, markRecent: false, motion: .stationary)
            }
            return
        }

        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        // Clamped exactly as the route walker clamps the same parameter. Left
        // open, a stored jitter above 1 makes the multiplier negative, and the
        // joystick drives you backwards at random.
        let jitter = (1 + Double.random(in: -1...1) * activeProfile.speedJitter).clamped(to: 0.5...1.5)
        let speed = joystickTopSpeed * min(1.0, magnitude) * jitter
        let dt = 0.25
        let meters = speed * dt
        let next = Geo.offset(current, east: nx * meters, north: ny * meters)

        let course = Geo.bearing(from: current, to: next)
        if await apply(next, pairing: pairing, markRecent: false, motion: Motion(speed: speed, course: course)), joystickActive {
            joystick?.speed = speed
            joystick?.course = course
            joystick?.distance += meters
        }
    }

    // MARK: - Independent flight simulation

    func startFlight(_ configuration: FlightConfiguration, elapsed: Double = 0) {
        guard !isStopping, isReady(PairingStore.shared) else { return }
        let plan: FlightPlan
        do { plan = try FlightPlan(configuration) }
        catch { lastError = error.localizedDescription; return }
        guard elapsed.isFinite, (0...plan.duration).contains(elapsed) else { return }
        cancelRoute(settle: false)
        stopJoystick(settle: false)
        currentFlightPlan = plan
        flightPath = plan.legs.flatMap { $0.track }
        flightConfiguration = configuration
        flightPoints = configuration.points.map { Optional($0) }
        flightFix = plan.fix(at: elapsed)
        verificationIssue = nil
        isFlightPaused = false
        let generation = flightGeneration
        checkpointFlight()
        flightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.flightGeneration {
                    self.flightTask = nil
                    self.refreshIdleTimer()
                }
            }
            let pairing = PairingStore.shared
            guard await self.prepareTunnel(), generation == self.flightGeneration, !Task.isCancelled else { return }
            var clock = elapsed
            var lastSave = elapsed
            var phase: FlightPhase?
            guard await self.apply(plan.fix(at: clock).coordinate, pairing: pairing, markRecent: false)
                    || self.isRecovering else { return }
            // Send just one short movement along the requested flight before
            // waiting. A static point may not generate new Core Location fixes.
            // The scenario clock is committed only after fresh confirmation.
            self.refreshVerification()
            let command = self.commandGeneration
            if !self.isRecovering, !self.isFlightPaused,
               !(await self.waitForConfirmation(generation: command, seconds: 3)),
               !self.isRecovering, command == self.commandGeneration,
               generation == self.flightGeneration, !Task.isCancelled,
               !self.backgroundBudgetExpired,
               let probe = plan.startupProbe(at: clock) {
                SessionDiagnostics.shared.record("Vol: avance de vérification unique, limitée à 5 m")
                let pause = max(0, probe.elapsed - clock - 3)
                if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
                guard generation == self.flightGeneration, !Task.isCancelled, !self.isStopping,
                      !self.isFlightPaused else { return }
                guard await self.apply(probe.coordinate, pairing: pairing, markRecent: false) else { return }
                guard await self.awaitRecovery(pairing: pairing, coordinate: probe.coordinate),
                      generation == self.flightGeneration, !Task.isCancelled else { return }
                clock = probe.elapsed
                self.flightFix = probe
                self.checkpointFlight()
            }
            while generation == self.flightGeneration, !Task.isCancelled, !self.isStopping {
                guard await self.awaitRecovery(pairing: pairing, coordinate: plan.fix(at: clock).coordinate) else {
                    self.checkpointFlight(); return
                }
                guard generation == self.flightGeneration, !Task.isCancelled else { return }
                if self.isFlightPaused {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                let tick = ProcessInfo.processInfo.systemUptime
                let next = min(plan.duration, clock + 1)
                let fix = plan.fix(at: next)
                guard await self.apply(fix.coordinate, pairing: pairing, markRecent: false) else {
                    if self.isRecovering { continue }
                    self.checkpointFlight(); return
                }
                guard generation == self.flightGeneration, !Task.isCancelled else { return }
                clock = next
                self.flightFix = fix
                if fix.phase != phase {
                    phase = fix.phase
                    SessionDiagnostics.shared.record("Phase aérienne: \(fix.phase.rawValue)")
                    self.checkpointFlight()
                }
                if clock - lastSave >= 5 { self.checkpointFlight(); lastSave = clock }
                if clock >= plan.duration {
                    self.verification.reset()
                    guard await self.apply(fix.coordinate, pairing: pairing, markRecent: false)
                            || self.isRecovering else { return }
                    guard await self.awaitRecovery(pairing: pairing, coordinate: fix.coordinate),
                          generation == self.flightGeneration, !Task.isCancelled else { return }
                    FlightCheckpoint.clear()
                    self.savedFlight = nil
                    self.currentFlightPlan = nil
                    HeldPositionRecord.save(fix.coordinate)
                    self.postSessionEvent("Scénario terminé", body: "La position d’arrivée vient d’être confirmée.")
                    return
                }
                let delay = max(0.02, 1 - (ProcessInfo.processInfo.systemUptime - tick))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        refreshIdleTimer()
    }

    func toggleFlightPause() {
        guard isFlying else { return }
        isFlightPaused.toggle()
        checkpointFlight()
    }

    func resumeFlightCheckpoint() {
        guard let savedFlight else { return }
        startFlight(savedFlight.configuration, elapsed: savedFlight.elapsed)
    }

    private func checkpointFlight() {
        guard let plan = currentFlightPlan, let fix = flightFix else { return }
        let checkpoint = FlightCheckpoint(configuration: plan.configuration, elapsed: fix.elapsed, savedAt: Date())
        checkpoint.save()
        savedFlight = checkpoint
    }

    private func cancelFlight(keepResumePoint: Bool = false) {
        if keepResumePoint { checkpointFlight() }
        flightGeneration += 1
        flightTask?.cancel()
        flightTask = nil
        flightFix = nil
        flightPath = []
        currentFlightPlan = nil
        isFlightPaused = false
        if !keepResumePoint { FlightCheckpoint.clear(); savedFlight = nil }
    }

    // MARK: - Routes

    /// Plays `coordinates` using the current `DriveProfile`.
    ///
    /// - Parameter expectedSpeed: `MKRoute.distance / expectedTravelTime` when
    ///   the path came from Apple's directions. Without it the road-limit
    ///   estimate has nothing to scale off and falls back to the travel mode.
    func startRoute(
        _ coordinates: [CLLocationCoordinate2D],
        pairing: PairingStore,
        expectedSpeed: CLLocationSpeed? = nil,
        name: String = "Route",
        overrides: [LimitOverride] = [],
        recordedSpeed: ((CLLocationDistance) -> CLLocationSpeed)? = nil,
        // The timestamps behind `recordedSpeed`, kept only so the resume file
        // can carry them. A closure can't be written to disk, so without this
        // an interrupted "As recorded" drive came back at a generic pace.
        recordedTimes: [Date]? = nil,
        startingAt startDistance: CLLocationDistance = 0,
        roads: [RoadSegment] = [],
        startingLap: Int = 1,
        restoredPlan: RoutePlan? = nil,
        restoredWalker: DriveWalkerSnapshot? = nil,
        restoredProfile: DriveProfile? = nil
    ) {
        guard !isStopping, isReady(pairing) else { return }
        guard coordinates.count >= 2 else {
            lastError = "Build or draw a route first."
            return
        }

        // The pin is about to move every second; an address for where it
        // started would only go stale and mislead.
        places.clear()

        let profile = restoredProfile ?? activeProfile
        let mode = travelMode
        let basePlan = restoredPlan ?? RouteSimulator.plan(
            coordinates: coordinates,
            profile: profile,
            mode: mode,
            routeExpectedSpeed: expectedSpeed,
            overrides: overrides,
            recordedSpeed: recordedSpeed,
            roads: roads
        )
        guard !basePlan.isEmpty else {
            lastError = "That route is too short to drive."
            return
        }
        cancelRoute(settle: false)
        stopJoystick(settle: false)
        invalidateCommands()

        if let restoredProfile {
            profileOverride = restoredProfile
            ownsResumeProfileOverride = true
        }
        isRoutePaused = false
        routeStartedAt = Date()
        lastRouteName = name
        lastTrip = nil
        let opening = DriveTelemetry(totalDistance: basePlan.totalDistance)
        telemetry = opening

        if profile.showLiveActivity {
            LiveActivityController.shared.start(
                routeName: name,
                profileName: profile.name,
                state: Self.activityState(for: opening, profile: profile, paused: false)
            )
        }

        routeGeneration += 1
        let generation = routeGeneration
        var initialState = RouteResumeState(
            routeName: name, coordinates: coordinates.codable,
            expectedTravelTime: expectedSpeed.map { basePlan.totalDistance / max($0, 0.1) } ?? 0,
            distance: basePlan.totalDistance, recordedTimes: recordedTimes, roads: roads,
            overrides: overrides, travelled: startDistance, lap: max(1, startingLap), profileID: profile.id
        )
        initialState.scenarioID = UUID()
        initialState.travelMode = mode
        initialState.profileSnapshot = profile
        initialState.planSnapshot = SavedRoutePlan(basePlan)
        initialState.walkerSnapshot = restoredWalker
        currentResumeState = initialState
        checkpointRoute()

        routeTask = Task { [weak self] in
            // Set inside the task, after `routeTask` is assigned: `isRouting`
            // reads that, so calling this any earlier would ask about a route
            // that doesn't exist yet.
            self?.refreshIdleTimer()
            guard let self else { return }
            guard await self.prepareTunnel() else {
                self.finishRoute(generation: generation, completed: false)
                return
            }
            guard generation == self.routeGeneration, !Task.isCancelled else { return }
            await self.countDown(seconds: profile.startDelaySeconds)
            var completed = false
            if !Task.isCancelled {
                completed = await self.run(
                    plan: basePlan,
                    profile: profile,
                    pairing: pairing,
                    resume: initialState,
                    startDistance: startDistance
                )
            }
            self.finishRoute(generation: generation, completed: completed)
        }
    }

    private func finishRoute(generation: Int, completed: Bool) {
        guard generation == routeGeneration else { return }

        // Arriving is the one moment of a drive worth marking, and it used to
        // be the one that showed nothing: the HUD simply vanished after forty
        // minutes. Only for a drive that actually reached the end — a cancel
        // bumps the generation and never gets here.
        if completed, let telemetry, telemetry.distanceTravelled > 0 {
            lastTrip = TripSummary(
                routeName: lastRouteName,
                distance: telemetry.distanceTravelled,
                simulatedSeconds: telemetry.elapsed,
                wallClockSeconds: routeStartedAt.map { Date().timeIntervalSince($0) } ?? telemetry.elapsed,
                laps: telemetry.lap,
                profileName: activeProfile.name,
                mode: travelMode
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        routeStartedAt = nil

        routeTask = nil
        telemetry = nil
        isRoutePaused = false
        routeCountdown = nil
        LiveActivityController.shared.end()
        // A route that reached its end has nothing left to resume.
        if completed {
            routeStore.clearResume()
            currentResumeState = nil
            if verification.isFresh(at: Date()) {
                postSessionEvent("Arrivée", body: "Destination atteinte. La dernière position reste demandée à iOS.")
            }
        } else {
            checkpointRoute()
        }
        if let simulated { HeldPositionRecord.save(simulated) }
        clearResumeProfileOverride()
        refreshIdleTimer()
        settleMotion()
    }

    func pauseRoute() {
        isRoutePaused = true
        currentResumeState?.paused = true
        checkpointRoute()
    }
    func resumeRoute() {
        isRoutePaused = false
        currentResumeState?.paused = false
        checkpointRoute()
    }

    func toggleRoutePause() {
        if isRoutePaused { resumeRoute() } else { pauseRoute() }
        // Pausing is one of the few changes worth an immediate Live Activity
        // push rather than waiting out the throttle.
        if let telemetry, activeProfile.showLiveActivity {
            LiveActivityController.shared.update(
                Self.activityState(for: telemetry, profile: activeProfile, paused: isRoutePaused)
            )
        }
    }

    /// Stops the drive.
    ///
    /// - Parameter keepResumePoint: a deliberate stop discards where it got to;
    ///   starting a different route also does. The progress file is only there
    ///   for the drive nobody chose to end.
    /// - Parameter settle: report the location as stationary where the drive
    ///   stopped. Off when something else is about to send a fix of its own.
    func cancelRoute(keepResumePoint: Bool = false, settle: Bool = true) {
        cancelFlight(keepResumePoint: keepResumePoint)
        invalidateCommands()
        routeGeneration += 1
        routeTask?.cancel()
        routeTask = nil
        telemetry = nil
        isRoutePaused = false
        routeCountdown = nil
        wasOverLimit = false
        LiveActivityController.shared.end()
        if !keepResumePoint {
            routeStore.clearResume()
            currentResumeState = nil
        }
        if let simulated { HeldPositionRecord.save(simulated) }
        clearResumeProfileOverride()
        refreshIdleTimer()
        if settle { settleMotion() }
    }

    private func clearResumeProfileOverride() {
        guard ownsResumeProfileOverride else { return }
        ownsResumeProfileOverride = false
        profileOverride = nil
    }

    func setPlaybackScale(_ scale: Double) {
        if profileOverride != nil { profileOverride?.timeScale = scale }
        else { drive.timeScale = scale }
    }

    /// Picks an interrupted drive back up from where the progress file says it
    /// stopped.
    func resumeSavedRoute(pairing: PairingStore) {
        guard let state = routeStore.resumable else { return }
        if let mode = state.travelMode { travelMode = mode }
        if let profileID = state.profileID, profileID != drive.id {
            selectProfile(profileID)
        }
        // `built` rebuilds the sampler from the stored timestamps, so a drive
        // that was replaying a recorded pace comes back replaying it — before,
        // resuming quietly dropped to the estimator's guess.
        let route = state.built
        startRoute(
            state.coordinates.clLocations,
            pairing: pairing,
            expectedSpeed: route.expectedSpeed,
            name: state.routeName,
            overrides: state.overrides,
            recordedSpeed: route.recordedSpeedSampler(),
            recordedTimes: state.recordedTimes,
            startingAt: state.travelled,
            roads: state.roads,
            startingLap: state.lap,
            restoredPlan: state.planSnapshot?.restored,
            restoredWalker: state.walkerSnapshot,
            restoredProfile: state.profileSnapshot
        )
    }

    /// Pause first, finish the in-flight command, then route from its accepted
    /// coordinate. A failed directions request preserves the old scenario.
    func changeDestination(to destination: CLLocationCoordinate2D, pairing: PairingStore) {
        guard !isStopping, !isRecovering, !isChangingDestination, simulated != nil,
              isReady(pairing), CLLocationCoordinate2DIsValid(destination) else { return }
        let generation = routeGeneration
        let wasRunning = isRouting && !isRoutePaused
        if isRouting { pauseRoute() }
        stopJoystick()
        isChangingDestination = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isChangingDestination = false }
            while self.commandInFlight {
                guard generation == self.routeGeneration, !self.isStopping else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let start = self.simulated, generation == self.routeGeneration, !self.isStopping else { return }
            do {
                let routes = try await RouteBuilder.roadRoutes(from: start, to: destination,
                                                              mode: self.travelMode, alternatives: false)
                guard generation == self.routeGeneration, !self.isStopping else { return }
                guard let route = routes.first else { throw CancellationError() }
                self.startRoute(route.coordinates, pairing: pairing, expectedSpeed: route.expectedSpeed,
                                name: route.name, roads: route.roads)
                SessionDiagnostics.shared.record("Destination modifiée sans effacer la simulation")
            } catch {
                guard generation == self.routeGeneration, !self.isStopping else { return }
                self.lastError = "Impossible de calculer ce trajet. Le parcours précédent est conservé."
                if wasRunning { self.resumeRoute() }
            }
        }
    }

    func holdPosition() {
        guard simulated != nil, !isStopping else { return }
        cancelRoute()
        stopJoystick()
        flash("Position fixe demandée — surveillance active lorsque iOS le permet")
    }

    private func countDown(seconds: Double) async {
        guard seconds >= 1 else { return }
        var remaining = Int(seconds.rounded())
        while remaining > 0, !Task.isCancelled {
            routeCountdown = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            remaining -= 1
        }
        routeCountdown = nil
    }

    /// One pass over `plan`, repeated or reversed per `endBehavior`.
    private func run(
        plan: RoutePlan,
        profile: DriveProfile,
        pairing: PairingStore,
        resume template: RouteResumeState,
        startDistance: CLLocationDistance
    ) async -> Bool {
        let dt = profile.updateInterval

        var current = plan
        var lap = max(1, template.lap)
        var offset = startDistance
        var snapshot = template.walkerSnapshot
        var lastProgressWrite = Date.distantPast

        // Establish and verify the starting position before moving the clock.
        let startWalker = DriveWalker(plan: current, profile: profile, startDistance: offset, snapshot: snapshot)
        let startPoint = startWalker.currentFix.coordinate
        let sent = await apply(startPoint, pairing: pairing, markRecent: false)
        var confirmed = false
        if sent { confirmed = await waitForConfirmation(generation: commandGeneration) }
        if !confirmed {
            guard await awaitRecovery(pairing: pairing, coordinate: startPoint) else { return false }
        }
        guard !Task.isCancelled else { return false }
        postSessionEvent("Trajet lancé", body: "La position initiale est confirmée. Le trajet commence.")

        while !Task.isCancelled {
            let walker = DriveWalker(plan: current, profile: profile, startDistance: offset, snapshot: snapshot)
            let savedPlan = SavedRoutePlan(current)
            offset = 0
            snapshot = nil

            while !Task.isCancelled {
                while isRoutePaused, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard !Task.isCancelled else { return false }
                if !verification.isFresh(at: Date()) || isRecovering {
                    guard await awaitRecovery(pairing: pairing, coordinate: simulated ?? startPoint) else { return false }
                }
                guard let fix = walker.step(dt: dt) else { break }

                // Read from the live profile rather than the snapshot taken at
                // the start: the time scale is the one dial worth moving while
                // watching a drive, and it used to do nothing until the route
                // was restarted. Everything else is baked into the plan and
                // can't change under a walker mid-route, so it stays snapshotted.
                let scale = activeProfile.timeScaleClamped

                // Speed as the phone experiences it: at 4× playback the fixes
                // cover ground four times as fast, and a reported speed that
                // disagreed with the distance between them would be the
                // inconsistency an app notices.
                let tickStarted = ProcessInfo.processInfo.systemUptime
                while !(await apply(fix.coordinate, pairing: pairing, markRecent: false,
                                    motion: fix.isStopped ? .stationary : Motion(speed: fix.speed * scale, course: fix.course))) {
                    guard !Task.isCancelled,
                          await awaitRecovery(pairing: pairing, coordinate: fix.coordinate) else { return false }
                }
                guard !Task.isCancelled else { return false }
                telemetry = DriveTelemetry(
                    speed: fix.speed,
                    speedLimit: fix.speedLimit,
                    course: fix.course,
                    progress: walker.progress,
                    distanceTravelled: fix.distanceTravelled,
                    distanceRemaining: fix.distanceRemaining,
                    elapsed: fix.elapsed,
                    isStopped: fix.isStopped,
                    isOverLimit: fix.isOverLimit,
                    lap: lap,
                    totalDistance: walker.totalDistance
                )

                if fix.isOverLimit != wasOverLimit {
                    wasOverLimit = fix.isOverLimit
                    if fix.isOverLimit, profile.hapticOnLimitChange {
                        limitHaptic.impactOccurred(intensity: 0.4)
                    }
                }

                if profile.showLiveActivity, let telemetry {
                    // Throttled inside the controller: a route emits fixes far
                    // faster than ActivityKit's update budget allows.
                    LiveActivityController.shared.update(
                        Self.activityState(
                            for: telemetry,
                            profile: profile,
                            paused: isRoutePaused,
                            timeScale: scale
                        )
                    )
                }

                // Written every few seconds rather than on a clean exit, so a
                // crash or a swipe-away can still be picked up where it left off.
                var state = template
                state.travelled = fix.distanceTravelled
                state.lap = lap
                state.savedAt = Date()
                state.planSnapshot = savedPlan
                state.walkerSnapshot = walker.snapshot
                state.profileSnapshot?.timeScale = scale
                state.paused = isRoutePaused
                currentResumeState = state
                if Date().timeIntervalSince(lastProgressWrite) >= 5 || fix.isStopped {
                    lastProgressWrite = Date()
                    routeStore.recordProgress(state)
                }

                let remaining = max(0, dt / scale - (ProcessInfo.processInfo.systemUptime - tickStarted))
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            guard !Task.isCancelled else { return false }

            // A fresh confirmation for the endpoint is required before the
            // checkpoint is discarded or arrival is announced.
            verification.reset()
            let endpoint = current.points[current.points.count - 1].coordinate
            let endpointSent = await apply(endpoint, pairing: pairing, markRecent: false)
            var endpointConfirmed = false
            if endpointSent { endpointConfirmed = await waitForConfirmation(generation: commandGeneration) }
            if !endpointConfirmed {
                guard await awaitRecovery(pairing: pairing, coordinate: endpoint) else { return false }
            }
            guard !Task.isCancelled else { return false }

            switch profile.endBehavior {
            case .stop:
                return true
            case .loop:
                lap += 1
                // Straight back to the start line — the jump is a teleport, the
                // same as pressing play again.
                continue
            case .pingPong:
                lap += 1
                current = current.reversed()
                continue
            case .reverseOnce:
                guard lap == 1 else { return true }
                lap += 1
                current = current.reversed()
                continue
            }
        }
        return false
    }

    /// Formats telemetry for the Live Activity.
    ///
    /// The widget receives text, not numbers: it is a separate module, and
    /// giving it `DriveProfile` and `SpeedUnit` just to render "48 km/h" would
    /// drag half the engine over a target boundary and split unit handling in
    /// two.
    /// - Parameter timeScale: the scale in force right now, which is not
    ///   necessarily the one `profile` was snapshotted with — the dial moves
    ///   mid-drive, and an ETA computed at the old scale would be wrong on the
    ///   Lock Screen while the HUD showed the right one.
    private static func activityState(
        for telemetry: DriveTelemetry,
        profile: DriveProfile,
        paused: Bool,
        timeScale: Double? = nil
    ) -> DriveActivityAttributes.ContentState {
        let unit = profile.units
        return DriveActivityAttributes.ContentState(
            speed: "\(Int(unit.fromMetresPerSecond(telemetry.speed).rounded()))",
            unit: unit.short,
            limit: telemetry.speedLimit.map { "\(Int(unit.fromMetresPerSecond($0).rounded()))" },
            progress: telemetry.progress,
            remaining: DriveFormat.distance(telemetry.distanceRemaining) + " left",
            eta: DriveFormat.eta(telemetry: telemetry, timeScale: timeScale ?? profile.timeScale),
            isPaused: paused,
            isStopped: telemetry.isStopped,
            isOverLimit: telemetry.isOverLimit && profile.warnWhenOverLimit
        )
    }

    /// Fuel and CO₂ for a distance driven. Garnish — it is the profile's flat
    /// L/100 km figure times the distance, not anything the simulation measured,
    /// and the UI says so.
    func tripEconomy(distance: CLLocationDistance) -> (litres: Double, gramsCO2: Double) {
        let litres = (distance / 1000) * (drive.consumption / 100)
        // ~2.31 kg CO₂ per litre of petrol burnt.
        return (litres, litres * 2310)
    }

    // MARK: - Places

    @discardableResult
    func addFavorite(name: String, coordinate: CLLocationCoordinate2D, emoji: String? = nil) -> SavedPlace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            emoji: emoji
        )

        // Matching on coordinate rather than id: ids are unique now, so
        // "already starred this spot" is a question about where it is.
        if let existing = favorites.first(where: { $0.isAt(coordinate) }) {
            // Don't let a generic star overwrite a named favourite for the same spot.
            if Self.isGenericFavoriteName(place.name), !Self.isGenericFavoriteName(existing.name) {
                return existing
            }
            // Starring the same spot again from the Pro map carries no emoji;
            // keeping the one it already had beats blanking it because the tap
            // came from a screen that doesn't show them.
            if place.emoji == nil, let kept = existing.emoji {
                return replace(existing, with: SavedPlace(
                    name: place.name,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    emoji: kept,
                    id: existing.id
                ))
            }
            favorites.removeAll { $0.isAt(coordinate) }
        }

        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
        return place
    }

    /// True when this spot is already starred — so the map can show a filled
    /// star instead of offering to save it twice.
    func isFavorite(_ coordinate: CLLocationCoordinate2D) -> Bool {
        favorites.contains { $0.isAt(coordinate) }
    }

    func removeFavorite(at coordinate: CLLocationCoordinate2D) {
        favorites.removeAll { $0.isAt(coordinate) }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    /// Favourites are an ordered list people curate; the order should be theirs.
    func moveFavorites(from offsets: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: offsets, toOffset: destination)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    /// Renames a favourite and sets the emoji Fun mode shows it with, together.
    ///
    /// The spot sheet edits both at once, and an empty name means "leave it" —
    /// clearing the field shouldn't be able to leave a place called nothing.
    func updateFavorite(_ place: SavedPlace, name: String, emoji: String?) {
        guard let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { favorites[index].name = trimmed }
        favorites[index].emoji = emoji
        SavedPlace.save(favorites, key: favoritesKey)
    }

    /// Swaps a favourite for an edited copy, keeping its place in the list.
    @discardableResult
    private func replace(_ existing: SavedPlace, with place: SavedPlace) -> SavedPlace {
        guard let index = favorites.firstIndex(where: { $0.id == existing.id }) else {
            favorites.insert(place, at: 0)
            SavedPlace.save(favorites, key: favoritesKey)
            return place
        }
        favorites[index] = place
        SavedPlace.save(favorites, key: favoritesKey)
        return place
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A resolved address beats every other guess here, and beats the
        // coordinate label by a mile.
        if let address = places.address(for: coordinate) {
            return address
        }
        if let favorite = favorites.first(where: { $0.isAt(coordinate) }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: { $0.isAt(coordinate) }),
           !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    // MARK: - Engine

    /// How the simulated phone is moving, for the engine that can say so.
    struct Motion {
        var speed: CLLocationSpeed
        var course: CLLocationDirection?

        static let stationary = Motion(speed: 0, course: nil)
    }

    /// One fix through whichever engine is in use.
    ///
    /// `coordinate` is in map space; this is the one place it leaves the app,
    /// so this is where a GCJ-02 map coordinate becomes the WGS-84 the
    /// location system expects.
    private func send(
        _ coordinate: CLLocationCoordinate2D,
        through engine: LocationBackend,
        motion: Motion?,
        pairing: PairingStore
    ) async -> Result<Void, LocationEngineError> {
        let wire = MapDatumMode.current.toWGS84(coordinate)
        switch engine {
        case .direct:
            return await DirectLocationEngine.set(DirectLocationEngine.Fix(
                coordinate: wire,
                altitude: DirectSimulationOptions.altitude,
                speed: motion?.speed,
                course: motion?.course
            ))
        case .tunnel:
            return await LocationEngine.set(
                latitude: wire.latitude,
                longitude: wire.longitude,
                pairingPath: pairing.pairingPath,
                deviceIP: TunnelConfig.targetIP
            )
        }
    }

    /// Sends one fix and folds the outcome back into the session's state.
    ///
    /// The suspension is the whole point: the engine call is a round trip over
    /// the tunnel, and it used to run synchronously from the main actor — so
    /// the map froze for its duration on every fix.
    /// - Parameter interactive: whether this fix is one somebody is waiting on.
    ///   `isBusy` only disables the Teleport button, and a route or the joystick
    ///   sets it true and false again several times a second — two published
    ///   changes per fix, each of which invalidates every view watching the
    ///   session, including the map and its route overlay.
    @discardableResult
    private func apply(
        _ coordinate: CLLocationCoordinate2D,
        pairing: PairingStore,
        markRecent: Bool,
        interactive: Bool = false,
        motion: Motion? = nil,
        recovering: Bool = false
    ) async -> Bool {
        let generation = commandGeneration
        guard !isStopping, !Task.isCancelled, !backgroundBudgetExpired,
              CLLocationCoordinate2DIsValid(coordinate),
              recovering || !isRecovering else { return false }
        while commandInFlight {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard generation == commandGeneration, !Task.isCancelled, !isStopping else { return false }
        }
        guard generation == commandGeneration else { return false }
        commandInFlight = true
        defer { commandInFlight = false }
        if status == .idle || status.isDropped {
            status = .connecting
        }
        let engine = backend
        if interactive { isBusy = true }
        let sentAt = Date()
        if verification.commands.isEmpty { monitoringStartedAt = sentAt }
        LocationProbe.shared.monitorSession(true)
        let result = await send(coordinate, through: engine, motion: motion, pairing: pairing)
        if interactive { isBusy = false }
        guard generation == commandGeneration, !Task.isCancelled, !isStopping else { return false }
        switch result {
        case .success:
            simulated = coordinate
            // Keep a map/search selection intact while the route or hold timer
            // sends updates, so it can become the next destination.
            if markRecent || pin == nil { pin = coordinate }
            verification.sent(MapDatumMode.current.toWGS84(coordinate), at: sentAt)
            if let reading = LocationProbe.shared.reading { observe(reading) }
            status = verification.isFresh(at: Date()) ? .active : (recovering ? .reconnecting : .verifying)
            lastError = nil
            activeBackend = engine
            if markRecent { HeldPositionRecord.save(coordinate) }
            lastFixWasMoving = engine == .direct && (motion?.speed ?? 0) > 0.05
            locationKeeper.start()
            followTimeZone(to: coordinate, force: markRecent)
            switch engine {
            case .direct:
                // Nothing to keep alive and nothing that can drop: the
                // simulation is `locationd`'s now. Remembered so the next
                // launch knows it is still running.
                DirectSimulationRecord.save(coordinate)
                if interactive, directCheck == .notRun {
                    checkDirectSimulation()
                }
            case .tunnel:
                beginBackground()
                startResend(pairing: pairing)
                startHealth(pairing: pairing)
            }
            // Ask now, while it is working, rather than at the moment it breaks.
            requestDropAlertsIfNeeded()
            if markRecent {
                pushRecent(coordinate)
                // Only for a deliberate teleport: the health timer and the route
                // walker both come through here, and buzzing once a second for
                // an hour is not confirmation, it's a fault.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if engine == .tunnel, SpoofBackend.current == .network {
                    // Nothing has moved yet: the reply is only rewritten when iOS
                    // next asks Apple, and saying "now at" before that is a lie.
                    // GPS wins over network positioning within seconds; with a
                    // pairing file, Both is what keeps the place from slipping.
                    flash(pairing.hasPairingFile
                          ? "Set to \(suggestedFavoriteName(for: coordinate)) — GPS can pull it back; Both holds it"
                          : "Set to \(suggestedFavoriteName(for: coordinate)) — asking iOS to look again")
                } else {
                    flash("Position envoyée — vérification en cours")
                }
            }
            return true
        case .failure(let error):
            lastError = error.localizedDescription
            status = .dropped(error.localizedDescription)
            SessionDiagnostics.shared.record("Échec moteur: \(error.diagnosticCode)")
            if !recovering {
                beginRecovery(at: markRecent ? coordinate : (simulated ?? coordinate), pairing: pairing)
            }
            return false
        }
    }

    /// Both timers are started from `apply`, which runs up to four times a
    /// second for the length of a route — so they used to be torn down and
    /// rebuilt eight times a second, each rebuild an allocation and two run-loop
    /// edits. The one already running is the one we want; `stopResend` /
    /// `stopHealth` are what end them.
    private func startResend(pairing: PairingStore) {
        guard resendTimer == nil else { return }
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
                // A route re-sends far more often than this on its own; resending
                // underneath it would fight the walker for the current fix.
                guard (!self.isRouting || self.isRoutePaused || self.isFlightPaused), !self.joystickActive, !self.isRecovering,
                      !self.commandInFlight, !self.isBusy, !self.status.isDropped, !self.isStopping else { return }
                await self.apply(sim, pairing: pairing, markRecent: false)
            }
        }
    }

    /// Asks iOS to move the clock to wherever the location now is — on every
    /// deliberate teleport, and during a drive only once it has crossed enough
    /// ground to plausibly be in another zone. Asking four times a second for
    /// an hour would be asking `timed` to do nothing else.
    private func followTimeZone(to coordinate: CLLocationCoordinate2D, force: Bool) {
        if !force, let anchor = timeZoneAnchor, Geo.distance(anchor, coordinate) < 25_000 { return }
        timeZoneAnchor = coordinate
        TimeZoneFollower.requestUpdate()
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.simulated != nil else { return }
                guard !self.isRecovering, !self.isStopping, !self.status.isDropped else { return }
                if !self.verification.isFresh(at: Date()) {
                    self.status = .verifying
                    if UIApplication.shared.applicationState == .active {
                        LocationProbe.shared.refresh()
                    }
                    // A stationary, locked phone may stop delivering fixes.
                    // Keep the confirmation honest without reconnecting on silence.
                }
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        // The best name there is for this spot, not its latitude. Teleporting
        // to somewhere you had searched for by name used to rewrite that recent
        // as "48.85837, 2.29448".
        pushNamedRecent(name: suggestedFavoriteName(for: coordinate), coordinate: coordinate)
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var label = trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed
        // A coordinate label never wins against a name this spot already had.
        if Self.isGenericFavoriteName(label),
           let existing = recents.first(where: { $0.isAt(coordinate) }),
           !Self.isGenericFavoriteName(existing.name) {
            label = existing.name
        }

        let place = SavedPlace(
            name: label,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll { $0.isAt(coordinate) }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid, !backgroundBudgetExpired, !backgroundTaskRequested else { return }
        backgroundTaskRequested = true
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.checkpointRoute()
            self?.checkpointFlight()
            self?.backgroundBudgetExpired = true
            self?.recoveryTask?.cancel()
            self?.recoveryTask = nil
            self?.isRecovering = false
            if self?.simulated != nil { self?.status = .verifying }
            SessionDiagnostics.shared.record("Temps d’exécution supplémentaire expiré; récupération différée")
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Asks for notification permission once, while something is working.
    ///
    /// It used to be requested at the moment of a drop, with the alert posted
    /// immediately after and without waiting for an answer — so the very first
    /// drop, the one that teaches you the feature exists, was always silent.
    /// Asking here means the prompt arrives with context ("this app just
    /// started spoofing") and the alert lands the first time it is needed.
    private static var hasAskedAboutNotifications = false

    private func requestDropAlertsIfNeeded() {
        guard !Self.hasAskedAboutNotifications else { return }
        Self.hasAskedAboutNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postDropNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Locus Next — simulation à vérifier"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: "locus.next.session.failure", content: content, trigger: nil)

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                // Belt and braces: if the ask above never happened, do it now
                // and post only once there is an answer.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            default:
                // Denied. The status bar and the in-app alert still say so.
                break
            }
        }
    }
}

extension SpoofSession {
    private func invalidateCommands() {
        commandGeneration += 1
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        verification.reset()
        monitoringStartedAt = Date()
        failureNotified = false
        if simulated != nil { status = .verifying }
    }

    private func observe(_ reading: LocationProbe.Reading) {
        // A fresh location callback is an actual execution opportunity granted
        // by iOS, unlike a timer that merely survived in memory.
        if abs(Date().timeIntervalSince(reading.timestamp)) < 2 { backgroundBudgetExpired = false }
        guard !isStopping, !status.isDropped || isRecovering else { return }
        let rejection = verification.rejection(coordinate: reading.coordinate, timestamp: reading.timestamp,
                                               accuracy: reading.horizontalAccuracy,
                                               simulated: reading.isSimulatedBySoftware, now: Date())
        if let rejection, simulated != nil, rejection != lastRejectionLog {
            lastRejectionLog = rejection
            SessionDiagnostics.shared.record("Confirmation refusée: \(rejection.rawValue)")
        }
        if verification.observesRealPosition(timestamp: reading.timestamp,
                                            accuracy: reading.horizontalAccuracy,
                                            simulated: reading.isSimulatedBySoftware, now: Date()) {
            verification.reset()
            status = .verifying
            SessionDiagnostics.shared.record("Core Location signale une position non simulée")
            let generation = commandGeneration
            Task { @MainActor [weak self] in
                guard let self, generation == self.commandGeneration, let coordinate = self.simulated else { return }
                self.beginRecovery(at: coordinate, pairing: PairingStore.shared)
            }
        }
        if verification.observe(coordinate: reading.coordinate, timestamp: reading.timestamp,
                                accuracy: reading.horizontalAccuracy,
                                simulated: reading.isSimulatedBySoftware, now: Date()) {
            lastConfirmedAt = verification.confirmedAt
            verificationIssue = nil
            lastRejectionLog = nil
            status = .active
            if Date().timeIntervalSince(lastEvidenceLog) > 30 {
                lastEvidenceLog = Date()
                SessionDiagnostics.shared.record("Position simulée confirmée par Core Location")
            }
        }
    }

    private func waitForConfirmation(generation: Int, seconds: TimeInterval = 8) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, generation == commandGeneration,
                  !isStopping, !backgroundBudgetExpired else { return false }
            if verification.isFresh(at: Date()) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func retrySimulation() {
        guard !isStopping, !isRecovering, let coordinate = simulated ?? pin else { return }
        refreshVerification()
        beginRecovery(at: coordinate, pairing: PairingStore.shared)
    }

    func refreshVerification() {
        guard simulated != nil, !isStopping else { return }
        LocationProbe.shared.monitorSession(true)
        LocationProbe.shared.refresh()
        SessionDiagnostics.shared.record(LocationProbe.shared.diagnosticSummary)
    }

    private func beginRecovery(at coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard !isStopping, !isRecovering, !backgroundBudgetExpired else { return }
        commandGeneration += 1
        let generation = commandGeneration
        verification.reset()
        monitoringStartedAt = Date()
        status = .reconnecting
        isRecovering = true
        checkpointRoute()
        SessionDiagnostics.shared.record("Récupération commencée; scénario suspendu")
        checkpointFlight()
        if !failureNotified {
            failureNotified = true
            postDropNotification("La simulation n’est plus confirmée. Tentatives de reconnexion en cours.")
        }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.commandGeneration == generation {
                    self.recoveryTask = nil
                    self.isRecovering = false
                }
            }
            let detectedAt = ProcessInfo.processInfo.systemUptime
            for (index, offset) in RecoverySchedule.offsets.enumerated() {
                while ProcessInfo.processInfo.systemUptime < detectedAt + offset || self.commandInFlight {
                    guard self.recoveryAllowed(generation) else { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.recoveryAllowed(generation) else { return }
                SessionDiagnostics.shared.record("Tentative de reconnexion \(index + 1)/3")
                self.verification.reset()
                if self.backend == .tunnel { await LocationEngine.disconnectSession() }
                guard self.recoveryAllowed(generation) else { return }
                guard await self.prepareTunnel() else { continue }
                guard self.recoveryAllowed(generation) else { return }
                let sent = await self.apply(coordinate, pairing: pairing, markRecent: false, recovering: true)
                guard self.recoveryAllowed(generation) else { return }
                if sent, await self.waitForConfirmation(generation: generation) {
                    self.status = .active
                    self.lastError = nil
                    self.failureNotified = false
                    SessionDiagnostics.shared.record("Connexion rétablie et position confirmée")
                    self.postSessionEvent("Connexion rétablie", body: "La position simulée vient d’être vérifiée par iOS.")
                    return
                }
            }
            guard self.recoveryAllowed(generation) else { return }
            self.status = .dropped("Simulation non confirmée après trois tentatives")
            self.lastError = "Vérifiez LocalDevVPN et les autorisations de localisation. Une initialisation sur Wi-Fi peut être nécessaire."
            self.verification.reset()
            self.checkpointRoute()
            SessionDiagnostics.shared.record("Trois tentatives épuisées; reprise manuelle nécessaire")
            self.postDropNotification("Trois tentatives n’ont pas permis de confirmer la simulation. Ouvrez Locus Next et vérifiez LocalDevVPN.")
        }
    }

    private func recoveryAllowed(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == commandGeneration && !isStopping && !backgroundBudgetExpired
    }

    /// Waits without advancing the walker or issuing more location commands.
    private func awaitRecovery(pairing: PairingStore, coordinate: CLLocationCoordinate2D) async -> Bool {
        var lastRefresh = Date.distantPast
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !verification.isFresh(at: Date()) || isRecovering {
            guard !Task.isCancelled, !isStopping, !backgroundBudgetExpired else { return false }
            if status.isDropped, !isRecovering { return false }
            if !isRecovering, ProcessInfo.processInfo.systemUptime >= deadline {
                let message = "Aucune position récente confirmée après 30 secondes. Le scénario est sauvegardé. Ouvrez Simulation et diagnostics pour vérifier les lectures, puis reprenez le trajet."
                verificationIssue = message
                status = .verifying
                if UIApplication.shared.applicationState == .active { lastError = message }
                checkpointRoute()
                checkpointFlight()
                SessionDiagnostics.shared.record("Attente de confirmation expirée; scénario sauvegardé")
                SessionDiagnostics.shared.record(LocationProbe.shared.diagnosticSummary)
                return false
            }
            if !isRecovering, Date().timeIntervalSince(lastRefresh) >= 8 {
                lastRefresh = Date()
                if UIApplication.shared.applicationState == .active { LocationProbe.shared.refresh() }
                // An actual send failure starts bounded recovery in apply.
                // Otherwise wait for fresh proof without changing the scenario clock.
                _ = await apply(simulated ?? coordinate, pairing: pairing, markRecent: false)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !Task.isCancelled && verification.isFresh(at: Date()) && !status.isDropped
    }

    private func checkpointRoute() {
        guard var state = currentResumeState else { return }
        state.savedAt = Date()
        state.profileSnapshot?.timeScale = activeProfile.timeScaleClamped
        routeStore.recordProgress(state)
    }

    private func postSessionEvent(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Locus Next — \(title)"
        content.body = body
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.add(UNNotificationRequest(identifier: "locus.next.event.\(title)", content: content, trigger: nil))
        }
    }
}
