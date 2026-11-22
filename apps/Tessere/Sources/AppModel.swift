import SwiftUI
import WidgetKit
import TessereCore

struct Toast: Identifiable, Equatable {
    enum Style { case success, info, error }
    let id = UUID()
    let message: String
    let icon: String
    let style: Style
}

enum AppTab: Hashable {
    case cards, offers
}

enum AppSheet: Identifiable, Equatable {
    case add
    case edit(UUID)
    case settings
    case family

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let id): return "edit-\(id.uuidString)"
        case .settings: return "settings"
        case .family: return "family"
        }
    }
}

/// What to do with the logo when a card is saved.
enum LogoChange: Equatable {
    case keep
    case set(Data)
    case remove
}

/// Writes the data file off the main thread; older revisions never overwrite newer ones.
/// The previous file is kept as `.bak` so a bad write can always be recovered.
actor DataWriter {
    private let store: JSONFileStore<TessereData>
    private var lastRevision = -1

    init(url: URL) {
        store = JSONFileStore(url: url, compact: true)
    }

    func save(_ data: TessereData, revision: Int) throws {
        guard revision > lastRevision else { return }
        try store.save(data, keepBackup: true)
        lastRevision = revision
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var data = TessereData()
    private(set) var isLoaded = false
    var toast: Toast?
    var errorMessage: String?
    var tab: AppTab = .cards
    var sheet: AppSheet?
    /// Card shown expanded (tap on the grid, widget, notification, nearby).
    var presentedCardID: UUID?
    /// Invite opened from a link/QR, handled by the family screen.
    var pendingInvite: InviteLink?
    /// Bumped when a card logo changes, to refresh images.
    private(set) var logoRevision = 0

    private let writer: DataWriter
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var derivedTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var deferredOpen: UUID?

    static var dataURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("tessere-data.json")
    }

    private init() {
        writer = DataWriter(url: Self.dataURL)
        Task { await load() }
    }

    // MARK: Loading and saving

    private func load() async {
        let url = Self.dataURL
        let result = await Task.detached(priority: .userInitiated) { () -> (TessereData?, Bool) in
            let store = JSONFileStore<TessereData>(url: url)
            do {
                return (try store.load(), false)
            } catch {
                // Main file unreadable: keep it aside, fall back to the previous copy.
                let stamp = Int(Date().timeIntervalSince1970)
                let aside = url.deletingLastPathComponent().appendingPathComponent("tessere-data-illeggibile-\(stamp).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                return ((try? store.loadBackup()) ?? nil, true)
            }
        }.value
        if result.1 {
            errorMessage = result.0 == nil
                ? "Il file dei dati non era leggibile ed è stato messo da parte. Puoi ripristinare un backup dalle Impostazioni."
                : "Il file dei dati non era leggibile: è stata ripristinata la copia precedente."
        }
        var loaded = result.0 ?? TessereData()
        loaded.pruneTombstones(now: Date())
        data = loaded
        Haptics.enabled = data.settings.haptics
        isLoaded = true
        AppLock.shared.configure(enabled: data.settings.faceID)
        refreshDerived()
        let ids = Set(data.cards.map(\.id))
        Task.detached(priority: .background) { LogoStore.removeOrphans(keeping: ids) }
        if let id = deferredOpen {
            deferredOpen = nil
            open(cardID: id)
        }
        didBecomeActive()
    }

    /// Saves after a short pause (many quick edits → one write).
    private func scheduleSave() {
        revision += 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.writeNow()
        }
    }

    /// Saves immediately (used when the app goes to background).
    func saveNow() {
        guard isLoaded else { return }
        revision += 1
        saveTask?.cancel()
        saveTask = nil
        BackgroundWork.run("tessere-save") { [weak self] in
            await self?.writeNow()
        }
    }

    private func writeNow() async {
        let snapshot = data
        let rev = revision
        do {
            try await writer.save(snapshot, revision: rev)
        } catch {
            errorMessage = "Salvataggio non riuscito: \(error.localizedDescription)"
        }
    }

    // MARK: Derived state (widgets, reminders, regions, sync)

    private func refreshDerived(syncSoon: Bool = false) {
        derivedTask?.cancel()
        derivedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            let snap = WidgetSnapshot(data: self.data, now: Date())
            if SharedStore.saveSnapshot(snap) {
                WidgetCenter.shared.reloadAllTimelines()
            }
            LocationService.shared.cardsChanged(self.data.cards)
            await Notifier.rescheduleExpiry(ExpiryPlanner.reminders(for: self.data, now: Date()))
        }
        if syncSoon { SyncService.shared.scheduleSync() }
    }

    func didBecomeActive() {
        guard isLoaded else { return }
        SyncService.shared.scheduleSync(delay: .milliseconds(300))
        if data.settings.offersEnabled {
            Task { await OffersService.refresh(force: false) }
        }
        LocationService.shared.refreshIfNeeded()
    }

    // MARK: Mutations

    /// Any change to the data: saved and propagated (sync included).
    func update(_ change: (inout TessereData) -> Void) {
        var copy = data
        change(&copy)
        guard copy != data else { return }
        let needsSync = copy.pendingSync != data.pendingSync || copy.cards.map(\.updatedAt) != data.cards.map(\.updatedAt)
        data = copy
        Haptics.enabled = data.settings.haptics
        scheduleSave()
        refreshDerived(syncSoon: needsSync)
    }

    /// Device-local change (usage, offers, sync cursor): saved, not synced.
    func updateLocal(_ change: (inout TessereData) -> Void) {
        var copy = data
        change(&copy)
        guard copy != data else { return }
        data = copy
        scheduleSave()
    }

    func updateSettings(_ change: (inout TessereSettings) -> Void) {
        updateLocal { change(&$0.settings) }
        Haptics.enabled = data.settings.haptics
        AppLock.shared.configure(enabled: data.settings.faceID)
        refreshDerived()
    }

    func saveCard(_ card: Card, logo: LogoChange) {
        var c = card
        switch logo {
        case .keep:
            break
        case .set(let png):
            LogoStore.save(png, for: c.id)
            c.hasLogo = true
            c.logoVersion += 1
            logoRevision += 1
        case .remove:
            LogoStore.remove(c.id)
            c.hasLogo = false
            c.logoVersion += 1
            logoRevision += 1
        }
        let isNew = data.card(c.id) == nil
        update { $0.upsert(c) }
        if isNew {
            show("\(c.kind.title) aggiunta", icon: "checkmark.circle.fill")
            LocationService.shared.cardAdded(c)
        }
    }

    func editCard(_ id: UUID, _ change: (inout Card) -> Void) {
        update { $0.edit(id, change) }
    }

    /// Shop locations found nearby (device-local).
    func setStoreLocations(_ id: UUID, _ points: [GeoPoint]) {
        updateLocal { d in
            d.editLocal(id) {
                $0.storeLocations = points
                $0.locationsUpdatedAt = Date()
            }
        }
    }

    func deleteCard(_ id: UUID) {
        if presentedCardID == id { presentedCardID = nil }
        let name = data.card(id)?.storeName ?? ""
        update { $0.delete(id) }
        LogoStore.remove(id)
        show("\(name) eliminata", icon: "trash.fill", style: .info)
    }

    func recordUse(_ id: UUID) {
        updateLocal { $0.recordUse(id) }
        refreshDerived()
    }

    func markWalletAdded(_ id: UUID) {
        updateLocal { $0.walletAdded[id.uuidString] = Date() }
    }

    /// Applies a sync outcome coming from the server.
    func applySync(_ change: (inout TessereData) -> SyncEngine.Outcome) -> SyncEngine.Outcome {
        var copy = data
        let outcome = change(&copy)
        for (id, png) in outcome.logoWrites {
            if let png { LogoStore.save(png, for: id) } else { LogoStore.remove(id) }
        }
        if !outcome.logoWrites.isEmpty { logoRevision += 1 }
        if copy != data {
            data = copy
            scheduleSave()
            refreshDerived()
        }
        return outcome
    }

    // MARK: Navigation

    func open(cardID: UUID) {
        guard isLoaded else { deferredOpen = cardID; return }
        guard data.card(cardID) != nil else { return }
        tab = .cards
        if sheet != nil {
            sheet = nil
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.presentedCardID = cardID
            }
        } else {
            presentedCardID = cardID
        }
    }

    private func present(_ s: AppSheet) {
        if presentedCardID != nil { presentSheetAfterClosingCard(s) } else { sheet = s }
    }

    /// Closes the expanded card, then opens a sheet (two presentations at once would clash).
    func presentSheetAfterClosingCard(_ s: AppSheet) {
        presentedCardID = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.sheet = s
        }
    }

    func handle(url: URL) {
        guard url.scheme == "tessere" else { return }
        switch url.host {
        case "card":
            if let id = UUID(uuidString: url.lastPathComponent) { open(cardID: id) }
        case "add":
            tab = .cards
            present(.add)
        case "join":
            if let invite = InviteLink(url: url) {
                pendingInvite = invite
                present(.family)
            } else {
                show("Invito non valido", icon: "exclamationmark.triangle.fill", style: .error)
            }
        case "offers":
            presentedCardID = nil
            tab = .offers
        default:
            tab = .cards
        }
    }

    func show(_ message: String, icon: String = "checkmark.circle.fill", style: Toast.Style = .success) {
        toast = Toast(message: message, icon: icon, style: style)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Backup

    func makeBackup() -> Data? {
        var logos: [UUID: Data] = [:]
        for c in data.cards where c.hasLogo {
            if let d = LogoStore.data(for: c.id) { logos[c.id] = d }
        }
        return try? BackupFile(data: data, logos: logos, now: Date()).encoded()
    }

    func restore(from raw: Data) {
        do {
            let backup = try BackupFile.decode(raw)
            for (id, png) in backup.logoData { LogoStore.save(png, for: id) }
            var count = 0
            update { d in count = backup.merge(into: &d, now: Date()) }
            logoRevision += 1
            show("Backup ripristinato: \(ItalianFormat.plural(count, "carta", "carte"))")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
