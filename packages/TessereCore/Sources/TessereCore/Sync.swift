import Foundation

// MARK: - Wire format (shared with the Cloudflare Worker in backend/)

/// One record on the server. `payload` is the end-to-end encrypted
/// `CardPayload` (base64): the server only sees ids and timestamps.
public struct SyncRecord: Codable, Equatable, Sendable {
    public var id: String
    /// Milliseconds since 1970 (LWW clock).
    public var updatedAt: Int64
    public var deleted: Bool
    public var payload: String?
    /// Server sequence (responses only).
    public var seq: Int?

    public init(id: String, updatedAt: Int64, deleted: Bool, payload: String?, seq: Int? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.payload = payload
        self.seq = seq
    }
}

public struct SyncRequest: Codable, Equatable, Sendable {
    public var since: Int
    public var changes: [SyncRecord]

    public init(since: Int, changes: [SyncRecord]) {
        self.since = since
        self.changes = changes
    }
}

public struct SyncResponse: Codable, Equatable, Sendable {
    /// New cursor (max seq of the space).
    public var cursor: Int
    /// Records changed after `since` (may include our own, harmless).
    public var changes: [SyncRecord]
    /// Ids accepted from the request.
    public var applied: [String]
    /// Ids refused because the server has a newer version (sent in `changes`).
    public var rejected: [String]
    /// More changes are waiting on the server (call again with the new cursor).
    public var more: Bool

    public init(cursor: Int, changes: [SyncRecord], applied: [String], rejected: [String] = [], more: Bool = false) {
        self.cursor = cursor
        self.changes = changes
        self.applied = applied
        self.rejected = rejected
        self.more = more
    }

    enum CodingKeys: String, CodingKey { case cursor, changes, applied, rejected, more }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decode(Int.self, forKey: .cursor)
        changes = try c.decodeIfPresent([SyncRecord].self, forKey: .changes) ?? []
        applied = try c.decodeIfPresent([String].self, forKey: .applied) ?? []
        rejected = try c.decodeIfPresent([String].self, forKey: .rejected) ?? []
        more = try c.decodeIfPresent(Bool.self, forKey: .more) ?? false
    }
}

/// Plain content of a record before encryption.
public struct CardPayload: Codable, Equatable, Sendable {
    public var card: Card
    /// Processed logo (PNG, base64), if any.
    public var logoPNG: String?

    public init(card: Card, logoPNG: String?) {
        self.card = card
        self.logoPNG = logoPNG
    }
}

/// End-to-end encryption of the payloads (AES-GCM in the app, a fake in tests).
public protocol SyncCipher: Sendable {
    func seal(_ plain: Data) throws -> String
    func open(_ sealed: String) throws -> Data
}

public enum SyncError: Error, LocalizedError, Equatable {
    case badPayload
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .badPayload: return "Dati di sincronizzazione non leggibili (chiave della famiglia diversa?)."
        case .server(let m): return m
        }
    }
}

// MARK: - Engine

/// Pure merge logic (last-writer-wins per card, with tombstones).
public enum SyncEngine {

    public static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    public static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// Records to push: shared cards (upsert), private or deleted cards (delete).
    public static func outgoing(_ data: TessereData, cipher: SyncCipher, logo: (UUID) -> Data?) throws -> [SyncRecord] {
        var out: [SyncRecord] = []
        for id in data.pendingSync.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let card = data.card(id) {
                if card.shared {
                    let payload = CardPayload(card: card.syncable, logoPNG: card.hasLogo ? logo(id)?.base64EncodedString() : nil)
                    let plain = try JSONFileStore<CardPayload>.encoder(compact: true).encode(payload)
                    out.append(SyncRecord(id: id.uuidString, updatedAt: millis(card.updatedAt), deleted: false,
                                          payload: try cipher.seal(plain)))
                } else {
                    out.append(SyncRecord(id: id.uuidString, updatedAt: millis(card.updatedAt), deleted: true, payload: nil))
                }
            } else if let t = data.tombstones.first(where: { $0.id == id }) {
                out.append(SyncRecord(id: id.uuidString, updatedAt: millis(t.deletedAt), deleted: true, payload: nil))
            }
        }
        return out
    }

    public struct Outcome: Equatable, Sendable {
        /// Logos to write (card id → PNG) or remove (nil).
        public var logoWrites: [UUID: Data?] = [:]
        public var added = 0
        public var updated = 0
        public var removed = 0
        public var unreadable = 0

        public var changedSomething: Bool { added + updated + removed > 0 }
    }

    /// Applies a server response: clears pending ids that were accepted
    /// unchanged, merges remote changes (strictly newer wins).
    public static func apply(_ response: SyncResponse, sent: [SyncRecord], to data: inout TessereData,
                             cipher: SyncCipher) -> Outcome {
        var outcome = Outcome()
        let sentByID = Dictionary(sent.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for idString in response.applied {
            guard let id = UUID(uuidString: idString), let s = sentByID[idString] else { continue }
            // Still the same version we sent? Then nothing left to push.
            let current: Int64? = data.card(id).map { millis($0.updatedAt) }
                ?? data.tombstones.first(where: { $0.id == id }).map { millis($0.deletedAt) }
            if current == s.updatedAt { data.pendingSync.remove(id) }
        }
        for record in response.changes {
            guard let id = UUID(uuidString: record.id) else { continue }
            let remoteDate = date(record.updatedAt)
            let localCard = data.card(id)
            let localStamp: Int64? = localCard.map { millis($0.updatedAt) }
                ?? data.tombstones.first(where: { $0.id == id }).map { millis($0.deletedAt) }
            if let localStamp, localStamp >= record.updatedAt { continue }
            // A private card never takes remote content.
            if let lc = localCard, !lc.shared { continue }
            if record.deleted {
                if localCard != nil {
                    data.cards.removeAll { $0.id == id }
                    data.usage[id.uuidString] = nil
                    outcome.logoWrites[id] = .some(nil)
                    outcome.removed += 1
                }
                data.tombstones.removeAll { $0.id == id }
                data.tombstones.append(Tombstone(id: id, deletedAt: remoteDate))
                data.pendingSync.remove(id)
                continue
            }
            guard let sealed = record.payload,
                  let plain = try? cipher.open(sealed),
                  let payload = try? JSONFileStore<CardPayload>.decoder.decode(CardPayload.self, from: plain),
                  payload.card.id == id else {
                outcome.unreadable += 1
                continue
            }
            var incoming = payload.card
            incoming.updatedAt = remoteDate
            incoming.shared = true
            if let lc = localCard {
                incoming.storeLocations = lc.storeLocations
                incoming.locationsUpdatedAt = lc.locationsUpdatedAt
                let i = data.cards.firstIndex { $0.id == id }!
                data.cards[i] = incoming
                outcome.updated += 1
            } else {
                data.cards.append(incoming)
                data.tombstones.removeAll { $0.id == id }
                outcome.added += 1
            }
            if incoming.hasLogo, let b64 = payload.logoPNG, let png = Data(base64Encoded: b64) {
                outcome.logoWrites[id] = .some(png)
            } else if !incoming.hasLogo {
                outcome.logoWrites[id] = .some(nil)
            }
            data.pendingSync.remove(id)
        }
        data.sync.cursor = max(data.sync.cursor, response.cursor)
        return outcome
    }

    /// After joining a space: every shared card must be uploaded.
    public static func markAllForUpload(_ data: inout TessereData) {
        for c in data.cards where c.shared { data.pendingSync.insert(c.id) }
        data.sync.cursor = 0
    }
}

// MARK: - Family invites

/// Link that brings a new device into the family:
/// `tessere://join?u=<server>&c=<code>#k=<space key base64url>`.
/// The key travels only in the fragment/QR, never to the server.
public struct InviteLink: Equatable, Sendable, Identifiable {
    public var id: String { code }
    public var server: String
    public var code: String
    public var key: Data

    public init(server: String, code: String, key: Data) {
        self.server = server
        self.code = code
        self.key = key
    }

    public var url: URL? {
        var c = URLComponents()
        c.scheme = "tessere"
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "u", value: server), URLQueryItem(name: "c", value: code)]
        c.fragment = "k=" + Base64URL.encode(key)
        return c.url
    }

    public init?(url: URL) {
        guard url.scheme == "tessere", url.host == "join",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let server = comps.queryItems?.first(where: { $0.name == "u" })?.value, !server.isEmpty,
              let code = comps.queryItems?.first(where: { $0.name == "c" })?.value, !code.isEmpty,
              let frag = comps.fragment, frag.hasPrefix("k="),
              let key = Base64URL.decode(String(frag.dropFirst(2))), key.count == 32 else { return nil }
        self.init(server: server, code: code, key: key)
    }

    public init?(string: String) {
        guard let u = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: u)
    }
}

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}

/// Cleans a server URL typed by the user ("tessere.example.workers.dev" → "https://…").
public func normalizedServerURL(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if !s.contains("://") { s = "https://" + s }
    while s.hasSuffix("/") { s.removeLast() }
    guard let u = URL(string: s), let scheme = u.scheme, scheme == "https" || scheme == "http", u.host != nil else { return nil }
    return s
}
