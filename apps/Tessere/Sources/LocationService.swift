import Foundation
import CoreLocation
import MapKit
import TessereCore

/// Location-based suggestions ("Attiva ora" in the banner):
/// - finds the shops of each card near the user with MapKit search;
/// - monitors the 20 nearest shops (iOS limit) and notifies "Sei da …?"
///   when the user walks in, even with the app closed (needs "Sempre");
/// - shows "Sei vicino a" in the app when a shop is a few steps away.
/// Positions never leave the iPhone.
@MainActor
@Observable
final class LocationService: NSObject {
    static let shared = LocationService()

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: GeoPoint?
    /// Cards with a shop within ~250 m, nearest first.
    private(set) var nearbyCardIDs: [UUID] = []

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var searching = false
    @ObservationIgnored private var lastSearchAt: Date?
    @ObservationIgnored private var delegateProxy: LocationDelegateProxy?

    private var enabled: Bool { AppModel.shared.data.settings.locationSuggestions == .enabled }

    var isAuthorized: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }
    var hasAlways: Bool { authorization == .authorizedAlways }

    /// Called at launch (also for background relaunches caused by region events).
    func start() {
        guard !started else { return }
        started = true
        let proxy = LocationDelegateProxy(owner: self)
        delegateProxy = proxy
        manager.delegate = proxy
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 150
        authorization = manager.authorizationStatus
    }

    /// "Attiva ora": asks for the permission, then for "Sempre" to monitor shops.
    func activate() {
        start()
        Task { _ = await Notifier.requestAuthorization() }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            beginUpdates()
        case .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    func deactivate() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        for r in manager.monitoredRegions { manager.stopMonitoring(for: r) }
        nearbyCardIDs = []
    }

    func refreshIfNeeded() {
        guard enabled, isAuthorized else { return }
        beginUpdates()
    }

    private func beginUpdates() {
        guard enabled else { return }
        manager.requestLocation()
        if hasAlways, CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    // MARK: Delegate events (forwarded on the main actor)

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        guard enabled else { return }
        if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
            beginUpdates()
        } else if status == .authorizedAlways {
            beginUpdates()
        }
    }

    fileprivate func moved(to point: GeoPoint) {
        lastLocation = point
        guard enabled else { return }
        let cards = AppModel.shared.data.cards
        nearbyCardIDs = LocationPlanner.nearbyCards(cards, at: point).map(\.card.id)
        Task { await refreshShops(near: point) }
        updateRegions()
    }

    fileprivate func enteredRegion(_ identifier: String) {
        guard enabled, let id = LocationPlanner.cardID(fromRegion: identifier),
              let card = AppModel.shared.data.card(id) else { return }
        if !nearbyCardIDs.contains(id) { nearbyCardIDs.insert(id, at: 0) }
        Task { await Notifier.nearby(card: card) }
    }

    // MARK: Cards

    func cardsChanged(_ cards: [Card]) {
        guard enabled, let p = lastLocation else { return }
        nearbyCardIDs = LocationPlanner.nearbyCards(cards, at: p).map(\.card.id)
        updateRegions()
    }

    func cardAdded(_ card: Card) {
        guard enabled, let p = lastLocation else { return }
        Task { await searchShops(for: card, near: p) }
    }

    /// Searches shops of the cards whose list is old or far away (max 8 per round).
    private func refreshShops(near point: GeoPoint) async {
        guard !searching else { return }
        if let last = lastSearchAt, Date().timeIntervalSince(last) < 60 { return }
        searching = true
        lastSearchAt = Date()
        defer { searching = false }
        let now = Date()
        let model = AppModel.shared
        let due = CardQuery.sorted(model.data.cards, by: .frequent, usage: model.data.usage, now: now)
            .filter { $0.kind != .ticket && LocationPlanner.needsRefresh($0, near: point, now: now) }
            .prefix(8)
        for card in due {
            await searchShops(for: card, near: point)
        }
        let cards = model.data.cards
        nearbyCardIDs = LocationPlanner.nearbyCards(cards, at: point).map(\.card.id)
        updateRegions()
    }

    private func searchShops(for card: Card, near point: GeoPoint) async {
        let name = card.catalogEntry?.name ?? card.storeName
        let key = StoreCatalog.normalize(name)
        guard key.count >= 2 else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                                            latitudinalMeters: 25_000, longitudinalMeters: 25_000)
        var points: [GeoPoint] = []
        if let response = try? await MKLocalSearch(request: request).start() {
            let keys = ([name] + (card.catalogEntry?.aliases ?? [])).map(StoreCatalog.normalize)
            for item in response.mapItems {
                let itemName = StoreCatalog.normalize(item.name ?? "")
                // Only shops whose name contains the brand (no unrelated POIs).
                guard keys.contains(where: { itemName.contains($0) }) else { continue }
                let c = item.location.coordinate
                points.append(GeoPoint(latitude: c.latitude, longitude: c.longitude, label: item.name))
            }
        }
        points.sort { point.distance(to: $0) < point.distance(to: $1) }
        AppModel.shared.setStoreLocations(card.id, Array(points.prefix(12)))
    }

    /// Monitors the nearest shops (max 20 regions, 120 m radius).
    private func updateRegions() {
        guard hasAlways, let p = lastLocation,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let wanted = LocationPlanner.regions(for: AppModel.shared.data.cards, near: p)
        let wantedIDs = Set(wanted.map(\.identifier))
        for r in manager.monitoredRegions where !wantedIDs.contains(r.identifier) {
            manager.stopMonitoring(for: r)
        }
        let existing = Set(manager.monitoredRegions.map(\.identifier))
        for w in wanted where !existing.contains(w.identifier) {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: w.point.latitude, longitude: w.point.longitude),
                                          radius: 120, identifier: w.identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }
}

/// CLLocationManager delegate (callbacks on the main thread, forwarded to the main actor).
final class LocationDelegateProxy: NSObject, CLLocationManagerDelegate {
    private weak var owner: LocationService?

    init(owner: LocationService) {
        self.owner = owner
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let owner = self.owner
        Task { @MainActor in owner?.authorizationChanged(status) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let p = GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
        let owner = self.owner
        Task { @MainActor in owner?.moved(to: p) }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        let owner = self.owner
        Task { @MainActor in owner?.enteredRegion(id) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}
}
