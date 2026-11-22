import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import TessereCore

/// Draws any supported code in black on a transparent background
/// (the caller provides the white panel and the margins).
struct BarcodeView: View {
    let payload: String
    let format: BarcodeFormat

    var body: some View {
        switch format {
        case .none:
            Text(payload)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.3)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
        case .qr, .aztec:
            codeImage
                .aspectRatio(1, contentMode: .fit)
        case .pdf417:
            codeImage
                .aspectRatio(contentMode: .fit)
        case .code128:
            codeImage
        default:
            if let code = Barcode1D.encode(payload, as: format) {
                LinearBarsView(code: code)
            } else {
                invalid
            }
        }
    }

    @ViewBuilder
    private var codeImage: some View {
        if let img = CodeImageFactory.image(payload: payload, format: format) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .accessibilityLabel(Text("Codice \(format.title)"))
        } else {
            invalid
        }
    }

    private var invalid: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
            Text("Il numero non è valido per \(format.title).\nModifica la carta e scegli un altro formato.")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.black.opacity(0.7))
        .padding()
    }
}

/// Linear bars snapped to whole device pixels, centered, quiet zone included.
struct LinearBarsView: View {
    let code: LinearCode
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { ctx, size in
            let scale = max(displayScale, 1)
            let total = CGFloat(code.totalWidth)
            let pxPerModule = max(1, floor(size.width * scale / total))
            let unit = pxPerModule / scale
            let used = unit * total
            let x0 = ((size.width - used) / 2 * scale).rounded() / scale + CGFloat(code.quietZone) * unit
            var path = Path()
            for bar in code.bars {
                path.addRect(CGRect(x: x0 + CGFloat(bar.start) * unit, y: 0,
                                    width: CGFloat(bar.width) * unit, height: size.height))
            }
            ctx.fill(path, with: .color(.black))
        }
        .accessibilityLabel(Text("Codice a barre"))
    }
}

/// Core Image generators (QR, Aztec, PDF417, Code 128), cached.
enum CodeImageFactory {
    private static let cache = NSCache<NSString, UIImage>()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(payload: String, format: BarcodeFormat) -> UIImage? {
        let key = "\(format.rawValue)|\(payload)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let output = ciImage(payload: payload, format: format),
              let cg = context.createCGImage(output, from: output.extent.integral) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }

    private static func ciImage(payload: String, format: BarcodeFormat) -> CIImage? {
        switch format {
        case .qr:
            let f = CIFilter.qrCodeGenerator()
            f.message = Data(payload.utf8)
            f.correctionLevel = "M"
            return f.outputImage
        case .aztec:
            let f = CIFilter.aztecCodeGenerator()
            f.message = payload.data(using: .isoLatin1) ?? Data(payload.utf8)
            f.correctionLevel = 23
            return f.outputImage
        case .pdf417:
            let f = CIFilter.pdf417BarcodeGenerator()
            f.message = payload.data(using: .isoLatin1) ?? Data(payload.utf8)
            return f.outputImage
        case .code128:
            guard let data = payload.data(using: .ascii) else { return nil }
            let f = CIFilter.code128BarcodeGenerator()
            f.message = data
            f.quietSpace = 10
            f.barcodeHeight = 40
            return f.outputImage
        default:
            return nil
        }
    }
}

/// Codes that are better shown rotated (landscape) at full screen.
enum CodeLayout {
    static func isLong(_ card: Card) -> Bool {
        switch card.format {
        case .pdf417:
            return true
        case .qr, .aztec, .none:
            return false
        default:
            return Barcode1D.moduleCount(card.number, format: card.format) > 150
        }
    }

    /// Height/width ratio of the code area on the white panel.
    static func aspect(_ format: BarcodeFormat) -> CGFloat {
        switch format {
        case .qr, .aztec: return 1
        case .pdf417: return 0.38
        case .none: return 0.35
        default: return 0.42
        }
    }
}
