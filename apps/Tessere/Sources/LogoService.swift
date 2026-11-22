import Foundation
import UIKit
import TessereCore

/// Finds a logo for a store: icons of its web domain (apple-touch-icon,
/// icons declared by the home page, then favicon services), turned into a
/// single-color mark by `LogoMask`. Also returns the brand color.
enum LogoService {
    struct Found: Equatable {
        /// White mark on transparent, PNG.
        let png: Data
        let brandHex: String?
        let source: URL?
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": "it-IT,it;q=0.9"
        ]
        return URLSession(configuration: c)
    }()

    /// Looks for a usable logo on `domain`. Nil when nothing good is found.
    static func find(domain: String) async -> Found? {
        let normalized = StoreCatalog.normalizeDomain(domain)
        guard normalized.contains(".") else { return nil }
        var tried = Set<String>()
        var candidates: [URL] = []
        let fixed = LogoSources.urls(domain: normalized)
        // apple-touch-icon first, then what the home page declares, then favicon services.
        candidates += fixed.prefix(2)
        if let home = LogoSources.homePage(domain: normalized), let html = await fetchHTML(home) {
            candidates += HTMLMeta.iconCandidates(in: html, base: home).prefix(4)
        }
        candidates += fixed.dropFirst(2)
        var fallback: Found?
        for url in candidates where tried.insert(url.absoluteString).inserted {
            guard let image = await fetchImage(url) else { continue }
            let px = max(image.size.width * image.scale, image.size.height * image.scale)
            guard px >= 32, let found = process(image, source: url) else { continue }
            if px >= 96 { return found }
            if fallback == nil { fallback = found }
        }
        return fallback
    }

    /// Logo chosen by the user from Photos.
    static func fromImage(_ image: UIImage) -> Found? { process(image, source: nil) }

    // MARK: Network

    static func fetchHTML(_ url: URL) async -> String? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let head = data.prefix(400_000)
        return String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1)
    }

    private static func fetchImage(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 100, data.count < 5_000_000 else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("svg") || type.contains("html") { return nil }
        return UIImage(data: data)
    }

    // MARK: Processing

    /// Draws the image at most 256 px, extracts the mark, returns it as PNG.
    static func process(_ image: UIImage, source: URL?) -> Found? {
        guard let (pixels, w, h) = rgba(of: image, maxSide: 256),
              let result = LogoMask.extract(rgba: pixels, width: w, height: h),
              let png = maskPNG(result) else { return nil }
        let brand = LogoMask.brandColor(result) ?? ColorMath.dominantColor(rgba: pixels, width: w, height: h)
        return Found(png: png, brandHex: brand?.hex, source: source)
    }

    static func rgba(of image: UIImage, maxSide: CGFloat) -> ([UInt8], Int, Int)? {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let k = min(1, maxSide / max(size.width, size.height))
        let w = max(8, Int((size.width * k).rounded())), h = max(8, Int((size.height * k).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            UIGraphicsPushContext(ctx)
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            UIGraphicsPopContext()
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    /// White pixels with the mask as alpha (premultiplied).
    static func maskPNG(_ r: LogoMask.Result) -> Data? {
        var px = [UInt8](repeating: 0, count: r.width * r.height * 4)
        for i in 0..<(r.width * r.height) {
            let a = r.alpha[i]
            px[i * 4] = a; px[i * 4 + 1] = a; px[i * 4 + 2] = a; px[i * 4 + 3] = a
        }
        let cg: CGImage? = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: r.width, height: r.height, bitsPerComponent: 8,
                                      bytesPerRow: r.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
        guard let cg else { return nil }
        return UIImage(cgImage: cg).pngData()
    }
}
