# Piano di test

## 1. Test unitari (protocollo, curva, stabilizzatore, geometria)

- **Xcode:** schema `TabletMac` → Product → Test (⌘U). Non usare ⌘R per i test: un bundle di test non si avvia.
- **Terminale:** `cd Shared && swift test`

Coprono: andata/ritorno di tutti i messaggi, quantizzazione dei campioni, flusso TCP spezzato a pezzi da 7 byte, frame troppo grandi o troncati, curva lineare = identità, monotonia delle curve, sensibilità min/max, attenuazione del tremolio, rotazioni inverse, adattamento alle proporzioni, codifica JSON dei profili, stima dell'offset degli orologi.

## 2. Connessione USB

| # | Passi | Atteso |
|---|---|---|
| U1 | Mac app aperta, iPad app aperta, collega il cavo | Entro ~2 s: dashboard "Collegato via USB", iPad nero con indicatore verde "USB" |
| U2 | Scollega il cavo | Mac: "In attesa"; iPad torna alla schermata iniziale (o passa al Wi-Fi se associato) |
| U3 | Ricollega | Riconnessione automatica senza toccare nulla |
| U4 | Collegato in Wi-Fi, inserisci il cavo | Passaggio automatico a USB (priorità) |
| U5 | iPad mai autorizzato sul Mac | Nessuna connessione finché sull'iPad non tocchi "Autorizza" |
| U6 | Test e diagnostica → Registro | Righe "USB: dispositivo collegato", "tunnel aperto" |

## 3. Connessione Wi-Fi

| # | Passi | Atteso |
|---|---|---|
| W1 | Dopo un collegamento USB, scollega e scegli il Mac dall'elenco Wi-Fi | Connessione senza codice (chiave ricevuta via USB) |
| W2 | iPad mai collegato: Mac → Connessione → Associa con codice; iPad → Associa… → PIN | "Associato", poi connessione automatica |
| W3 | PIN errato 5 volte | La finestra di associazione si chiude |
| W4 | IP manuale (indirizzo mostrato in Connessione) + Mac associato | Connessione riuscita |
| W5 | Spegni il Wi-Fi del Mac per 10 s e riaccendi | L'iPad si riconnette da solo (Riconnessione automatica attiva) |
| W6 | Mac → "Revoca tutte le associazioni" | La sessione Wi-Fi cade; la riconnessione richiede USB o nuovo PIN |

## 3-bis. Safari (senza app)

| # | Passi | Atteso |
|---|---|---|
| S1 | Mac → Connessione → Safari attivo; sull'iPad apri `http://IP:47830` | Pagina nera "iPad Graphic Tablet" con campo codice |
| S2 | Inserisci il codice e tocca Collega | Schermo nero, indicatore "Safari · N ms"; Mac: "Collegato via Safari" |
| S3 | Codice sbagliato 5 volte | "Codice errato", poi il Mac rifiuta i tentativi per 60 s |
| S4 | Inquadra il QR con la Fotocamera | La pagina si apre con il codice già inserito |
| S5 | Disegna in Test e diagnostica | Pressione e inclinazione variano come con l'app |
| S6 | Spegni e riaccendi il Wi-Fi dell'iPad | La pagina si ricollega da sola ogni 2 s |
| S7 | Con un iPad collegato via USB apri anche Safari | Safari viene rifiutato: l'USB ha la precedenza |

Test automatici del client web (codec, HMAC, sessione simulata, gesti): `cd Tools/webclient-tests && npm install && npm test`.

## 3-ter. Modalità Display (schermo sull'iPad)

| # | Passi | Atteso |
|---|---|---|
| D1 | Profilo *Display (schermo sull'iPad)*, iPad collegato | Al primo uso macOS chiede Registrazione schermo; dopo averlo concesso e riaperto l'app l'iPad mostra il monitor |
| D2 | Tocca con la penna un'icona visibile sull'iPad | Il cursore del Mac va esattamente su quell'icona (in tutti e quattro gli angoli) |
| D3 | Seleziona area sullo schermo… → trascina un rettangolo | L'iPad mostra solo quell'area, ingrandita; la penna resta allineata |
| D4 | Shift durante il trascinamento, poi "Proporzioni dell'iPad" | L'immagine riempie il tablet senza bande nere |
| D5 | Disegna in Photoshop con la tela nell'area | Il tratto compare sull'iPad sotto la punta, con pressione |
| D6 | Abbassa Risoluzione/Qualità | Lo stato mostra meno KB per fotogramma e più fotogrammi al secondo |
| D7 | Schermo fermo per alcuni secondi, poi un cambiamento | L'iPad si aggiorna sempre all'ultimo stato (nessun fotogramma perso) |
| D8 | Scorri un dito in un punto qualsiasi | Il cursore si sposta come con un trackpad (relativo), senza clic |
| D9 | Tocca con un dito un'icona visibile sull'iPad, poi toccala due volte rapidamente | Il cursore salta sull'icona: clic, poi doppio clic (apre il file) |
| D9-bis | Tocca un'icona con la Pencil | Clic esattamente sotto la punta |
| D10 | Pizzica con due dita su un dettaglio | Il dettaglio si ingrandisce restando sotto le dita; le bande nere spariscono |
| D11 | Trascina con due dita, poi allarga al massimo | L'area si sposta senza uscire dal monitor; alla fine si vede tutto lo schermo |
| D12 | Dopo lo zoom tocca con la Pencil un punto preciso | Il clic avviene esattamente sotto la punta |
| D14 | Impostazione rapida "Nitida", testo piccolo sul Mac | Sull'iPad il testo è definito come sul Mac (Retina 1:1) |
| D15 | "Fluida" + "Massima nitidezza da fermo", scorri una pagina e fermati | Durante lo scorrimento immagine morbida; ¼ di secondo dopo l'arresto diventa nitida; lo stato mostra "da fermo W×H" |
| D13 | Due dita = "Zoom e scorrimento nell'app" | Il trascinamento scorre il documento, il pizzico esegue ⌘+ / ⌘− |

## 3-quater. Modalità Trackpad

| # | Passi | Atteso |
|---|---|---|
| T1 | Menu ☰ → Trackpad | L'iPad mostra la superficie "TRACKPAD", il Mac smette di trasmettere lo schermo |
| T2 | Un dito che scorre, tocco, doppio tocco | Cursore relativo, clic, doppio clic |
| T3 | Clic secondario = angolo in basso a destra, tocca l'angolo | Clic destro |
| T4 | Due dita su una pagina lunga, poi solleva in movimento | Scorrimento fluido che continua per inerzia; con "Scorrimento naturale" spento il verso si inverte |
| T5 | Tre dita verso l'alto | Mission Control |
| T6 | Tre dita a sinistra/destra con due Spaces | Cambio di Space |
| T7 | Pollice e tre dita: pizzica, poi allarga | Launchpad/App, poi Mostra scrivania |
| T8 | Tocco con tre dita su una parola | Finestra Ricerca (dizionario) |
| T9 | Trascinamento con tre dita attivo: sposta una finestra con tre dita | La finestra si trascina |

## 4. Latenza

Dashboard → **Test e diagnostica → Latenza**:
- **RTT**: ping ogni secondo (media, p95, jitter). Riferimenti indicativi: USB 1–3 ms, Wi-Fi 5 GHz 3–10 ms.
- **Penna → Mac**: età del campione all'invio dell'evento, con orologi sincronizzati stile NTP.
- **Frequenza**: campioni/s durante un tratto (atteso ~240 Hz su iPad Pro/Air recenti, 120 Hz su altri modelli).
- **Campioni persi**: deve restare 0 (il trasporto è TCP).

Prova consigliata: disegna cerchi veloci per 10 s via USB e poi via Wi-Fi e annota i valori.

## 5. Pressione reale nelle app (criterio di successo 6–7)

1. Concedi il permesso **Accessibilità** quando richiesto (Impostazioni di Sistema → Privacy e sicurezza → Accessibilità).
2. Modalità **Schermo** o **Photoshop**, monitor = quello con la finestra della dashboard.
3. **Test e diagnostica → Test pressione**: disegna premendo piano e forte.
   - Atteso: tratto sottile/spesso, "Pressione ricevuta dalle app Cocoa", evento `tablet`, puntatore "penna".
   - Se la pressione resta 1.000: la Pencil non riporta pressione (es. Apple Pencil USB-C) — la Panoramica lo indica.
4. **Photoshop**: Pennello → pannello Impostazioni pennello → Dinamica forma → Controllo: *Pressione penna* (dimensione) e Trasferimento → *Pressione penna* (opacità).
   - Atteso: dimensione/opacità seguono la pressione.
   - Se compare il triangolo "richiede una tavoletta sensibile alla pressione": esci dal raggio della tavoletta (allontana la penna o cambia modalità e torna), poi riprova; verifica che Photoshop sia aggiornato. Segnala il risultato: è il punto in cui ogni app decide autonomamente.
5. **Illustrator**: l'opzione "Pressione" si abilita solo con un driver Wacom installato (anche senza tavoletta): è il workaround documentato anche da Astropad.
6. Penna ↔ gomma: con la gomma attiva Photoshop passa allo strumento Gomma da solo (puntatore `eraser`).

## 6. Funzioni penna e interfaccia

| # | Verifica |
|---|---|
| P1 | Curva morbida/lineare/rigida: il punto rosso nell'editor segue la pressione live |
| P2 | Soglia di click 20% su iPad senza hover: sfiorando si muove il cursore senza disegnare |
| P3 | Stabilizzazione 80%: linee lente più pulite, nessun ritardo nei tratti veloci |
| P4 | Rotazione 90/180/270 e Mancini: il cursore segue la penna nel nuovo orientamento, la barra passa a destra |
| P5 | Area attiva ridotta: in modalità Schermo l'iPad mostra il rettangolo tratteggiato corretto |
| P6 | Blocco cursore e Precisione dalla barra dei menu e dal menu dell'iPad |
| P7 | Pulsanti "tieni premuto" (Alt, Spazio): la mano di Photoshop resta attiva finché tieni il dito |
| P8 | Scorciatoie con layout italiano: Pennello +/− e Zoom funzionano; se no, registra il tasto nel campo dell'azione |
| P9 | Touchpad: 1 dito muove, tocco = clic, 2 dita = scorrimento/clic destro, pinch = zoom |
| P10 | Hover (iPad compatibili): il cursore segue la penna sollevata; la Panoramica mostra "In prossimità" |
| P11 | Doppio tocco / squeeze: eseguono le azioni del profilo; le capacità compaiono dopo il primo uso |
| P12 | Uscita: tieni premuto ✕ → pausa; il Mac non si ricollega finché non premi "Riprendi" |
