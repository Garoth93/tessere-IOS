import SwiftUI
import UIKit
import TessereCore

/// The colored face of a card: brand color with a light diagonal gradient,
/// logo (or name / initials) in white or dark for contrast, optional note pill.
struct CardFace: View {
    enum Size { case mini, grid, large }

    let name: String
    let colorHex: String
    let style: LogoStyle
    let initials: String
    let logo: UIImage?
    var note: String? = nil
    var badge: String? = nil
    var badgeIsAlert = false
    var size: Size = .grid

    private var base: RGB { RGB(hex: colorHex) ?? RGB(r: 0.3, g: 0.3, b: 0.32) }
    private var fg: Color { base.prefersDarkForeground ? Color(rgb: .ink) : .white }

    private var radius: CGFloat {
        switch size {
        case .mini: return 12
        case .grid: return Theme.cardRadius
        case .large: return 28
        }
    }

    var body: some View {
        let g = ColorMath.gradient(for: base.hex)
        Color.clear
            .aspectRatio(Theme.cardAspect, contentMode: .fit)
            .overlay {
                ZStack {
                    LinearGradient(colors: [Color(hex: g.top), Color(hex: g.bottom)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(colors: [.white.opacity(0.10), .clear],
                                   startPoint: .topLeading, endPoint: .center)
                    GeometryReader { geo in
                        mark(in: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) { notePill }
            .overlay(alignment: .topTrailing) { badgeView }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var s = name
        if let note, !note.isEmpty { s += ", \(note)" }
        if let badge { s += ", \(badge)" }
        return s
    }

    @ViewBuilder
    private func mark(in size: CGSize) -> some View {
        if style == .auto, let logo {
            Image(uiImage: logo)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(fg)
                .frame(maxWidth: size.width * 0.64, maxHeight: size.height * 0.42)
                .offset(y: hasNote ? -size.height * 0.05 : 0)
        } else if style == .initials {
            Text(initials)
                .font(.system(size: size.height * 0.36, weight: .heavy, design: .rounded))
                .foregroundStyle(fg)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.horizontal, size.width * 0.08)
        } else {
            Text(name)
                .font(.system(size: size.height * (name.count > 14 ? 0.15 : 0.2), weight: .heavy, design: .rounded))
                .foregroundStyle(fg)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.35)
                .padding(.horizontal, size.width * 0.09)
                .offset(y: hasNote ? -size.height * 0.05 : 0)
        }
    }

    private var hasNote: Bool { !(note ?? "").isEmpty && size != .mini }

    @ViewBuilder
    private var notePill: some View {
        if hasNote, let note {
            Text(note)
                .font(.system(size: size == .large ? 15 : 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, size == .large ? 11 : 8)
                .padding(.vertical, size == .large ? 5 : 3.5)
                .foregroundStyle(fg)
                .background(fg.opacity(0.18), in: Capsule())
                .padding(size == .large ? 16 : 9)
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge, size != .mini {
            Text(badge)
                .font(.system(size: size == .large ? 13 : 10, weight: .bold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(badgeIsAlert ? .white : fg)
                .background(badgeIsAlert ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(fg.opacity(0.2)), in: Capsule())
                .padding(size == .large ? 14 : 8)
        }
    }
}

extension CardFace {
    init(card: Card, size: Size = .grid, now: Date = Date(), showBadge: Bool = true) {
        var badge: String?
        var alert = false
        if showBadge, let d = card.daysToExpiry(now: now), d <= 30 {
            badge = d < 0 ? "Scaduta" : (d == 0 ? "Oggi" : "\(d) gg")
            alert = d <= 7
        }
        self.init(name: card.storeName, colorHex: card.resolvedColorHex, style: card.logoStyle,
                  initials: card.initials,
                  logo: card.hasLogo ? LogoStore.image(for: card.id, version: card.logoVersion) : nil,
                  note: card.trimmedNote.isEmpty ? nil : card.trimmedNote,
                  badge: badge, badgeIsAlert: alert, size: size)
    }
}
