import Foundation

/// Turns a downloaded logo/icon into a single-color mark (alpha mask) that
/// the app tints white or dark depending on the card color.
///
/// Works on raw RGBA8 (premultiplied) so it is testable on Linux.
public enum LogoMask {

    public struct Result: Equatable, Sendable {
        /// Alpha of each pixel (row-major), cropped to the mark plus padding.
        public var alpha: [UInt8]
        public var width: Int
        public var height: Int
        /// Background color detected behind the mark (opaque icons), if any.
        public var background: RGB?
        /// Most common color of the mark itself.
        public var markColor: RGB?
        /// Fraction of the cropped area covered by the mark.
        public var coverage: Double
    }

    /// Brand color of an icon: a colorful background wins (typical
    /// apple-touch-icon), otherwise the color of the mark.
    public static func brandColor(_ r: Result) -> RGB? {
        if let bg = r.background, bg.chroma > 0.2 || bg.hsl.l < 0.25 { return bg }
        if let m = r.markColor, m.chroma > 0.15 { return m }
        if let bg = r.background, min(bg.r, bg.g, bg.b) < 0.9 { return bg }
        return r.markColor
    }

    /// - Returns: nil when no usable mark is found (photo-like images, empty
    ///   images, or a mark that fills the whole square).
    public static func extract(rgba: [UInt8], width w: Int, height h: Int) -> Result? {
        guard w >= 8, h >= 8, rgba.count >= w * h * 4 else { return nil }

        func color(_ x: Int, _ y: Int) -> RGB? { ColorMath.pixel(rgba, (y * w + x) * 4) }
        func alphaAt(_ x: Int, _ y: Int) -> Double { Double(rgba[(y * w + x) * 4 + 3]) / 255 }

        // 1. Backgrounds: the outer border ring and a ring inset by ~12%
        //    (rounded-square icons with transparent corners).
        var candidates: [RGB] = []
        for inset in [0, max(1, min(w, h) * 12 / 100)] {
            if let c = ringColor(w: w, h: h, inset: inset, color: color) { candidates.append(c) }
        }
        var unique: [RGB] = []
        for c in candidates where !unique.contains(where: { $0.distance(to: c) < 0.12 }) { unique.append(c) }
        candidates = unique

        // 2. Foreground strength per pixel.
        let near = 0.10, far = 0.28
        var a = [UInt8](repeating: 0, count: w * h)
        var markR = 0.0, markG = 0.0, markB = 0.0, markN = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let al = alphaAt(x, y)
                guard al > 0.02 else { continue }
                var strength = al
                if let c = color(x, y) {
                    let d = candidates.map { $0.distance(to: c) }.min() ?? 1
                    let t = min(max((d - near) / (far - near), 0), 1)
                    strength *= t
                    if t > 0.9 { markR += c.r; markG += c.g; markB += c.b; markN += 1 }
                } else if !candidates.isEmpty {
                    // Semi-transparent edge pixel of an opaque icon: background.
                    strength = 0
                }
                a[y * w + x] = UInt8((strength * 255).rounded())
            }
        }

        // 3. Bounding box of the mark.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where a[y * w + x] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        // Too small (noise) or filling the whole image (photo / no background found).
        guard bw >= w / 8 || bh >= h / 8 else { return nil }
        var covered = 0
        for y in minY...maxY { for x in minX...maxX where a[y * w + x] > 127 { covered += 1 } }
        let coverage = Double(covered) / Double(bw * bh)
        let fillsAll = bw >= w * 97 / 100 && bh >= h * 97 / 100
        guard coverage > 0.04, !(fillsAll && coverage > 0.80) else { return nil }

        // 4. Crop with a small padding.
        let pad = max(1, max(bw, bh) / 25)
        let cx0 = max(0, minX - pad), cy0 = max(0, minY - pad)
        let cx1 = min(w - 1, maxX + pad), cy1 = min(h - 1, maxY + pad)
        let cw = cx1 - cx0 + 1, ch = cy1 - cy0 + 1
        var out = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw { out[y * cw + x] = a[(y + cy0) * w + (x + cx0)] }
        }
        let mark = markN > 0 ? RGB(r: markR / markN, g: markG / markN, b: markB / markN) : nil
        return Result(alpha: out, width: cw, height: ch,
                      background: candidates.first, markColor: mark, coverage: coverage)
    }

    /// Uniform color of a rectangular ring, nil if the ring is mostly
    /// transparent or not uniform.
    static func ringColor(w: Int, h: Int, inset: Int, color: (Int, Int) -> RGB?) -> RGB? {
        guard inset * 2 < min(w, h) - 2 else { return nil }
        var samples: [RGB] = []
        var total = 0
        let x0 = inset, x1 = w - 1 - inset, y0 = inset, y1 = h - 1 - inset
        let stepX = max(1, (x1 - x0) / 40), stepY = max(1, (y1 - y0) / 40)
        var x = x0
        while x <= x1 {
            total += 2
            if let c = color(x, y0) { samples.append(c) }
            if let c = color(x, y1) { samples.append(c) }
            x += stepX
        }
        var y = y0
        while y <= y1 {
            total += 2
            if let c = color(x0, y) { samples.append(c) }
            if let c = color(x1, y) { samples.append(c) }
            y += stepY
        }
        guard total > 0, Double(samples.count) / Double(total) > 0.6 else { return nil }
        // Median-ish: the sample closest to the most others.
        var best: RGB?
        var bestScore = -1
        for s in samples.prefix(80) {
            let score = samples.filter { $0.distance(to: s) < 0.12 }.count
            if score > bestScore { bestScore = score; best = s }
        }
        guard let b = best, Double(bestScore) / Double(samples.count) > 0.6 else { return nil }
        return b
    }
}
