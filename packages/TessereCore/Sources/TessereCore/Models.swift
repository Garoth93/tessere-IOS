import Foundation

// MARK: - Card kind

/// What the card is: shown as filter chips under the title.
public enum CardKind: String, Codable, CaseIterable, Sendable, Hashable {
    case loyalty, voucher, ticket, other

    public var title: String {
        switch self {
        case .loyalty: return "Tessera"
        case .voucher: return "Buono"
        case .ticket: return "Biglietto"
        case .other: return "Altro"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .loyalty: return "Tessere"
        case .voucher: return "Buoni"
        case .ticket: return "Biglietti"
        case .other: return "Altro"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .loyalty: return "creditcard"
        case .voucher: return "giftcard"
        case .ticket: return "ticket"
        case .other: return "square.grid.2x2"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CardKind(rawValue: raw) ?? .other
    }
}

/// How the face of the card shows the brand.
public enum LogoStyle: String, Codable, CaseIterable, Sendable, Hashable {
    /// Logo when available, otherwise the store name.
    case auto
    /// Always the store name in large rounded type.
    case name
    /// Initials on the card color.
    case initials

    public var title: String {
        switch self {
        case .auto: return "Logo"
        case .name: return "Nome"
        case .initials: return "Iniziali"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LogoStyle(rawValue: raw) ?? .auto
    }
}

// MARK: - Geo

public struct GeoPoint: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Optional label (address of the shop).
    public var label: String?

    public init(latitude: Double, longitude: Double, label: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
    }

    /// Great-circle distance in meters (haversine).
    public func distance(to other: GeoPoint) -> Double {
        let r = 6_371_000.0
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = (other.latitude - latitude) * .pi / 180
        let dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - Card

public struct Card: Codable, Equatable, Identifiable, Sendable, Hashable {
    public var id: UUID
    /// Store / brand name as written or chosen by the user.
    public var storeName: String
    /// The payload encoded in the barcode.
    public var number: String
    /// Printed number when it differs from the barcode payload (optional).
    public var displayNumber: String?
    public var format: BarcodeFormat
    public var kind: CardKind
    /// Free note: shown as a pill on the card when not empty.
    public var note: String
    /// Name printed on the card (used on the Wallet pass).
    public var cardholder: String?
    /// Expiry day (start of day, local).
    public var expiry: Date?
    /// Matched entry of `StoreCatalog`, if any.
    public var catalogID: String?
    /// Web domain used to fetch the logo (e.g. "esselunga.it").
    public var domain: String?
    /// User override of the card color.
    public var colorHex: String?
    /// Color found automatically (catalog, logo, or generated).
    public var autoColorHex: String?
    public var logoStyle: LogoStyle
    /// Bumped every time the logo image changes (the file itself lives in the app).
    public var logoVersion: Int
    /// True when a processed logo image exists for this card.
    public var hasLogo: Bool
    /// Flyer page (Offerte). Nil = catalog default.
    public var flyerURL: String?
    /// Shops of this brand near the user (device-local, not synced).
    public var storeLocations: [GeoPoint]
    public var locationsUpdatedAt: Date?
    /// Shared with the family space (when sync is on). Private cards stay on this device.
    public var shared: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                storeName: String,
                number: String,
                displayNumber: String? = nil,
                format: BarcodeFormat = .code128,
                kind: CardKind = .loyalty,
                note: String = "",
                cardholder: String? = nil,
                expiry: Date? = nil,
                catalogID: String? = nil,
                domain: String? = nil,
                colorHex: String? = nil,
                autoColorHex: String? = nil,
                logoStyle: LogoStyle = .auto,
                logoVersion: Int = 0,
                hasLogo: Bool = false,
                flyerURL: String? = nil,
                storeLocations: [GeoPoint] = [],
                locationsUpdatedAt: Date? = nil,
                shared: Bool = true,
                createdAt: Date = Date(),
                updatedAt: Date? = nil) {
        self.id = id
        self.storeName = storeName
        self.number = number
        self.displayNumber = displayNumber
        self.format = format
        self.kind = kind
        self.note = note
        self.cardholder = cardholder
        self.expiry = expiry
        self.catalogID = catalogID
        self.domain = domain
        self.colorHex = colorHex
        self.autoColorHex = autoColorHex
        self.logoStyle = logoStyle
        self.logoVersion = logoVersion
        self.hasLogo = hasLogo
        self.flyerURL = flyerURL
        self.storeLocations = storeLocations
        self.locationsUpdatedAt = locationsUpdatedAt
        self.shared = shared
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, storeName, number, displayNumber, format, kind, note, cardholder, expiry
        case catalogID, domain, colorHex, autoColorHex, logoStyle, logoVersion, hasLogo
        case flyerURL, storeLocations, locationsUpdatedAt, shared, createdAt, updatedAt
    }

    /// Tolerant decoding: missing fields take defaults (older files, newer peers).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        storeName = try c.decodeIfPresent(String.self, forKey: .storeName) ?? ""
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        displayNumber = try c.decodeIfPresent(String.self, forKey: .displayNumber)
        format = try c.decodeIfPresent(BarcodeFormat.self, forKey: .format) ?? .code128
        kind = try c.decodeIfPresent(CardKind.self, forKey: .kind) ?? .loyalty
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        cardholder = try c.decodeIfPresent(String.self, forKey: .cardholder)
        expiry = try c.decodeIfPresent(Date.self, forKey: .expiry)
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        autoColorHex = try c.decodeIfPresent(String.self, forKey: .autoColorHex)
        logoStyle = try c.decodeIfPresent(LogoStyle.self, forKey: .logoStyle) ?? .auto
        logoVersion = try c.decodeIfPresent(Int.self, forKey: .logoVersion) ?? 0
        hasLogo = try c.decodeIfPresent(Bool.self, forKey: .hasLogo) ?? false
        flyerURL = try c.decodeIfPresent(String.self, forKey: .flyerURL)
        storeLocations = try c.decodeIfPresent([GeoPoint].self, forKey: .storeLocations) ?? []
        locationsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .locationsUpdatedAt)
        shared = try c.decodeIfPresent(Bool.self, forKey: .shared) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    // MARK: Derived

    /// Color actually used for the card face.
    public var resolvedColorHex: String {
        if let c = colorHex, RGB(hex: c) != nil { return c }
        if let c = autoColorHex, RGB(hex: c) != nil { return c }
        return ColorMath.generatedHex(for: storeName)
    }

    public var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Number shown under the code.
    public var shownNumber: String {
        if let d = displayNumber?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        return number
    }

    public var initials: String { ColorMath.initials(of: storeName) }

    public var catalogEntry: StoreCatalog.Entry? { catalogID.flatMap(StoreCatalog.entry(id:)) }

    /// Flyer page: user value, then catalog.
    public var resolvedFlyerURL: String? {
        if let f = flyerURL?.trimmingCharacters(in: .whitespaces), !f.isEmpty { return f }
        return catalogEntry?.flyerURL
    }

    public var resolvedDomain: String? {
        if let d = domain.map(StoreCatalog.normalizeDomain), !d.isEmpty { return d }
        return catalogEntry?.domain
    }

    /// Days until expiry (negative when expired), nil without expiry.
    public func daysToExpiry(now: Date, calendar: Calendar = .current) -> Int? {
        guard let expiry else { return nil }
        let a = calendar.startOfDay(for: now)
        let b = calendar.startOfDay(for: expiry)
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// Content used by the sync and by equality on the server: everything
    /// except device-local fields.
    public var syncable: Card {
        var c = self
        c.storeLocations = []
        c.locationsUpdatedAt = nil
        c.shared = true
        return c
    }
}

// MARK: - Usage (device-local)

public struct CardUsage: Codable, Equatable, Sendable {
    public var count: Int
    public var lastUsed: Date?
    /// Most recent uses, newest last (capped).
    public var recent: [Date]

    public static let cap = 30

    public init(count: Int = 0, lastUsed: Date? = nil, recent: [Date] = []) {
        self.count = count
        self.lastUsed = lastUsed
        self.recent = recent
    }

    public mutating func record(_ date: Date) {
        count += 1
        lastUsed = date
        recent.append(date)
        if recent.count > Self.cap { recent.removeFirst(recent.count - Self.cap) }
    }

    /// Frecency: recent uses weigh more (half-life ~3 weeks), plus a small
    /// bonus for the total count.
    public func score(now: Date) -> Double {
        let halfLife = 21.0 * 86_400
        var s = 0.0
        for d in recent {
            let age = max(0, now.timeIntervalSince(d))
            s += pow(0.5, age / halfLife)
        }
        return s + log1p(Double(count)) * 0.15
    }

    enum CodingKeys: String, CodingKey { case count, lastUsed, recent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        recent = try c.decodeIfPresent([Date].self, forKey: .recent) ?? []
    }
}

// MARK: - Settings

public enum Appearance: String, Codable, CaseIterable, Sendable {
    case dark, light, system

    public var title: String {
        switch self {
        case .dark: return "Scuro"
        case .light: return "Chiaro"
        case .system: return "Sistema"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Appearance(rawValue: raw) ?? .dark
    }
}

public enum SortMode: String, Codable, CaseIterable, Sendable {
    case frequent, name, recent, added

    public var title: String {
        switch self {
        case .frequent: return "Più usate"
        case .name: return "Nome"
        case .recent: return "Usate di recente"
        case .added: return "Aggiunte di recente"
        }
    }

    public var symbol: String {
        switch self {
        case .frequent: return "flame"
        case .name: return "textformat"
        case .recent: return "clock"
        case .added: return "plus.circle"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SortMode(rawValue: raw) ?? .frequent
    }
}

/// The "Attiva ora / Non interessato" banner state.
public enum LocationSuggestions: String, Codable, Sendable {
    case undecided, enabled, dismissed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LocationSuggestions(rawValue: raw) ?? .undecided
    }
}

public struct TessereSettings: Codable, Equatable, Sendable {
    public var appearance: Appearance = .dark
    public var sortMode: SortMode = .frequent
    public var faceID: Bool = false
    public var expiryReminders: Bool = true
    /// Days before the expiry for the first reminder.
    public var expiryLeadDays: Int = 7
    public var reminderHour: Int = 9
    public var locationSuggestions: LocationSuggestions = .undecided
    public var haptics: Bool = true
    public var maxBrightness: Bool = true
    public var autoRotateLongCodes: Bool = true
    public var offersEnabled: Bool = true
    /// Automatic backup in iCloud Drive (shared "Backup" container, "Tessere" folder).
    public var cloudBackup: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case appearance, sortMode, faceID, expiryReminders, expiryLeadDays, reminderHour
        case locationSuggestions, haptics, maxBrightness, autoRotateLongCodes, offersEnabled, cloudBackup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TessereSettings()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        sortMode = try c.decodeIfPresent(SortMode.self, forKey: .sortMode) ?? d.sortMode
        faceID = try c.decodeIfPresent(Bool.self, forKey: .faceID) ?? d.faceID
        expiryReminders = try c.decodeIfPresent(Bool.self, forKey: .expiryReminders) ?? d.expiryReminders
        expiryLeadDays = try c.decodeIfPresent(Int.self, forKey: .expiryLeadDays) ?? d.expiryLeadDays
        reminderHour = try c.decodeIfPresent(Int.self, forKey: .reminderHour) ?? d.reminderHour
        locationSuggestions = try c.decodeIfPresent(LocationSuggestions.self, forKey: .locationSuggestions) ?? d.locationSuggestions
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        maxBrightness = try c.decodeIfPresent(Bool.self, forKey: .maxBrightness) ?? d.maxBrightness
        autoRotateLongCodes = try c.decodeIfPresent(Bool.self, forKey: .autoRotateLongCodes) ?? d.autoRotateLongCodes
        offersEnabled = try c.decodeIfPresent(Bool.self, forKey: .offersEnabled) ?? d.offersEnabled
        cloudBackup = try c.decodeIfPresent(Bool.self, forKey: .cloudBackup) ?? d.cloudBackup
    }
}

// MARK: - Offers

/// Last known cover of a store's flyer page.
public struct OfferState: Codable, Equatable, Sendable {
    public var pageURL: String
    public var coverURL: String?
    public var title: String?
    /// Identifies the current flyer (cover URL or page fingerprint).
    public var currentKey: String?
    /// Key the user has already opened.
    public var seenKey: String?
    public var fetchedAt: Date?

    public init(pageURL: String, coverURL: String? = nil, title: String? = nil,
                currentKey: String? = nil, seenKey: String? = nil, fetchedAt: Date? = nil) {
        self.pageURL = pageURL
        self.coverURL = coverURL
        self.title = title
        self.currentKey = currentKey
        self.seenKey = seenKey
        self.fetchedAt = fetchedAt
    }

    /// New flyer not opened yet.
    public var isNew: Bool {
        guard let currentKey else { return false }
        return currentKey != seenKey
    }

    enum CodingKeys: String, CodingKey { case pageURL, coverURL, title, currentKey, seenKey, fetchedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageURL = try c.decodeIfPresent(String.self, forKey: .pageURL) ?? ""
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        currentKey = try c.decodeIfPresent(String.self, forKey: .currentKey)
        seenKey = try c.decodeIfPresent(String.self, forKey: .seenKey)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
    }
}

// MARK: - Sync state

/// Device side of the family sync. The secret token and the space key are
/// kept in the Keychain by the app, never here.
public struct SyncState: Codable, Equatable, Sendable {
    public var serverURL: String = ""
    public var deviceID: String?
    public var deviceName: String = "iPhone"
    public var spaceID: String?
    public var spaceName: String?
    public var isOwner: Bool = false
    /// Server sequence already applied.
    public var cursor: Int = 0
    public var lastSyncAt: Date?
    public var lastError: String?

    public init() {}

    public var isRegistered: Bool { deviceID != nil && !serverURL.isEmpty }
    public var isInSpace: Bool { isRegistered && spaceID != nil }

    enum CodingKeys: String, CodingKey {
        case serverURL, deviceID, deviceName, spaceID, spaceName, isOwner, cursor, lastSyncAt, lastError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "iPhone"
        spaceID = try c.decodeIfPresent(String.self, forKey: .spaceID)
        spaceName = try c.decodeIfPresent(String.self, forKey: .spaceName)
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        cursor = try c.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// A deleted card, remembered so the deletion reaches the other devices.
public struct Tombstone: Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var deletedAt: Date

    public init(id: UUID, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

// MARK: - Root

public struct TessereData: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var cards: [Card] = []
    public var tombstones: [Tombstone] = []
    /// Keyed by card id (uuidString). Device-local.
    public var usage: [String: CardUsage] = [:]
    public var settings = TessereSettings()
    /// Keyed by `OffersPlanner.key`.
    public var offers: [String: OfferState] = [:]
    public var sync = SyncState()
    /// Card ids changed since the last successful push.
    public var pendingSync: Set<UUID> = []
    /// Cards added to Wallet from this device (id → date).
    public var walletAdded: [String: Date] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, cards, tombstones, usage, settings, offers, sync, pendingSync, walletAdded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        cards = try c.decodeIfPresent([Card].self, forKey: .cards) ?? []
        tombstones = try c.decodeIfPresent([Tombstone].self, forKey: .tombstones) ?? []
        usage = try c.decodeIfPresent([String: CardUsage].self, forKey: .usage) ?? [:]
        settings = try c.decodeIfPresent(TessereSettings.self, forKey: .settings) ?? TessereSettings()
        offers = try c.decodeIfPresent([String: OfferState].self, forKey: .offers) ?? [:]
        sync = try c.decodeIfPresent(SyncState.self, forKey: .sync) ?? SyncState()
        pendingSync = try c.decodeIfPresent(Set<UUID>.self, forKey: .pendingSync) ?? []
        walletAdded = try c.decodeIfPresent([String: Date].self, forKey: .walletAdded) ?? [:]
    }

    // MARK: Lookup

    public func card(_ id: UUID) -> Card? { cards.first { $0.id == id } }

    public func usage(of id: UUID) -> CardUsage { usage[id.uuidString] ?? CardUsage() }

    /// Card kinds present, in canonical order (for the chips).
    public var kindsInUse: [CardKind] {
        let set = Set(cards.map(\.kind))
        return CardKind.allCases.filter(set.contains)
    }

    // MARK: Mutations (all stamp `updatedAt` and mark for sync)

    public mutating func upsert(_ card: Card, now: Date = Date()) {
        var c = card
        c.updatedAt = now
        if let i = cards.firstIndex(where: { $0.id == c.id }) {
            cards[i] = c
        } else {
            cards.append(c)
            tombstones.removeAll { $0.id == c.id }
        }
        pendingSync.insert(c.id)
    }

    public mutating func edit(_ id: UUID, now: Date = Date(), _ change: (inout Card) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        var c = cards[i]
        change(&c)
        guard c != cards[i] else { return }
        c.updatedAt = now
        cards[i] = c
        pendingSync.insert(id)
    }

    /// Device-local edit (no sync stamp): locations etc.
    public mutating func editLocal(_ id: UUID, _ change: (inout Card) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[i])
    }

    public mutating func delete(_ id: UUID, now: Date = Date()) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        let wasShared = cards[i].shared
        cards.remove(at: i)
        usage[id.uuidString] = nil
        walletAdded[id.uuidString] = nil
        if wasShared {
            tombstones.removeAll { $0.id == id }
            tombstones.append(Tombstone(id: id, deletedAt: now))
            pendingSync.insert(id)
        } else {
            pendingSync.remove(id)
        }
    }

    public mutating func recordUse(_ id: UUID, at date: Date = Date()) {
        var u = usage(of: id)
        u.record(date)
        usage[id.uuidString] = u
    }

    /// Tombstones older than the horizon are forgotten (all peers had time to sync).
    public mutating func pruneTombstones(now: Date, keepDays: Double = 120) {
        let limit = now.addingTimeInterval(-keepDays * 86_400)
        tombstones.removeAll { $0.deletedAt < limit && !pendingSync.contains($0.id) }
    }
}
