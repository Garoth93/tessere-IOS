import XCTest
@testable import TessereCore

final class BarcodeTests: XCTestCase {
    func testEANCheckDigits() {
        XCTAssertEqual(Barcode1D.ean13Check("400638133393"), 1)
        XCTAssertEqual(Barcode1D.ean13Check("978020137962"), 4)
        XCTAssertEqual(Barcode1D.eanCheck("9638507"), 4) // EAN-8 96385074
        XCTAssertEqual(Barcode1D.eanCheck("03600029145"), 2) // UPC-A 036000291452
    }

    func testEAN13Structure() throws {
        let code = try XCTUnwrap(Barcode1D.ean13("4006381333931"))
        XCTAssertEqual(code.count, 95)
        XCTAssertEqual(code.text, "4006381333931")
        XCTAssertEqual(Array(code.modules.prefix(3)), [true, false, true])
        XCTAssertEqual(Array(code.modules[45..<50]), [false, true, false, true, false])
        // Twelve digits: the check digit is added.
        XCTAssertEqual(Barcode1D.ean13("400638133393")?.text, "4006381333931")
        // Wrong check digit refused.
        XCTAssertNil(Barcode1D.ean13("4006381333932"))
        XCTAssertNil(Barcode1D.ean13("12345"))
    }

    func testOtherLinearLengths() {
        XCTAssertEqual(Barcode1D.ean8("96385074")?.count, 67)
        XCTAssertEqual(Barcode1D.upcA("036000291452")?.count, 95)
        XCTAssertEqual(Barcode1D.upcA("036000291452")?.text, "036000291452")
        XCTAssertEqual(Barcode1D.upcE("04252614")?.count, 51)
        XCTAssertEqual(Barcode1D.upcE("425261")?.text, "04252614")
        XCTAssertNil(Barcode1D.upcE("04252615"))
        XCTAssertEqual(Barcode1D.upcEExpand(numberSystem: 0, six: [4, 2, 5, 2, 6, 1]).map(String.init).joined(), "04210000526")
    }

    func testCode39TableHasThreeWideElements() {
        for (ch, pattern) in Barcode1D.code39Characters {
            XCTAssertEqual(pattern.count, 9, "\(ch)")
            XCTAssertEqual(pattern.filter { $0 == "1" }.count, 3, "\(ch)")
        }
        XCTAssertNotNil(Barcode1D.code39("ABC-123"))
        XCTAssertEqual(Barcode1D.code39("abc")?.text, "ABC")
        XCTAssertNil(Barcode1D.code39("ab@"))
    }

    func testCodabarAndITF() {
        for (ch, pattern) in Barcode1D.codabarCharacters { XCTAssertEqual(pattern.count, 7, "\(ch)") }
        XCTAssertEqual(Barcode1D.codabar("A40156B")?.text, "40156")
        XCTAssertEqual(Barcode1D.codabar("40156")?.text, "40156")
        XCTAssertNil(Barcode1D.codabar("4A0"))
        XCTAssertEqual(Barcode1D.itf("123")?.text, "0123")
        XCTAssertNil(Barcode1D.itf("12a"))
    }

    func testFormatHelpers() {
        XCTAssertEqual(BarcodeFormat.ean13.walletFormat, "PKBarcodeFormatCode128")
        XCTAssertEqual(BarcodeFormat.qr.walletFormat, "PKBarcodeFormatQR")
        XCTAssertNil(BarcodeFormat.none.walletFormat)
        XCTAssertEqual(BarcodeFormat.fromScanner("org.gs1.EAN-13"), .ean13)
        XCTAssertEqual(BarcodeFormat.fromScanner("org.iso.Code128"), .code128)
        XCTAssertEqual(BarcodeFormat.fromVision("VNBarcodeSymbologyQR"), .qr)
        XCTAssertEqual(BarcodeFormat.suggest(for: "4006381333931"), .ean13)
        XCTAssertEqual(BarcodeFormat.suggest(for: "ABC123"), .code128)
        let (f, p) = BarcodeFormat.normalizeScan(format: .ean13, payload: "0036000291452")
        XCTAssertEqual(f, .upcA); XCTAssertEqual(p, "036000291452")
        XCTAssertTrue(BarcodeFormat.ean13.accepts("400638133393"))
        XCTAssertFalse(BarcodeFormat.ean13.accepts("4006381333932"))
        XCTAssertFalse(BarcodeFormat.code128.accepts("è"))
        // Long codes
        XCTAssertGreaterThan(Barcode1D.moduleCount("ABCDEFGHIJKLMNOPQRST", format: .code128), 200)
    }

    func testBarsRuns() {
        let c = LinearCode(modules: [true, true, false, true, false, false, true], quietZone: 0, text: "")
        XCTAssertEqual(c.bars.map { [$0.start, $0.width] }, [[0, 2], [3, 1], [6, 1]])
    }

    /// Writes module strings for an external decoder check (scripts/verify-barcodes.py).
    func testDumpForExternalDecoder() throws {
        guard let path = ProcessInfo.processInfo.environment["DUMP_BARCODES"] else { return }
        let samples: [(BarcodeFormat, String)] = [
            (.ean13, "4006381333931"), (.ean13, "800123456789"), (.ean8, "96385074"), (.upcA, "036000291452"),
            (.upcE, "04252614"), (.code39, "TESSERA-42"), (.itf, "12345678"), (.codabar, "A40156B")
        ]
        var lines: [String] = []
        for (f, s) in samples {
            let c = try XCTUnwrap(Barcode1D.encode(s, as: f))
            lines.append("\(f.rawValue)\t\(c.text)\t\(c.modules.map { $0 ? "1" : "0" }.joined())")
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
