import Foundation

/// Local catalog of the main Italian chains: name, aliases, web domain
/// (for the logo), brand color and flyer page.
///
/// `colorHex` is set only when the brand color is well known; otherwise the
/// color is taken from the downloaded logo. `flyerURL` nil = home page of
/// the domain. Both can be changed by the user on each card.
public enum StoreCatalog {

    public enum Category: String, Codable, CaseIterable, Sendable {
        case grocery, electronics, home, fashion, sport, beauty, books, pets, fuel, travel, other

        public var title: String {
            switch self {
            case .grocery: return "Supermercati"
            case .electronics: return "Elettronica"
            case .home: return "Casa e bricolage"
            case .fashion: return "Abbigliamento"
            case .sport: return "Sport"
            case .beauty: return "Profumeria e cura"
            case .books: return "Libri"
            case .pets: return "Animali"
            case .fuel: return "Carburante"
            case .travel: return "Viaggi"
            case .other: return "Altro"
            }
        }
    }

    public struct Entry: Equatable, Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let aliases: [String]
        public let domain: String
        public let colorHex: String?
        public let category: Category
        public let flyerPath: String?

        /// Flyer page, or the home page when the catalog has no specific path.
        public var flyerURL: String {
            if let p = flyerPath {
                return p.hasPrefix("http") ? p : "https://www.\(domain)\(p)"
            }
            return "https://www.\(domain)"
        }

        var keys: [String] { ([name] + aliases).map(StoreCatalog.normalize) }
    }

    private static func e(_ id: String, _ name: String, _ domain: String, _ color: String?, _ cat: Category,
                          aliases: [String] = [], flyer: String? = nil) -> Entry {
        Entry(id: id, name: name, aliases: aliases, domain: domain, colorHex: color, category: cat, flyerPath: flyer)
    }

    public static let entries: [Entry] = [
        // Supermercati
        e("esselunga", "Esselunga", "esselunga.it", "#E2231A", .grocery, aliases: ["fidaty", "esselunga fidaty"], flyer: "/it-it/promozioni/volantini.html"),
        e("conad", "Conad", "conad.it", "#E30613", .grocery, aliases: ["carta insieme", "conad superstore", "spazio conad", "conad city"], flyer: "/volantini"),
        e("coop", "Coop", "e-coop.it", "#E2001A", .grocery, aliases: ["ipercoop", "socio coop", "coop alleanza", "coop lombardia", "unicoop", "novacoop", "coop italia"], flyer: "/volantini"),
        e("carrefour", "Carrefour", "carrefour.it", "#004E9F", .grocery, aliases: ["carrefour market", "carrefour express", "carrefour iper", "mia carrefour"], flyer: "/volantino"),
        e("lidl", "Lidl", "lidl.it", "#0050AA", .grocery, aliases: ["lidl plus"]),
        e("eurospin", "Eurospin", "eurospin.it", "#0B3B8C", .grocery, flyer: "/volantino/"),
        e("aldi", "Aldi", "aldi.it", "#0A2D6E", .grocery),
        e("pam", "Pam Panorama", "pampanorama.it", "#D6001C", .grocery, aliases: ["pam", "panorama", "pam local"]),
        e("despar", "Despar", "despar.it", "#00843D", .grocery, aliases: ["interspar", "eurospar", "spar"]),
        e("iper", "Iper La grande i", "iper.it", "#EE3124", .grocery, aliases: ["iper", "la grande i"]),
        e("bennet", "Bennet", "bennet.com", nil, .grocery),
        e("famila", "Famila", "famila.it", nil, .grocery, aliases: ["famila superstore"]),
        e("penny", "Penny", "penny.it", "#CD1719", .grocery, aliases: ["penny market"]),
        e("md", "MD", "mdspa.it", "#004B93", .grocery, aliases: ["md discount", "md spa"]),
        e("crai", "Crai", "crai-supermercati.it", nil, .grocery),
        e("todis", "Todis", "todis.it", nil, .grocery),
        e("unes", "Unes", "unes.it", nil, .grocery, aliases: ["u2 supermercato"]),
        e("ilgigante", "Il Gigante", "ilgigante.net", nil, .grocery, aliases: ["gigante"]),
        e("iperal", "Iperal", "iperal.it", nil, .grocery),
        e("tigros", "Tigros", "tigros.it", "#F39200", .grocery),
        e("basko", "Basko", "basko.it", nil, .grocery),
        e("ins", "In's Mercato", "insmercato.it", nil, .grocery, aliases: ["ins", "in s mercato"]),
        e("naturasi", "NaturaSì", "naturasi.it", nil, .grocery, aliases: ["natura si"]),
        e("tigota", "Tigotà", "tigota.it", nil, .beauty),
        e("acquaesapone", "Acqua & Sapone", "acquaesapone.it", nil, .beauty, aliases: ["acqua e sapone"]),
        // Elettronica
        e("mediaworld", "MediaWorld", "mediaworld.it", "#DF0000", .electronics, aliases: ["media world", "mediaworld club"]),
        e("unieuro", "Unieuro", "unieuro.it", nil, .electronics, aliases: ["unieuro club"]),
        e("euronics", "Euronics", "euronics.it", "#00539F", .electronics),
        e("trony", "Trony", "trony.it", nil, .electronics),
        e("comet", "Comet", "comet.it", nil, .electronics),
        e("gamestop", "GameStop", "gamestop.it", nil, .electronics, aliases: ["game stop"]),
        // Casa e bricolage
        e("ikea", "IKEA", "ikea.com", "#0058A3", .home, aliases: ["ikea family"], flyer: "https://www.ikea.com/it/it/offers/"),
        e("leroymerlin", "Leroy Merlin", "leroymerlin.it", "#78BE20", .home, aliases: ["leroy"]),
        e("obi", "OBI", "obi-italia.it", "#FF7E21", .home),
        e("bricocenter", "Bricocenter", "bricocenter.it", nil, .home, aliases: ["brico center"]),
        e("bricoman", "Bricoman", "bricoman.it", nil, .home),
        e("maisonsdumonde", "Maisons du Monde", "maisonsdumonde.com", nil, .home),
        e("kasanova", "Kasanova", "kasanova.com", nil, .home),
        e("flyingtiger", "Flying Tiger", "flyingtiger.com", nil, .home, aliases: ["tiger"]),
        // Abbigliamento e scarpe
        e("hm", "H&M", "hm.com", "#E50010", .fashion, aliases: ["h e m", "hm", "h m"]),
        e("zara", "Zara", "zara.com", "#000000", .fashion),
        e("ovs", "OVS", "ovs.it", nil, .fashion),
        e("coin", "Coin", "coin.it", nil, .fashion),
        e("upim", "Upim", "upim.com", nil, .fashion),
        e("calzedonia", "Calzedonia", "calzedonia.com", nil, .fashion),
        e("intimissimi", "Intimissimi", "intimissimi.com", nil, .fashion),
        e("tezenis", "Tezenis", "tezenis.com", nil, .fashion),
        e("piazzaitalia", "Piazza Italia", "piazzaitalia.it", nil, .fashion),
        e("primark", "Primark", "primark.com", nil, .fashion),
        e("rinascente", "Rinascente", "rinascente.it", nil, .fashion, aliases: ["la rinascente"]),
        e("deichmann", "Deichmann", "deichmann.com", nil, .fashion),
        e("pittarello", "Pittarello", "pittarello.com", nil, .fashion),
        e("scarpescarpe", "Scarpe & Scarpe", "scarpescarpe.it", nil, .fashion, aliases: ["scarpe e scarpe"]),
        e("bata", "Bata", "bata.com", nil, .fashion),
        // Sport
        e("decathlon", "Decathlon", "decathlon.it", "#0082C3", .sport),
        e("sportler", "Sportler", "sportler.com", nil, .sport),
        e("cisalfa", "Cisalfa Sport", "cisalfasport.it", nil, .sport, aliases: ["cisalfa"]),
        e("awlab", "AW Lab", "aw-lab.com", nil, .sport, aliases: ["aw lab", "awlab"]),
        e("footlocker", "Foot Locker", "footlocker.it", nil, .sport),
        // Profumeria
        e("sephora", "Sephora", "sephora.it", "#000000", .beauty),
        e("douglas", "Douglas", "douglas.it", nil, .beauty, aliases: ["limoni"]),
        e("kiko", "KIKO Milano", "kikocosmetics.com", nil, .beauty, aliases: ["kiko"]),
        e("pinalli", "Pinalli", "pinalli.it", nil, .beauty),
        // Libri
        e("feltrinelli", "laFeltrinelli", "lafeltrinelli.it", "#E2001A", .books, aliases: ["feltrinelli", "la feltrinelli"]),
        e("mondadori", "Mondadori Store", "mondadoristore.it", nil, .books, aliases: ["mondadori"]),
        e("giunti", "Giunti al Punto", "giunti.it", nil, .books, aliases: ["giunti"]),
        // Animali
        e("arcaplanet", "Arcaplanet", "arcaplanet.it", nil, .pets),
        e("maxizoo", "Maxi Zoo", "maxizoo.it", nil, .pets, aliases: ["maxizoo"]),
        e("isoladeitesori", "Isola dei Tesori", "isoladeitesori.it", nil, .pets),
        // Carburante
        e("enilive", "Enilive", "enilive.it", "#FFD400", .fuel, aliases: ["eni", "eni live", "you and eni"]),
        e("q8", "Q8", "q8.it", nil, .fuel, aliases: ["q8 star"]),
        e("esso", "Esso", "esso.it", nil, .fuel),
        e("tamoil", "Tamoil", "tamoil.it", nil, .fuel),
        // Viaggi
        e("trenitalia", "Trenitalia", "trenitalia.com", "#C3002F", .travel, aliases: ["cartafreccia", "carta freccia", "x go"]),
        e("italo", "Italo", "italotreno.com", "#A51E36", .travel, aliases: ["italo piu", "italotreno"]),
        e("itaairways", "ITA Airways", "ita-airways.com", "#002D72", .travel, aliases: ["volare", "ita"]),
        // Multi-partner
        e("payback", "PAYBACK", "payback.it", "#003EB0", .other)
    ]

    public static func entry(id: String) -> Entry? { byID[id] }

    private static let byID: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    // MARK: Matching

    /// Lowercase, no accents, "&" → "e", only letters/digits separated by one space.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "it_IT"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " e ")
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "’", with: " ")
        var out = ""
        var lastSpace = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Best catalog entry for a store name written by the user.
    /// Exact name/alias first, then a name/alias contained as whole words
    /// ("Esselunga Fidaty" → Esselunga), longest key wins.
    public static func match(_ name: String) -> Entry? {
        let q = normalize(name)
        guard !q.isEmpty else { return nil }
        if let exact = entries.first(where: { $0.keys.contains(q) }) { return exact }
        let padded = " \(q) "
        var best: (Entry, Int)?
        for entry in entries {
            for key in entry.keys where key.count >= 2 && padded.contains(" \(key) ") {
                if best == nil || key.count > best!.1 { best = (entry, key.count) }
            }
        }
        if let best { return best.0 }
        // Compact spelling ("mediaworld" vs "media world").
        let compact = q.replacingOccurrences(of: " ", with: "")
        return entries.first { $0.keys.contains { $0.replacingOccurrences(of: " ", with: "") == compact } }
    }

    /// Suggestions while typing: prefix matches first, then substring matches.
    public static func suggestions(for query: String, limit: Int = 8) -> [Entry] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        var prefix: [Entry] = []
        var inner: [Entry] = []
        for entry in entries {
            let keys = entry.keys
            if keys.contains(where: { $0.hasPrefix(q) || $0.split(separator: " ").contains { $0.hasPrefix(q) } }) {
                prefix.append(entry)
            } else if keys.contains(where: { $0.contains(q) }) || (q.count >= 4 && keys.contains { q.contains($0) }) {
                inner.append(entry)
            }
        }
        return Array((prefix + inner).prefix(limit))
    }

    /// "https://www.Esselunga.it/path" → "esselunga.it".
    public static func normalizeDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }

    /// Guess for unknown stores: "Bar Sport Milano" → nil (spaces), "Gelateria" → "gelateria.it".
    public static func guessedDomain(for name: String) -> String? {
        let n = normalize(name).replacingOccurrences(of: " ", with: "")
        guard n.count >= 3, n.count <= 30, n.allSatisfy({ $0.isASCII }) else { return nil }
        return n + ".it"
    }
}
