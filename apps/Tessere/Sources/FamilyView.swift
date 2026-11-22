import SwiftUI
import TessereCore

/// Server (Cloudflare Worker), family sync and Wallet signing status.
struct FamilyView: View {
    let isRoot: Bool

    @Environment(AppModel.self) private var model
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var enrollKey = ""
    @State private var deviceName = SyncService.defaultDeviceName
    @State private var familyName = "Famiglia"
    @State private var busy = false
    @State private var error: String?
    @State private var invite: InviteLink?
    @State private var scanningInvite = false
    @State private var pastedLink = ""
    @State private var joinCandidate: InviteLink?
    @State private var confirmLeave = false
    @State private var confirmDisconnect = false

    private var state: SyncState { model.data.sync }

    var body: some View {
        Form {
            if !state.isRegistered {
                setupSections
            } else if !state.isInSpace {
                serverSection
                createSection
                joinSection
                disconnectSection
            } else {
                familySection
                membersSection
                serverSection
                leaveSection
            }
        }
        .navigationTitle("Famiglia e server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .disabled(busy)
        .overlay {
            if busy {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .task {
            if let pending = model.pendingInvite {
                model.pendingInvite = nil
                joinCandidate = pending
            }
            await sync.checkHealth()
            await sync.loadMembers()
        }
        .onChange(of: model.pendingInvite) { _, new in
            if let new {
                model.pendingInvite = nil
                joinCandidate = new
            }
        }
        .alert("Errore", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog("Unirti alla famiglia?", isPresented: Binding(get: { joinCandidate != nil }, set: { if !$0 { joinCandidate = nil } }), titleVisibility: .visible) {
            Button("Unisciti") {
                if let link = joinCandidate { run { try await sync.join(link, name: deviceName) } }
                joinCandidate = nil
            }
        } message: {
            Text("Server: \(joinCandidate.flatMap { URL(string: $0.server)?.host } ?? "")\nLe tue carte condivise verranno unite a quelle della famiglia.")
        }
        .sheet(item: $invite) { link in
            InviteSheet(link: link)
        }
        .sheet(isPresented: $scanningInvite) {
            NavigationStack {
                ScannerScreen(title: "Invito", hint: "Inquadra il QR dell'invito", showManual: false) { r in
                    scanningInvite = false
                    if let link = InviteLink(string: r.payload) {
                        joinCandidate = link
                    } else {
                        error = "Questo QR non è un invito di Tessere."
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annulla") { scanningInvite = false } }
                }
            }
        }
    }

    // MARK: Not registered

    @ViewBuilder
    private var setupSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text("Carte in famiglia")
                    .font(.title3.weight(.bold))
                Text("Collega Tessere al tuo server (un Worker Cloudflare gratuito, vedi README) per sincronizzare le carte tra i tuoi dispositivi e con la famiglia e per creare i pass di Apple Wallet. Il server vede solo dati cifrati.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        Section {
            Button {
                scanningInvite = true
            } label: {
                Label("Ho un invito: scansiona il QR", systemImage: "qrcode.viewfinder")
            }
            TextField("…oppure incolla il link dell'invito", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(usePastedLink)
            if !pastedLink.isEmpty {
                Button("Usa il link", action: usePastedLink)
            }
        } header: {
            Text("Entra in una famiglia")
        }
        Section {
            TextField("https://tessere.tuonome.workers.dev", text: $server)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Chiave di registrazione (ENROLL_KEY)", text: $enrollKey)
            TextField("Nome di questo iPhone", text: $deviceName)
            Button {
                run { try await sync.register(server: server, enrollKey: enrollKey, name: deviceName) }
            } label: {
                Label("Collega il server", systemImage: "link")
            }
            .disabled(server.isEmpty || enrollKey.isEmpty)
        } header: {
            Text("Oppure crea la famiglia sul tuo server")
        } footer: {
            Text("La chiave di registrazione è il segreto ENROLL_KEY impostato sul Worker: serve solo al primo dispositivo, gli altri entrano con un invito.")
        }
    }

    private func usePastedLink() {
        if let link = InviteLink(string: pastedLink) {
            joinCandidate = link
        } else {
            error = "Il link non è un invito valido di Tessere."
        }
    }

    // MARK: Registered

    private var serverSection: some View {
        Section {
            LabeledContent("Server", value: URL(string: state.serverURL)?.host ?? state.serverURL)
            LabeledContent("Questo dispositivo", value: state.deviceName)
            LabeledContent("Pass Apple Wallet") {
                switch sync.passSigningAvailable {
                case .some(true): Label("Pronti", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                case .some(false): Text("Certificato mancante").foregroundStyle(Theme.warning)
                case .none: Text("—").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            if sync.passSigningAvailable == false {
                Text("Carica sul Worker il certificato Pass Type ID (vedi README, sezione Wallet) per abilitare «Aggiungi a Wallet».")
            }
        }
    }

    private var createSection: some View {
        Section {
            TextField("Nome della famiglia", text: $familyName)
            Button {
                run { try await sync.createFamily(name: familyName.isEmpty ? "Famiglia" : familyName) }
            } label: {
                Label("Crea la famiglia", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Nuova famiglia")
        } footer: {
            Text("Anche da solo: crea la famiglia per avere le carte su più dispositivi.")
        }
    }

    private var joinSection: some View {
        Section("Hai un invito?") {
            Button {
                scanningInvite = true
            } label: {
                Label("Scansiona il QR dell'invito", systemImage: "qrcode.viewfinder")
            }
            TextField("…oppure incolla il link", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(usePastedLink)
        }
    }

    private var disconnectSection: some View {
        Section {
            Button("Scollega il server", role: .destructive) { confirmDisconnect = true }
        }
        .confirmationDialog("Scollegare il server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Scollega", role: .destructive) { run { await sync.disconnect() } }
        } message: {
            Text("Le carte restano su questo iPhone.")
        }
    }

    // MARK: In a family

    private var familySection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 50, height: 50)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.spaceName ?? "Famiglia")
                        .font(.headline)
                    Text(lastSyncText)
                        .font(.caption)
                        .foregroundStyle(state.lastError == nil ? Color.secondary : Theme.danger)
                }
            }
            .padding(.vertical, 4)
            Button {
                Task { await sync.syncNow(manual: true) }
            } label: {
                Label(sync.isSyncing ? "Sincronizzazione…" : "Sincronizza ora", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.isSyncing)
            Button {
                run { invite = try await sync.makeInvite() }
            } label: {
                Label("Invita un familiare o un dispositivo", systemImage: "person.badge.plus")
            }
        } footer: {
            Text("Le carte sono cifrate sul dispositivo con la chiave della famiglia, che viaggia solo dentro l'invito. Le carte segnate «solo su questo iPhone» non vengono condivise.")
        }
    }

    private var lastSyncText: String {
        if let e = state.lastError { return e }
        guard let at = state.lastSyncAt else { return "Mai sincronizzata" }
        return "Ultima sincronizzazione " + at.formatted(.relative(presentation: .named).locale(Locale(identifier: "it_IT")))
    }

    private var membersSection: some View {
        Section("Membri") {
            if sync.members.isEmpty {
                Text("Caricamento…").foregroundStyle(.secondary)
            }
            ForEach(sync.members) { m in
                HStack {
                    Image(systemName: m.isYou == true ? "iphone" : "person.crop.circle")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text(m.name + (m.isYou == true ? " (tu)" : ""))
                        if m.isOwner == true {
                            Text("Ha creato la famiglia").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    if state.isOwner && m.isYou != true {
                        Button("Rimuovi", role: .destructive) {
                            run { try await sync.removeMember(m.deviceId) }
                        }
                    }
                }
            }
        }
    }

    private var leaveSection: some View {
        Section {
            Button("Esci dalla famiglia", role: .destructive) { confirmLeave = true }
        } footer: {
            Text("Le carte restano su questo iPhone; non riceverai più le modifiche della famiglia.")
        }
        .confirmationDialog("Uscire dalla famiglia?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Esci", role: .destructive) { run { await sync.leaveFamily() } }
        }
    }

    // MARK: Helpers

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
                Haptics.success()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }
}

/// QR + link of an invite (valid 48 hours, single use).
struct InviteSheet: View {
    let link: InviteLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text("Inquadra questo QR con Tessere sull'altro iPhone (Impostazioni › Famiglia e server › Ho un invito) oppure invia il link.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let url = link.url {
                    BarcodeView(payload: url.absoluteString, format: .qr)
                        .frame(width: 240, height: 240)
                        .padding(20)
                        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    ShareLink(item: url, message: Text("Entra nella famiglia di Tessere: apri questo link sull'iPhone con l'app installata.")) {
                        Label("Invia il link", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(Theme.onAccent)
                            .background(Theme.accent, in: Capsule())
                    }
                    .padding(.horizontal, 24)
                }
                Text("Valido 48 ore, una sola volta. Il link contiene la chiave della famiglia: invialo solo a chi deve entrare.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Invito")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
        }
    }
}
