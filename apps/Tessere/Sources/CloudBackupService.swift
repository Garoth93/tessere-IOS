import Foundation
import SwiftUI
import BackgroundTasks
import TessereCore

/// Automatic backups in iCloud Drive, in the shared container
/// `iCloud.com.garoth93.backup` › Documents › Tessere (visible in the Files
/// app as iCloud Drive › Backup › Tessere). One file per day plus "latest";
/// written when the data change, when the app goes to background and from a
/// background refresh task. Restore from Settings, or guided at first launch
/// when the app is empty.
@MainActor
@Observable
final class CloudBackupService {
    static let shared = CloudBackupService()

    /// nil = not checked yet; false = iCloud off / not signed in / no entitlement.
    private(set) var available: Bool?
    private(set) var isWorking = false
    private(set) var lastBackupAt: Date? = UserDefaults.standard.object(forKey: Keys.lastAt) as? Date
    private(set) var lastError: String?
    private(set) var entries: [CloudBackupPlan.Entry] = []

    @ObservationIgnored private var scheduled: Task<Void, Never>?

    private enum Keys {
        static let fingerprint = "cloudBackup.fingerprint"
        static let lastAt = "cloudBackup.lastAt"
        static let restoreOffered = "cloudBackup.restoreOffered"
    }

    static let refreshTaskID = "com.garoth93.tessere.refresh"

    private var model: AppModel { AppModel.shared }

    // MARK: Folder

    /// Resolving the ubiquity container can block: always off the main thread.
    nonisolated static func folderURL() async -> URL? {
        await Task.detached(priority: .utility) { () -> URL? in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: CloudBackupPlan.containerID) else { return nil }
            let folder = container.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(CloudBackupPlan.folderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }.value
    }

    // MARK: Backup

    /// After a change: back up a few seconds later (many edits → one write).
    func schedule() {
        guard model.data.settings.cloudBackup else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.backup(force: false)
        }
    }

    /// Writes the backup if the content changed since the last one (or `force`).
    /// An empty app never overwrites existing backups.
    @discardableResult
    func backup(force: Bool) async -> Bool {
        guard model.isLoaded, force || model.data.settings.cloudBackup, !model.data.cards.isEmpty else { return false }
        guard let file = model.makeBackupFile() else { return false }
        let fp = CloudBackupPlan.fingerprint(file)
        if !force, fp == UserDefaults.standard.string(forKey: Keys.fingerprint) { return false }
        guard let data = try? file.encoded() else { return false }
        isWorking = true
        defer { isWorking = false }
        guard let folder = await Self.folderURL() else {
            available = false
            if force { lastError = "iCloud Drive non disponibile: controlla di aver fatto l'accesso a iCloud e che iCloud Drive sia attivo per Tessere." }
            return false
        }
        available = true
        let now = Date()
        let result = await Task.detached(priority: .utility) { () -> String? in
            do {
                try Self.coordinatedWrite(data, to: folder.appendingPathComponent(CloudBackupPlan.dailyName(for: now)))
                try Self.coordinatedWrite(data, to: folder.appendingPathComponent(CloudBackupPlan.latestName))
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for name in CloudBackupPlan.namesToPrune(names) {
                    Self.coordinatedDelete(folder.appendingPathComponent(name))
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let result {
            lastError = "Backup su iCloud non riuscito: \(result)"
            return false
        }
        lastError = nil
        lastBackupAt = now
        UserDefaults.standard.set(now, forKey: Keys.lastAt)
        UserDefaults.standard.set(fp, forKey: Keys.fingerprint)
        return true
    }

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    nonisolated private static func coordinatedDelete(_ url: URL) {
        var err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &err) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }

    // MARK: Restore

    /// Backups in the iCloud folder, newest first.
    func refreshEntries() async {
        guard let folder = await Self.folderURL() else {
            available = false
            entries = []
            return
        }
        available = true
        let names = await Task.detached(priority: .userInitiated) {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }.value
        entries = CloudBackupPlan.entries(fromFileNames: names)
    }

    /// Downloads (if needed) and decodes a backup.
    func load(_ entry: CloudBackupPlan.Entry) async throws -> BackupFile {
        guard let folder = await Self.folderURL() else { throw BackupError.unreadable }
        let url = folder.appendingPathComponent(entry.name)
        let data = try await Task.detached(priority: .userInitiated) { () async throws -> Data in
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            // The coordinated read waits for the download of the iCloud file.
            for _ in 0..<60 {
                var coordError: NSError?
                var out: Data?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { target in
                    out = try? Data(contentsOf: target)
                }
                if let out { return out }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw BackupError.unreadable
        }.value
        return try BackupFile.decode(data)
    }

    func restore(_ entry: CloudBackupPlan.Entry) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let file = try await load(entry)
            model.restore(file)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: First launch

    /// Empty app + backups in iCloud → guided restore (asked once).
    func offerRestoreIfNeeded() async {
        guard model.data.cards.isEmpty, !UserDefaults.standard.bool(forKey: Keys.restoreOffered) else { return }
        await refreshEntries()
        guard !entries.isEmpty, model.data.cards.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Keys.restoreOffered)
        if model.sheet == nil { model.sheet = .cloudRestore }
    }

    // MARK: Background refresh

    /// Called once in didFinishLaunching.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            let work = Task { @MainActor in
                await SyncService.shared.syncNow(manual: false)
                await CloudBackupService.shared.backup(force: false)
                CloudBackupService.scheduleBackgroundRefresh()
            }
            task.expirationHandler = { work.cancel() }
            Task {
                await work.value
                task.setTaskCompleted(success: true)
            }
        }
    }

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Guided restore at first launch / from Settings: list of iCloud backups.
struct CloudRestoreView: View {
    let firstLaunch: Bool
    @Environment(CloudBackupService.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var choice: CloudBackupPlan.Entry?
    @State private var preview: BackupFile?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if firstLaunch {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "icloud.and.arrow.down.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(Theme.accent)
                            Text("Bentornato!")
                                .font(.title2.weight(.bold))
                            Text("In iCloud Drive c'è un backup di Tessere. Vuoi ripristinare le tue carte?")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                Section {
                    if cloud.entries.isEmpty {
                        Text(cloud.available == false ? "iCloud Drive non disponibile." : "Nessun backup trovato.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cloud.entries) { entry in
                        Button {
                            choice = entry
                            Task { await loadPreview(entry) }
                        } label: {
                            HStack {
                                Image(systemName: entry.isLatest ? "clock.arrow.circlepath" : "doc.text")
                                    .foregroundStyle(Theme.accent)
                                Text(title(entry))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if choice == entry {
                                    if loading { ProgressView() } else { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Backup in iCloud Drive › Backup › Tessere")
                } footer: {
                    Text("Il ripristino aggiunge le carte del backup e aggiorna quelle con lo stesso identificativo; non cancella le altre.")
                }
                if let preview, let choice {
                    Section {
                        LabeledContent("Carte", value: "\(preview.cards.count)")
                        LabeledContent("Salvato il", value: preview.exportedAt.formatted(date: .abbreviated, time: .shortened))
                        Button {
                            Task {
                                await cloud.restore(choice)
                                if cloud.lastError == nil { dismiss() }
                            }
                        } label: {
                            Label("Ripristina \(ItalianFormat.plural(preview.cards.count, "carta", "carte"))", systemImage: "arrow.counterclockwise")
                                .font(.headline)
                        }
                        .disabled(cloud.isWorking)
                    }
                }
                if let e = cloud.lastError {
                    Section { Text(e).foregroundStyle(Theme.danger) }
                }
            }
            .navigationTitle("Ripristina da iCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(firstLaunch ? "Inizia da zero" : "Chiudi") { dismiss() }
                }
            }
            .task {
                await cloud.refreshEntries()
                if let first = cloud.entries.first, choice == nil {
                    choice = first
                    await loadPreview(first)
                }
            }
        }
    }

    private func title(_ e: CloudBackupPlan.Entry) -> String {
        if let d = e.day { return d.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT"))) }
        return "Ultimo backup"
    }

    private func loadPreview(_ entry: CloudBackupPlan.Entry) async {
        loading = true
        preview = try? await cloud.load(entry)
        loading = false
    }
}
