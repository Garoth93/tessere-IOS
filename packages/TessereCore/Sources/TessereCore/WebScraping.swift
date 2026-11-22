import Foundation

/// Tiny HTML helpers (no parser dependency): `<meta>` and `<link>` tags.
public enum HTMLMeta {

    /// Attributes of every tag named `tag` (lowercased keys).
    public static func tags(_ tag: String, in html: String) -> [[String: String]] {
        var out: [[String: String]] = []
        let lower = html.lowercased()
        var searchStart = lower.startIndex
        let open = "<\(tag)"
        while let r = lower.range(of: open, range: searchStart..<lower.endIndex) {
            guard let end = lower.range(of: ">", range: r.upperBound..<lower.endIndex) else { break }
            // Same offsets in the original string (lowercasing ASCII keeps offsets; be safe with distance).
            let startOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
            let endOffset = lower.distance(from: lower.startIndex, to: end.lowerBound)
            if let s = html.index(html.startIndex, offsetBy: startOffset, limitedBy: html.endIndex),
               let e = html.index(html.startIndex, offsetBy: endOffset, limitedBy: html.endIndex), s <= e {
                let next = html[s..<e].first
                if next == nil || next == " " || next == "\n" || next == "\t" || next == "/" || next == "\r" {
                    out.append(attributes(String(html[s..<e])))
                }
            }
            searchStart = end.upperBound
        }
        return out
    }

    static func attributes(_ s: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let chars = Array(s)
        var i = 0
        func skipSpaces() { while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 } }
        while i < chars.count {
            skipSpaces()
            var name = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" { name.append(chars[i]); i += 1 }
            guard !name.isEmpty else { i += 1; continue }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let q = chars[i]; i += 1
                    while i < chars.count, chars[i] != q { value.append(chars[i]); i += 1 }
                    i += 1
                } else {
                    while i < chars.count, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                }
            }
            attrs[name.lowercased()] = decodeEntities(value)
        }
        return attrs
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Absolute URL of `href` relative to `base`.
    public static func resolve(_ href: String, base: URL) -> URL? {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.hasPrefix("data:") else { return nil }
        if h.hasPrefix("//") { return URL(string: "https:" + h) }
        return URL(string: h, relativeTo: base)?.absoluteURL
    }

    /// og:image / twitter:image of a page.
    public static func coverImage(in html: String, base: URL) -> URL? {
        let metas = tags("meta", in: html)
        for key in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
            if let m = metas.first(where: { ($0["property"] ?? $0["name"])?.lowercased() == key }),
               let c = m["content"], let u = resolve(c, base: base) {
                return u
            }
        }
        return nil
    }

    public static func title(in html: String) -> String? {
        let metas = tags("meta", in: html)
        if let t = metas.first(where: { ($0["property"] ?? $0["name"])?.lowercased() == "og:title" })?["content"],
           !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Icon candidates declared by a page, best first (apple-touch-icon,
    /// big PNG/SVG-less icons). SVG is skipped (not decodable by UIImage).
    public static func iconCandidates(in html: String, base: URL) -> [URL] {
        var scored: [(URL, Int)] = []
        for link in tags("link", in: html) {
            guard let rel = link["rel"]?.lowercased(), let href = link["href"],
                  let url = resolve(href, base: base) else { continue }
            let path = url.path.lowercased()
            if path.hasSuffix(".svg") || (link["type"]?.contains("svg") ?? false) { continue }
            var size = 0
            if let sizes = link["sizes"]?.lowercased(), let first = sizes.split(separator: " ").first,
               let w = Int(first.split(separator: "x").first ?? "") {
                size = w
            }
            var score: Int
            if rel.contains("apple-touch-icon") {
                score = 1000 + (size == 0 ? 180 : size)
            } else if rel.contains("icon") {
                score = size == 0 ? 16 : size
                if path.hasSuffix(".ico") { score = min(score, 48) }
            } else if rel.contains("mask-icon") {
                continue
            } else {
                continue
            }
            scored.append((url, score))
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.absoluteString).inserted }
    }
}

/// Where to look for a logo, in order.
public enum LogoSources {
    public static func urls(domain raw: String) -> [URL] {
        let d = StoreCatalog.normalizeDomain(raw)
        guard !d.isEmpty, d.contains(".") else { return [] }
        let enc = d.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? d
        return [
            "https://www.\(d)/apple-touch-icon.png",
            "https://\(d)/apple-touch-icon.png",
            "https://www.google.com/s2/favicons?domain=\(enc)&sz=256",
            "https://icons.duckduckgo.com/ip3/\(enc).ico"
        ].compactMap(URL.init(string:))
    }

    public static func homePage(domain raw: String) -> URL? {
        let d = StoreCatalog.normalizeDomain(raw)
        guard !d.isEmpty else { return nil }
        return URL(string: "https://www.\(d)/")
    }
}

// MARK: - Offers

public enum OffersPlanner {

    public struct Source: Equatable, Sendable, Identifiable {
        public var id: String { key }
        /// Dedup key (catalog id or normalized store name).
        public var key: String
        public var storeName: String
        public var pageURL: String
        public var colorHex: String
        /// A card whose logo represents the store.
        public var cardID: UUID
    }

    public static func key(for card: Card) -> String {
        card.catalogID ?? StoreCatalog.normalize(card.storeName)
    }

    /// One flyer source per store among the saved cards (loyalty cards and
    /// vouchers with a known site), most used first.
    public static func sources(_ data: TessereData, now: Date = Date()) -> [Source] {
        var seen = Set<String>()
        var out: [Source] = []
        for card in CardQuery.sorted(data.cards, by: .frequent, usage: data.usage, now: now) {
            guard card.kind != .ticket else { continue }
            let page = card.resolvedFlyerURL ?? card.resolvedDomain.flatMap { LogoSources.homePage(domain: $0)?.absoluteString }
            guard let page, URL(string: page) != nil else { continue }
            let k = key(for: card)
            guard seen.insert(k).inserted else { continue }
            out.append(Source(key: k, storeName: card.catalogEntry?.name ?? card.storeName,
                              pageURL: page, colorHex: card.resolvedColorHex, cardID: card.id))
        }
        return out
    }

    /// Fingerprint of the current flyer from a fetched page: cover URL when
    /// present, otherwise the title.
    public static func fingerprint(cover: URL?, title: String?) -> String? {
        if let cover { return cover.absoluteString }
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return "title:" + t }
        return nil
    }

    /// Merges a fetch result into the stored state.
    /// The first fetch of a store is not "new" (nothing to compare with).
    public static func updated(_ old: OfferState?, pageURL: String, cover: URL?, title: String?, now: Date) -> OfferState {
        let key = fingerprint(cover: cover, title: title)
        var s = old ?? OfferState(pageURL: pageURL)
        let firstTime = old?.currentKey == nil
        if old?.pageURL != pageURL { s.seenKey = nil }
        s.pageURL = pageURL
        s.coverURL = cover?.absoluteString
        s.title = title
        s.fetchedAt = now
        if let key {
            s.currentKey = key
            if firstTime || old?.pageURL != pageURL { s.seenKey = key }
        }
        return s
    }

    public static func newCount(_ data: TessereData) -> Int {
        sources(data).filter { data.offers[$0.key]?.isNew ?? false }.count
    }
}
