import WidgetKit
import SwiftUI
import TessereCore

@main
struct TessereWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TopCardsWidget()
    }
}

// MARK: - Timeline

struct CardsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CardsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CardsEntry {
        CardsEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CardsEntry) -> Void) {
        let snap = SharedStore.loadSnapshot()
        let use = (context.isPreview && (snap?.cards.isEmpty ?? true)) ? WidgetSnapshot.placeholder : (snap ?? .placeholder)
        completion(CardsEntry(date: Date(), snapshot: use))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CardsEntry>) -> Void) {
        let snap = SharedStore.loadSnapshot() ?? WidgetSnapshot(generatedAt: Date(), cards: [], totalCards: 0, locked: false)
        // The app reloads the timelines after every change; refresh daily anyway.
        completion(Timeline(entries: [CardsEntry(date: Date(), snapshot: snap)], policy: .after(Date().addingTimeInterval(86_400))))
    }
}

// MARK: - Widget

struct TopCardsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TessereTopCards", provider: CardsProvider()) { entry in
            TopCardsView(entry: entry)
        }
        .configurationDisplayName("Tessere più usate")
        .description("Le carte che usi più spesso: toccane una per mostrare il codice.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

private func cardURL(_ id: UUID?) -> URL {
    if let id { return URL(string: "tessere://card/\(id.uuidString)")! }
    return URL(string: "tessere://add")!
}

struct TopCardsView: View {
    let entry: CardsEntry
    @Environment(\.widgetFamily) private var family

    private var cards: [WidgetSnapshot.CardInfo] { entry.snapshot.cards }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: grid(columns: 2, rows: 2)
            case .systemLarge: grid(columns: 2, rows: 3)
            case .accessoryRectangular: rectangular
            case .accessoryCircular: circular
            case .accessoryInline: inline
            default: small
            }
        }
        .fontDesign(.rounded)
        .containerBackground(for: .widget) { Color.black }
    }

    // MARK: Home screen

    private var small: some View {
        Group {
            if let c = cards.first {
                VStack(alignment: .leading, spacing: 8) {
                    MiniCard(info: c)
                    HStack(spacing: 4) {
                        Image(systemName: "barcode")
                        Text(c.name).lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .padding(14)
                .widgetURL(cardURL(c.id))
            } else {
                empty
            }
        }
    }

    private func grid(columns: Int, rows: Int) -> some View {
        let shown = Array(cards.prefix(columns * rows))
        return Group {
            if shown.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if rows > 2 {
                        Text("Tessere")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(0..<rows, id: \.self) { r in
                            GridRow {
                                ForEach(0..<columns, id: \.self) { c in
                                    let i = r * columns + c
                                    if i < shown.count {
                                        Link(destination: cardURL(shown[i].id)) {
                                            MiniCard(info: shown[i])
                                        }
                                    } else {
                                        Color.clear
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(Color(red: 0.24, green: 0.96, blue: 0.76))
            Text("Aggiungi una carta")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .widgetURL(cardURL(nil))
    }

    // MARK: Lock screen

    private var rectangular: some View {
        Group {
            if let c = cards.first {
                HStack(spacing: 8) {
                    Image(systemName: "barcode")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(cards.count > 1 ? cards.dropFirst().prefix(2).map(\.name).joined(separator: " · ") : "Tocca per il codice")
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .widgetURL(cardURL(c.id))
            } else {
                Label("Tessere", systemImage: "creditcard")
                    .widgetURL(cardURL(nil))
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let c = cards.first {
                VStack(spacing: 0) {
                    Image(systemName: "barcode")
                        .font(.caption)
                    Text(c.initials)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.5)
                }
            } else {
                Image(systemName: "creditcard")
            }
        }
        .widgetURL(cardURL(cards.first?.id))
    }

    private var inline: some View {
        Group {
            if let c = cards.first {
                Label(c.name, systemImage: "creditcard")
            } else {
                Label("Tessere", systemImage: "creditcard")
            }
        }
        .widgetURL(cardURL(cards.first?.id))
    }
}

/// Small card face for the widgets (logo from the shared container).
struct MiniCard: View {
    let info: WidgetSnapshot.CardInfo

    var body: some View {
        CardFace(name: info.name, colorHex: info.colorHex, style: info.logoStyle, initials: info.initials,
                 logo: info.hasLogo ? LogoStore.image(for: info.id, version: info.logoVersion) : nil,
                 size: .mini)
    }
}
