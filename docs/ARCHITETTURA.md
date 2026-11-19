# Architettura

```
┌───────────────────────── iPad (iPadOS 17+) ─────────────────────────┐
│ PencilSurfaceView (UIKit)                                            │
│  touches + coalesced (240 Hz) · hover · double tap · squeeze · dita  │
│        │                                                             │
│ TabletInputController — numerazione campioni, rilevamento capacità,  │
│        │                 frequenza adattiva dell'hover               │
│ PadConnectionManager — USB: listener 127.0.0.1:47820                 │
│                        Wi-Fi: Bonjour + TLS-PSK, PIN, IP manuale     │
└────────┼─────────────────────────────────────────────────────────────┘
         │  protocollo binario (TabletCore) su TCP
         │  USB: tunnel usbmuxd  ·  Wi-Fi: TLS 1.2 PSK
         │  (in alternativa all'app: Safari → WebClient.html → stessi frame su WebSocket)
┌────────┼─────────────────────── Mac (macOS 14+) ─────────────────────┐
│ USBMuxClient / WiFiServer → PeerChannel → ConnectionManager           │
│        │  (handshake, priorità USB, ping, associazione)               │
│ TabletEngine — stabilizzatore 1€ → rotazione → mapping assoluto /     │
│        │       relativo / precisione → curva di pressione → tilt →    │
│        │       macchina a stati (prossimità, punta, gomma) → tasti    │
│ InputBackend ← CGEventTabletBackend (oggi) / backend HID (futuro)     │
│        │                                                             │
│ AppState + SwiftUI (dashboard, barra dei menu, test pressione)        │
└──────────────────────────────────────────────────────────────────────┘
```

## Moduli

| Cartella | Contenuto | Dipendenze |
|---|---|---|
| `Shared/Sources/TabletCore` | Protocollo binario, framing, campioni, geometria, curva di pressione, stabilizzatore, profili, statistiche di latenza | solo Foundation (compila anche su Linux: `swift test`) |
| `Shared/Sources/TabletLink` | Trasporto (NWConnection), canale di messaggi, TLS-PSK, Portachiavi, log | Network, CryptoKit, Security |
| `Mac/Connection` | usbmuxd, server Wi-Fi, server pagina/WebSocket per Safari, sessioni e priorità | TabletLink |
| `Mac/Resources/WebClient.html` | Client per Safari in un solo file (vanilla JS): Pointer Events → stesso protocollo binario | nessuna |
| `Mac/Input` | Backend eventi, layout tastiera, monitor, permessi | CoreGraphics, Carbon (solo layout) |
| `Mac/Capture` | Modalità Display: cattura con ScreenCaptureKit, JPEG, controllo di flusso, selezione dell'area | ScreenCaptureKit, CoreImage |
| `Mac/Engine` | Motore, mapping, salvataggio profili | — |
| `Mac/UI`, `Mac/App` | SwiftUI: dashboard, impostazioni, test, barra dei menu | SwiftUI, AppKit |
| `iPad/Input` | Cattura Pencil, capacità, calibrazione, controller | UIKit |
| `iPad/Connection` | USB loopback, Bonjour, associazione, riconnessione | TabletLink |
| `iPad/UI`, `iPad/App` | Schermata di connessione, sessione nera, barra strumenti, calibrazione | SwiftUI |

## Scelte di progetto

**Una sola coda seriale sul Mac** (`tablet.core`, QoS userInteractive) per rete e motore: niente lock sul percorso critico, ordine degli eventi garantito.

**TCP con Nagle disattivato** invece di UDP: il requisito "nessuna perdita di eventi" esclude UDP senza ritrasmissione. In caso di congestione Wi-Fi l'iPad dirada **solo l'hover** (fino a 60 Hz o sospeso oltre 64 KB in coda); i campioni a contatto non vengono mai scartati. I numeri di sequenza permettono al Mac di contare eventuali buchi (mostrati in Test e diagnostica).

**Pressione grezza dall'iPad, curva sul Mac**: il profilo vive in un solo posto e si cambia senza toccare l'iPad.

**Capacità osservate, mai presunte**: la maschera di prossimità dichiarata alle app riflette solo ciò che l'iPad ha davvero rilevato; quando cambia, la prossimità viene riannunciata.

**Tastiera**: le scorciatoie preconfigurate sono definite per carattere (`[`, `]`, `+`, `z`…) e tradotte nel tasto fisico del layout attivo; quelle registrate dall'utente salvano il tasto fisico premuto.

**Penna ↔ gomma**: invece di simulare il tasto E, il Mac può riannunciare il puntatore come `eraser` negli eventi di prossimità, come una Wacom girata (le app che lo supportano cambiano strumento da sole).

## Estensione futura: backend HID

`InputBackend` definisce prossimità, eventi penna, mouse, scroll e tasti. Un `HIDVirtualDeviceBackend` dovrà:
1. creare un digitizer HID (Usage Page 0x0D, Pen) con Tip Switch, In Range, X/Y, Tip Pressure, X/Y Tilt;
2. tradurre `PenEventData` in report HID;
3. lasciare a `CGEventTabletBackend` mouse e tastiera.

Prerequisiti: entitlement `com.apple.developer.hid.virtual.device` concesso da Apple e correzione del bug che oggi azzera la pressione dei digitizer HID virtuali (vedi FATTIBILITA.md §1).
