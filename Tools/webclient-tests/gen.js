const L = require('./lib.js');
const out = {};
const hex = u => Buffer.from(u).toString('hex');
out.hmac = L.toHex(L.hmacSha256(L.utf8Enc.encode('482913'), L.utf8Enc.encode('a1b2c3d4e5f60718293a4b5c6d7e8f90')));
out.sha_empty = L.toHex(L.sha256(new Uint8Array(0)));
out.sha_long = L.toHex(L.sha256(L.utf8Enc.encode('x'.repeat(1000))));
out.hmac_longkey = L.toHex(L.hmacSha256(L.utf8Enc.encode('k'.repeat(100)), L.utf8Enc.encode('msg')));
out.hello = hex(L.Codec.hello({deviceID:'ID-1',deviceName:'iPad (Safari)',model:'Web',systemVersion:'Safari 18.2',capabilities:7,width:1194,height:834,scale:2}));
out.pen = hex(L.Codec.penBatch([{seq:5,t:123.456789,x:0.25,y:0.75,p:0.5,alt:1.0,az:3.0,roll:0,hover:0,flags:1|4},
                                 {seq:6,t:123.46,x:0.3,y:0.7,p:1.2,alt:2.0,az:-1.0,roll:0,hover:0,flags:8}]));
out.gesture = hex(L.Codec.gesture(L.GK.scroll, 3.5, -12, 1, 2));
out.button = hex(L.Codec.button(7, true));
out.control = hex(L.Codec.control(L.CMD.setMode, 2));
out.ping = hex(L.Codec.ping(42, 1234.5));
out.pong = hex(L.Codec.pong(42, 1234.5, 99.25));
out.dev = hex(L.Codec.deviceUpdate(3, 834, 1194));
out.bye = hex(L.Codec.bye('fine è'));
out.ack = hex(L.Codec.frameAck(42));
console.log(JSON.stringify(out));
