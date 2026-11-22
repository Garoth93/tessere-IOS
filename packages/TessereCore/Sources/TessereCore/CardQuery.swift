import Foundation

/// Search, kind filter and ordering of the card grid.
public struct CardQuery: Equatable, Sendable {
    public var text: String
    public var kind: CardKind?
    public var sort: SortMode

    public init(text: String = "", kind: CardKind? = nil, sort: SortMode = .frequent) {
        self.text = text
        self.kind = kind
        self.sort = sort
    }

    /// Accent-insensitive match on store, note, number, kind and catalog aliases.
    public static func matches(_ card: Card, text: String) -> Bool {
        let q = StoreCatalog.normalize(text)
        guard !q.isEmpty else { return true }
        var hay = [card.storeName, card.note, card.kind.title, card.kind.pluralTitle, card.cardholder ?? ""]
        if let e = card.catalogEntry { hay.append(e.name); hay += e.aliases; hay.append(e.category.title) }
        let normalized = hay.map(StoreCatalog.normalize).joined(separator: " | ")
        let words = q.split(separator: " ")
        if words.allSatisfy({ normalized.contains($0) }) { return true }
        let digits = text.filter(\.isASCIIDigit)
        return digits.count >= 3 && (card.number.contains(digits) || card.shownNumber.filter(\.isASCIIDigit).contains(digits))
    }

    public func apply(to data: TessereData, now: Date = Date()) -> [Card] {
        let filtered = data.cards.filter { card in
            (kind == nil || card.kind == kind) && Self.matches(card, text: text)
        }
        return Self.sorted(filtered, by: sort, usage: data.usage, now: now)
    }

    public static func sorted(_ cards: [Card], by sort: SortMode, usage: [String: CardUsage], now: Date) -> [Card] {
        func u(_ c: Card) -> CardUsage { usage[c.id.uuidString] ?? CardUsage() }
        func byName(_ a: Card, _ b: Card) -> Bool {
            a.storeName.localizedCaseInsensitiveCompare(b.storeName) == .orderedAscending
        }
        switch sort {
        case .name:
            return cards.sorted(by: byName)
        case .added:
            return cards.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : byName($0, $1) }
        case .recent:
            return cards.sorted {
                let a = u($0).lastUsed ?? .distantPast, b = u($1).lastUsed ?? .distantPast
                return a != b ? a > b : byName($0, $1)
            }
        case .frequent:
            let scores = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, u($0).score(now: now)) })
            return cards.sorted {
                let a = scores[$0.id] ?? 0, b = scores[$1.id] ?? 0
                if abs(a - b) > 0.0001 { return a > b }
                return $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : byName($0, $1)
            }
        }
    }

    /// Most used cards (widgets, quick access).
    public static func top(_ data: TessereData, limit: Int, now: Date = Date()) -> [Card] {
        Array(sorted(data.cards, by: .frequent, usage: data.usage, now: now).prefix(limit))
    }
}

// MARK: - Expiry reminders

public struct ExpiryReminder: Equatable, Sendable {
    public var id: String
    public var cardID: UUID
    public var fireDate: Date
    public var title: String
    public var body: String
}

public enum ExpiryPlanner {
    public static let prefix = "tessere.expiry."

    /// One reminder `leadDays` before, one on the day (at `hour`), only in the future.
    public static func reminders(for data: TessereData, now: Date, calendar: Calendar = .current) -> [ExpiryReminder] {
        let s = data.settings
        guard s.expiryReminders else { return [] }
        var out: [ExpiryReminder] = []
        for card in data.cards {
            guard let expiry = card.expiry else { continue }
            let day = calendar.startOfDay(for: expiry)
            var offsets = [0]
            if s.expiryLeadDays > 0 { offsets.insert(s.expiryLeadDays, at: 0) }
            for lead in offsets {
                guard let d = calendar.date(byAdding: .day, value: -lead, to: day),
                      let fire = calendar.date(bySettingHour: s.reminderHour, minute: 0, second: 0, of: d),
                      fire > now else { continue }
                let what = card.kind == .loyalty ? "La tessera" : (card.kind == .voucher ? "Il buono" : (card.kind == .ticket ? "Il biglietto" : "La carta"))
                let body: String
                if lead == 0 {
                    body = "\(what) \(card.storeName) scade oggi."
                } else if lead == 1 {
                    body = "\(what) \(card.storeName) scade domani."
                } else {
                    body = "\(what) \(card.storeName) scade tra \(lead) giorni, il \(ItalianFormat.day(expiry))."
                }
                out.append(ExpiryReminder(id: "\(prefix)\(card.id.uuidString).\(lead)", cardID: card.id,
                                          fireDate: fire, title: "Scadenza \(card.storeName)", body: body))
            }
        }
        return out.sorted { $0.fireDate < $1.fireDate }
    }
}

// MARK: - Formatting

public enum ItalianFormat {
    public static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: date)
    }

    public static func shortDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "dd/MM/yy"
        return f.string(from: date)
    }

    public static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// "Scade tra 3 giorni" / "Scade oggi" / "Scaduta".
    public static func expiryText(days: Int) -> String {
        switch days {
        case ..<0: return "Scaduta"
        case 0: return "Scade oggi"
        case 1: return "Scade domani"
        default: return "Scade tra \(days) giorni"
        }
    }

    /// Groups digits for reading at the till: "1234567890123" → "1 234567 890123" for EAN,
    /// otherwise blocks of 4.
    public static func groupedNumber(_ s: String, format: BarcodeFormat) -> String {
        guard s.count > 6, s.allSatisfy(\.isASCIIDigit) else { return s }
        let chars = Array(s)
        if format == .ean13 && chars.count == 13 {
            return "\(chars[0]) \(String(chars[1...6])) \(String(chars[7...12]))"
        }
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0 && i % 4 == 0 { out.append(" ") }
            out.append(c)
        }
        return out
    }
}
