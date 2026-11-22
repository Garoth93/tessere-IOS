import XCTest
@testable import TessereCore

final class CardLogicTests: XCTestCase {
    let now = Synthetic.now

    func testTolerantDecoding() throws {
        let json = #"{"cards":[{"id":"6F1C1F9A-4D7B-4C1E-9C55-1E2B6E7A0001","storeName":"Negozio TEST","format":"futuro","kind":"altrotipo"}],"settings":{"sortMode":"name"}}"#
        let d = try JSONFileStore<TessereData>.decoder.decode(TessereData.self, from: Data(json.utf8))
        XCTAssertEqual(d.cards.count, 1)
        XCTAssertEqual(d.cards[0].format, .code128)
        XCTAssertEqual(d.cards[0].kind, .other)
        XCTAssertTrue(d.cards[0].shared)
        XCTAssertEqual(d.settings.sortMode, .name)
        XCTAssertEqual(d.settings.appearance, .dark)
    }

    func testRoundTrip() throws {
        var d = TessereData()
        d.upsert(Synthetic.card(), now: now)
        d.recordUse(d.cards[0].id, at: now)
        let data = try JSONFileStore<TessereData>.encoder().encode(d)
        let back = try JSONFileStore<TessereData>.decoder.decode(TessereData.self, from: data)
        XCTAssertEqual(back, d)
    }

    func testResolvedValues() {
        var c = Synthetic.card("Esselunga")
        c.catalogID = "esselunga"
        XCTAssertEqual(c.resolvedFlyerURL, "https://www.esselunga.it/it-it/promozioni/volantini.html")
        XCTAssertEqual(c.resolvedDomain, "esselunga.it")
        XCTAssertEqual(c.resolvedColorHex, ColorMath.generatedHex(for: "Esselunga"))
        c.autoColorHex = "#E2231A"
        XCTAssertEqual(c.resolvedColorHex, "#E2231A")
        c.colorHex = "#000000"
        XCTAssertEqual(c.resolvedColorHex, "#000000")
        c.displayNumber = " "
        XCTAssertEqual(c.shownNumber, c.number)
        c.expiry = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(c.daysToExpiry(now: now), 3)
    }

    func testMutationsMarkPending() {
        var d = TessereData()
        let c = Synthetic.card()
        d.upsert(c, now: now)
        XCTAssertTrue(d.pendingSync.contains(c.id))
        d.pendingSync = []
        d.edit(c.id, now: now) { $0.note = $0.note } // no change
        XCTAssertTrue(d.pendingSync.isEmpty)
        d.edit(c.id, now: now.addingTimeInterval(5)) { $0.note = "Sconto" }
        XCTAssertTrue(d.pendingSync.contains(c.id))
        XCTAssertEqual(d.card(c.id)?.updatedAt, now.addingTimeInterval(5))
        d.delete(c.id, now: now.addingTimeInterval(10))
        XCTAssertTrue(d.cards.isEmpty)
        XCTAssertEqual(d.tombstones.first?.id, c.id)
        // Private card: no tombstone.
        var p = Synthetic.card("Privata TEST")
        p.shared = false
        d.upsert(p, now: now)
        d.delete(p.id, now: now)
        XCTAssertFalse(d.tombstones.contains { $0.id == p.id })
        XCTAssertFalse(d.pendingSync.contains(p.id))
        d.pendingSync = []
        d.pruneTombstones(now: now.addingTimeInterval(200 * 86_400))
        XCTAssertTrue(d.tombstones.isEmpty)
    }

    func testQueryFilterAndSort() {
        var d = TessereData()
        let a = Synthetic.card("Alfa TEST", created: now.addingTimeInterval(-300))
        var b = Synthetic.card("Beta TEST", number: "555000111", format: .code128, kind: .voucher, created: now.addingTimeInterval(-200))
        b.note = "Sconto caffè"
        let c = Synthetic.card("Gamma TEST", created: now.addingTimeInterval(-100))
        for x in [a, b, c] { d.upsert(x, now: x.createdAt) }
        d.recordUse(a.id, at: now.addingTimeInterval(-86_400))
        d.recordUse(a.id, at: now.addingTimeInterval(-3_600))
        d.recordUse(b.id, at: now.addingTimeInterval(-60))

        XCTAssertEqual(CardQuery(sort: .frequent).apply(to: d, now: now).map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(CardQuery(sort: .recent).apply(to: d, now: now).map(\.id), [b.id, a.id, c.id])
        XCTAssertEqual(CardQuery(sort: .added).apply(to: d, now: now).map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(CardQuery(sort: .name).apply(to: d, now: now).map(\.storeName), ["Alfa TEST", "Beta TEST", "Gamma TEST"])
        XCTAssertEqual(CardQuery(text: "caffe").apply(to: d, now: now).map(\.id), [b.id])
        XCTAssertEqual(CardQuery(text: "000 111").apply(to: d, now: now).map(\.id), [b.id])
        XCTAssertEqual(CardQuery(kind: .voucher).apply(to: d, now: now).map(\.id), [b.id])
        XCTAssertEqual(CardQuery(text: "buono").apply(to: d, now: now).map(\.id), [b.id])
        XCTAssertEqual(d.kindsInUse, [.loyalty, .voucher])
        XCTAssertEqual(CardQuery.top(d, limit: 1, now: now).map(\.id), [a.id])
    }

    func testUsageCapAndScore() {
        var u = CardUsage()
        for i in 0..<40 { u.record(now.addingTimeInterval(Double(i))) }
        XCTAssertEqual(u.count, 40)
        XCTAssertEqual(u.recent.count, CardUsage.cap)
        var old = CardUsage()
        old.record(now.addingTimeInterval(-120 * 86_400))
        var fresh = CardUsage()
        fresh.record(now)
        XCTAssertGreaterThan(fresh.score(now: now), old.score(now: now))
    }

    func testExpiryReminders() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        var d = TessereData()
        var c = Synthetic.card("Buono TEST", kind: .voucher)
        c.expiry = now.addingTimeInterval(10 * 86_400)
        d.upsert(c, now: now)
        let r = ExpiryPlanner.reminders(for: d, now: now, calendar: cal)
        XCTAssertEqual(r.count, 2)
        XCTAssertTrue(r[0].body.contains("tra 7 giorni"))
        XCTAssertTrue(r[1].body.contains("oggi"))
        XCTAssertEqual(cal.component(.hour, from: r[0].fireDate), 9)
        d.settings.expiryReminders = false
        XCTAssertTrue(ExpiryPlanner.reminders(for: d, now: now, calendar: cal).isEmpty)
        // Past expiry: nothing.
        d.settings.expiryReminders = true
        d.edit(c.id, now: now) { $0.expiry = self.now.addingTimeInterval(-86_400) }
        XCTAssertTrue(ExpiryPlanner.reminders(for: d, now: now, calendar: cal).isEmpty)
    }

    func testFormatting() {
        XCTAssertEqual(ItalianFormat.groupedNumber("4006381333931", format: .ean13), "4 006381 333931")
        XCTAssertEqual(ItalianFormat.groupedNumber("12345678", format: .code128), "1234 5678")
        XCTAssertEqual(ItalianFormat.groupedNumber("AB12", format: .code128), "AB12")
        XCTAssertEqual(ItalianFormat.expiryText(days: -1), "Scaduta")
        XCTAssertEqual(ItalianFormat.expiryText(days: 1), "Scade domani")
    }

    func testLocations() {
        let milano = GeoPoint(latitude: 45.4642, longitude: 9.19)
        let near = GeoPoint(latitude: 45.4650, longitude: 9.19)   // ~90 m
        let roma = GeoPoint(latitude: 41.9028, longitude: 12.4964)
        XCTAssertEqual(milano.distance(to: roma), 477_000, accuracy: 5_000)
        var a = Synthetic.card("Alfa TEST"); a.storeLocations = [roma, near]
        var b = Synthetic.card("Beta TEST"); b.storeLocations = [roma]
        let regions = LocationPlanner.regions(for: [a, b], near: milano)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].cardID, a.id)
        XCTAssertEqual(LocationPlanner.cardID(fromRegion: regions[0].identifier), a.id)
        XCTAssertEqual(LocationPlanner.nearbyCards([a, b], at: milano).map(\.card.id), [a.id])
        XCTAssertTrue(LocationPlanner.needsRefresh(b, near: milano, now: now))
        b.locationsUpdatedAt = now
        XCTAssertTrue(LocationPlanner.needsRefresh(b, near: milano, now: now), "negozi lontani")
        a.locationsUpdatedAt = now
        XCTAssertFalse(LocationPlanner.needsRefresh(a, near: milano, now: now))
        XCTAssertEqual(LocationPlanner.walletLocations(a, near: milano).first, near)
    }
}
