# Analisi di fattibilità

Questa analisi è stata fatta **prima** di scrivere il codice e ne guida tutte le scelte.
Per ogni requisito: cosa si può fare con API pubbliche, cosa no, e cosa è stato fatto.

Legenda: ✅ realizzato con API pubbliche · ⚠️ realizzato con un limite dichiarato · ❌ non realizzabile senza privilegi Apple

---

## 1. La domanda chiave: la pressione arriva davvero a Photoshop?

**Sì, attraverso un percorso preciso, con un limite da verificare app per app.**

macOS ha due modi per far arrivare la pressione di una penna alle app:

| Percorso | Come funziona | Stato |
|---|---|---|
| **A. Eventi tavoletta Quartz** (`CGEvent`) | Il processo "posta" un evento `kCGEventTabletProximity` (penna in prossimità, con maschera delle capacità) e poi eventi mouse con sottotipo `kCGEventMouseSubtypeTabletPoint`, che contengono `kCGTabletEventPointPressure`, `kCGTabletEventTiltX/Y`, `kCGTabletEventRotation`. AppKit li consegna alle app come `NSEvent` con `subtype == .tabletPoint` e `pressure` valorizzata. | ✅ **Usato da questo progetto.** API pubblica, richiede solo il permesso Accessibilità. È il percorso dei driver che "postano" eventi tablet direttamente. |
| **B. Dispositivo HID virtuale** (CoreHID `HIDVirtualDevice` / DriverKit) | Si crea un digitizer HID che macOS tratta come una tavoletta fisica. | ❌ **Oggi non utilizzabile per la pressione.** Richiede un entitlement concesso da Apple (`com.apple.developer.hid.virtual.device`) e, secondo una segnalazione su macOS 26.2 confermata come instradata correttamente da Apple DTS, la pressione di un digitizer HID virtuale arriva alle app sempre a 0 (bug FB24785043). L'entitlement DriverKit `…family.hid.virtual.device` è indicato da Apple come non più funzionante. |

**Conseguenza:** il percorso A è l'unico che oggi porta pressione e inclinazione alle app con API pubbliche. Il progetto lo implementa per intero (`Mac/Input/CGEventTabletBackend.swift`) e include un **banco di prova** (Dashboard → Test e diagnostica) che legge gli `NSEvent` esattamente come un'app di grafica: se lì la pressione varia, la catena iPad → rete → CGEvent → AppKit funziona.

### Il limite onesto
Il Mac **non vede** un dispositivo "Wacom": vede eventi tavoletta generati da un processo. La maggior parte delle app Cocoa (Photoshop, Affinity, Pixelmator, Krita…) legge semplicemente `NSEvent.pressure` e funziona. Alcune app fanno controlli aggiuntivi:

- **Illustrator** su macOS abilita le opzioni di pressione solo se è presente un driver Wacom. Astropad, prodotto commerciale che usa lo stesso principio, documenta la soluzione: installare il driver Wacom gratuito anche senza tavoletta e riavviare.
- Con **Sidecar** (la soluzione di Apple) diversi utenti segnalano che Photoshop mostra l'avviso "richiede una tavoletta sensibile alla pressione": il riconoscimento dipende dall'app.

Per questo la consegna non dichiara "pressione garantita in ogni app": dichiara pressione **reale** a livello di sistema, verificabile, e un test documentato per ogni app (docs/TEST.md §5). Una simulazione del mouse non viene mai presentata come pressione: se l'iPad non rileva variazioni di forza (es. Apple Pencil USB-C) la maschera delle capacità **non** dichiara la pressione e la punta invia pressione piena, come un mouse.

---

## 2. Collegamento USB

| Opzione | Esito |
|---|---|
| USB "grezzo" tra app (endpoint bulk) | ❌ Su iPadOS richiede MFi/accessori certificati. |
| Rete USB (tethering / Ethernet over USB) | ❌ Non attivabile dall'app. |
| **usbmuxd** (`/var/run/usbmuxd`) | ✅ Il demone di sistema che Finder e Xcode usano per parlare con iPhone/iPad via cavo. Un'app Mac può chiedergli di aprire una connessione TCP verso una porta dell'iPad; l'app iPad ascolta su `127.0.0.1`. È il metodo di PeerTalk, usato da Duet Display. |

**Scelta:** usbmuxd, implementato da zero in Swift (`Mac/Connection/USBMuxClient.swift`), senza driver né librerie esterne.

Limiti dichiarati:
- il protocollo usbmuxd **non è documentato ufficialmente** da Apple, ma è stabile da oltre 15 anni;
- l'app Mac deve essere **non sandbox** (accesso al socket di sistema) → distribuzione fuori dal Mac App Store (firma Developer ID + notarizzazione);
- l'iPad deve aver autorizzato il Mac ("Autorizza questo computer") almeno una volta;
- l'app iPad deve essere **in primo piano**: iPadOS sospende le app in background.

## 3. Collegamento Wi-Fi

✅ Bonjour + Network.framework, TLS 1.2 con chiave pre-condivisa (TLS-PSK, AES-128-GCM), come nell'esempio Apple per protocolli peer-to-peer. Su piattaforme Apple TLS-PSK è supportato solo in TLS 1.2. Associazione: automatica al primo collegamento USB (canale fisico fidato) oppure con PIN a 6 cifre valido 2 minuti, con blocco dopo 5 tentativi. IP manuale supportato.

## 4. Schermo nero

✅ Una `UIView` nera riceve **tutti** gli eventi della Pencil: lo schermo nero non limita l'input.
⚠️ Ciò che iPadOS non consente: spegnere il pannello lasciando l'app attiva (blocco schermo = app sospesa) e restare in background. Modalità adottata: nero puro (pixel spenti sugli iPad OLED), luminosità ridotta durante la sessione (regolabile), blocco automatico disattivato, overlay minimo semitrasparente. Per evitare uscite accidentali si può usare Accesso Guidato.

## 5. Apple Pencil

| Dato | API | Disponibilità |
|---|---|---|
| X/Y precise | `preciseLocation(in:)` + `coalescedTouches` | ✅ tutte (fino a 240 Hz) |
| Pressione | `force / maximumPossibleForce` | ✅ Pencil 1ª/2ª gen, Pro · ❌ Pencil USB-C (rilevato a runtime) |
| Inclinazione / azimut | `altitudeAngle`, `azimuthAngle(in:)` | ✅ tutte |
| Hover | `UIHoverGestureRecognizer` (`zOffset`, altitudine, azimut) | ✅ solo iPad/Pencil compatibili, rilevato al primo hover |
| Doppio tocco | `UIPencilInteraction` | ✅ Pencil 2 e Pro |
| Squeeze | `UIPencilInteraction.Squeeze` (iPadOS 17.5+) | ✅ Pencil Pro |
| Rotazione (barrel roll) | `UITouch.rollAngle` (17.5+) | ✅ Pencil Pro |

Nessun dato è simulato: ogni capacità viene dichiarata al Mac solo dopo essere stata **osservata** (`iPad/Input/CapabilityDetector.swift`).

## 6. Input su macOS: cosa si può generare

| Funzione | Esito |
|---|---|
| Movimento, click, trascinamento | ✅ `CGEvent` |
| Pressione, inclinazione, rotazione, prossimità, penna/gomma | ✅ eventi tavoletta Quartz (vedi §1) |
| Tasti e combinazioni (anche con layout italiano) | ✅ `CGEvent` + traduzione del layout attivo con `UCKeyTranslate` |
| Scorrimento | ✅ `CGEvent` scroll wheel |
| Gesti nativi del trackpad (pinch/rotazione di sistema) | ❌ non generabili con API pubbliche → il pinch invia scorciatoie di zoom configurabili |
| Dispositivo che macOS elenca come tavoletta HID | ❌ richiede entitlement Apple e oggi non trasmette la pressione (vedi §1-B) |

## 7. Architettura per un driver futuro

Il motore non chiama mai `CGEvent` direttamente: passa da `InputBackend` (`Mac/Input/InputBackend.swift`). Un backend futuro basato su `HIDVirtualDevice` o DriverKit potrà sostituire `CGEventTabletBackend` senza toccare rete, protocollo, profili o interfaccia — quando Apple concederà l'entitlement e il percorso HID trasporterà la pressione.

## 8. Modalità senza app: Safari sull'iPad

Quando sull'iPad non si possono installare app, l'app Mac pubblica una pagina web
(`http://<IP-del-Mac>:47830`) e un WebSocket (porta 47831). Safari invia gli stessi
messaggi binari dell'app iPad: motore, profili ed eventi tavoletta sul Mac sono identici.

| Dato | In Safari | Note |
|---|---|---|
| Posizione, pressione, inclinazione | ✅ Pointer Events (`pressure`, `altitudeAngle`, `azimuthAngle`, `tiltX/Y`) | Safari supera i test di interfaccia del W3C per questi attributi |
| Frequenza | ✅ fino a 240 Hz | `pointermove` della Pencil arriva fino a 240 Hz; `getCoalescedEvents()` è usato se disponibile (Safari 18.2+) |
| Hover | ✅ su iPad/Pencil compatibili | WebKit inoltra l'hover della Pencil come eventi puntatore; rilevato solo dopo una sequenza reale di eventi |
| Doppio tocco, squeeze | ❌ | non esposti alle pagine web |
| Rotazione (barrel roll) | ❌ | in WebKit è solo sperimentale (`twist`) |
| Dita (Touchpad), barra strumenti | ✅ | gesti ricostruiti in JavaScript |
| USB | ❌ | il browser non può usare usbmuxd: solo rete locale |
| Schermo sempre acceso | ⚠️ | la Wake Lock API funziona solo su https: impostare *Blocco automatico: Mai* |
| Cifratura | ⚠️ | http in chiaro sulla rete locale; accesso protetto da codice con challenge HMAC-SHA256 (il codice non viaggia), blocco dopo 5 errori |

## 9. Modalità Display: lo schermo del Mac sull'iPad

| Aspetto | Scelta | Motivo |
|---|---|---|
| Cattura | ✅ ScreenCaptureKit, monitor intero o area (`sourceRect`), cursore incluso | API pubblica e accelerata; invia fotogrammi solo quando lo schermo cambia |
| Formato | JPEG, un fotogramma per messaggio | Il decoder video WebCodecs di Safari funziona solo su https: con la pagina http il JPEG è l'unica via universale |
| Fluidità | Controllo di flusso a conferme (max 2 fotogrammi in volo) | La frequenza si adatta alla rete; l'ultimo fotogramma non viene mai perso |
| Nitidezza | Risoluzione fino a Retina 1:1 e, da fermo, una foto singola a piena risoluzione (SCScreenshotManager) con qualità 95% | Il movimento può viaggiare a risoluzione ridotta senza sacrificare l'immagine ferma |
| Allineamento penna/immagine | ✅ stessa area e stesso adattamento (letterbox) su Mac e iPad | Il punto toccato corrisponde al pixel mostrato |
| Permesso | ⚠️ Registrazione schermo | Dopo averlo concesso l'app va riaperta; macOS Sequoia lo riconferma ogni mese |
| Latenza dell'immagine | ⚠️ maggiore di Sidecar | JPEG su Wi-Fi: tipicamente qualche decina di millisecondi; la penna resta a bassa latenza perché viaggia nell'altra direzione |

---

## 10. Modalità Trackpad

| Opzione di macOS | Come | Limite |
|---|---|---|
| Puntamento, tocco, clic secondario, trascinamento, trascinamento a tre dita | Eventi mouse CGEvent | — |
| Scorrimento (naturale, inerzia) | Eventi di scorrimento continui con le fasi pubbliche kCGScrollWheelEventScrollPhase / MomentumPhase | L'inerzia è calcolata dall'app Mac |
| Zoom con il pizzico | Scorciatoie ⌘+ / ⌘− | I veri eventi di ingrandimento del trackpad non sono generabili con API pubbliche |
| Spaces, pagine, Ricerca | Scorciatoie di sistema ⌃←/⌃→, ⌘[/⌘], ⌃⌘D | Le scorciatoie devono essere attive in Impostazioni → Tastiera |
| Mission Control, Exposé, Mostra scrivania, Launchpad/App | Apertura delle app di sistema con NSWorkspace | — |
| Force Click, Smart zoom, rotazione, Centro Notifiche dal bordo | ❌ | Richiedono eventi del trackpad non pubblici |

## Fonti
- [Apple Developer Forums — HIDVirtualDevice digitizer pen: pressure always 0](https://developer.apple.com/forums/thread/845787)
- [Apple Developer Forums — HID Entitlement Configuration Guide](https://developer.apple.com/forums/thread/843327)
- [Apple Developer Forums — TLS 1.3 with PSK using Network framework](https://developer.apple.com/forums/thread/688508)
- [Astropad — Pen pressure in Adobe Illustrator for macOS](https://help.astropad.com/article/168-illustrator-mojave)
- [PeerTalk (rsms) — comunicazione iOS/macOS via USB](https://github.com/rsms/peertalk)
- [Apple — documentazione CGEventField](https://developer.apple.com/documentation/coregraphics/cgeventfield)
- [Apple — UIPencilInteraction](https://developer.apple.com/documentation/uikit/uipencilinteraction)
- [Apple Developer Forums — Apple Pencil a 240 Hz in Mobile Safari](https://developer.apple.com/forums/thread/689375)
- [Flutter — getCoalescedEvents introdotto in Safari iOS 18.2](https://github.com/flutter/engine/pull/56903)
- [W3C — risultati dei test Pointer Events (gennaio 2026)](https://w3c.github.io/pointereventswg/implementation-reports/wpt-pointerevents-2026-01-25.html)
- [WebKit Bugzilla — hover e rotazione della Apple Pencil nel web](https://bugs.webkit.org/show_bug.cgi?id=296943)
- [MDN — Screen Wake Lock API (solo contesti sicuri)](https://developer.mozilla.org/docs/Web/API/Screen_Wake_Lock_API)
- [MDN — VideoDecoder disponibile solo in contesti sicuri](https://developer.mozilla.org/en-US/docs/Web/API/VideoDecoder/VideoDecoder)
- [Apple — Capturing screen content in macOS (ScreenCaptureKit)](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [9to5Mac — macOS Sequoia: conferma mensile del permesso di registrazione schermo](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/)
