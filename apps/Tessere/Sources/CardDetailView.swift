import SwiftUI
import PassKit
import TessereCore

/// Expanded card: colored card on top, white panel with the code,
/// brightness at maximum and screen always on while open.
/// Tapping the panel shows the code alone at full screen (rotated for long codes).
struct CardDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let cardID: UUID

    @State private var focus = false
    @State private var rotated = false
    @State private var panelIn = false
    @State private var confirmDelete = false
    @State private var wallet = WalletFlow()
    @Namespace private var codeNS

    var body: some View {
        Group {
            if let card = model.data.card(cardID) {
                content(card)
            } else {
                Color.black.onAppear { dismiss() }
            }
        }
        .onAppear {
            ScreenBoost.begin(maxBrightness: model.data.settings.maxBrightness)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.08)) { panelIn = true }
        }
        .onDisappear { ScreenBoost.end() }
    }

    @ViewBuilder
    private func content(_ card: Card) -> some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if focus {
                FocusedCode(card: card, rotated: $rotated, ns: codeNS) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { focus = false }
                }
                .zIndex(2)
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        header(card)
                        CardFace(card: card, size: .large)
                            .shadow(color: Color(hex: card.resolvedColorHex).opacity(0.35), radius: 24, y: 12)
                            .onTapGesture { dismiss() }
                        codePanel(card)
                            .offset(y: panelIn ? 0 : 80)
                            .opacity(panelIn ? 1 : 0)
                        details(card)
                            .opacity(panelIn ? 1 : 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .sheet(item: $wallet.pass) { item in
            AddPassSheet(pass: item.pass) { added in
                wallet.pass = nil
                if added {
                    model.markWalletAdded(card.id)
                    model.show("Aggiunta a Wallet", icon: "wallet.pass.fill")
                }
            }
            .ignoresSafeArea()
        }
        .alert("Wallet", isPresented: Binding(get: { wallet.error != nil }, set: { if !$0 { wallet.error = nil } })) {
            if wallet.needsSetup {
                Button("Configura") {
                    model.presentSheetAfterClosingCard(.family)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(wallet.error ?? "")
        }
        .confirmationDialog("Eliminare \(card.storeName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                dismiss()
                model.deleteCard(card.id)
            }
        }
    }

    // MARK: Parts

    private func header(_ card: Card) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Chiudi")
            Spacer()
            VStack(spacing: 1) {
                Text(card.storeName)
                    .font(.headline)
                    .lineLimit(1)
                Text(card.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    model.presentSheetAfterClosingCard(.edit(card.id))
                } label: {
                    Label("Modifica", systemImage: "pencil")
                }
                Button {
                    copy(card)
                } label: {
                    Label("Copia numero", systemImage: "doc.on.doc")
                }
                ShareLink(item: "\(card.storeName): \(card.shownNumber)") {
                    Label("Condividi numero", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Elimina", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Altre azioni")
        }
        .padding(.top, 6)
    }

    private func codePanel(_ card: Card) -> some View {
        VStack(spacing: 14) {
            BarcodeView(payload: card.number, format: card.format)
                .frame(maxWidth: card.format.isSquare ? 230 : .infinity)
                .frame(height: card.format.isSquare ? 230 : (card.format == .pdf417 ? 110 : 120))
                .matchedGeometryEffect(id: "code", in: codeNS)
            numberText(card, size: 20)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .matchedGeometryEffect(id: "panel", in: codeNS)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {
            Haptics.soft()
            rotated = model.data.settings.autoRotateLongCodes && CodeLayout.isLong(card)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { focus = true }
        }
        .accessibilityAction(named: "Mostra a schermo intero") { focus = true }
        .environment(\.colorScheme, .light)
    }

    private func numberText(_ card: Card, size: CGFloat) -> some View {
        Text(ItalianFormat.groupedNumber(card.shownNumber, format: card.format))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.black)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
            .textSelection(.disabled)
            .onLongPressGesture(minimumDuration: 0.4) { copy(card) }
            .accessibilityHint("Tocca e tieni premuto per copiare")
    }

    private func copy(_ card: Card) {
        UIPasteboard.general.string = card.shownNumber
        Haptics.success()
        model.show("Numero copiato", icon: "doc.on.doc.fill")
    }

    @ViewBuilder
    private func details(_ card: Card) -> some View {
        VStack(spacing: 12) {
            if card.format.walletFormat != nil {
                WalletButton {
                    Task { await wallet.start(card: card) }
                }
                .frame(height: 48)
                .overlay {
                    if wallet.working {
                        ZStack {
                            Capsule().fill(.black.opacity(0.6))
                            ProgressView().tint(.white)
                        }
                    }
                }
                .disabled(wallet.working)
                if let added = model.data.walletAdded[card.id.uuidString] {
                    Text("Aggiunta a Wallet il \(ItalianFormat.shortDay(added))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                infoRow("Tipo", card.kind.title, symbol: card.kind.symbol)
                if let d = card.daysToExpiry(now: Date()), let e = card.expiry {
                    Divider().padding(.leading, 44)
                    infoRow("Scadenza", "\(ItalianFormat.day(e)) · \(ItalianFormat.expiryText(days: d))",
                            symbol: "calendar", tint: d <= 7 ? Theme.danger : nil)
                }
                if !card.trimmedNote.isEmpty {
                    Divider().padding(.leading, 44)
                    infoRow("Nota", card.trimmedNote, symbol: "note.text")
                }
                if let holder = card.cardholder, !holder.isEmpty {
                    Divider().padding(.leading, 44)
                    infoRow("Titolare", holder, symbol: "person")
                }
                Divider().padding(.leading, 44)
                infoRow("Formato", card.format.title, symbol: "barcode")
                if model.data.sync.isInSpace {
                    Divider().padding(.leading, 44)
                    infoRow("Famiglia", card.shared ? "Condivisa" : "Solo su questo iPhone",
                            symbol: card.shared ? "person.2.fill" : "lock.fill")
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                model.presentSheetAfterClosingCard(.edit(card.id))
            } label: {
                Label("Modifica carta", systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.surface, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func infoRow(_ title: String, _ value: String, symbol: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? Theme.accent)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint ?? .primary)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The code alone on white, as large as possible with margins; long codes
/// are rotated to landscape.
struct FocusedCode: View {
    @Environment(AppModel.self) private var model
    let card: Card
    @Binding var rotated: Bool
    let ns: Namespace.ID
    let close: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Color.white
                    .matchedGeometryEffect(id: "panel", in: ns)
                    .ignoresSafeArea()
                codeStack(width: rotated ? h : w, height: rotated ? w : h)
                    .frame(width: rotated ? h : w, height: rotated ? w : h)
                    .rotationEffect(.degrees(rotated ? 90 : 0))
                    .position(x: w / 2, y: h / 2)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 12) {
                    if card.format.isLinear || card.format == .pdf417 {
                        Button {
                            Haptics.selection()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { rotated.toggle() }
                        } label: {
                            Image(systemName: "rotate.right")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                        }
                        .glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("Ruota")
                    }
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Chiudi")
                }
                .foregroundStyle(.black)
                .padding(.trailing, 18)
            }
        }
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
    }

    private func codeStack(width: CGFloat, height: CGFloat) -> some View {
        let margin: CGFloat = 28
        let maxW = width - margin * 2
        let codeH: CGFloat
        let codeW: CGFloat
        if card.format.isSquare {
            codeW = min(maxW, height * 0.62)
            codeH = codeW
        } else if card.format == .none {
            codeW = maxW
            codeH = height * 0.3
        } else {
            codeW = maxW
            codeH = min(height * 0.55, maxW * CodeLayout.aspect(card.format) * (rotated ? 1.2 : 1))
        }
        return VStack(spacing: 18) {
            Text(card.storeName)
                .font(.headline)
                .foregroundStyle(.black.opacity(0.55))
            BarcodeView(payload: card.number, format: card.format)
                .frame(width: codeW, height: codeH)
                .matchedGeometryEffect(id: "code", in: ns)
            Text(ItalianFormat.groupedNumber(card.shownNumber, format: card.format))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .onLongPressGesture(minimumDuration: 0.4) {
                    UIPasteboard.general.string = card.shownNumber
                    Haptics.success()
                    model.show("Numero copiato", icon: "doc.on.doc.fill")
                }
        }
        .padding(margin)
    }
}
