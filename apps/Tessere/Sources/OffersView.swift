import SwiftUI
import SafariServices
import TessereCore

/// Reads the flyer page of every saved store and keeps its cover
/// (og:image) and a fingerprint: when it changes, the store gets "Nuovo".
@MainActor
enum OffersService {
    private static var running = false

    static func refresh(force: Bool) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let model = AppModel.shared
        let sources = OffersPlanner.sources(model.data)
        await withTaskGroup(of: (String, OfferState)?.self) { group in
            for src in sources {
                let old = model.data.offers[src.key]
                if !force, let at = old?.fetchedAt, old?.pageURL == src.pageURL, Date().timeIntervalSince(at) < 6 * 3600 { continue }
                group.addTask {
                    guard let url = URL(string: src.pageURL) else { return nil }
                    let html = await LogoService.fetchHTML(url)
                    let cover = html.flatMap { HTMLMeta.coverImage(in: $0, base: url) }
                    let title = html.flatMap { HTMLMeta.title(in: $0) }
                    if html == nil, let old { return (src.key, old) }
                    let state = OffersPlanner.updated(old, pageURL: src.pageURL, cover: cover, title: title, now: Date())
                    return (src.key, state)
                }
            }
            var results: [(String, OfferState)] = []
            for await r in group { if let r { results.append(r) } }
            if !results.isEmpty {
                model.updateLocal { d in
                    for (k, s) in results { d.offers[k] = s }
                }
            }
        }
    }

    static func markSeen(_ key: String) {
        AppModel.shared.updateLocal { d in
            if var s = d.offers[key] {
                s.seenKey = s.currentKey
                d.offers[key] = s
            }
        }
    }
}

struct SafariLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// "Offerte": covers of the flyers of the stores you have a card for.
struct OffersView: View {
    @Environment(AppModel.self) private var model
    @State private var open: SafariLink?
    @State private var refreshing = false

    private var sources: [OffersPlanner.Source] { OffersPlanner.sources(model.data) }

    var body: some View {
        NavigationStack {
            Group {
                if !model.data.settings.offersEnabled {
                    ContentUnavailableView {
                        Label("Offerte disattivate", systemImage: "tag.slash")
                    } description: {
                        Text("Puoi riattivarle in Impostazioni.")
                    } actions: {
                        Button("Attiva") { model.updateSettings { $0.offersEnabled = true } }
                    }
                } else if sources.isEmpty {
                    ContentUnavailableView {
                        Label("Nessun volantino", systemImage: "newspaper")
                    } description: {
                        Text("Qui trovi i volantini dei negozi di cui hai la tessera. Aggiungi una carta per iniziare.")
                    } actions: {
                        Button("Aggiungi carta") { model.tab = .cards; model.sheet = .add }
                    }
                } else {
                    grid
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Offerte")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if refreshing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Aggiorna volantini")
                    }
                }
            }
        }
        .sheet(item: $open) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .task { await OffersService.refresh(force: false) }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                ForEach(sources) { src in
                    let state = model.data.offers[src.key]
                    Button {
                        Haptics.light()
                        if let url = URL(string: src.pageURL) { open = SafariLink(url: url) }
                        OffersService.markSeen(src.key)
                    } label: {
                        FlyerCover(source: src, state: state, card: model.data.card(src.cardID))
                    }
                    .buttonStyle(CardPressStyle())
                }
            }
            .padding(16)
            Text("I volantini si aprono sul sito del negozio. Il link si cambia da Modifica carta › Altre informazioni.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        refreshing = true
        await OffersService.refresh(force: true)
        refreshing = false
    }
}

struct FlyerCover: View {
    let source: OffersPlanner.Source
    let state: OfferState?
    let card: Card?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(0.75, contentMode: .fit)
                .overlay { fallback }
                .overlay {
                    if let s = state?.coverURL, let url = URL(string: s) {
                        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                .overlay(alignment: .topTrailing) {
                    if state?.isNew == true {
                        Text("NUOVO")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(Theme.onAccent)
                            .background(Theme.accent, in: Capsule())
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.storeName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(state?.title ?? "Volantino e promozioni")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .foregroundStyle(.primary)
        }
    }

    /// Brand color with the logo, used until (or instead of) the real cover.
    private var fallback: some View {
        let base = RGB(hex: source.colorHex) ?? RGB(r: 0.3, g: 0.3, b: 0.3)
        let g = ColorMath.gradient(for: base.hex)
        let fg: Color = base.prefersDarkForeground ? Color(rgb: .ink) : .white
        return ZStack {
            LinearGradient(colors: [Color(hex: g.top), Color(hex: g.bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                if let card, card.hasLogo, let logo = LogoStore.image(for: card.id, version: card.logoVersion) {
                    Image(uiImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 100, maxHeight: 50)
                } else {
                    Text(source.storeName)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 10)
                }
                Label("Volantino", systemImage: "newspaper.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(fg.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(fg)
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
