import Foundation

/// Body of `POST /v1/pass` on the Worker, which turns it into a signed
/// `.pkpass` (generic pass). Images are PNG, base64.
public struct PassRequest: Codable, Equatable, Sendable {
    public struct Location: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var relevantText: String?
    }

    public var serialNumber: String
    public var organizationName: String
    public var description: String
    /// Store name shown next to the logo when there is no logo image.
    public var logoText: String?
    public var kindLabel: String
    public var message: String
    /// PKBarcodeFormat… (QR, PDF417, Aztec, Code128).
    public var format: String
    public var altText: String?
    public var backgroundColor: String
    public var foregroundColor: String
    public var labelColor: String
    public var cardholder: String?
    public var note: String?
    /// ISO-8601 date-time.
    public var expirationDate: String?
    public var locations: [Location]
    public var iconPNG: String
    public var logoPNG: String?
    public var stripPNG: String?
}

public enum WalletPassBuilder {

    public enum Problem: Error, Equatable, LocalizedError {
        case noBarcode

        public var errorDescription: String? {
            switch self {
            case .noBarcode: return "Questa carta non ha un codice a barre: Wallet richiede un codice."
            }
        }
    }

    /// Builds the request. EAN/UPC/Code39/ITF/Codabar go to Wallet as Code 128
    /// with the same number (Wallet does not support them natively).
    public static func request(for card: Card, icon: Data, logo: Data?, near: GeoPoint?) throws -> PassRequest {
        guard let format = card.format.walletFormat else { throw Problem.noBarcode }
        let bg = RGB(hex: card.resolvedColorHex) ?? RGB(r: 0.2, g: 0.2, b: 0.2)
        let fg = bg.foreground
        let label = fg == .white ? RGB(r: 1, g: 1, b: 1).adjustingLightness(by: -0.18) : RGB.ink.adjustingLightness(by: 0.25)
        var message = card.number
        if format == "PKBarcodeFormatCode128", let full = Barcode1D.encode(card.number, as: card.format)?.text,
           [.ean13, .ean8, .upcA, .upcE, .itf].contains(card.format) {
            // Same digits including the computed check digit.
            message = full
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var expiration: String?
        if let e = card.expiry {
            // End of the expiry day.
            expiration = iso.string(from: Calendar.current.startOfDay(for: e).addingTimeInterval(86_399))
        }
        let locs = LocationPlanner.walletLocations(card, near: near).map {
            PassRequest.Location(latitude: $0.latitude, longitude: $0.longitude,
                                 relevantText: "Sei vicino a \(card.storeName): ecco la tua carta.")
        }
        let note = card.trimmedNote
        return PassRequest(
            serialNumber: card.id.uuidString,
            organizationName: card.storeName,
            description: "\(card.kind.title) \(card.storeName)",
            logoText: logo == nil ? card.storeName : nil,
            kindLabel: card.kind.title.uppercased(),
            message: message,
            format: format,
            altText: card.shownNumber,
            backgroundColor: bg.cssRGB,
            foregroundColor: fg.cssRGB,
            labelColor: label.cssRGB,
            cardholder: card.cardholder?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            note: note.isEmpty ? nil : note,
            expirationDate: expiration,
            locations: locs,
            iconPNG: icon.base64EncodedString(),
            logoPNG: logo?.base64EncodedString(),
            stripPNG: nil
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Widget snapshot

/// Small JSON shared with the widgets through the App Group.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct CardInfo: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var colorHex: String
        public var darkForeground: Bool
        public var hasLogo: Bool
        public var logoVersion: Int
        public var initials: String
        public var logoStyle: LogoStyle
        public var kind: CardKind
    }

    public var generatedAt: Date
    public var cards: [CardInfo]
    public var totalCards: Int
    public var locked: Bool

    public init(generatedAt: Date, cards: [CardInfo], totalCards: Int, locked: Bool) {
        self.generatedAt = generatedAt
        self.cards = cards
        self.totalCards = totalCards
        self.locked = locked
    }

    public init(data: TessereData, now: Date, limit: Int = 6) {
        let top = CardQuery.top(data, limit: limit, now: now)
        self.init(generatedAt: now, cards: top.map { c in
            let hex = c.resolvedColorHex
            return CardInfo(id: c.id, name: c.storeName, colorHex: hex,
                            darkForeground: RGB(hex: hex)?.prefersDarkForeground ?? false,
                            hasLogo: c.hasLogo, logoVersion: c.logoVersion, initials: c.initials,
                            logoStyle: c.logoStyle, kind: c.kind)
        }, totalCards: data.cards.count, locked: data.settings.faceID)
    }

    public static let placeholder = WidgetSnapshot(generatedAt: Date(), cards: [
        CardInfo(id: UUID(), name: "Supermercato", colorHex: "#E2231A", darkForeground: false, hasLogo: false, logoVersion: 0, initials: "SU", logoStyle: .name, kind: .loyalty),
        CardInfo(id: UUID(), name: "Elettronica", colorHex: "#0058A3", darkForeground: false, hasLogo: false, logoVersion: 0, initials: "EL", logoStyle: .name, kind: .loyalty),
        CardInfo(id: UUID(), name: "Sport", colorHex: "#0082C3", darkForeground: false, hasLogo: false, logoVersion: 0, initials: "SP", logoStyle: .name, kind: .loyalty),
        CardInfo(id: UUID(), name: "Profumeria", colorHex: "#111111", darkForeground: false, hasLogo: false, logoVersion: 0, initials: "PR", logoStyle: .name, kind: .loyalty)
    ], totalCards: 4, locked: false)
}

// MARK: - Backup

/// JSON backup with the logos inline. Sync state and device-local usage
/// are not part of it.
public struct BackupFile: Codable, Equatable, Sendable {
    public var app: String = "Tessere"
    public var version: Int = 1
    public var exportedAt: Date
    public var cards: [Card]
    public var settings: TessereSettings
    /// Card id → PNG base64.
    public var logos: [String: String]

    public init(data: TessereData, logos: [UUID: Data], now: Date) {
        exportedAt = now
        cards = data.cards
        settings = data.settings
        self.logos = Dictionary(uniqueKeysWithValues: logos.map { ($0.key.uuidString, $0.value.base64EncodedString()) })
    }

    public func encoded() throws -> Data {
        try JSONFileStore<BackupFile>.encoder().encode(self)
    }

    public static func decode(_ raw: Data) throws -> BackupFile {
        do {
            let b = try JSONFileStore<BackupFile>.decoder.decode(BackupFile.self, from: raw)
            guard b.app == "Tessere" else { throw BackupError.notTessere }
            return b
        } catch let e as BackupError {
            throw e
        } catch {
            throw BackupError.unreadable
        }
    }

    public var logoData: [UUID: Data] {
        var out: [UUID: Data] = [:]
        for (k, v) in logos {
            if let id = UUID(uuidString: k), let d = Data(base64Encoded: v) { out[id] = d }
        }
        return out
    }

    /// Merges into existing data: cards with the same id are replaced, others added.
    public func merge(into data: inout TessereData, now: Date) -> Int {
        var n = 0
        for card in cards {
            data.upsert(card, now: max(card.updatedAt, now))
            n += 1
        }
        return n
    }

    enum CodingKeys: String, CodingKey { case app, version, exportedAt, cards, settings, logos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date(timeIntervalSince1970: 0)
        cards = try c.decodeIfPresent([Card].self, forKey: .cards) ?? []
        settings = try c.decodeIfPresent(TessereSettings.self, forKey: .settings) ?? TessereSettings()
        logos = try c.decodeIfPresent([String: String].self, forKey: .logos) ?? [:]
    }
}

public enum BackupError: Error, LocalizedError, Equatable {
    case unreadable, notTessere

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Il file non è un backup leggibile."
        case .notTessere: return "Il file non è un backup di Tessere."
        }
    }
}
