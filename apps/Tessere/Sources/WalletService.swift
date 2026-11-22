import SwiftUI
import UIKit
import PassKit
import TessereCore

struct PassItem: Identifiable {
    let id = UUID()
    let pass: PKPass
}

/// "Aggiungi a Apple Wallet": the Worker (backend/) signs a generic pass
/// with the user's Pass Type ID certificate; the app shows Apple's sheet.
@MainActor
@Observable
final class WalletFlow {
    var working = false
    var pass: PassItem?
    var error: String?
    var needsSetup = false

    func start(card: Card) async {
        guard PKAddPassesViewController.canAddPasses() else {
            error = "Questo iPhone non permette di aggiungere carte a Wallet."
            return
        }
        working = true
        defer { working = false }
        do {
            let data = try await WalletService.passData(for: card)
            let p = try PKPass(data: data)
            Haptics.success()
            pass = PassItem(pass: p)
        } catch let e as WalletService.Problem {
            needsSetup = e == .notConfigured
            error = e.errorDescription
        } catch let e as WalletPassBuilder.Problem {
            needsSetup = false
            error = e.errorDescription
        } catch {
            needsSetup = false
            self.error = "Il pass non è valido: \(error.localizedDescription). Controlla il certificato configurato sul server."
        }
    }
}

enum WalletService {
    enum Problem: Error, Equatable, LocalizedError {
        case notConfigured
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Per creare il pass serve il server di Tessere (lo stesso della famiglia) con il certificato Wallet. Configuralo in Impostazioni › Famiglia e server."
            case .server(let m):
                return m
            }
        }
    }

    @MainActor
    static func passData(for card: Card) async throws -> Data {
        let sync = SyncService.shared
        guard let api = sync.api else { throw Problem.notConfigured }
        let fg = (RGB(hex: card.resolvedColorHex) ?? RGB(r: 0.2, g: 0.2, b: 0.2)).foreground
        let mask = card.hasLogo ? LogoStore.data(for: card.id).flatMap { UIImage(data: $0) } : nil
        let icon = PassImages.icon(card: card, mask: mask)
        let logo = mask.flatMap { PassImages.logo(mask: $0, color: UIColor(rgb: fg)) }
        let request = try WalletPassBuilder.request(for: card, icon: icon, logo: (card.logoStyle == .auto) ? logo : nil,
                                                    near: LocationService.shared.lastLocation)
        do {
            return try await api.pass(request)
        } catch let e as SyncError {
            throw Problem.server(e.errorDescription ?? "Errore del server")
        }
    }
}

/// Images of the pass, drawn from the card.
enum PassImages {
    /// 87×87 px square (29 pt @3x): brand color with the mark or the initials.
    static func icon(card: Card, mask: UIImage?) -> Data {
        let size = CGSize(width: 87, height: 87)
        let base = RGB(hex: card.resolvedColorHex) ?? RGB(r: 0.2, g: 0.2, b: 0.2)
        let fg = UIColor(rgb: base.foreground)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(rgb: base).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let mask {
                let tinted = mask.withTintColor(fg, renderingMode: .alwaysOriginal)
                tinted.draw(in: fit(mask.size, in: CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)))
            } else {
                let text = card.initials as NSString
                let font = UIFont.systemFont(ofSize: 34, weight: .heavy)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
                let s = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2), withAttributes: attrs)
            }
        }
        return img.pngData() ?? Data()
    }

    /// Logo for the top-left of the pass: max 480×150 px (160×50 pt @3x).
    static func logo(mask: UIImage, color: UIColor) -> Data? {
        let box = CGRect(x: 0, y: 0, width: 480, height: 150)
        let r = fit(mask.size, in: box)
        let size = CGSize(width: ceil(r.width), height: ceil(r.height))
        guard size.width > 4, size.height > 4 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            mask.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.pngData()
    }

    static func fit(_ s: CGSize, in box: CGRect) -> CGRect {
        guard s.width > 0, s.height > 0 else { return box }
        let k = min(box.width / s.width, box.height / s.height)
        let w = s.width * k, h = s.height * k
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}

/// Apple's official "Add to Apple Wallet" button.
struct WalletButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> PKAddPassButton {
        let b = PKAddPassButton(addPassButtonStyle: .black)
        b.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return b
    }

    func updateUIView(_ uiView: PKAddPassButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}

/// Apple's sheet to review and add the pass.
struct AddPassSheet: UIViewControllerRepresentable {
    let pass: PKPass
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pass: pass, completion: completion) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard let vc = PKAddPassesViewController(pass: pass) else { return UIViewController() }
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, PKAddPassesViewControllerDelegate {
        let pass: PKPass
        let completion: (Bool) -> Void

        init(pass: PKPass, completion: @escaping (Bool) -> Void) {
            self.pass = pass
            self.completion = completion
        }

        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            let added = PKPassLibrary().containsPass(pass)
            completion(added)
        }
    }
}
