import SwiftUI
import TessereCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Carte", systemImage: "rectangle.stack.fill", value: AppTab.cards) {
                CardsView()
            }
            Tab("Offerte", systemImage: "tag.fill", value: AppTab.offers) {
                OffersView()
            }
            .badge(model.data.settings.offersEnabled ? OffersPlanner.newCount(model.data) : 0)
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .add:
                AddCardFlow()
            case .edit(let id):
                if let card = model.data.card(id) {
                    NavigationStack { CardFormView(mode: .edit(card)) }
                }
            case .settings:
                SettingsView()
            case .family:
                NavigationStack { FamilyView(isRoot: true) }
            case .cloudRestore:
                CloudRestoreView(firstLaunch: model.data.cards.isEmpty)
            }
        }
        .overlay(alignment: .top) { ToastView() }
        .alert("Attenzione", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let t = model.toast {
            HStack(spacing: 10) {
                Image(systemName: t.icon)
                    .foregroundStyle(t.style == .error ? Theme.danger : Theme.accent)
                Text(t.message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(t.id)
            .onTapGesture { model.toast = nil }
            .animation(.spring(duration: 0.35), value: model.toast)
        }
    }
}
