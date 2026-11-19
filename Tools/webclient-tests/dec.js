const L=require('./lib.js'); const fs=require('fs');
const buf=Buffer.from(fs.readFileSync('mac_stream.hex','utf8'),'hex');
const d=new L.FrameDecoder(); let msgs=[];
for(let i=0;i<buf.length;i+=7){ msgs=msgs.concat(d.push(new Uint8Array(buf.subarray(i,i+7)))); }
const out=msgs.map(f=>L.Codec.decode(f.type,f.payload));
console.log(JSON.stringify(out));
const c=out[1];
const ok = out.length===3 && out[0].accepted===true && out[0].macName==='MacBook Pro di Jody'
 && c.mode===2 && c.profileName==='Photoshop Retouching' && Math.abs(c.rect.w-0.8)<1e-6 && c.showRect===true && c.leftHanded===false
 && c.toolbar.length===2 && c.toolbar[1].hold===true && c.toolbar[1].id===8 && c.locked===false && c.precision===true
 && c.palm===true && c.eraser===false && c.canPost===true && Math.abs(c.rtt-3.5)<1e-6 && out[2].id===7 && out[2].sentAt===55.5
 && d.buf.length===0;
console.log(ok?'JS DECODE OK':'JS DECODE FAIL');
process.exit(ok?0:1);
