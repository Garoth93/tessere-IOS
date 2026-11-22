import XCTest
@testable import TessereCore

final class WebSyncTests: XCTestCase {
    let now = Synthetic.now
    let cipher = Synthetic.FakeCipher()

    func testHTMLMeta() {
        let html = """
        <html><head>
        <meta property="og:image" content="/img/volantino-42.jpg?x=1&amp;y=2">
        <META name='og:title' content='Volantino TEST'>
        <link rel="icon" href="/favicon.ico">
        <link rel="apple-touch-icon" sizes="180x180" href="https://cdn.example.com/touch.png"/>
        <link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png">
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <linkfoo rel="icon" href="/no.png">
        </head></html>
        """
        let base = URL(string: "https://www.example.com/volantini/")!
        XCTAssertEqual(HTMLMeta.coverImage(in: html, base: base)?.absoluteString, "https://www.example.com/img/volantino-42.jpg?x=1&y=2")
        XCTAssertEqual(HTMLMeta.title(in: html), "Volantino TEST")
        let icons = HTMLMeta.iconCandidates(in: html, base: base).map(\.absoluteString)
        XCTAssertEqual(icons, ["https://cdn.example.com/touch.png", "https://www.example.com/icon-192.png", "https://www.example.com/favicon.ico"])
        XCTAssertNil(HTMLMeta.coverImage(in: "<html></html>", base: base))
        XCTAssertEqual(LogoSources.urls(domain: "https://www.esselunga.it/").first?.absoluteString, "https://www.esselunga.it/apple-touch-icon.png")
        XCTAssertTrue(LogoSources.urls(domain: "nodot").isEmpty)
    }

    func testOffers() {
        var d = TessereData()
        var a = Synthetic.card("Esselunga"); a.catalogID = "esselunga"
        var a2 = Synthetic.card("Esselunga Fidaty TEST"); a2.catalogID = "esselunga"
        let t = Synthetic.card("Treno TEST", kind: .ticket)
        var u = Synthetic.card("Senza sito TEST")
        u.domain = nil
        for c in [a, a2, t, u] { d.upsert(c, now: now) }
        let s = OffersPlanner.sources(d, now: now)
        XCTAssertEqual(s.map(\.key), ["esselunga"])
        var st = OffersPlanner.updated(nil, pageURL: s[0].pageURL, cover: URL(string: "https://x/1.jpg"), title: nil, now: now)
        XCTAssertFalse(st.isNew, "il primo caricamento non è una novità")
        st = OffersPlanner.updated(st, pageURL: s[0].pageURL, cover: URL(string: "https://x/2.jpg"), title: nil, now: now)
        XCTAssertTrue(st.isNew)
        d.offers["esselunga"] = st
        XCTAssertEqual(OffersPlanner.newCount(d), 1)
        st.seenKey = st.currentKey
        XCTAssertFalse(st.isNew)
    }

    func testOutgoingAndApplyRoundTrip() throws {
        // Device A creates a card with a logo, device B receives it.
        var a = TessereData()
        var card = Synthetic.card("Alfa TEST")
        card.hasLogo = true
        card.storeLocations = [GeoPoint(latitude: 1, longitude: 2)]
        a.upsert(card, now: now)
        let logo = Data([1, 2, 3])
        let out = try SyncEngine.outgoing(a, cipher: cipher) { _ in logo }
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].deleted)
        let resp = SyncResponse(cursor: 5, changes: out.map { var r = $0; r.seq = 5; return r }, applied: out.map(\.id))
        _ = SyncEngine.apply(resp, sent: out, to: &a, cipher: cipher)
        XCTAssertTrue(a.pendingSync.isEmpty)
        XCTAssertEqual(a.sync.cursor, 5)
        XCTAssertEqual(a.card(card.id)?.storeLocations.count, 1, "i negozi locali restano")

        var b = TessereData()
        let o = SyncEngine.apply(SyncResponse(cursor: 5, changes: out, applied: []), sent: [], to: &b, cipher: cipher)
        XCTAssertEqual(o.added, 1)
        XCTAssertEqual(o.logoWrites[card.id], .some(logo))
        XCTAssertEqual(b.card(card.id)?.storeName, "Alfa TEST")
        XCTAssertEqual(b.card(card.id)?.storeLocations, [], "le posizioni non viaggiano")
        XCTAssertEqual(b.card(card.id)?.updatedAt, now)

        // Older remote version is ignored.
        var older = out[0]; older.updatedAt -= 1000
        let o2 = SyncEngine.apply(SyncResponse(cursor: 6, changes: [older], applied: []), sent: [], to: &b, cipher: cipher)
        XCTAssertFalse(o2.changedSomething)

        // Deletion from A reaches B.
        a.delete(card.id, now: now.addingTimeInterval(60))
        let del = try SyncEngine.outgoing(a, cipher: cipher) { _ in nil }
        XCTAssertEqual(del.map(\.deleted), [true])
        let o3 = SyncEngine.apply(SyncResponse(cursor: 7, changes: del, applied: []), sent: [], to: &b, cipher: cipher)
        XCTAssertEqual(o3.removed, 1)
        XCTAssertTrue(b.cards.isEmpty)
        XCTAssertEqual(b.tombstones.map(\.id), [card.id])
    }

    func testLocalNewerWinsAndPendingKeptWhenEditedMeanwhile() throws {
        var d = TessereData()
        let card = Synthetic.card()
        d.upsert(card, now: now)
        let sent = try SyncEngine.outgoing(d, cipher: cipher) { _ in nil }
        // Edited again while the request was in flight.
        d.edit(card.id, now: now.addingTimeInterval(10)) { $0.note = "nuova" }
        var remote = sent[0]; remote.updatedAt = SyncEngine.millis(now.addingTimeInterval(5))
        _ = SyncEngine.apply(SyncResponse(cursor: 1, changes: [remote], applied: [card.id.uuidString]), sent: sent, to: &d, cipher: cipher)
        XCTAssertTrue(d.pendingSync.contains(card.id))
        XCTAssertEqual(d.card(card.id)?.note, "nuova")
    }

    func testPrivateCardsPushedAsDeletionAndProtected() throws {
        var d = TessereData()
        var card = Synthetic.card()
        card.shared = false
        d.upsert(card, now: now)
        let out = try SyncEngine.outgoing(d, cipher: cipher) { _ in nil }
        XCTAssertEqual(out.map(\.deleted), [true])
        XCTAssertNil(out[0].payload)
        // Remote newer content for a private card does not overwrite it.
        var other = TessereData()
        var shared = card; shared.shared = true; shared.note = "remota"
        other.upsert(shared, now: now.addingTimeInterval(100))
        let remote = try SyncEngine.outgoing(other, cipher: cipher) { _ in nil }
        _ = SyncEngine.apply(SyncResponse(cursor: 1, changes: remote, applied: []), sent: [], to: &d, cipher: cipher)
        XCTAssertEqual(d.card(card.id)?.note, "")
    }

    func testUnreadablePayloadCounted() throws {
        var d = TessereData()
        let rec = SyncRecord(id: UUID().uuidString, updatedAt: 1, deleted: false, payload: "K2:xxx")
        let o = SyncEngine.apply(SyncResponse(cursor: 1, changes: [rec], applied: []), sent: [], to: &d, cipher: cipher)
        XCTAssertEqual(o.unreadable, 1)
        XCTAssertTrue(d.cards.isEmpty)
    }

    func testMarkAllForUpload() {
        var d = TessereData()
        var p = Synthetic.card("P TEST"); p.shared = false
        let s = Synthetic.card("S TEST")
        d.upsert(p, now: now); d.upsert(s, now: now)
        d.pendingSync = []
        d.sync.cursor = 9
        SyncEngine.markAllForUpload(&d)
        XCTAssertEqual(d.pendingSync, [s.id])
        XCTAssertEqual(d.sync.cursor, 0)
    }

    func testInviteLink() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let link = InviteLink(server: "https://tessere.example.workers.dev", code: "ABCD-1234", key: key)
        let url = try XCTUnwrap(link.url)
        XCTAssertTrue(url.absoluteString.hasPrefix("tessere://join?"))
        XCTAssertEqual(InviteLink(url: url), link)
        XCTAssertEqual(InviteLink(string: url.absoluteString), link)
        XCTAssertNil(InviteLink(string: "tessere://join?u=x&c=y#k=short"))
        XCTAssertEqual(normalizedServerURL("tessere.example.workers.dev/"), "https://tessere.example.workers.dev")
        XCTAssertNil(normalizedServerURL(""))
        XCTAssertNil(normalizedServerURL("ftp://x"))
        XCTAssertEqual(Base64URL.decode(Base64URL.encode(Data([255, 254, 253]))), Data([255, 254, 253]))
    }

    func testResponseDecodingTolerant() throws {
        let r = try JSONDecoder().decode(SyncResponse.self, from: Data(#"{"cursor":3}"#.utf8))
        XCTAssertEqual(r.cursor, 3)
        XCTAssertTrue(r.changes.isEmpty)
    }

    func testWalletRequest() throws {
        var c = Synthetic.card("Alfa TEST", number: "400638133393", format: .ean13)
        c.autoColorHex = "#FFD400"
        c.note = " Sconto 10% "
        c.expiry = now
        c.storeLocations = (0..<15).map { GeoPoint(latitude: 45 + Double($0) / 100, longitude: 9) }
        let r = try WalletPassBuilder.request(for: c, icon: Data([1]), logo: nil, near: GeoPoint(latitude: 45.14, longitude: 9))
        XCTAssertEqual(r.format, "PKBarcodeFormatCode128")
        XCTAssertEqual(r.message, "4006381333931", "EAN completo di cifra di controllo")
        XCTAssertEqual(r.logoText, "Alfa TEST")
        XCTAssertEqual(r.note, "Sconto 10%")
        XCTAssertEqual(r.locations.count, 10)
        XCTAssertEqual(r.locations.first?.latitude ?? 0, 45.14, accuracy: 0.0001)
        XCTAssertEqual(r.foregroundColor, RGB.ink.cssRGB)
        XCTAssertNotNil(r.expirationDate)
        c.format = .none
        XCTAssertThrowsError(try WalletPassBuilder.request(for: c, icon: Data(), logo: nil, near: nil))
        c.format = .qr
        XCTAssertEqual(try WalletPassBuilder.request(for: c, icon: Data(), logo: Data([2]), near: nil).format, "PKBarcodeFormatQR")
    }

    func testWidgetSnapshotAndBackup() throws {
        var d = TessereData()
        let a = Synthetic.card("Alfa TEST")
        d.upsert(a, now: now)
        d.recordUse(a.id, at: now)
        let snap = WidgetSnapshot(data: d, now: now)
        XCTAssertEqual(snap.cards.map(\.id), [a.id])
        XCTAssertEqual(snap.totalCards, 1)

        let backup = BackupFile(data: d, logos: [a.id: Data([9, 9])], now: now)
        let raw = try backup.encoded()
        let back = try BackupFile.decode(raw)
        XCTAssertEqual(back.cards, d.cards)
        XCTAssertEqual(back.logoData[a.id], Data([9, 9]))
        var fresh = TessereData()
        XCTAssertEqual(back.merge(into: &fresh, now: now), 1)
        XCTAssertTrue(fresh.pendingSync.contains(a.id))
        XCTAssertThrowsError(try BackupFile.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try BackupFile.decode(Data("nope".utf8)))
    }
}
