import XCTest
@testable import TessereCore

final class CatalogColorTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(StoreCatalog.normalize("  NaturaSì  "), "naturasi")
        XCTAssertEqual(StoreCatalog.normalize("Acqua & Sapone"), "acqua e sapone")
        XCTAssertEqual(StoreCatalog.normalize("In's Mercato"), "in s mercato")
    }

    func testMatch() {
        XCTAssertEqual(StoreCatalog.match("esselunga")?.id, "esselunga")
        XCTAssertEqual(StoreCatalog.match("Fidaty")?.id, "esselunga")
        XCTAssertEqual(StoreCatalog.match("Carta Fidaty Esselunga")?.id, "esselunga")
        XCTAssertEqual(StoreCatalog.match("IKEA Family")?.id, "ikea")
        XCTAssertEqual(StoreCatalog.match("Media World")?.id, "mediaworld")
        XCTAssertEqual(StoreCatalog.match("mediaworld")?.id, "mediaworld")
        XCTAssertEqual(StoreCatalog.match("Coop Lombardia")?.id, "coop")
        XCTAssertNil(StoreCatalog.match("Panificio TEST"))
        XCTAssertEqual(Set(StoreCatalog.entries.map(\.id)).count, StoreCatalog.entries.count, "ids unici")
    }

    func testSuggestions() {
        let s = StoreCatalog.suggestions(for: "es")
        XCTAssertEqual(s.first?.id, "esselunga")
        XCTAssertTrue(StoreCatalog.suggestions(for: "leroy").contains { $0.id == "leroymerlin" })
        XCTAssertTrue(StoreCatalog.suggestions(for: "").isEmpty)
    }

    func testDomains() {
        XCTAssertEqual(StoreCatalog.normalizeDomain("https://www.Esselunga.it/path?x=1"), "esselunga.it")
        XCTAssertEqual(StoreCatalog.normalizeDomain("shop.example.com:8080"), "shop.example.com")
        XCTAssertEqual(StoreCatalog.guessedDomain(for: "Panificio"), "panificio.it")
        XCTAssertEqual(StoreCatalog.entry(id: "ikea")?.flyerURL, "https://www.ikea.com/it/it/offers/")
        XCTAssertEqual(StoreCatalog.entry(id: "bennet")?.flyerURL, "https://www.bennet.com")
        for e in StoreCatalog.entries {
            XCTAssertNotNil(URL(string: e.flyerURL), e.id)
            if let c = e.colorHex { XCTAssertNotNil(RGB(hex: c), e.id) }
        }
    }

    func testHexAndContrast() throws {
        let red = try XCTUnwrap(RGB(hex: "#E2231A"))
        XCTAssertEqual(red.hex, "#E2231A")
        XCTAssertEqual(RGB(hex: "#fff"), .white)
        XCTAssertNil(RGB(hex: "zz"))
        XCTAssertFalse(red.prefersDarkForeground)
        XCTAssertTrue(RGB(hex: "#FFD400")!.prefersDarkForeground)
        XCTAssertFalse(RGB(hex: "#000000")!.prefersDarkForeground)
        XCTAssertEqual(red.cssRGB, "rgb(226, 35, 26)")
        let back = RGB(h: red.hsl.h, s: red.hsl.s, l: red.hsl.l)
        XCTAssertLessThan(back.distance(to: red), 0.01)
    }

    func testGeneratedColorStableAndInitials() {
        XCTAssertEqual(ColorMath.generatedHex(for: "Panificio TEST"), ColorMath.generatedHex(for: "panificio test"))
        XCTAssertNotNil(RGB(hex: ColorMath.generatedHex(for: "X")))
        XCTAssertEqual(ColorMath.initials(of: "Coop Lombardia"), "CL")
        XCTAssertEqual(ColorMath.initials(of: "ikea"), "IK")
        XCTAssertEqual(ColorMath.initials(of: "  "), "?")
        let g = ColorMath.gradient(for: "#336699")
        XCTAssertNotEqual(g.top, g.bottom)
    }

    // MARK: Image analysis on synthetic bitmaps

    /// w×h RGBA, filled with `bg`, with a centered rectangle of `fg`.
    func bitmap(w: Int = 64, h: Int = 64, bg: (UInt8, UInt8, UInt8, UInt8), fg: (UInt8, UInt8, UInt8, UInt8),
                rect: (Int, Int, Int, Int) = (16, 24, 48, 40), cornerAlpha0: Int = 0) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var c = bg
                if x >= rect.0 && x < rect.2 && y >= rect.1 && y < rect.3 { c = fg }
                if cornerAlpha0 > 0 && (x < cornerAlpha0 || x >= w - cornerAlpha0) && (y < cornerAlpha0 || y >= h - cornerAlpha0) { c = (0, 0, 0, 0) }
                let o = (y * w + x) * 4
                px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2; px[o + 3] = c.3
            }
        }
        return px
    }

    func testDominantColorPrefersColorful() throws {
        let px = bitmap(bg: (255, 255, 255, 255), fg: (200, 20, 30, 255))
        let c = try XCTUnwrap(ColorMath.dominantColor(rgba: px, width: 64, height: 64))
        XCTAssertLessThan(c.distance(to: RGB(r8: 200, g8: 20, b8: 30)), 0.08)
        let grey = bitmap(bg: (255, 255, 255, 255), fg: (20, 20, 20, 255))
        let g = try XCTUnwrap(ColorMath.dominantColor(rgba: grey, width: 64, height: 64))
        XCTAssertLessThan(g.hsl.l, 0.2)
        XCTAssertNil(ColorMath.dominantColor(rgba: [], width: 0, height: 0))
    }

    func testLogoMaskOnOpaqueIcon() throws {
        // White mark on a red square: background red, mark white.
        let px = bitmap(bg: (220, 0, 20, 255), fg: (255, 255, 255, 255))
        let r = try XCTUnwrap(LogoMask.extract(rgba: px, width: 64, height: 64))
        XCTAssertLessThan(r.background!.distance(to: RGB(r8: 220, g8: 0, b8: 20)), 0.05)
        XCTAssertGreaterThan(r.coverage, 0.6)
        XCTAssertLessThan(r.width, 40)
        XCTAssertEqual(LogoMask.brandColor(r)?.hex, RGB(r8: 220, g8: 0, b8: 20).hex)
    }

    func testLogoMaskOnTransparentLogo() throws {
        let px = bitmap(bg: (0, 0, 0, 0), fg: (0, 80, 170, 255))
        let r = try XCTUnwrap(LogoMask.extract(rgba: px, width: 64, height: 64))
        XCTAssertNil(r.background)
        XCTAssertLessThan(LogoMask.brandColor(r)!.distance(to: RGB(r8: 0, g8: 80, b8: 170)), 0.05)
    }

    func testLogoMaskRoundedIconWithTransparentCorners() throws {
        let px = bitmap(bg: (0, 130, 195, 255), fg: (255, 255, 255, 255), cornerAlpha0: 6)
        let r = try XCTUnwrap(LogoMask.extract(rgba: px, width: 64, height: 64))
        XCTAssertLessThan(r.width, 40, "lo sfondo del quadrato arrotondato non fa parte del marchio")
    }

    func testLogoMaskRejectsUniformImage() {
        let px = bitmap(bg: (10, 200, 10, 255), fg: (10, 200, 10, 255))
        XCTAssertNil(LogoMask.extract(rgba: px, width: 64, height: 64))
    }
}
