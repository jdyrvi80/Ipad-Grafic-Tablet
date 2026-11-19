# Protocollo di comunicazione (v1)

Binario, little-endian, su TCP (Nagle disattivato). Implementazione: `Shared/Sources/TabletCore/Messages.swift`.

## Trasporti e porte

| Collegamento | Chi ascolta | Porta | Sicurezza |
|---|---|---|---|
| USB | iPad, `127.0.0.1` | 47820 | canale fisico usbmuxd (iPad autorizzato) |
| Wi-Fi sessioni | Mac, tutte le interfacce, Bonjour `_ipadtablet._tcp` | 47821 | TLS 1.2 PSK, chiave a lungo termine 256 bit |
| Wi-Fi associazione | Mac, solo su richiesta per 120 s, Bonjour `_ipadtablet-pair._tcp` | 47822 | TLS 1.2 PSK, chiave = HKDF-SHA256(PIN) |
| Safari — pagina | Mac, HTTP | 47830 | nessuna (serve solo `WebClient.html`) |
| Safari — dati | Mac, WebSocket | 47831 | challenge HMAC-SHA256 con codice a 6 cifre, traffico in chiaro |

Record TXT Bonjour: `id` = identificativo del Mac, `v` = versione protocollo.
Ciphersuite: `TLS_PSK_WITH_AES_128_GCM_SHA256`, identità PSK `ipad-graphic-tablet/v1`.

## Frame

```
u32  lunghezza  (= 1 + byte del payload, max 512 KB)
u8   tipo
...  payload
```

Tipi primitivi: `u8/u16/u32/u64`, `i32`, `f32/f64` IEEE-754, `bool` (u8 0/1),
`string` = u16 lunghezza + UTF-8, `blob` = u32 lunghezza + byte.

## Messaggi

| Tipo | Nome | Direzione | Payload |
|---|---|---|---|
| 1 | hello | iPad→Mac | u16 versione, string deviceID, string nome, string modello, string iPadOS, u16 capacità, f32 larghezza pt, f32 altezza pt, f32 scala |
| 2 | welcome | Mac→iPad | u16 versione, string macID, string nome Mac, bool accettato, string motivo |
| 3 | sessionConfig | Mac→iPad | u8 modalità, string profilo, string monitor, 4×f32 area input (non ruotata), bool mostra area, bool mancino, bool barra visibile, u16 N + N×(u16 id, string etichetta, string simbolo, bool hold), bool cursore bloccato, bool precisione, bool palm rejection, bool gomma, bool permesso Accessibilità, f32 RTT ms |
| 4 | penBatch | iPad→Mac | u16 N + N × campione (32 byte) |
| 5 | gesture | iPad→Mac | u8 tipo, f32 dx, f32 dy, f32 scala, u8 dita |
| 6 | button | iPad→Mac | u16 id, bool premuto |
| 7 | pencilGesture | iPad→Mac | u8 tipo (0 doppio tocco, 1 squeeze), u8 fase (0 began … 3 cancelled) |
| 8 | control | iPad→Mac | u8 comando, i32 valore |
| 9 | ping | entrambi | u32 id, f64 istante invio |
| 10 | pong | entrambi | u32 id, f64 istante invio (eco), f64 istante ricezione del peer |
| 11 | pairingKey | Mac→iPad | string macID, string nome, blob chiave (32 byte) |
| 12 | deviceUpdate | iPad→Mac | u16 capacità, f32 larghezza, f32 altezza |
| 13 | bye | entrambi | string motivo |
| 14 | videoFrame | Mac→iPad | u32 id, f64 istante di cattura, u16 larghezza, u16 altezza, u8 formato (1 = JPEG), blob immagine, NormRect area del monitor contenuta |
| 15 | frameAck | iPad→Mac | u32 id del fotogramma mostrato (o scartato) |

`sessionConfig` termina con i campi della modalità Display: `bool mirrorActive`, `string mirrorStatus`,
`NormRect mirrorRegion` (area del monitor mostrata ora). Il client disegna ogni fotogramma nella posizione
`(area del fotogramma − mirrorRegion) / mirrorRegion`: dopo uno zoom l'immagine si adatta subito, prima
che arrivi il fotogramma nuovo.

**Gesti (tipo 5) in modalità Display:** un dito si comporta come un trackpad (`pointerMove` 0 relativo,
movimento relativo); i tocchi cliccano nel punto toccato: `tapAt` (11), `doubleTapAt` (12, secondo tocco entro
450 ms, posizione del primo) e `rightTapAt` (13, due dita), con dx, dy = posizione normalizzata 0…1;
`pointTo` (10) resta supportato ma i client attuali non lo usano;
in modalità Trackpad `leftClick` (1) porta in dx, dy la posizione normalizzata del tocco (clic secondario negli angoli);
gesti a tre o più dita: `multiMove` (14, dx, dy = spostamento del centro, fingers = dita), `multiEnd` (15),
`multiPinch` (16, scale relativa, quattro o più dita), `threeFingerTap` (17). Il Mac decide l'azione secondo
le opzioni del Trackpad (un'azione per gesto); `scroll` (7) sposta l'area; `pinch` (8) la ingrandisce
con dx, dy = centro delle dita normalizzato. Lo zoom e lo spostamento li calcola il Mac (`DisplayViewport`),
che rimanda subito `sessionConfig` con la nuova area.
I client li leggono solo se presenti, quindi restano compatibili con messaggi senza questi campi.

**Controllo di flusso dello schermo:** il Mac tiene al massimo 2 fotogrammi senza conferma; quelli nuovi
sostituiscono il "fotogramma in attesa", che parte appena arriva un `frameAck`. Il client conferma ogni
fotogramma ricevuto, anche quelli che scarta perché ne è già arrivato uno più recente.

### Campione penna (32 byte)

| Offset | Tipo | Campo |
|---|---|---|
| 0 | u32 | sequenza (assegnata all'invio) |
| 4 | f64 | timestamp `UITouch.timestamp` (s) |
| 12 | f32 | x normalizzata 0…1 |
| 16 | f32 | y normalizzata 0…1 |
| 20 | u16 | pressione 0…1 (×65535), grezza |
| 22 | u16 | altitudine 0…π/2 |
| 24 | u16 | azimut 0…2π |
| 26 | u16 | rotazione 0…2π |
| 28 | u16 | distanza hover 0…1 |
| 30 | u8 | flag: 1 contatto · 2 hover · 4 inizio tratto · 8 fine tratto · 16 annullato · 32 predetto · 64 pressione stimata · 128 fuori portata |
| 31 | u8 | riservato |

Capacità (u16): 1 pressione · 2 inclinazione · 4 hover · 8 rotazione · 16 doppio tocco · 32 squeeze · 64 multitouch · 128 mostra lo schermo (modalità Display) · 256 OS con hover · 512 OS con squeeze.

Modalità (u8): 0 Tavoletta · 1 Schermo · 2 Photoshop · 3 Touchpad · 4 Display.

## Sequenza tipica

```
iPad                                   Mac
 │── hello ───────────────────────────▶│  verifica versione, sceglie sessione attiva
 │◀────────────────────────── welcome ─│
 │◀─────────── pairingKey (solo USB) ──│  associazione Wi-Fi automatica
 │◀──────────────────── sessionConfig ─│  modalità, barra, area
 │── penBatch / gesture / button ─────▶│  → eventi macOS
 │◀──── ping ── pong ──▶ (ogni 1–2 s)  │  RTT + offset orologi
 │── deviceUpdate (capacità/rotazione)▶│  → riannuncio prossimità
 │── bye ─────────────────────────────▶│
```

## Compatibilità
Un `hello` con versione diversa riceve `welcome(accettato: false)` e la connessione viene chiusa. Ogni modifica incompatibile incrementa `TabletWire.protocolVersion`.

## Trasporto WebSocket (Safari)

1. Il Mac invia un messaggio di testo `{"t":"auth","nonce":"<32 cifre esadecimali>"}`.
2. La pagina risponde `{"t":"auth","proof":"<hex HMAC-SHA256(chiave = codice, messaggio = nonce)>"}`.
3. Il Mac risponde `{"t":"ok"}` oppure `{"t":"denied","reason":"…"}` e chiude (5 errori in 5 minuti → blocco 60 s).
4. Da qui ogni messaggio **binario** WebSocket contiene uno o più frame del protocollo descritto sopra,
   identici a quelli dell'app iPad (`hello`, `penBatch`, …). Il Mac invia un frame per messaggio.

Il client web usa `performance.now()` / `event.timeStamp` come orologio: i campioni e i `pong`
condividono la stessa base, quindi la stima della latenza penna → Mac funziona come con l'app.
