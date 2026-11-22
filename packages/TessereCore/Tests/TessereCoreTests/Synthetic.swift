import Foundation
@testable import TessereCore

/// Synthetic data only (never real cards).
enum Synthetic {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func card(_ name: String = "Negozio TEST", number: String = "1234567890128", format: BarcodeFormat = .ean13,
                     kind: CardKind = .loyalty, created: Date = now) -> Card {
        Card(storeName: name, number: number, format: format, kind: kind, createdAt: created)
    }

    /// Reversible fake cipher (base64 + marker).
    struct FakeCipher: SyncCipher {
        var tag = "K1"
        func seal(_ plain: Data) throws -> String { tag + ":" + plain.base64EncodedString() }
        func open(_ sealed: String) throws -> Data {
            guard sealed.hasPrefix(tag + ":"), let d = Data(base64Encoded: String(sealed.dropFirst(tag.count + 1))) else { throw SyncError.badPayload }
            return d
        }
    }
}
