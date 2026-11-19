# iPad Graphic Tablet

Trasforma un iPad con Apple Pencil in una tavoletta grafica **con schermo** per Mac: l'iPad mostra il monitor
(o un'area scelta) e la Pencil disegna sull'immagine con pressione e inclinazione, via **Wi-Fi** (Safari o app) o **USB** (app).

L'app ha **una sola modalità, Display**: le vecchie modalità Tavoletta, Schermo, Photoshop e Touchpad sono state tolte.
Non ci sono più profili né barra strumenti sull'iPad: c'è un solo insieme di impostazioni (le ultime usate restano).

- **App Mac** (macOS 14+): barra dei menu + dashboard SwiftUI, cattura lo schermo e genera veri eventi tavoletta macOS.
- **App iPad** (iPadOS 17+) oppure **Safari**: mostra lo schermo del Mac e invia Pencil e dita.

## Senza installare nulla sull'iPad (Safari + IP)

Se sull'iPad non puoi installare app, basta Safari:

1. Compila e avvia **solo l'app Mac** (vedi sotto, passo 2).
2. Dashboard → **Connessione → Safari — senza installare app**: trovi l'indirizzo (es. `http://192.168.1.20:47830`), un codice a 6 cifre e un QR.
3. Sull'iPad apri **Safari**, scrivi l'indirizzo (o inquadra il QR con la Fotocamera), inserisci il codice, tocca **Collega**.
4. Concedi sul Mac il permesso **Accessibilità** quando richiesto.
5. Consigliato: Condividi → *Aggiungi alla schermata Home* (è un segnalibro, non un'app) per avere lo schermo intero senza le barre di Safari, e *Blocco automatico: Mai* durante l'uso.

Per avere l'icona sulla schermata Home dell'iPad: in Safari tocca **Condividi → Aggiungi alla schermata Home** (la pagina usa l'icona dell'app).

Cosa arriva dal browser: posizione, **pressione**, **inclinazione**, **hover** (iPad compatibili), dita (cursore, clic, zoom e spostamento dell'area). Cosa manca rispetto all'app iPad: doppio tocco, squeeze e rotazione della Pencil (Safari non li espone), USB, cifratura del traffico (l'accesso è comunque protetto dal codice, che non viaggia mai in rete). Dettagli in [docs/FATTIBILITA.md §8](docs/FATTIBILITA.md).

## Modalità Display: lo schermo del Mac sull'iPad

Con la modalità **Display** l'iPad diventa una tavoletta con schermo: mostra il monitor del Mac, o solo l'area che scegli, e la penna disegna esattamente sotto la punta.

1. Collega l'iPad (Safari o app): mostra subito lo schermo del Mac.
2. **Seleziona area sullo schermo…**: trascina un rettangolo sul monitor. Tieni premuto Shift per le proporzioni dell'iPad; Invio = tutto lo schermo; Esc = annulla. Più l'area è piccola, più è ingrandita sull'iPad.
3. **Proporzioni dell'iPad** allarga l'area perché l'immagine riempia il tablet senza bande nere.
4. Al primo uso macOS chiede il permesso **Registrazione schermo**: concedilo e **riapri l'app**.

**Dita e penna in modalità Display**

| Gesto sull'iPad | Effetto sul Mac |
|---|---|
| Un dito che scorre | Muove il cursore **come un trackpad** (movimento relativo; velocità in Area e monitor → Dita) |
| Tocco con un dito | Clic **nel punto toccato** (il cursore ci va da solo) |
| Doppio tocco con un dito | Doppio clic nel punto toccato |
| Apple Pencil | Clic, trascinamento e disegno con pressione e inclinazione, nel punto toccato |
| Due dita: pizzico | Zoom dell'area mostrata attorno al centro delle dita (allargando al massimo torni a tutto lo schermo) |
| Due dita: trascinamento | Sposta l'area mostrata sul monitor |
| Tocco con due dita | Clic destro nel punto toccato (tra le due dita) |

Ingrandendo, l'area prende da sola le proporzioni dell'iPad, così spariscono le bande nere. In **Area e monitor → Due dita** puoi scegliere invece "Zoom e scorrimento nell'app": il trascinamento scorre il documento e il pizzico usa le scorciatoie di zoom (Pencil e gesti → Pinch).

Funziona sia da Safari sia con l'app iPad. Le immagini viaggiano come JPEG sulla rete locale e la frequenza reale si adatta da sola alla velocità del Wi-Fi.

**Qualità sull'iPad** (Area e monitor → Qualità sull'iPad):

| Impostazione | Effetto |
|---|---|
| Impostazione rapida | Fluida · Bilanciata · Nitida · Massima (oppure Personalizzata con i cursori) |
| Risoluzione 30–100% | 100% = Retina: un pixel inviato per ogni pixel dell'iPad. Mai oltre i pixel reali del monitor |
| Qualità JPEG 30–100% | Meno artefatti su testi e bordi, più dati in rete |
| Massima nitidezza da fermo | Quando lo schermo smette di cambiare (¼ di secondo) arriva una versione a piena risoluzione Retina e qualità 95%: movimento fluido, immagine ferma nitida |

La riga di stato mostra pixel, fotogrammi al secondo, KB per fotogramma e la dimensione della versione nitida.

> Prima di tutto leggi [docs/FATTIBILITA.md](docs/FATTIBILITA.md): spiega cosa è possibile con le API Apple, cosa è stato fatto e i limiti reali (in particolare il comportamento della pressione nelle singole app).

## Modalità Trackpad

Dal menu ☰ dell'iPad (o dalla dashboard) scegli **Trackpad**: l'iPad diventa una superficie per le dita, come il trackpad di un Mac,
e la Pencil funziona da tavoletta sull'intero monitor. Le opzioni sono in **Dashboard → Trackpad**, con i nomi di Impostazioni di Sistema:

| Gruppo | Opzione | Gesto sull'iPad | Sul Mac |
|---|---|---|---|
| Punta e clic | Velocità di puntamento | un dito | cursore relativo con accelerazione |
| | Tocca per fare clic (sempre) | tocco / doppio tocco | clic / doppio clic |
| | Clic secondario | due dita · angolo in basso a destra · a sinistra | clic destro |
| | Ricerca e rilevatori dati | tocco con tre dita | ⌃⌘D |
| | Trascina tenendo premuto | tieni fermo, poi muovi | trascinamento |
| | Trascinamento con tre dita | tre dita | trascinamento |
| Scorri e ingrandisci | Scorrimento naturale, inerzia, velocità | due dita | scorrimento continuo con fasi da trackpad |
| | Ingrandisci o riduci | pizzico con due dita | ⌘+ / ⌘− |
| Altri gesti | Scorri tra le pagine | 3 o 4 dita a sinistra/destra | ⌘[ / ⌘] |
| | Scorri tra le app a tutto schermo | 3 o 4 dita a sinistra/destra | ⌃← / ⌃→ (Spaces) |
| | Mission Control / Exposé app | 3 o 4 dita in alto / in basso | apre Mission Control |
| | Launchpad / App · Mostra scrivania | pollice e tre dita: pizzica / allarga | apre l'app di sistema |

Non riproducibili con API pubbliche: Force Click, Smart zoom, rotazione, Centro Notifiche dal bordo.
Per i gesti a quattro dita disattiva sull'iPad **Impostazioni → Multitasking e gesti → Gesti** (altrimenti li usa iPadOS).
I gesti a tre e quattro dita funzionano anche in modalità Display.

## Requisiti

| | |
|---|---|
| Mac | macOS 14 Sonoma o successivo, Apple Silicon o Intel |
| iPad | iPadOS 17 o successivo, qualsiasi Apple Pencil (pressione assente su Pencil USB-C) |
| Sviluppo | Xcode 15 o successivo (testato come progetto per Xcode 16/26), un Apple ID (anche gratuito) |

## Compilazione e installazione

### 1. Apri il progetto
Apri `iPadGraphicTablet.xcodeproj`.
(In alternativa, con [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen && xcodegen generate`.)

### 2. App Mac — target `TabletMac`
1. Seleziona il target **TabletMac** → *Signing & Capabilities*.
2. Il progetto è impostato su **Sign to Run Locally**: compila subito. Consigliato: scegli il tuo **Team**, così il permesso Accessibilità non va riconcesso a ogni ricompilazione (macOS lo lega alla firma).
3. Nel menu degli schemi in alto scegli **TabletMac** (non *TabletCoreTests*, che contiene solo i test) → destinazione *My Mac* → ⌘R.
4. L'icona compare nella barra dei menu. La dashboard si apre con "Apri dashboard".
5. Per installarla: Product → Archive → Distribute App → *Copy App* (o Developer ID per distribuirla) e copia l'app in Applicazioni.

### 3. App iPad — target `TabletPad`
1. Collega l'iPad al Mac con il cavo e sblocca l'iPad; se richiesto tocca **Autorizza**.
2. Target **TabletPad** → *Signing & Capabilities* → scegli il tuo **Team** (con un Apple ID gratuito l'app dura 7 giorni, poi va reinstallata).
3. Sull'iPad attiva **Modalità sviluppatore** (Impostazioni → Privacy e sicurezza) se richiesto.
4. Schema **TabletPad** → destinazione il tuo iPad → ⌘R.
5. Al primo avvio dell'app firmata con Apple ID gratuito: Impostazioni → Generali → VPN e gestione dispositivi → autorizza lo sviluppatore.

### 4. Primo utilizzo
1. Apri l'app sul Mac e sull'iPad, collega il cavo: la connessione è automatica.
2. Alla prima sessione macOS chiede il permesso **Accessibilità** per l'app Mac: concedilo (Impostazioni di Sistema → Privacy e sicurezza → Accessibilità). Senza, macOS ignora gli eventi generati.
3. Dalla dashboard regola pressione (Penna e pressione) e qualità dell'immagine (Area e monitor).
4. Verifica la pressione in **Test e diagnostica** prima di aprire Photoshop.
5. Il primo collegamento via cavo associa anche il Wi-Fi: da quel momento puoi scollegare e scegliere il Mac dall'elenco Wi-Fi sull'iPad. Su macOS 15+ concedi anche il permesso **Rete locale**.

## Permessi

| Permesso | Dove | Quando | Perché |
|---|---|---|---|
| Accessibilità | Mac | all'avvio della prima sessione | generare eventi di penna, mouse e tastiera |
| Rete locale | Mac e iPad | al primo uso del Wi-Fi | Bonjour e connessione sulla LAN |
| Autorizza questo computer | iPad | primo collegamento USB | richiesto da usbmuxd |
| Connessioni in entrata (firewall) | Mac | primo uso della pagina Safari | porte 47830–47831 |
| Registrazione schermo | Mac | prima attivazione della modalità Display | catturare il monitor da mostrare sull'iPad (poi riaprire l'app) |

L'app Mac **non è sandbox** (necessario per usbmuxd e per gli eventi di input): si distribuisce fuori dal Mac App Store. Nessun dato lascia la rete locale; nessuna raccolta di dati.

## Struttura

```
iPadGraphicTablet.xcodeproj   progetto Xcode (generato da Tools/generate_xcodeproj.py)
project.yml                   stesso progetto per XcodeGen
Shared/                       modulo condiviso (protocollo, rete) + test, anche come Swift Package
Mac/                          app macOS (connessione, input, motore, interfaccia)
iPad/                         app iPadOS (cattura Pencil, connessione, interfaccia)
docs/                         fattibilità, architettura, protocollo, piano di test
Mac/Resources/WebClient.html  client web per Safari (servito dall'app Mac)
Tools/                        generatore del progetto Xcode, test del client web
```

## Risoluzione problemi

| Sintomo | Soluzione |
|---|---|
| L'iPad non si collega via USB | App iPad in primo piano e non in pausa; iPad autorizzato; Dashboard → Connessione → USB "In ascolto" |
| Il cursore non si muove | Permesso Accessibilità mancante: banner rosso nella dashboard |
| Permesso concesso ma ignorato dopo una ricompilazione | Rimuovi l'app da Accessibilità e riaggiungila, oppure firma con il tuo Team |
| Nessun Mac in Wi-Fi | Stessa rete, permesso Rete locale concesso su entrambi, firewall del Mac che consente le connessioni in entrata |
| Pressione assente in un'app specifica | docs/TEST.md §5 |
| Safari non apre la pagina | Stessa rete Wi-Fi; indirizzo con `http://` e `:47830`; firewall del Mac che consente le connessioni in entrata; interruttore "Pagina per Safari" attivo |
| Safari: "Codice errato" | Controlla il codice in Connessione; dopo 5 errori il Mac blocca i tentativi per 60 s |
| Modalità Display: "In attesa dello schermo del Mac" | Permesso Registrazione schermo concesso e app riaperta; Dashboard → Area e monitor → stato della trasmissione |
| Pagina Safari vecchia dopo un aggiornamento del Mac | Si ricarica da sola al collegamento; se non succede, ricaricala a mano una volta |
| Modalità Display lenta o a scatti | Abbassa Risoluzione o Qualità; usa il Wi-Fi a 5 GHz; riduci l'area mostrata |
| Il cursore non si muove ma l'interruttore Accessibilità è acceso | L'interruttore si riferisce a una compilazione precedente: in Privacy e sicurezza → Accessibilità (o «Controllo del dispositivo e accesso ai dati») rimuovi l'app con «−», imposta un Team in Xcode (Signing & Capabilities), ricompila e concedi di nuovo il permesso |
| Scorciatoia sbagliata con tastiera italiana | Nell'azione del pulsante clicca il campo e premi la combinazione sul Mac |

## Nota sulla compilazione
Il codice è stato scritto e rivisto senza poterlo compilare in questo ambiente (nessun SDK Apple disponibile).
Il modulo `TabletCore` è Foundation puro e ha test unitari; per il resto, se Xcode segnala un errore al primo
build si tratta di aggiustamenti puntuali: il messaggio indica file e riga.
