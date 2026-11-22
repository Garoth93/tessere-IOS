import Foundation

/// A linear barcode as a row of modules (true = bar), plus its quiet zone.
public struct LinearCode: Equatable, Sendable {
    public var modules: [Bool]
    /// Blank modules required on each side.
    public var quietZone: Int
    /// Text to print under the bars (digits with check digit).
    public var text: String

    public var count: Int { modules.count }
    /// Total width including both quiet zones.
    public var totalWidth: Int { modules.count + 2 * quietZone }

    /// Bars as (start, width) runs in module units, without the quiet zone.
    public var bars: [(start: Int, width: Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i < modules.count {
            if modules[i] {
                var j = i
                while j < modules.count, modules[j] { j += 1 }
                out.append((i, j - i))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }
}

/// Pure-Swift encoders for the linear symbologies Core Image cannot draw.
public enum Barcode1D {

    public static func encode(_ payload: String, as format: BarcodeFormat) -> LinearCode? {
        switch format {
        case .ean13: return ean13(payload)
        case .ean8: return ean8(payload)
        case .upcA: return upcA(payload)
        case .upcE: return upcE(payload)
        case .code39: return code39(payload)
        case .itf: return itf(payload)
        case .codabar: return codabar(payload)
        default: return nil
        }
    }

    // MARK: EAN / UPC

    private static let lCodes = ["0001101", "0011001", "0010011", "0111101", "0100011",
                                 "0110001", "0101111", "0111011", "0110111", "0001011"]
    private static let gCodes = ["0100111", "0110011", "0011011", "0100001", "0011101",
                                 "0111001", "0000101", "0010001", "0001001", "0010111"]
    private static let rCodes = ["1110010", "1100110", "1101100", "1000010", "1011100",
                                 "1001110", "1010000", "1000100", "1001000", "1110100"]
    /// L/G parity of the left half, chosen by the first EAN-13 digit.
    private static let ean13Parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG",
                                      "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
    /// UPC-E parity (number system 0) chosen by the check digit; E = G code, O = L code.
    private static let upcEParity = ["EEEOOO", "EEOEOO", "EEOOEO", "EEOOOE", "EOEEOO",
                                     "EOOEEO", "EOOOEE", "EOEOEO", "EOEOOE", "EOOEOE"]

    private static func digits(_ s: String) -> [Int]? {
        let d = s.compactMap { $0.isASCIIDigit ? $0.wholeNumberValue : nil }
        return d.count == s.count ? d : nil
    }

    private static func bits(_ s: String) -> [Bool] { s.map { $0 == "1" } }

    /// GS1 mod-10 check digit for any length (weights 3,1,3… from the right).
    public static func eanCheck(_ data: String) -> Int? {
        guard let d = digits(data), !d.isEmpty else { return nil }
        var sum = 0
        for (i, v) in d.reversed().enumerated() {
            sum += v * (i % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    public static func ean13Check(_ twelve: String) -> Int? {
        guard twelve.count == 12 else { return nil }
        return eanCheck(twelve)
    }

    /// Adds or verifies the check digit.
    private static func withCheck(_ s: String, dataLength: Int) -> [Int]? {
        let p = s.trimmingCharacters(in: .whitespaces)
        guard var d = digits(p) else { return nil }
        if d.count == dataLength, let c = eanCheck(p) {
            d.append(c)
        } else if d.count == dataLength + 1 {
            guard eanCheck(String(p.prefix(dataLength))) == d.last else { return nil }
        } else {
            return nil
        }
        return d
    }

    public static func ean13(_ s: String) -> LinearCode? {
        guard let d = withCheck(s, dataLength: 12) else { return nil }
        var m = bits("101")
        let parity = Array(ean13Parity[d[0]])
        for i in 1...6 {
            m += bits(parity[i - 1] == "L" ? lCodes[d[i]] : gCodes[d[i]])
        }
        m += bits("01010")
        for i in 7...12 { m += bits(rCodes[d[i]]) }
        m += bits("101")
        return LinearCode(modules: m, quietZone: 11, text: d.map(String.init).joined())
    }

    public static func ean8(_ s: String) -> LinearCode? {
        guard let d = withCheck(s, dataLength: 7) else { return nil }
        var m = bits("101")
        for i in 0..<4 { m += bits(lCodes[d[i]]) }
        m += bits("01010")
        for i in 4..<8 { m += bits(rCodes[d[i]]) }
        m += bits("101")
        return LinearCode(modules: m, quietZone: 7, text: d.map(String.init).joined())
    }

    /// UPC-A is an EAN-13 with a leading zero.
    public static func upcA(_ s: String) -> LinearCode? {
        let p = s.trimmingCharacters(in: .whitespaces)
        guard p.count == 11 || p.count == 12, var code = ean13("0" + p) else { return nil }
        code.text = String(code.text.dropFirst())
        code.quietZone = 9
        return code
    }

    /// Expands a UPC-E (number system + 6 digits) to the 11 data digits of UPC-A.
    public static func upcEExpand(numberSystem ns: Int, six d: [Int]) -> [Int] {
        switch d[5] {
        case 0, 1, 2: return [ns, d[0], d[1], d[5], 0, 0, 0, 0, d[2], d[3], d[4]]
        case 3: return [ns, d[0], d[1], d[2], 0, 0, 0, 0, 0, d[3], d[4]]
        case 4: return [ns, d[0], d[1], d[2], d[3], 0, 0, 0, 0, 0, d[4]]
        default: return [ns, d[0], d[1], d[2], d[3], d[4], 0, 0, 0, 0, d[5]]
        }
    }

    /// Accepts 6 digits (number system 0), 7 (ns + 6) or 8 (ns + 6 + check).
    public static func upcE(_ s: String) -> LinearCode? {
        guard let all = digits(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        let ns: Int
        let six: [Int]
        var given: Int?
        switch all.count {
        case 6: ns = 0; six = all
        case 7: ns = all[0]; six = Array(all[1...6])
        case 8: ns = all[0]; six = Array(all[1...6]); given = all[7]
        default: return nil
        }
        guard ns == 0 || ns == 1 else { return nil }
        let expanded = upcEExpand(numberSystem: ns, six: six).map(String.init).joined()
        guard let check = eanCheck(expanded) else { return nil }
        if let given, given != check { return nil }
        var pattern = Array(upcEParity[check])
        if ns == 1 { pattern = pattern.map { $0 == "E" ? "O" : "E" } }
        var m = bits("101")
        for i in 0..<6 {
            m += bits(pattern[i] == "O" ? lCodes[six[i]] : gCodes[six[i]])
        }
        m += bits("010101")
        let text = ([ns] + six + [check]).map(String.init).joined()
        return LinearCode(modules: m, quietZone: 9, text: text)
    }

    // MARK: Code 39

    /// 9 elements (bar, space, …, bar); 1 = wide.
    private static let code39Table: [Character: String] = [
        "0": "000110100", "1": "100100001", "2": "001100001", "3": "101100000",
        "4": "000110001", "5": "100110000", "6": "001110000", "7": "000100101",
        "8": "100100100", "9": "001100100", "A": "100001001", "B": "001001001",
        "C": "101001000", "D": "000011001", "E": "100011000", "F": "001011000",
        "G": "000001101", "H": "100001100", "I": "001001100", "J": "000011100",
        "K": "100000011", "L": "001000011", "M": "101000010", "N": "000010011",
        "O": "100010010", "P": "001010010", "Q": "000000111", "R": "100000110",
        "S": "001000110", "T": "000010110", "U": "110000001", "V": "011000001",
        "W": "111000000", "X": "010010001", "Y": "110010000", "Z": "011010000",
        "-": "010000101", ".": "110000100", " ": "011000100", "*": "010010100",
        "$": "010101000", "/": "010100010", "+": "010001010", "%": "000101010"
    ]

    static var code39Characters: [Character: String] { code39Table }

    public static func code39(_ s: String) -> LinearCode? {
        var text = s.uppercased()
        if text.hasPrefix("*") && text.hasSuffix("*") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty, !text.contains("*"), text.allSatisfy({ code39Table[$0] != nil }) else { return nil }
        let wide = 3
        var m: [Bool] = []
        for (n, ch) in ("*" + text + "*").enumerated() {
            if n > 0 { m.append(false) } // narrow inter-character gap
            for (i, w) in code39Table[ch]!.enumerated() {
                let isBar = i % 2 == 0
                m += Array(repeating: isBar, count: w == "1" ? wide : 1)
            }
        }
        return LinearCode(modules: m, quietZone: 10, text: text)
    }

    // MARK: Interleaved 2 of 5

    private static let itfTable = ["00110", "10001", "01001", "11000", "00101",
                                   "10100", "01100", "00011", "10010", "01010"]

    public static func itf(_ s: String) -> LinearCode? {
        guard var d = digits(s.trimmingCharacters(in: .whitespaces)), !d.isEmpty else { return nil }
        if d.count % 2 == 1 { d.insert(0, at: 0) }
        let wide = 3
        var m: [Bool] = bits("1010") // start: narrow bar, space, bar, space
        var i = 0
        while i < d.count {
            let bar = Array(itfTable[d[i]])
            let space = Array(itfTable[d[i + 1]])
            for k in 0..<5 {
                m += Array(repeating: true, count: bar[k] == "1" ? wide : 1)
                m += Array(repeating: false, count: space[k] == "1" ? wide : 1)
            }
            i += 2
        }
        m += Array(repeating: true, count: wide) + [false, true] // stop: wide bar, space, bar
        return LinearCode(modules: m, quietZone: 10, text: d.map(String.init).joined())
    }

    // MARK: Codabar

    /// 7 elements (bar, space, …, bar); 1 = wide.
    private static let codabarTable: [Character: String] = [
        "0": "0000011", "1": "0000110", "2": "0001001", "3": "1100000",
        "4": "0010010", "5": "1000010", "6": "0100001", "7": "0100100",
        "8": "0110000", "9": "1001000", "-": "0001100", "$": "0011000",
        ":": "1000101", "/": "1010001", ".": "1010100", "+": "0010101",
        "A": "0011010", "B": "0101001", "C": "0001011", "D": "0001110"
    ]

    static var codabarCharacters: [Character: String] { codabarTable }

    public static func codabar(_ s: String) -> LinearCode? {
        var text = s.uppercased().trimmingCharacters(in: .whitespaces)
        let guards: Set<Character> = ["A", "B", "C", "D"]
        // Start/stop characters: kept when present, "A…A" otherwise.
        if let f = text.first, let l = text.last, text.count >= 2, guards.contains(f), guards.contains(l) {
            // already framed
        } else {
            text = "A" + text + "A"
        }
        let inner = text.dropFirst().dropLast()
        guard !inner.isEmpty, inner.allSatisfy({ codabarTable[$0] != nil && !guards.contains($0) }) else { return nil }
        let wide = 3
        var m: [Bool] = []
        for (n, ch) in text.enumerated() {
            if n > 0 { m.append(false) }
            for (i, w) in codabarTable[ch]!.enumerated() {
                m += Array(repeating: i % 2 == 0, count: w == "1" ? wide : 1)
            }
        }
        return LinearCode(modules: m, quietZone: 10, text: String(inner))
    }

    /// Rough module count of a Code 128 symbol (for the "long code" rotation).
    public static func estimatedCode128Modules(_ s: String) -> Int {
        // Subset C packs digit pairs; otherwise 11 modules per character.
        let digitsOnly = s.allSatisfy(\.isASCIIDigit)
        let symbols = digitsOnly ? (s.count + 1) / 2 : s.count
        return 11 * (symbols + 3) + 2
    }

    /// Module count used to decide when a linear code is "long".
    public static func moduleCount(_ payload: String, format: BarcodeFormat) -> Int {
        if format == .code128 { return estimatedCode128Modules(payload) }
        return encode(payload, as: format)?.count ?? 0
    }
}
