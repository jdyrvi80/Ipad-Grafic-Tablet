const fs = require('fs');
// Riusa l'impianto dello smoke test principale fino alla sessione attiva.
let src = fs.readFileSync('smoke.js', 'utf8');
const cut = src.indexOf('  // Superficie: dimensioni simulate');
src = src.slice(0, cut) + `
  const surf = d.getElementById('surface');
  surf.getBoundingClientRect = () => ({ left: 0, top: 0, width: 1000, height: 800 });
  w.dispatchEvent(new w.Event('resize'));
  sock.onmessage({ data: new Uint8Array(Buffer.from(fs.readFileSync('touch_cfg.hex','utf8'), 'hex')).buffer });
  w.performance.now = (() => { let t = 100000; return () => (t += 1); })();   // orologio controllato
  sent.length = 0;
  const T = (type, id, x, y, extra) => surf.dispatchEvent(pe(type, Object.assign({ pointerId: id, pointerType: 'touch', clientX: x, clientY: y }, extra || {})));
  // tocco singolo = clic
  T('pointerdown', 1, 100, 100); T('pointerup', 1, 100, 100);
  // 1 dito che scorre = movimento cursore
  T('pointerdown', 2, 100, 100); T('pointermove', 2, 130, 100); T('pointermove', 2, 140, 110); T('pointerup', 2, 140, 110);
  // 2 dita che scorrono = scroll, poi fine gesto
  T('pointerdown', 3, 100, 100); T('pointerdown', 4, 200, 100);
  T('pointermove', 3, 100, 140); T('pointermove', 4, 200, 140);
  T('pointerup', 3, 100, 140); T('pointerup', 4, 200, 140);
  // palmo (contatto ampio) ignorato
  T('pointerdown', 5, 500, 500, { width: 200, height: 180 }); T('pointerup', 5, 500, 500, { width: 200, height: 180 });
  const kinds = decodeSent().filter(f => f.type === 5).map(f => f.payload[0]);
  console.log('gesti:', kinds.join(','));
  check('clic', kinds[0] === 1);
  check('movimento cursore dopo la soglia', kinds.includes(0));
  check('scroll a due dita', kinds.includes(7));
  check('fine gesto', kinds[kinds.length - 1] === 9);
  check('palmo ignorato (nessun clic in più)', kinds.filter(k => k === 1).length === 1);
  // ── Trackpad: aspetto e menu
  check('superficie trackpad visibile', d.body.classList.contains('trackpad'));
  check('menu: Trackpad selezionato', d.getElementById('mTrackpad').classList.contains('on'));
  const G = () => decodeSent().filter(f => f.type === 5).map(f => {
    const v = new DataView(f.payload.buffer, f.payload.byteOffset, f.payload.byteLength);
    return { kind: v.getUint8(0), dx: v.getFloat32(1, true), dy: v.getFloat32(5, true), scale: v.getFloat32(9, true), fingers: v.getUint8(13) };
  });
  const near = (a, b) => Math.abs(a - b) < 1e-3;
  // tocco nell'angolo in basso a destra: il clic porta la posizione (per il clic secondario)
  sent.length = 0;
  T('pointerdown', 10, 900, 700); T('pointerup', 10, 900, 700);
  let gs = G();
  check('clic con posizione del tocco', gs.length === 1 && gs[0].kind === 1 && near(gs[0].dx, 0.9) && near(gs[0].dy, 0.875));
  // tocco con tre dita = Ricerca
  sent.length = 0;
  T('pointerdown', 11, 300, 300); T('pointerdown', 12, 400, 300); T('pointerdown', 13, 500, 300);
  T('pointerup', 11, 300, 300); T('pointerup', 12, 400, 300); T('pointerup', 13, 500, 300);
  gs = G();
  // (il gestureEnd iniziale chiude la fase a due dita, prima che arrivi la terza)
  const k3 = gs.map(x => x.kind).filter(k => k !== 9);
  check('tre dita: tocco', JSON.stringify(k3) === '[17,15]' && gs.find(x => x.kind === 17).fingers === 3);
  // tre dita verso l'alto = movimento multiplo (Mission Control sul Mac)
  sent.length = 0;
  T('pointerdown', 14, 300, 500); T('pointerdown', 15, 400, 500); T('pointerdown', 16, 500, 500);
  for (let y = 480; y >= 380; y -= 20) { T('pointermove', 14, 300, y); T('pointermove', 15, 400, y); T('pointermove', 16, 500, y); }
  T('pointerup', 14, 300, 380); T('pointerup', 15, 400, 380); T('pointerup', 16, 500, 380);
  gs = G();
  const moves = gs.filter(x => x.kind === 14);
  const up = moves.reduce((acc, x) => acc + x.dy, 0);
  check('tre dita: spostamento verso l alto', moves.length > 0 && moves.every(x => x.fingers === 3) && near(up, -120));
  check('tre dita: nessun tocco né clic', !gs.some(x => x.kind === 17 || x.kind === 1 || x.kind === 2));
  check('tre dita: fine gesto', gs[gs.length - 1].kind === 15);
  // pollice e tre dita che si avvicinano = pizzico a quattro dita (Launchpad sul Mac)
  sent.length = 0;
  const P = [[200, 200], [600, 200], [200, 600], [600, 600]];
  P.forEach((p, i) => T('pointerdown', 20 + i, p[0], p[1]));
  for (let k = 1; k <= 4; k++) P.forEach((p, i) => T('pointermove', 20 + i, p[0] + (400 - p[0]) * k / 8, p[1] + (400 - p[1]) * k / 8));
  P.forEach((p, i) => T('pointerup', 20 + i, 400, 400));
  gs = G();
  const pinch = gs.filter(x => x.kind === 16);
  const total = pinch.reduce((acc, x) => acc * x.scale, 1);
  check('quattro dita: pizzico', pinch.length > 0 && pinch.every(x => x.fingers === 4) && near(total, 0.5));
  // due dita che si appoggiano e poi una terza: il gesto diventa a tre dita
  sent.length = 0;
  T('pointerdown', 30, 300, 300); T('pointerdown', 31, 400, 300); T('pointerdown', 32, 500, 300);
  T('pointermove', 30, 330, 300); T('pointermove', 31, 430, 300); T('pointermove', 32, 530, 300);
  T('pointerup', 30, 330, 300); T('pointerup', 31, 430, 300); T('pointerup', 32, 530, 300);
  gs = G();
  check('due → tre dita', gs.some(x => x.kind === 14 && x.fingers === 3) && !gs.some(x => x.kind === 7));

  console.log(results.every(Boolean) ? '\\nTOUCH TEST OK' : '\\nTOUCH TEST FALLITO');
  process.exit(results.every(Boolean) ? 0 : 1);
}, 20);
`;
fs.writeFileSync('smoke_touch_run.js', src);
