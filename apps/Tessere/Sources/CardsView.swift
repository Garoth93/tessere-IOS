import SwiftUI
import TessereCore

struct CardRef: Identifiable, Hashable {
    let id: UUID
}

/// The "Carte" tab: 2-column grid of colored cards, kind chips, search
/// (pull down), sync and settings at the top left, + at the top right.
struct CardsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncService.self) private var sync
    @Environment(LocationService.self) private var location
    @State private var search = ""
    @State private var kind: CardKind?
    @State private var deleting: Card?
    @Namespace private var zoom

    private var cards: [Card] {
        CardQuery(text: search, kind: kind, sort: model.data.settings.sortMode).apply(to: model.data)
    }

    private var presented: Binding<CardRef?> {
        Binding(
            get: { model.presentedCardID.map(CardRef.init(id:)) },
            set: { model.presentedCardID = $0?.id }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.data.cards.isEmpty {
                    EmptyCardsView { model.sheet = .add }
                } else {
                    grid
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Tessere")
            .toolbar { toolbar }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Cerca negozio, nota o numero")
        }
        .fullScreenCover(item: presented) { ref in
            CardDetailView(cardID: ref.id)
                .navigationTransition(.zoom(sourceID: ref.id, in: zoom))
        }
        .confirmationDialog("Eliminare \(deleting?.storeName ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                if let d = deleting { model.deleteCard(d.id) }
                deleting = nil
            }
        } message: {
            Text(model.data.sync.isInSpace && (deleting?.shared ?? false) ? "Sarà eliminata anche dagli altri dispositivi della famiglia." : "L'operazione non si può annullare.")
        }
        .onChange(of: model.data.kindsInUse) { _, kinds in
            if let k = kind, !kinds.contains(k) { kind = nil }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                if model.data.sync.isInSpace {
                    Task { await sync.syncNow(manual: true) }
                } else {
                    model.sheet = .family
                }
            } label: {
                Image(systemName: sync.lastFailed ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, options: .repeating, isActive: sync.isSyncing)
            }
            .accessibilityLabel(model.data.sync.isInSpace ? "Sincronizza" : "Sincronizzazione e famiglia")

            Button {
                model.sheet = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Impostazioni")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Haptics.light()
                model.sheet = .add
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Aggiungi carta")
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.data.settings.locationSuggestions == .undecided {
                    LocationBanner()
                }
                if !location.nearbyCardIDs.isEmpty && search.isEmpty {
                    NearbyStrip(ids: location.nearbyCardIDs, zoom: zoom)
                }
                filterBar
                let list = cards
                if list.isEmpty {
                    if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .padding(.top, 40)
                    } else {
                        ContentUnavailableView("Nessuna carta di questo tipo", systemImage: kind?.symbol ?? "creditcard")
                            .padding(.top, 40)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(list) { card in
                            cardTile(card)
                        }
                        if search.isEmpty {
                            AddPlaceholderCard(compact: true) { model.sheet = .add }
                        }
                    }
                    .id(model.logoRevision)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func cardTile(_ card: Card) -> some View {
        Button {
            Haptics.light()
            model.recordUse(card.id)
            model.presentedCardID = card.id
        } label: {
            CardFace(card: card)
        }
        .buttonStyle(CardPressStyle())
        .matchedTransitionSource(id: card.id, in: zoom) { src in
            src.clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .contextMenu {
            Button {
                model.sheet = .edit(card.id)
            } label: {
                Label("Modifica", systemImage: "pencil")
            }
            Button {
                UIPasteboard.general.string = card.shownNumber
                Haptics.success()
                model.show("Numero copiato", icon: "doc.on.doc.fill")
            } label: {
                Label("Copia numero", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                deleting = card
            } label: {
                Label("Elimina", systemImage: "trash")
            }
        } preview: {
            CardFace(card: card, size: .large)
                .frame(width: 320)
        }
    }

    // MARK: Chips + sort

    private var filterBar: some View {
        HStack(spacing: 8) {
            let kinds = model.data.kindsInUse
            if kinds.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Tutte", symbol: nil, selected: kind == nil) { kind = nil }
                        ForEach(kinds, id: \.self) { k in
                            Chip(title: k.pluralTitle, symbol: k.symbol, selected: kind == k) {
                                kind = kind == k ? nil : k
                            }
                        }
                    }
                }
                .scrollClipDisabled()
            } else {
                Text(ItalianFormat.plural(model.data.cards.count, "carta", "carte"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Picker("Ordina", selection: Binding(get: { model.data.settings.sortMode }, set: { m in model.updateSettings { $0.sortMode = m } })) {
                    ForEach(SortMode.allCases, id: \.self) { m in
                        Label(m.title, systemImage: m.symbol).tag(m)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("Ordina")
        }
        .animation(.snappy, value: kind)
    }
}

struct Chip: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)) }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Dashed placeholder card (+): empty state and last tile of the grid.
struct AddPlaceholderCard: View {
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(Theme.cardAspect, contentMode: .fit)
                .overlay {
                    VStack(spacing: compact ? 4 : 8) {
                        Image(systemName: "plus")
                            .font(.system(size: compact ? 22 : 30, weight: .semibold))
                        if !compact {
                            Text("Aggiungi carta")
                                .font(.headline)
                        }
                    }
                    .foregroundStyle(Theme.accent)
                }
                .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                )
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel("Aggiungi carta")
    }
}

/// Tilted card with a barcode on black (same as the app icon).
struct TiltedCardArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.31, green: 1, blue: 0.80), Color(red: 0, green: 0.62, blue: 0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        Circle().fill(.white.opacity(0.9)).frame(width: 18, height: 18)
                        Capsule().fill(.white.opacity(0.75)).frame(width: 60, height: 9)
                    }
                    .padding(16)
                }
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white)
                        .frame(height: 46)
                        .overlay {
                            if let code = Barcode1D.ean13("400638133393") {
                                LinearBarsView(code: code).padding(.vertical, 7)
                            }
                        }
                        .padding(14)
                }
                .frame(width: 190, height: 120)
                .shadow(color: Theme.accent.opacity(0.45), radius: 28, y: 10)
        }
        .rotationEffect(.degrees(-12))
        .accessibilityHidden(true)
    }
}

struct EmptyCardsView: View {
    let add: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                TiltedCardArt()
                    .padding(.top, 36)
                    .padding(.bottom, 8)
                VStack(spacing: 8) {
                    Text("Tutte le tue carte, in tasca")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Aggiungi tessere fedeltà, buoni e biglietti: scansiona il codice a barre o inseriscilo a mano. Logo e colore li trova l'app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
                AddPlaceholderCard(action: add)
                    .frame(maxWidth: 300)
                Button(action: add) {
                    Label("Scansiona la prima carta", systemImage: "barcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
    }
}

/// "Attiva ora / Non interessato": suggestions based on location.
struct LocationBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("La carta giusta, al momento giusto")
                        .font(.headline)
                    Text("Quando entri in un negozio ti suggeriamo la sua tessera, anche dalla schermata di blocco.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button {
                    Haptics.light()
                    model.updateSettings { $0.locationSuggestions = .enabled }
                    LocationService.shared.activate()
                } label: {
                    Text("Attiva ora")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accent, in: Capsule())
                }
                Button {
                    withAnimation { model.updateSettings { $0.locationSuggestions = .dismissed } }
                } label: {
                    Text("Non interessato")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Cards whose shop is a few steps away.
struct NearbyStrip: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]
    let zoom: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sei vicino a", systemImage: "location.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ids.compactMap { model.data.card($0) }) { card in
                        Button {
                            Haptics.light()
                            model.recordUse(card.id)
                            model.presentedCardID = card.id
                        } label: {
                            HStack(spacing: 10) {
                                CardFace(card: card, size: .mini, showBadge: false)
                                    .frame(width: 58)
                                Text(card.storeName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: "barcode")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .padding(.trailing, 6)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(CardPressStyle())
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}
