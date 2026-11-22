import SwiftUI
import UIKit
import TessereCore

extension Color {
    init(rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1) }
    init(hex: String) { self.init(rgb: RGB(hex: hex) ?? RGB(r: 0.3, g: 0.3, b: 0.3)) }
}

extension UIColor {
    convenience init(rgb: RGB) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
}

/// OLED-black dark theme by default, light supported. One accent (acid teal).
enum Theme {
    static let cardRadius: CGFloat = 22
    static let cardAspect: CGFloat = 1.586   // ISO ID-1 (credit card)

    private static func dyn(_ dark: UIColor, _ light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let accent = dyn(UIColor(red: 0.24, green: 0.96, blue: 0.76, alpha: 1),
                            UIColor(red: 0.00, green: 0.60, blue: 0.48, alpha: 1))
    /// Text/icons on top of the accent.
    static let onAccent = dyn(.black, .white)
    static let background = dyn(.black, .systemGroupedBackground)
    static let surface = dyn(UIColor(white: 0.085, alpha: 1), .secondarySystemGroupedBackground)
    static let surface2 = dyn(UIColor(white: 0.14, alpha: 1), .tertiarySystemGroupedBackground)
    static let hairline = dyn(UIColor(white: 1, alpha: 0.10), UIColor(white: 0, alpha: 0.08))
    static let secondaryText = Color.secondary
    static let danger = Color(red: 1, green: 0.27, blue: 0.23)
    static let warning = Color(red: 1, green: 0.72, blue: 0.0)
}

extension View {
    /// SF Rounded everywhere.
    func roundedDesign() -> some View { fontDesign(.rounded) }
}
