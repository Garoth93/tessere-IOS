# Tessere — tessere fedeltà, buoni e biglietti (iOS)

App iOS nativa (Swift + SwiftUI) per tenere in tasca tessere fedeltà, buoni e
biglietti: griglia di carte colorate con il logo del negozio, codice a schermo
intero alla cassa, Apple Wallet, widget, offerte e condivisione in famiglia.

Sviluppata senza Mac: compilata e firmata da GitHub Actions e distribuita con
**TestFlight** (Sideloadly resta come ripiego). La sincronizzazione in famiglia
passa da un piccolo server tuo (Worker Cloudflare gratuito).

## Cosa c'è

- **Carte**: griglia a 2 colonne, card con raggio 22 pt, colore del marchio con
  leggero gradiente diagonale e logo bianco o scuro (contrasto automatico).
  In alto a sinistra sincronizzazione e impostazioni, in alto a destra **+**.
  Chip **Tessere / Buoni / Biglietti / Altro** sotto il titolo, **ricerca tirando
  giù** (nome, nota, numero), ordinamento **più usate** (default), nome, recenti,
  aggiunte. Stato vuoto con carta segnaposto tratteggiata.
- **Banner «Attiva ora / Non interessato»**: con la posizione l'app cerca i
  negozi delle tue carte vicino a te (MapKit), mostra «Sei vicino a…» e, con il
  permesso «Sempre», ti avvisa quando entri nel negozio (anche dalla schermata
  di blocco). La posizione non lascia l'iPhone.
- **Aggiunta**: scanner (EAN-13/8, UPC-A/E, Code 128, Code 39, ITF, Codabar,
  QR, PDF417, Aztec), lettura da foto/screenshot, oppure a mano. Scrivi o scegli
  il negozio: l'app trova **logo e colore** da sola — catalogo locale di ~80
  catene italiane → icone del sito del negozio → colore dominante del logo →
  altrimenti nome/iniziali su colore generato. Logo anche da una tua foto.
- **Nota** facoltativa: se c'è appare come etichetta sulla carta.
- **Dettaglio**: tocco → la carta si espande (transizione zoom), sotto il
  pannello bianco con il codice; luminosità al massimo (ripristinata alla
  chiusura), schermo sempre acceso, tap lungo sul numero per copiarlo, tocco sul
  pannello → solo codice a tutto schermo, **ruotato in orizzontale** per i
  codici lunghi. Feedback tattile leggero.
- **Aggiungi a Apple Wallet**: pass generico con codice, nome, colore, logo e
  fino a 10 negozi vicini (il pass compare da solo sulla schermata di blocco
  quando sei lì). EAN/UPC/Code 39/ITF vanno in Wallet come Code 128.
- **Scadenza** con notifica (N giorni prima e il giorno stesso).
- **Offerte**: copertine dei volantini dei negozi di cui hai la carta, badge
  **NUOVO** quando il volantino cambia, apertura in Safari.
- **Widget** Home (piccolo, medio, grande) e **schermata di blocco** con le
  tessere più usate: tocco → codice pronto.
- **Face ID** facoltativo; tema **scuro OLED** di default (chiaro supportato),
  un solo colore d'accento (teal acido), SF Rounded, Dynamic Type.
- **Famiglia**: sincronizzazione tra i tuoi dispositivi e con i familiari,
  **cifrata end-to-end** (AES-GCM): il server vede solo id e date. Ogni carta
  può restare «solo su questo iPhone».
- **Backup automatico su iCloud Drive** (app File › iCloud Drive › Backup ›
  Tessere): un file al giorno quando le carte cambiano; ripristino dalle
  Impostazioni o guidato al primo avvio. Resta anche l'export JSON manuale.

## Installare l'app

**TestFlight** (normale): Actions › **testflight** › *Run workflow* (o un push su
`main`). Il workflow firma, carica la build su App Store Connect e dopo 5-30
minuti compare nell'app TestFlight dell'iPhone. Ogni due mesi parte da solo
per rinnovare la build (TestFlight la fa scadere dopo 90 giorni).

**Sideloadly** (ripiego): Actions › **build-ipa** › artifact
`Tessere-unsigned-ipa`, poi Sideloadly con il tuo Apple ID. Con l'account
gratuito la firma dura 7 giorni.

## Server (sync famiglia + Wallet)

Un Worker Cloudflare (piano gratuito) in `backend/`, con database D1.

1. Su Cloudflare crea un **API token** (modello «Edit Cloudflare Workers» +
   permesso **D1 Edit**) e copia l'**Account ID**.
2. Nella repo, *Settings › Secrets and variables › Actions*:
   - secrets: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `ENROLL_KEY`
     (una frase lunga a caso: serve solo per collegare il primo iPhone);
   - per Wallet (vedi sotto): secrets `PASS_P12_BASE64`, `PASS_P12_PASSWORD`,
     variables `PASS_TYPE_ID` e `TEAM_ID`.
3. **Actions › deploy-backend › Run workflow**. Crea il database se manca,
   applica lo schema, pubblica il Worker e carica i segreti.
4. Nell'app: Impostazioni › **Famiglia e server** › indirizzo
   `https://tessere.<tuo-sottodominio>.workers.dev` + `ENROLL_KEY` › **Collega** ›
   **Crea la famiglia** (anche da solo, per più dispositivi).
5. **Invita**: mostra un QR (o manda il link) valido 48 ore, una sola volta.
   L'altro iPhone lo scansiona da *Famiglia e server › Ho un invito*. Il link
   contiene la chiave della famiglia (mai inviata al server): mandalo solo a chi
   deve entrare.

### Wallet: certificato Pass Type ID

Serve un account Apple Developer a pagamento (il certificato lo fornisci tu):

1. developer.apple.com › Identifiers › **Pass Type IDs** › `pass.com.<nome>.tessere`.
2. Crea il certificato del Pass Type ID, importalo nel Portachiavi ed
   esportalo come `.p12` con password.
3. `base64 -i pass.p12 | pbcopy` → secret `PASS_P12_BASE64`; la password →
   `PASS_P12_PASSWORD`; variabili `PASS_TYPE_ID` e `TEAM_ID` (10 caratteri).
4. Rilancia **deploy-backend**: converte il `.p12` in PEM, scarica il
   certificato intermedio Apple WWDR G4 e li salva come segreti del Worker.
   In app, *Famiglia e server* mostra «Pass Apple Wallet: Pronti».

Perché il Worker e non una GitHub Action: la firma deve avvenire nel momento in
cui tocchi «Aggiungi a Wallet» (richiesta → `.pkpass` firmato in un secondo); la
chiave privata resta sul server e mai nell'app. La firma è PKCS#7 staccata del
`manifest.json` (SHA-256, catena WWDR), verificata nei test con openssl.

API: `GET /v1/health`, `POST /v1/devices`, `POST /v1/spaces`,
`POST /v1/spaces/invite`, `POST /v1/join`, `GET /v1/space`,
`DELETE /v1/space/members/:id`, `POST /v1/sync` (push+pull, last-writer-wins),
`POST /v1/pass`.

## Struttura

```
apps/Tessere/            app SwiftUI (project.yml per XcodeGen)
  Sources/               schermate, modello, servizi (scanner, posizione, sync, Wallet, logo)
  Shared/                tema, faccia della carta, store condiviso con i widget
  Widgets/               estensione WidgetKit
packages/TessereCore/    logica non grafica, testata con `swift test` su Linux
backend/                 Worker Cloudflare (sync + firma .pkpass), test con node:test
scripts/                 icona dell'app, verifica dei codici a barre con zbar
.github/workflows/       build-simulator, build-ipa, test-linux, test-backend, deploy-backend
```

## Privacy

Le carte stanno sul telefono; con la famiglia attiva viaggiano cifrate. Nessun
dato reale nella repo: i test usano dati sintetici.
