// Prova end-to-end della pagina in un DOM simulato: Mac finto via WebSocket finto.
const { JSDOM } = require('jsdom');
const fs = require('fs');
const crypto = require('crypto');
const L = require('./lib.js');
const html = fs.readFileSync(require('path').join(__dirname,'../../Mac/Resources/WebClient.html'), 'utf8');

const sent = [];        // frame binari e testi inviati dalla pagina
let sock = null;
class FakeWS {
  constructor(url) { this.url = url; this.readyState = 1; this.bufferedAmount = 0; sock = this;
    setTimeout(() => this.onmessage({ data: JSON.stringify({ t: 'auth', nonce: 'NONCE123' }) }), 0); }
  send(d) { sent.push(d); }
  close() { this.readyState = 3; this.onclose && this.onclose(); }
}
const dom = new JSDOM(html, {
  url: 'http://192.168.1.20:47830/#code=482913', runScripts: 'dangerously', pretendToBeVisual: true,
  beforeParse(w) {
    w.WebSocket = FakeWS;
    w.TextEncoder = TextEncoder; w.TextDecoder = TextDecoder;
    Object.defineProperty(w, 'crypto', { value: { getRandomValues: a => crypto.randomFillSync(a) } });
    w.HTMLElement.prototype.setPointerCapture = function () {};
    w.HTMLElement.prototype.requestFullscreen = function () { return Promise.resolve(); };
  },
});
const w = dom.window, d = w.document;
const results = [];
const check = (name, cond) => { results.push(cond); console.log((cond ? 'OK  ' : 'FAIL') + ' ' + name); };

function pe(type, props) {
  const e = new w.Event(type, { bubbles: true, cancelable: true });
  Object.assign(e, { pointerId: 1, pointerType: 'pen', clientX: 0, clientY: 0, pressure: 0, buttons: 0,
                     altitudeAngle: 1.2, azimuthAngle: 0.5, tiltX: 0, tiltY: 0, width: 1, height: 1 }, props);
  Object.defineProperty(e, 'timeStamp', { value: props.ts || 1000 });
  return e;
}
const decodeSent = () => {
  const out = [];
  const dec = new L.FrameDecoder();
  for (const s of sent) if (typeof s !== 'string') for (const f of dec.push(s)) out.push(f);
  return out;
};

check('il codice dal link è precompilato', d.getElementById('code').value === '482913');
check('URL WebSocket = porta+1', true);
d.getElementById('connectBtn').click();
setTimeout(() => {
  check('URL socket', sock && sock.url === 'ws://192.168.1.20:47831/');
  const auth = JSON.parse(sent[0]);
  const expected = crypto.createHmac('sha256', '482913').update('NONCE123').digest('hex');
  check('prova HMAC corretta (il codice non viaggia)', auth.t === 'auth' && auth.proof === expected && !sent[0].includes('482913'));
  sock.onmessage({ data: JSON.stringify({ t: 'ok' }) });
  const frames1 = decodeSent();
  check('hello inviato dopo l\'autenticazione', frames1.length === 1 && frames1[0].type === 1);

  // welcome + config dal "Mac"
  const hexStream = fs.readFileSync('mac_stream.hex', 'utf8');
  sock.onmessage({ data: new Uint8Array(Buffer.from(hexStream, 'hex')).buffer });
  check('sessione attiva (schermo nero)', d.body.classList.contains('session'));
  check('nessuna barra strumenti sull iPad', d.querySelectorAll('#toolbar, .key').length === 0);
  check('pong al ping del Mac', decodeSent().some(f => f.type === 10));

  // Superficie: dimensioni simulate
  const surf = d.getElementById('surface');
  surf.getBoundingClientRect = () => ({ left: 0, top: 0, width: 1000, height: 800 });
  w.dispatchEvent(new w.Event('resize'));
  sent.length = 0;

  // Tratto della penna
  surf.dispatchEvent(pe('pointerdown', { clientX: 100, clientY: 200, pressure: 0.2, buttons: 1, ts: 1000 }));
  const mv = pe('pointermove', { clientX: 110, clientY: 205, pressure: 0.6, buttons: 1, ts: 1008 });
  mv.getCoalescedEvents = () => [pe('pointermove', { clientX: 105, clientY: 202, pressure: 0.4, buttons: 1, ts: 1004 }),
                                pe('pointermove', { clientX: 110, clientY: 205, pressure: 0.6, buttons: 1, ts: 1008 })];
  surf.dispatchEvent(mv);
  surf.dispatchEvent(pe('pointerup', { clientX: 110, clientY: 205, pressure: 0, buttons: 0, ts: 1012 }));

  const frames = decodeSent();
  const pens = frames.filter(f => f.type === 4);
  check('3 batch penna (giù, movimento con 2 campioni coalescenti, su)', pens.length === 3);
  const sample = (f, i) => { const v = new DataView(f.payload.buffer, f.payload.byteOffset + 2 + i * 32, 32);
    return { seq: v.getUint32(0, true), t: v.getFloat64(4, true), x: v.getFloat32(12, true), y: v.getFloat32(16, true),
             p: v.getUint16(20, true) / 65535, flags: v.getUint8(30) }; };
  const s0 = sample(pens[0], 0), s1 = sample(pens[1], 0), s2 = sample(pens[1], 1), s3 = sample(pens[2], 0);
  check('primo campione: contatto + inizio, x=0.1 y=0.25', s0.flags === 5 && Math.abs(s0.x - 0.1) < 1e-6 && Math.abs(s0.y - 0.25) < 1e-6);
  check('coalescenti in un solo batch', new DataView(pens[1].payload.buffer, pens[1].payload.byteOffset).getUint16(0, true) === 2);
  check('pressione trasmessa (0.4 / 0.6)', Math.abs(s1.p - 0.4) < 1e-4 && Math.abs(s2.p - 0.6) < 1e-4);
  check('sequenza crescente', s1.seq === s0.seq + 1 && s2.seq === s1.seq + 1 && s3.seq === s2.seq + 1);
  check('timestamp in secondi', Math.abs(s0.t - 1.0) < 1e-9 && Math.abs(s3.t - 1.012) < 1e-9);
  check('ultimo campione: fine tratto senza contatto', s3.flags === 8 && s3.p === 0);
  check('capacità aggiornate (tilt + pressione)', frames.some(f => f.type === 12));

  // Dita ignorate fuori dalla modalità Touchpad
  sent.length = 0;
  surf.dispatchEvent(pe('pointerdown', { pointerId: 9, pointerType: 'touch', clientX: 500, clientY: 500 }));
  surf.dispatchEvent(pe('pointerup', { pointerId: 9, pointerType: 'touch', clientX: 500, clientY: 500 }));
  check('dita ignorate in modalità Photoshop', decodeSent().length === 0);


  console.log(results.every(Boolean) ? '\nSMOKE TEST OK' : '\nSMOKE TEST FALLITO');
  process.exit(results.every(Boolean) ? 0 : 1);
}, 20);
