# Test del client web (Safari)

Verificano `Mac/Resources/WebClient.html` senza iPad:

- `check.py` — i frame prodotti dal JavaScript vengono decodificati da un decoder Python scritto
  dalla specifica (docs/PROTOCOLLO.md); SHA-256/HMAC confrontati con la libreria standard Python.
- `dec.js` — il JavaScript decodifica messaggi Mac → iPad (welcome, sessionConfig, ping) spezzati a pezzi da 7 byte.
- `smoke.js` — pagina caricata in un DOM simulato con un Mac finto: autenticazione HMAC, hello,
  sessione, tratto di penna con eventi coalescenti, pressione, sequenze, barra strumenti.
- `smoke_touch.js` — gesti della modalità Touchpad e palm rejection.

```
npm install
npm test
```
