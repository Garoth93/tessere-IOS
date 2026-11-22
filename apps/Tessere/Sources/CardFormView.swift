import SwiftUI
import UIKit
import PhotosUI
import TessereCore

/// Add flow: scanner first, then the form (or straight to the form "a mano").
struct AddCardFlow: View {
    enum Step: Hashable {
        case scanned(BarcodeFormat, String)
        case manual
    }

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScannerScreen(title: "Aggiungi carta", hint: "Inquadra il codice a barre o QR") { r in
                if path.isEmpty { path.append(.scanned(r.format, r.payload)) }
            } onManual: {
                path.append(.manual)
            }
            .navigationTitle("Aggiungi carta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .scanned(let f, let p):
                    CardFormView(mode: .new(ScanResult(format: f, payload: p))) { dismiss() }
                case .manual:
                    CardFormView(mode: .new(nil)) { dismiss() }
                }
            }
        }
    }
}

struct CardFormView: View {
    enum Mode {
        case new(ScanResult?)
        case edit(Card)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var onDone: (() -> Void)? = nil

    @State private var draft: Card
    @State private var logoChange: LogoChange = .keep
    @State private var previewLogo: UIImage?
    @State private var searchingLogo = false
    @State private var userPickedLogo = false
    @State private var hasExpiry: Bool
    @State private var expiryDate: Date
    @State private var customColor: Bool
    @State private var color: Color
    @State private var lookupTask: Task<Void, Never>?
    @State private var rescanning = false
    @State private var confirmDelete = false
    @State private var readingPhoto = false
    @State private var logoItem: PhotosPickerItem?
    @State private var showAdvanced = false
    /// Manual entry: the format follows what is typed until the user picks one.
    @State private var autoFormat = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case name, number, note, domain }

    init(mode: Mode, onDone: (() -> Void)? = nil) {
        self.mode = mode
        self.onDone = onDone
        let card: Card
        switch mode {
        case .new(let scan):
            card = Card(storeName: "", number: scan?.payload ?? "", format: scan?.format ?? .code128)
        case .edit(let c):
            card = c
        }
        _draft = State(initialValue: card)
        _hasExpiry = State(initialValue: card.expiry != nil)
        _expiryDate = State(initialValue: card.expiry ?? Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
        _customColor = State(initialValue: card.colorHex != nil)
        if case .new(let scan) = mode, scan == nil { _autoFormat = State(initialValue: true) }
        _color = State(initialValue: Color(hex: card.colorHex ?? card.resolvedColorHex))
        if case .edit(let c) = mode, c.hasLogo {
            _previewLogo = State(initialValue: LogoStore.image(for: c.id, version: c.logoVersion))
        }
    }

    private var isNew: Bool { if case .new = mode { return true } else { return false } }

    private var trimmedName: String { draft.storeName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanNumber: String {
        let t = draft.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = [.ean13, .ean8, .upcA, .upcE, .itf].contains(draft.format)
        return digitsOnly ? t.replacingOccurrences(of: " ", with: "") : t
    }
    private var numberValid: Bool { !cleanNumber.isEmpty && draft.format.accepts(cleanNumber) }
    private var canSave: Bool { !trimmedName.isEmpty && numberValid }

    private var previewColorHex: String {
        customColor ? color.hexString : (draft.autoColorHex ?? ColorMath.generatedHex(for: trimmedName.isEmpty ? "Tessere" : trimmedName))
    }

    var body: some View {
        Form {
            Section {
                CardFace(name: trimmedName.isEmpty ? "Nuova carta" : trimmedName,
                         colorHex: previewColorHex, style: draft.logoStyle, initials: ColorMath.initials(of: trimmedName),
                         logo: previewLogo, note: draft.note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : draft.note,
                         size: .large)
                    .overlay(alignment: .bottomTrailing) {
                        if searchingLogo {
                            ProgressView()
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(12)
                        }
                    }
                    .animation(.smooth, value: previewColorHex)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField("Nome del negozio", text: $draft.storeName)
                    .font(.headline)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = draft.number.isEmpty ? .number : nil }
                ForEach(suggestions) { entry in
                    Button {
                        draft.storeName = entry.name
                        focus = nil
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: entry.colorHex ?? ColorMath.generatedHex(for: entry.name)))
                                .frame(width: 14, height: 14)
                            Text(entry.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(entry.category.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Negozio")
            } footer: {
                if let e = draft.catalogEntry {
                    Text("Riconosciuto: \(e.name). Logo e colore arrivano in automatico.")
                } else if !trimmedName.isEmpty {
                    Text("Logo cercato sul sito del negozio. Se non lo trova, la carta usa il nome su un colore generato.")
                }
            }

            Section {
                HStack {
                    TextField("Numero della carta", text: $draft.number)
                        .font(.body.monospacedDigit())
                        .keyboardType(draft.format.isTwoDimensional || draft.format == .code128 || draft.format == .code39 ? .asciiCapable : .numberPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focus, equals: .number)
                    Button {
                        rescanning = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Scansiona")
                }
                Picker("Formato", selection: Binding(get: { draft.format }, set: { draft.format = $0; autoFormat = false })) {
                    ForEach(BarcodeFormat.editable, id: \.self) { f in
                        Text(f.title).tag(f)
                    }
                }
                if !cleanNumber.isEmpty && draft.format != .none {
                    BarcodeView(payload: cleanNumber, format: draft.format)
                        .frame(height: draft.format.isSquare ? 120 : 64)
                        .frame(maxWidth: draft.format.isSquare ? 120 : .infinity)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            } header: {
                Text("Codice")
            } footer: {
                if !cleanNumber.isEmpty && !numberValid {
                    Text("Il numero non è valido per \(draft.format.title). Prova «Code 128» o controlla le cifre.")
                        .foregroundStyle(Theme.danger)
                } else if draft.format == .ean13 || draft.format == .upcA || draft.format == .upcE || draft.format == .ean8 {
                    Text("In Apple Wallet questo codice viene mostrato come Code 128 con lo stesso numero.")
                }
            }

            Section("Tipo") {
                Picker("Tipo", selection: $draft.kind) {
                    ForEach(CardKind.allCases, id: \.self) { k in
                        Text(k.title).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                TextField("Nota (facoltativa)", text: $draft.note, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focus, equals: .note)
                Toggle("Scadenza", isOn: $hasExpiry.animation())
                if hasExpiry {
                    DatePicker("Scade il", selection: $expiryDate, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "it_IT"))
                }
            } footer: {
                Text("Se scrivi una nota appare come etichetta sulla carta. Con la scadenza ricevi un avviso \(model.data.settings.expiryLeadDays) giorni prima e il giorno stesso.")
            }

            Section {
                Picker("Mostra", selection: $draft.logoStyle) {
                    ForEach(LogoStyle.allCases, id: \.self) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Colore personalizzato", isOn: $customColor.animation())
                if customColor {
                    ColorPicker("Colore della carta", selection: $color, supportsOpacity: false)
                }
                PhotosPicker(selection: $logoItem, matching: .images) {
                    Label("Logo da una foto", systemImage: "photo")
                }
                Button {
                    userPickedLogo = false
                    scheduleLookup(delay: 0)
                } label: {
                    Label("Cerca di nuovo logo e colore", systemImage: "wand.and.stars")
                }
                .disabled(trimmedName.isEmpty || searchingLogo)
                if previewLogo != nil {
                    Button(role: .destructive) {
                        previewLogo = nil
                        logoChange = .remove
                        userPickedLogo = true
                    } label: {
                        Label("Togli il logo", systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text("Aspetto")
            }

            Section {
                DisclosureGroup("Altre informazioni", isExpanded: $showAdvanced) {
                    TextField("Sito web (per il logo)", text: Binding(get: { draft.domain ?? "" }, set: { draft.domain = $0.isEmpty ? nil : $0 }))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .domain)
                        .onSubmit { userPickedLogo = false; scheduleLookup(delay: 0) }
                    TextField("Titolare (per Wallet)", text: Binding(get: { draft.cardholder ?? "" }, set: { draft.cardholder = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.words)
                    TextField("Numero stampato, se diverso", text: Binding(get: { draft.displayNumber ?? "" }, set: { draft.displayNumber = $0.isEmpty ? nil : $0 }))
                        .autocorrectionDisabled()
                    TextField("Link al volantino", text: Binding(get: { draft.flyerURL ?? "" }, set: { draft.flyerURL = $0.isEmpty ? nil : $0 }),
                              prompt: Text(draft.catalogEntry?.flyerURL ?? "https://…"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if model.data.sync.isInSpace {
                    Toggle(isOn: $draft.shared) {
                        Label("Condividi con la famiglia", systemImage: "person.2.fill")
                    }
                }
            } footer: {
                if model.data.sync.isInSpace && !draft.shared {
                    Text("Resta solo su questo iPhone e viene tolta dagli altri dispositivi della famiglia.")
                }
            }

            if !isNew {
                Section {
                    Button("Elimina carta", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isNew ? "Nuova carta" : "Modifica")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Salva", action: save)
                    .fontWeight(.bold)
                    .disabled(!canSave)
            }
        }
        .onAppear {
            if isNew { focus = .name }
        }
        .onChange(of: draft.storeName) { _, _ in
            if !userPickedLogo { scheduleLookup(delay: 0.7) }
        }
        .onChange(of: draft.number) { _, new in
            if autoFormat { draft.format = BarcodeFormat.suggest(for: new.replacingOccurrences(of: " ", with: "")) }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                   let found = LogoService.fromImage(image) {
                    applyFound(found, manual: true)
                } else {
                    model.show("Non riesco a ricavare un logo da questa immagine", icon: "photo", style: .error)
                }
                logoItem = nil
            }
        }
        .sheet(isPresented: $rescanning) {
            NavigationStack {
                ScannerScreen(title: "Scansiona", hint: "Inquadra il codice", showManual: false) { r in
                    autoFormat = false
                    draft.number = r.payload
                    draft.format = r.format
                    rescanning = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annulla") { rescanning = false } }
                }
            }
        }
        .confirmationDialog("Eliminare la carta?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                model.deleteCard(draft.id)
                close()
            }
        }
    }

    private var suggestions: [StoreCatalog.Entry] {
        guard focus == .name else { return [] }
        let q = trimmedName
        guard q.count >= 2 else { return [] }
        let list = StoreCatalog.suggestions(for: q, limit: 5)
        if list.count == 1, list[0].name.caseInsensitiveCompare(q) == .orderedSame { return [] }
        return list
    }

    // MARK: Logo + color lookup

    private func scheduleLookup(delay: Double) {
        lookupTask?.cancel()
        lookupTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await lookup()
        }
    }

    private func lookup() async {
        let name = trimmedName
        guard name.count >= 2 else { return }
        let entry = StoreCatalog.match(name)
        draft.catalogID = entry?.id
        if let c = entry?.colorHex { draft.autoColorHex = c }
        let typedDomain = draft.domain.map(StoreCatalog.normalizeDomain).flatMap { $0.isEmpty ? nil : $0 }
        guard let domain = typedDomain ?? entry?.domain ?? StoreCatalog.guessedDomain(for: name) else {
            clearAutoLogo(entry: entry)
            return
        }
        searchingLogo = true
        let found = await LogoService.find(domain: domain)
        searchingLogo = false
        guard !Task.isCancelled, name == trimmedName, !userPickedLogo else { return }
        if let found {
            applyFound(found, manual: false, keepCatalogColor: entry?.colorHex != nil)
        } else {
            clearAutoLogo(entry: entry)
        }
    }

    private func applyFound(_ found: LogoService.Found, manual: Bool, keepCatalogColor: Bool = false) {
        previewLogo = UIImage(data: found.png, scale: 3)?.withRenderingMode(.alwaysTemplate)
        logoChange = .set(found.png)
        if manual { userPickedLogo = true }
        if !keepCatalogColor, let hex = found.brandHex { draft.autoColorHex = hex }
        if draft.logoStyle != .auto && manual { draft.logoStyle = .auto }
        Haptics.soft()
    }

    private func clearAutoLogo(entry: StoreCatalog.Entry?) {
        if previewLogo != nil {
            previewLogo = nil
            logoChange = .remove
        }
        if entry?.colorHex == nil { draft.autoColorHex = nil }
    }

    // MARK: Save

    private func save() {
        var c = draft
        c.storeName = trimmedName
        c.number = cleanNumber
        c.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        c.expiry = hasExpiry ? Calendar.current.startOfDay(for: expiryDate) : nil
        c.colorHex = customColor ? color.hexString : nil
        if c.catalogID == nil { c.catalogID = StoreCatalog.match(c.storeName)?.id }
        if c.autoColorHex == nil, let entryColor = c.catalogEntry?.colorHex { c.autoColorHex = entryColor }
        if c.domain != nil { c.domain = c.domain.map(StoreCatalog.normalizeDomain) }
        var change = logoChange
        if case .remove = change, !c.hasLogo { change = .keep }
        Haptics.success()
        model.saveCard(c, logo: change)
        close()
    }

    private func close() {
        if let onDone { onDone() } else { dismiss() }
    }
}

extension Color {
    /// "#RRGGBB" of a SwiftUI color (sRGB).
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: Double(r), g: Double(g), b: Double(b)).hex
    }
}
