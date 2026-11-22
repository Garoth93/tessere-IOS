import Foundation

/// Location-based suggestions: which shops to monitor and which card to
/// suggest when the user is near one.
public enum LocationPlanner {

    public struct Region: Equatable, Sendable {
        public var cardID: UUID
        public var point: GeoPoint
        public var distance: Double

        /// Identifier for CLCircularRegion: "<card uuid>|<index>".
        public var identifier: String
    }

    /// iOS monitors at most 20 regions per app.
    public static let maxRegions = 20

    /// The shops closest to `current` (one card can have several shops),
    /// within `maxDistance` meters, at most `limit`.
    public static func regions(for cards: [Card], near current: GeoPoint,
                               limit: Int = maxRegions, maxDistance: Double = 30_000) -> [Region] {
        var all: [Region] = []
        for card in cards {
            for (i, p) in card.storeLocations.enumerated() {
                let d = current.distance(to: p)
                guard d <= maxDistance else { continue }
                all.append(Region(cardID: card.id, point: p, distance: d, identifier: "\(card.id.uuidString)|\(i)"))
            }
        }
        return Array(all.sorted { $0.distance < $1.distance }.prefix(limit))
    }

    public static func cardID(fromRegion identifier: String) -> UUID? {
        UUID(uuidString: String(identifier.split(separator: "|").first ?? ""))
    }

    /// Cards with a shop within `radius` meters, nearest first.
    public static func nearbyCards(_ cards: [Card], at current: GeoPoint, radius: Double = 250) -> [(card: Card, distance: Double)] {
        var out: [(Card, Double)] = []
        for card in cards {
            guard let d = card.storeLocations.map({ current.distance(to: $0) }).min(), d <= radius else { continue }
            out.append((card, d))
        }
        return out.sorted { $0.1 < $1.1 }
    }

    /// Whether the shop list of a card should be refreshed (old or far away).
    public static func needsRefresh(_ card: Card, near current: GeoPoint, now: Date,
                                    maxAge: TimeInterval = 14 * 86_400, farAway: Double = 15_000) -> Bool {
        guard let at = card.locationsUpdatedAt else { return true }
        if now.timeIntervalSince(at) > maxAge { return true }
        guard let nearest = card.storeLocations.map({ current.distance(to: $0) }).min() else {
            // No shop found last time: retry only after a while.
            return now.timeIntervalSince(at) > 3 * 86_400
        }
        return nearest > farAway
    }

    /// Up to 10 shops for the Wallet pass, nearest to `current` when known.
    public static func walletLocations(_ card: Card, near current: GeoPoint?) -> [GeoPoint] {
        guard let current else { return Array(card.storeLocations.prefix(10)) }
        return Array(card.storeLocations.sorted { current.distance(to: $0) < current.distance(to: $1) }.prefix(10))
    }
}
