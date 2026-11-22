import Foundation

/// sRGB color with components in 0…1.
public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    public init(r8: UInt8, g8: UInt8, b8: UInt8) {
        self.init(r: Double(r8) / 255, g: Double(g8) / 255, b: Double(b8) / 255)
    }

    /// "#RRGGBB", "RRGGBB" or "#RGB".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r8: UInt8((v >> 16) & 0xFF), g8: UInt8((v >> 8) & 0xFF), b8: UInt8(v & 0xFF))
    }

    public var hex: String {
        func c(_ x: Double) -> String {
            let v = Int((x * 255).rounded())
            let s = String(v, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + c(r) + c(g) + c(b)
    }

    /// "rgb(r, g, b)" as used by pass.json.
    public var cssRGB: String {
        "rgb(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())))"
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static let white = RGB(r: 1, g: 1, b: 1)
    /// Dark foreground used on light cards (not pure black: softer).
    public static let ink = RGB(r: 0.07, g: 0.07, b: 0.08)

    /// True when dark text/logo reads better than white on this color.
    /// White is preferred unless it is clearly worse (brand cards look better in white).
    public var prefersDarkForeground: Bool {
        contrast(with: .white) < 2.2 && contrast(with: .ink) > contrast(with: .white)
    }

    public var foreground: RGB { prefersDarkForeground ? .ink : .white }

    // MARK: HSL

    public var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h * 360, s, l)
    }

    public init(h: Double, s: Double, l: Double) {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        if s == 0 { self.init(r: l, g: l, b: l); return }
        func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(r: hue2rgb(p, q, hh + 1 / 3), g: hue2rgb(p, q, hh), b: hue2rgb(p, q, hh - 1 / 3))
    }

    /// Saturation as max-min (cheap, used for "colorful" tests).
    public var chroma: Double { max(r, g, b) - min(r, g, b) }

    public func adjustingLightness(by delta: Double) -> RGB {
        let c = hsl
        return RGB(h: c.h, s: c.s, l: min(max(c.l + delta, 0), 1))
    }

    public func distance(to o: RGB) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return sqrt(dr * dr + dg * dg + db * db)
    }
}

public enum ColorMath {

    /// Diagonal gradient stops for the card face: a touch lighter at the
    /// top-left, a touch darker at the bottom-right.
    public static func gradient(for hex: String) -> (top: String, bottom: String) {
        guard let c = RGB(hex: hex) else { return (hex, hex) }
        let l = c.hsl.l
        let up = l > 0.85 ? 0.0 : 0.07
        let down = l < 0.12 ? 0.0 : -0.09
        return (c.adjustingLightness(by: up).hex, c.adjustingLightness(by: down).hex)
    }

    /// Stable hash (FNV-1a) so the same name always gets the same color.
    public static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in StoreCatalog.normalize(s).utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    /// Pleasant, saturated color generated from the store name.
    public static func generatedHex(for name: String) -> String {
        let h = stableHash(name)
        let hue = Double(h % 360)
        let sat = 0.55 + Double((h >> 9) % 20) / 100
        let light = 0.40 + Double((h >> 17) % 12) / 100
        return RGB(h: hue, s: sat, l: light).hex
    }

    /// Up to two initials ("Coop Lombardia" → "CL", "ikea" → "IK").
    public static func initials(of name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        if words.count >= 2 {
            return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
        if let w = words.first { return String(w.prefix(2)).uppercased() }
        return "?"
    }

    // MARK: Image analysis

    /// Dominant "brand" color of an RGBA8 image (premultiplied alpha).
    /// Ignores transparent and near-white pixels, prefers colorful buckets
    /// over greys, falls back to the most common grey/black.
    public static func dominantColor(rgba: [UInt8], width: Int, height: Int) -> RGB? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        struct Bucket { var weight = 0.0; var n = 0.0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var colorful: [Int: Bucket] = [:]
        var greys: [Int: Bucket] = [:]
        let step = max(1, (width * height) / 20_000)
        var i = 0
        while i < width * height {
            let o = i * 4
            i += step
            guard let c = pixel(rgba, o) else { continue }
            let key = Int(c.r * 7.99) << 6 | Int(c.g * 7.99) << 3 | Int(c.b * 7.99)
            if c.chroma > 0.18 {
                var bk = colorful[key] ?? Bucket()
                bk.weight += 1 + c.chroma; bk.n += 1; bk.r += c.r; bk.g += c.g; bk.b += c.b
                colorful[key] = bk
            } else if min(c.r, c.g, c.b) < 0.90 {
                var bk = greys[key] ?? Bucket()
                bk.weight += 1; bk.n += 1; bk.r += c.r; bk.g += c.g; bk.b += c.b
                greys[key] = bk
            }
        }
        let colorfulSamples = colorful.values.reduce(0) { $0 + $1.n }
        let source = colorfulSamples >= 8 ? colorful : greys
        guard let p = source.values.max(by: { $0.weight < $1.weight }), p.n > 0 else { return nil }
        return RGB(r: p.r / p.n, g: p.g / p.n, b: p.b / p.n)
    }

    /// Un-premultiplied color of the pixel at byte offset `o`, nil when mostly transparent.
    static func pixel(_ rgba: [UInt8], _ o: Int) -> RGB? {
        let a = Double(rgba[o + 3]) / 255
        guard a > 0.5 else { return nil }
        return RGB(r: Double(rgba[o]) / 255 / a, g: Double(rgba[o + 1]) / 255 / a, b: Double(rgba[o + 2]) / 255 / a)
    }
}
