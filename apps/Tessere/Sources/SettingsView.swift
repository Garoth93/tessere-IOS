import SwiftUI
import UniformTypeIdentifiers
import CoreLocation
import TessereCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncService.self) private var sync
    @Environment(LocationService.self) private var location
    @Environment(AppLock.self) private var lock
    @Environment(CloudBackupService.self) private var cloud
    @State private var showCloudRestore = false
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var importing = false
    @State private var backupDoc: BackupDocument?

    private func binding<T>(_ key: WritableKeyPath<TessereSettings, T>) -> Binding<T> {
        Binding(get: { model.data.settings[keyPath: key] }, set: { v in model.updateSettings { $0[keyPath: key] = v } })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Aspetto") {
                    Picker("Tema", selection: binding(\.appearance)) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Ordina le carte", selection: binding(\.sortMode)) {
                        ForEach(SortMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Toggle("Feedback tattile", isOn: binding(\.haptics))
                }

                Section {
                    Toggle("Luminosità al massimo", isOn: binding(\.maxBrightness))
                    Toggle("Ruota i codici lunghi", isOn: binding(\.autoRotateLongCodes))
                } header: {
                    Text("Codice a schermo intero")
                } footer: {
                    Text("Quando apri una carta lo schermo resta acceso e la luminosità torna com'era alla chiusura.")
                }

                Section {
                    Toggle(isOn: Binding(get: { model.data.settings.faceID }, set: { on in
                        if on {
                            Task {
                                if await lock.verifyForEnabling() { model.updateSettings { $0.faceID = true } }
                            }
                        } else {
                            model.updateSettings { $0.faceID = false }
                        }
                    })) {
                        Label("Blocca con \(lock.biometryName)", systemImage: lock.biometrySymbol)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Chiede \(lock.biometryName) all'apertura e quando torni nell'app.")
                }

                Section {
                    Toggle("Avvisi di scadenza", isOn: binding(\.expiryReminders))
                    if model.data.settings.expiryReminders {
                        Stepper("Primo avviso \(model.data.settings.expiryLeadDays) giorni prima", value: binding(\.expiryLeadDays), in: 0...60)
                        Picker("Ora", selection: binding(\.reminderHour)) {
                            ForEach(6..<23, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                    }
                } header: {
                    Text("Notifiche")
                }
                .onChange(of: model.data.settings.expiryReminders) { _, on in
                    if on { Task { _ = await Notifier.requestAuthorization() } }
                }

                Section {
                    Toggle(isOn: Binding(get: { model.data.settings.locationSuggestions == .enabled }, set: { on in
                        model.updateSettings { $0.locationSuggestions = on ? .enabled : .dismissed }
                        if on { location.activate() } else { location.deactivate() }
                    })) {
                        Label("Suggerimenti in base alla posizione", systemImage: "location.fill")
                    }
                    if model.data.settings.locationSuggestions == .enabled {
                        LabeledContent("Permesso", value: permissionText)
                        if !location.hasAlways {
                            Button("Consenti «Sempre» in Impostazioni") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                } header: {
                    Text("Posizione")
                } footer: {
                    Text("Tessere cerca i negozi delle tue carte vicino a te e ti avvisa quando ci entri. La posizione non lascia l'iPhone.")
                }

                Section {
                    Toggle("Offerte e volantini", isOn: binding(\.offersEnabled))
                }

                Section {
                    NavigationLink {
                        FamilyView(isRoot: false)
                    } label: {
                        LabeledContent {
                            Text(familyStatus)
                        } label: {
                            Label("Famiglia e server", systemImage: "person.2.fill")
                        }
                    }
                } header: {
                    Text("Sincronizzazione e Wallet")
                } footer: {
                    Text("Sincronizza le carte tra i tuoi dispositivi e la famiglia (cifrate end-to-end) e firma i pass di Apple Wallet.")
                }

                Section {
                    Toggle(isOn: binding(\.cloudBackup)) {
                        Label("Backup automatico su iCloud", systemImage: "icloud.fill")
                    }
                    LabeledContent("Ultimo backup") {
                        if cloud.isWorking {
                            ProgressView()
                        } else {
                            Text(cloud.lastBackupAt.map { $0.formatted(.relative(presentation: .named).locale(Locale(identifier: "it_IT"))) } ?? "Mai")
                        }
                    }
                    Button {
                        Task {
                            if await cloud.backup(force: true) { model.show("Backup salvato su iCloud", icon: "icloud.and.arrow.up.fill") }
                        }
                    } label: {
                        Label("Esegui backup ora", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(cloud.isWorking || model.data.cards.isEmpty)
                    Button {
                        showCloudRestore = true
                    } label: {
                        Label("Ripristina da iCloud", systemImage: "icloud.and.arrow.down")
                    }
                    if let e = cloud.lastError {
                        Text(e).font(.footnote).foregroundStyle(Theme.danger)
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Un file al giorno (gli ultimi 30) più l'ultimo, quando le carte cambiano e quando chiudi l'app. Li trovi nell'app File › iCloud Drive › Backup › Tessere.")
                }

                Section {
                    Button {
                        if let data = model.makeBackup() {
                            backupDoc = BackupDocument(data: data)
                            exporting = true
                        }
                    } label: {
                        Label("Esporta backup", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Ripristina da backup", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Backup su file")
                } footer: {
                    Text("File JSON con carte, note e loghi. Il ripristino aggiunge o aggiorna le carte, non cancella le altre.")
                }

                Section("Informazioni") {
                    LabeledContent("Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    LabeledContent("Carte", value: "\(model.data.cards.count)")
                    LabeledContent("Dati condivisi con i widget", value: SharedStore.isShared ? "Sì" : "Non disponibili")
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .fileExporter(isPresented: $exporting, document: backupDoc, contentType: .json,
                          defaultFilename: "tessere-backup-\(ItalianFormat.shortDay(Date()).replacingOccurrences(of: "/", with: "-"))") { result in
                if case .success = result { model.show("Backup esportato") }
            }
            .sheet(isPresented: $showCloudRestore) {
                CloudRestoreView(firstLaunch: false)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { model.restore(from: data) }
            }
        }
    }

    private var permissionText: String {
        switch location.authorization {
        case .authorizedAlways: return "Sempre"
        case .authorizedWhenInUse: return "Mentre usi l'app"
        case .denied, .restricted: return "Negato"
        default: return "Da chiedere"
        }
    }

    private var familyStatus: String {
        let s = model.data.sync
        if s.isInSpace { return s.spaceName ?? "Attiva" }
        if s.isRegistered { return "Server collegato" }
        return "Non attiva"
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
