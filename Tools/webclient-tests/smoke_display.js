// Modalità Display: schermo del Mac, zoom/spostamento dell'area e dita.
const fs = require('fs');
let src = fs.readFileSync('smoke.js', 'utf8');
src = src.replace("w.HTMLElement.prototype.setPointerCapture = function () {};",
  "w.HTMLElement.prototype.setPointerCapture = function () {};\n" +
  "    w.createImageBitmap = async () => ({ width: 1600, height: 1200, close() {} });\n" +
  "    w.HTMLCanvasElement.prototype.getContext = function () { return ctx2d; };");
src = "let draws = []; let fills = 0;\n" +
      "const ctx2d = { fillStyle: '', fillRect() { fills++; }, drawImage(img, x, y, w, h) { draws.push([x, y, w, h]); } };\n" + src;
const cut = src.indexOf('  // Superficie: dimensioni simulate');
src = src.slice(0, cut) + `
  const hex = name => new Uint8Array(Buffer.from(fs.readFileSync(name, 'utf8'), 'hex')).buffer;
  const near = (a, b) => Math.abs(a - b) < 1e-3;
  const gestures = () => decodeSent().filter(f => f.type === L.MT.gesture).map(f => {
    const v = new DataView(f.payload.buffer, f.payload.byteOffset, f.payload.byteLength);
    return { kind: v.getUint8(0), dx: v.getFloat32(1, true), dy: v.getFloat32(5, true), scale: v.getFloat32(9, true) };
  });
  sent.length = 0;
  sock.onmessage({ data: hex('display_stream.hex') });
  setTimeout(() => {
    const cv = d.getElementById('screen');
    check('modalità Display attiva', d.body.classList.contains('mirror'));
    check('canvas posizionato sull area', near(parseFloat(cv.style.top), 10) && near(parseFloat(cv.style.height), 80));
    check('fotogramma disegnato a tutta area', draws.length === 1 && JSON.stringify(draws[0]) === '[0,0,1600,1200]'
          && cv.width === 1600 && cv.height === 1200);
    check('canvas visibile', cv.classList.contains('ready'));
    const acks = decodeSent().filter(f => f.type === 15).map(f => new DataView(f.payload.buffer, f.payload.byteOffset).getUint32(0, true));
    check('conferma del fotogramma 42', JSON.stringify(acks) === '[42]');
    check('messaggio di attesa nascosto', !d.getElementById('mirrorMsg').classList.contains('visible'));

    // Zoom deciso dal Mac: il fotogramma vecchio si adatta subito alla nuova area (2×, centrato).
    sock.onmessage({ data: hex('display_zoom.hex') });
    const last = draws[draws.length - 1];
    check('ridisegno immediato dopo lo zoom', draws.length === 2 && fills === 1);
    check('fotogramma ingrandito 2× attorno al centro', near(last[0], -800) && near(last[1], -600) && near(last[2], 3200) && near(last[3], 2400));

    // Dita: un dito è un trackpad (movimento relativo), tocco = clic, doppio tocco = doppio clic.
    const surf = d.getElementById('surface');
    surf.getBoundingClientRect = () => ({ left: 0, top: 0, width: 1000, height: 800 });
    w.dispatchEvent(new w.Event('resize'));
    let clock = 200000;
    w.performance.now = () => clock;
    const T = (type, id, x, y, extra) => surf.dispatchEvent(pe(type, Object.assign({ pointerId: id, pointerType: 'touch', clientX: x, clientY: y, width: 40, height: 40 }, extra || {})));
    sent.length = 0;
    T('pointerdown', 21, 250, 200); clock += 20;
    T('pointermove', 21, 270, 200); clock += 20;
    T('pointermove', 21, 300, 230); clock += 20;
    T('pointerup', 21, 300, 230);
    let gs = gestures();
    check('dito: nessun salto assoluto', !gs.some(x => x.kind === 10));
    check('dito: movimento relativo', gs.length === 2 && gs.every(x => x.kind === 0) && near(gs[1].dx, 30) && near(gs[1].dy, 30));
    check('dito che scorre: nessun clic', !gs.some(x => x.kind === 1 || x.kind === 3 || x.kind === 4));

    clock += 1000; sent.length = 0;
    T('pointerdown', 22, 400, 400); clock += 60; T('pointerup', 22, 400, 400);
    gs = gestures();
    check('tocco = clic nel punto toccato', gs.length === 1 && gs[0].kind === 11 && near(gs[0].dx, 0.4) && near(gs[0].dy, 0.5));

    clock += 1000; sent.length = 0;
    T('pointerdown', 23, 400, 400); clock += 60; T('pointerup', 23, 400, 400); clock += 200;
    T('pointerdown', 24, 404, 402); clock += 60; T('pointerup', 24, 404, 402);
    gs = gestures();
    check('doppio tocco = clic + doppio clic nello stesso punto', JSON.stringify(gs.map(x => x.kind)) === '[11,12]'
          && near(gs[1].dx, 0.4) && near(gs[1].dy, 0.5));

    // Tocco con due dita = clic destro tra le dita.
    clock += 1000; sent.length = 0;
    T('pointerdown', 26, 600, 400); T('pointerdown', 27, 700, 400); clock += 80;
    T('pointerup', 26, 600, 400); T('pointerup', 27, 700, 400);
    gs = gestures();
    const rt = gs.find(x => x.kind === 13);
    check('due dita: clic destro nel punto toccato', !!rt && near(rt.dx, 0.65) && near(rt.dy, 0.5) && !gs.some(x => x.kind === 2));

    clock += 1000; sent.length = 0;
    T('pointerdown', 25, 400, 400); clock += 600; T('pointerup', 25, 400, 400);
    check('dito tenuto fermo: nessun trascinamento né clic', gestures().length === 0);
    clock += 1000;

    // Due dita: spostamento e pizzico con il centro delle dita.
    sent.length = 0;
    surf.dispatchEvent(pe('pointerdown', { pointerId: 31, pointerType: 'touch', clientX: 400, clientY: 400, width: 10, height: 10 }));
    surf.dispatchEvent(pe('pointerdown', { pointerId: 32, pointerType: 'touch', clientX: 600, clientY: 400, width: 10, height: 10 }));
    surf.dispatchEvent(pe('pointermove', { pointerId: 32, pointerType: 'touch', clientX: 700, clientY: 400, width: 10, height: 10 }));
    surf.dispatchEvent(pe('pointerup', { pointerId: 31, pointerType: 'touch', clientX: 400, clientY: 400 }));
    surf.dispatchEvent(pe('pointerup', { pointerId: 32, pointerType: 'touch', clientX: 700, clientY: 400 }));
    gs = gestures();
    const pinch = gs.find(x => x.kind === 8);
    const scroll = gs.find(x => x.kind === 7);
    check('due dita: spostamento', !!scroll && near(scroll.dx, 50));
    check('due dita: pizzico con centro normalizzato', !!pinch && near(pinch.scale, 1.5) && near(pinch.dx, 0.55) && near(pinch.dy, 0.5));
    check('due dita: fine gesto', gs.some(x => x.kind === 9));

    console.log(results.every(Boolean) ? '\\nDISPLAY TEST OK' : '\\nDISPLAY TEST FALLITO');
    process.exit(results.every(Boolean) ? 0 : 1);
  }, 30);
}, 20);
`;
fs.writeFileSync('smoke_display_run.js', src);
