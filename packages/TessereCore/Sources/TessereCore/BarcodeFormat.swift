import Foundation

/// Barcode symbologies the app can scan and draw.
///
/// 1D codes (except Code 128) are drawn from `Barcode1D` (this package);
/// Code 128, QR, PDF417 and Aztec are drawn by Core Image in the app.
public enum BarcodeFormat: String, Codable, CaseIterable, Sendable, Hashable {
    case ean13, ean8, upcA, upcE, code128, code39, itf, codabar
    case qr, pdf417, aztec
    /// No barcode: the number is shown in large type.
    case none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BarcodeFormat(rawValue: raw) ?? .code128
    }

    public var title: String {
        switch self {
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upcA: return "UPC-A"
        case .upcE: return "UPC-E"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .itf: return "ITF (2 su 5)"
        case .codabar: return "Codabar"
        case .qr: return "QR"
        case .pdf417: return "PDF417"
        case .aztec: return "Aztec"
        case .none: return "Solo numero"
        }
    }

    public var isTwoDimensional: Bool {
        switch self {
        case .qr, .aztec, .pdf417: return true
        default: return false
        }
    }

    /// Square codes (QR, Aztec).
    public var isSquare: Bool { self == .qr || self == .aztec }

    public var isLinear: Bool { !isTwoDimensional && self != .none }

    /// Apple Wallet supports only QR, PDF417, Aztec and Code 128: every
    /// linear code goes to Wallet as Code 128 with the same payload.
    public var walletFormat: String? {
        switch self {
        case .qr: return "PKBarcodeFormatQR"
        case .pdf417: return "PKBarcodeFormatPDF417"
        case .aztec: return "PKBarcodeFormatAztec"
        case .none: return nil
        default: return "PKBarcodeFormatCode128"
        }
    }

    /// AVFoundation metadata type raw values (`AVMetadataObject.ObjectType.rawValue`).
    public static func fromScanner(_ raw: String) -> BarcodeFormat? {
        switch raw {
        case "org.gs1.EAN-13": return .ean13
        case "org.gs1.EAN-8": return .ean8
        case "org.gs1.UPC-E": return .upcE
        case "com.intermec.Code128": return .code128
        case "org.iso.Code128": return .code128
        case "org.iso.Code39", "org.iso.Code39Mod43": return .code39
        case "org.ansi.Interleaved2of5", "org.gs1.ITF14": return .itf
        case "com.apple.Codabar", "org.ansi.Codabar": return .codabar
        case "org.iso.QRCode": return .qr
        case "org.iso.PDF417": return .pdf417
        case "org.iso.Aztec": return .aztec
        default: return nil
        }
    }

    /// Vision `VNBarcodeSymbology.rawValue` values (scan from photo).
    public static func fromVision(_ raw: String) -> BarcodeFormat? {
        switch raw.lowercased() {
        case let r where r.contains("ean13"): return .ean13
        case let r where r.contains("ean8"): return .ean8
        case let r where r.contains("upce"): return .upcE
        case let r where r.contains("code128"): return .code128
        case let r where r.contains("code39"): return .code39
        case let r where r.contains("i2of5") || r.contains("itf"): return .itf
        case let r where r.contains("codabar"): return .codabar
        case let r where r.contains("qr"): return .qr
        case let r where r.contains("pdf417"): return .pdf417
        case let r where r.contains("aztec"): return .aztec
        default: return nil
        }
    }

    /// Normalizes a scanned payload: a 13-digit EAN starting with 0 is a UPC-A.
    public static func normalizeScan(format: BarcodeFormat, payload: String) -> (BarcodeFormat, String) {
        let p = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if format == .ean13, p.count == 13, p.hasPrefix("0"), p.allSatisfy(\.isASCIIDigit) {
            return (.upcA, String(p.dropFirst()))
        }
        return (format, p)
    }

    /// Whether `payload` can be drawn with this format.
    public func accepts(_ payload: String) -> Bool {
        let p = payload
        guard !p.isEmpty else { return false }
        switch self {
        case .ean13:
            return p.allSatisfy(\.isASCIIDigit) && (p.count == 12 || (p.count == 13 && Barcode1D.ean13Check(String(p.prefix(12))) == p.last?.wholeNumberValue))
        case .ean8:
            return p.allSatisfy(\.isASCIIDigit) && (p.count == 7 || (p.count == 8 && Barcode1D.eanCheck(String(p.prefix(7))) == p.last?.wholeNumberValue))
        case .upcA:
            return p.allSatisfy(\.isASCIIDigit) && (p.count == 11 || (p.count == 12 && Barcode1D.eanCheck(String(p.prefix(11))) == p.last?.wholeNumberValue))
        case .upcE:
            return Barcode1D.upcE(p) != nil
        case .code39:
            return Barcode1D.code39(p) != nil
        case .itf:
            return p.allSatisfy(\.isASCIIDigit)
        case .codabar:
            return Barcode1D.codabar(p) != nil
        case .code128:
            return p.unicodeScalars.allSatisfy { $0.value < 128 }
        case .qr, .pdf417, .aztec, .none:
            return true
        }
    }

    /// Best guess when the user types a number by hand.
    public static func suggest(for payload: String) -> BarcodeFormat {
        let p = payload.trimmingCharacters(in: .whitespaces)
        if p.allSatisfy(\.isASCIIDigit) {
            if p.count == 13, BarcodeFormat.ean13.accepts(p) { return .ean13 }
            if p.count == 8, BarcodeFormat.ean8.accepts(p) { return .ean8 }
            if p.count == 12, BarcodeFormat.upcA.accepts(p) { return .upcA }
        }
        if p.count > 60 || p.contains("://") { return .qr }
        return .code128
    }

    /// Formats offered in the manual editor.
    public static var editable: [BarcodeFormat] {
        [.code128, .ean13, .ean8, .upcA, .upcE, .code39, .itf, .codabar, .qr, .pdf417, .aztec, .none]
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
