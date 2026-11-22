# CLAUDE.md — regole di lavoro per questa repo

Repo di app iOS **native (Swift + SwiftUI)** personali, sviluppate senza Mac:
il codice viene scritto su Linux (Claude Code) e compilato **solo** su GitHub
Actions con runner macOS. Le app non vanno su App Store: l'utente scarica il
`.ipa` non firmato dagli artifact e lo firma con Sideloadly/SideStore.

Stessa impostazione delle repo `Garoth93/ritorni-IOS`, `Garoth93/home-alarm-IOS`
e `Garoth93/LTIDI-Last-Time-I-Did-It-IOS`.

## Vincoli fissi

- Nativo vero: Swift/SwiftUI. Niente WebView, niente framework cross-platform,
  salvo richiesta esplicita dell'utente.
- Nessun `.xcodeproj` committato: il progetto è generato in CI da
  `apps/<app>/project.yml` con XcodeGen. `.gitignore` lo esclude.
- Mai committare segreti, chiavi API, certificati, profili di provisioning,
  Team ID reali.
- **PRIVACY (vincolo forte)**: mai committare dati personali dell'utente —
  backup, file dati, liste reali, foto — né nei test, né nei commenti, né nel
  README. I test usano solo dati **sintetici** generati nel codice
  (`Synthetic.swift`, nomi `... TEST`). I template di esempio
  (`SampleContent`) sono generici.
- Dati locali; rete solo per loghi/volantini e per il Worker personale (sync cifrata, Wallet). Niente CloudKit/iCloud (installazione con Sideloadly).
- Account Apple gratuito: nessuna firma in CI (`CODE_SIGNING_ALLOWED=NO`).
- Non modificare impostazioni della repo o secrets: spiegare all'utente cosa
  configurare.

## Struttura repo

```
apps/<NomeApp>/            un'app per cartella
  project.yml              spec XcodeGen (target, bundle id, deployment target)
  Sources/                 codice SwiftUI dell'app (solo strato UI + glue)
  Resources/               Assets.xcassets e altre risorse
  Shared/                  codice comune app + widget
  Widgets/                 estensione WidgetKit
  *.entitlements           entitlements (App Group) usati per la firma ad-hoc in CI
  Info.plist               GENERATO da XcodeGen (git-ignored)
packages/<NomePackage>/    Swift Package con la logica NON grafica
  Package.swift            tools-version 5.9, nessuna dipendenza da UIKit/SwiftUI
  Sources/<NomePackage>/   modelli, regole, persistenza (Foundation only)
  Tests/<NomePackage>Tests/ XCTest, eseguiti anche su Linux
.github/workflows/         CI (vedi sotto)
.github/actions/setup-xcode/ composite action: seleziona Xcode, installa XcodeGen, genera il progetto
```

| App     | Package logica | Bundle ID                               | Deployment target |
|---------|----------------|-----------------------------------------|-------------------|
| Tessere | TessereCore    | `com.garoth93.tessere` (+ `.widgets`)   | iOS 26.0 |

### Tessere

Tessere fedeltà, buoni, biglietti. Dettagli utente nel README.

Package (`TessereCore`, tutto testato):

- `Models.swift`: `Card` (decodifica tollerante, `syncable` senza campi locali),
  `CardUsage` (frecency), `TessereSettings`, `OfferState`, `SyncState`,
  `Tombstone`, `TessereData` (mutazioni che marcano `pendingSync`).
- `BarcodeFormat.swift` + `Barcode1D.swift`: formati, mappature scanner/Vision/
  Wallet (lineari → Code 128), encoder EAN-13/8, UPC-A/E, Code 39, ITF, Codabar
  (verificati con zbar: `scripts/verify-barcodes.py`). Code 128/QR/PDF417/Aztec
  li disegna Core Image nell'app.
- `StoreCatalog.swift`: catalogo locale catene italiane (dominio, colore solo se
  certo, volantino), `match`/`suggestions`/`normalize`.
- `ColorMath.swift` + `LogoMask.swift`: colori, contrasto, gradiente, colore
  generato, colore dominante, logo → maschera monocromatica (su RGBA grezzi).
- `CardQuery.swift` (ricerca/filtri/ordinamento, `ExpiryPlanner`, formati),
  `Location.swift` (regioni monitorate, negozi vicini), `WebScraping.swift`
  (og:image, icone, `OffersPlanner`), `Sync.swift` (formato wire condiviso con
  `backend/`, `SyncEngine` LWW, `InviteLink`), `WalletPass.swift`
  (`PassRequest`, `WidgetSnapshot`, `BackupFile`).

App: `AppModel.update` unico punto di modifica sincronizzata (`updateLocal` per
uso/offerte/stato sync). Dettaglio carta in `fullScreenCover` con transizione
zoom (matchedGeometryEffect non attraversa TabView/NavigationStack); dentro il
dettaglio `matchedGeometryEffect` tra pannello e codice a schermo intero.
Token del dispositivo e chiave famiglia nel Keychain. Loghi PNG (maschera
bianca) in App Group `Logos/`. App Group `group.com.garoth93.tessere`.

Backend: `backend/` Worker Cloudflare + D1 (`schema.sql`), test
`cd backend && npm install && npm test` (shim D1 su node:sqlite, firma
verificata con openssl). Segreti solo come secret del Worker/GitHub.

## Convenzioni di codice

- Swift 5 language mode (`SWIFT_VERSION: 5.0` nel project.yml), tools-version
  5.9 nei package, in modo che Linux (`swift:6.0`) e Xcode 26 compilino lo
  stesso codice. Il package dichiara `.iOS(.v17)` come minimo: è solo il suo
  minimo, l'app può avere un target più alto.
- Logica, modelli e persistenza nel package: tipi `struct` value-type,
  `Codable`, `Equatable`, `Sendable`, senza `import SwiftUI`/`UIKit`.
  Tutto ciò che è testabile va lì e ha un test. Le integrazioni esterne
  (es. `SyncCipher`) stanno dietro protocolli del package; le
  implementazioni finte esistono **solo nei test**. Nell'app non c'è nessun
  "genera dati di prova".
- Nell'app: `@Observable` (framework Observation) + `@MainActor`, iniettato
  con `.environment(...)` e letto con `@Environment(Tipo.self)`; stringhe UI
  e permessi (Info.plist) in italiano. Target iOS 26.0: si possono usare le
  API SwiftUI di iOS 26 senza `#available`.
- Grafica: tema scuro OLED di default (chiaro supportato), un solo accento teal (`Theme.accent`), SF Rounded (`fontDesign(.rounded)`), card raggio 22 pt (`CardFace`).
- Nessuna dipendenza esterna salvo necessità motivata.
- Commit piccoli e descrittivi; niente identificatori di modello AI nei commit.

## Xcode e runner

- Runner: `macos-26`. Xcode fissato con `XCODE_VERSION: "26.6"` (SDK iOS 26.5)
  (env in ogni workflow) e selezionato con `xcode-select`. Se GitHub ritira la
  versione, la composite action fallisce elencando le Xcode disponibili:
  aggiornare il valore in tutti i workflow e qui.
- Toolchain Linux per i test: immagine Docker `swift:6.0-noble`.
- XcodeGen e xcbeautify installati con Homebrew a ogni run.

## CI (GitHub Actions)

| Workflow | Trigger | Cosa fa |
|----------|---------|---------|
| `build-simulator.yml` | push su ogni branch, PR, manuale | `xcodebuild build` per iOS Simulator, senza firma. Serve a vedere gli errori di compilazione. |
| `build-ipa.yml` | push su `main` e `claude/**`, manuale | build Release per dispositivo con `CODE_SIGNING_ALLOWED=NO`, firma ad-hoc con gli `.entitlements` dell'app e del widget, impacchetta `Payload/<App>.app` in `<App>-unsigned.ipa` e lo carica come artifact (30 giorni). |
| `test-linux.yml` | push su ogni branch, PR, manuale | `swift test` su ogni package in `packages/`. |

### Come leggere i log di CI

Con gli strumenti GitHub MCP disponibili a Claude Code: `actions_list` con
`list_workflow_runs` per trovare il run, `list_workflow_jobs` per i job,
`get_job_logs` con `failed_only=true` e `return_content=true` per i log dei
job falliti. I log raw di `xcodebuild` sono anche caricati come artifact
`xcodebuild-*-log-<App>`. Gli errori Swift compaiono come annotazioni
`::error file=...` grazie a `xcbeautify --renderer github-actions`.

## Regole di lavoro (per Claude)

1. Dopo **ogni push** controllare l'esito della CI e correggere da soli gli
   errori di compilazione fino a build verde. Mai dichiarare "funziona" se la
   CI non è verde: riportare l'esito reale con il link al run.
2. Non si può vedere l'interfaccia: nelle scelte grafiche ambigue usare il
   comportamento standard e dire all'utente cosa verificare sul telefono.
3. Commit piccoli e descrittivi. Mai segreti, mai dati personali.
4. I test del package si possono eseguire in locale con Docker:
   `docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test --package-path packages/TessereCore`
   (avviare `dockerd` se non è attivo). L'app SwiftUI si compila solo in CI.
