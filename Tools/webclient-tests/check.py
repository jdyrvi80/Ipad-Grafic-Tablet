import json, struct, hmac, hashlib, math
o = json.load(open('js_out.json'))
ok = True
def chk(name, cond):
    global ok
    print(('OK  ' if cond else 'FAIL'), name); ok &= cond
chk('hmac', o['hmac'] == hmac.new(b'482913', b'a1b2c3d4e5f60718293a4b5c6d7e8f90', hashlib.sha256).hexdigest())
chk('sha empty', o['sha_empty'] == hashlib.sha256(b'').hexdigest())
chk('sha 1000', o['sha_long'] == hashlib.sha256(b'x'*1000).hexdigest())
chk('hmac long key', o['hmac_longkey'] == hmac.new(b'k'*100, b'msg', hashlib.sha256).hexdigest())

# Decoder di riferimento scritto dalla specifica Swift (Messages.swift / PenSample.swift)
class R:
    def __init__(s,b): s.b=b; s.o=0
    def take(s,n):
        assert s.o+n<=len(s.b), 'troncato'; v=s.b[s.o:s.o+n]; s.o+=n; return v
    def u8(s): return s.take(1)[0]
    def u16(s): return struct.unpack('<H',s.take(2))[0]
    def u32(s): return struct.unpack('<I',s.take(4))[0]
    def i32(s): return struct.unpack('<i',s.take(4))[0]
    def f32(s): return struct.unpack('<f',s.take(4))[0]
    def f64(s): return struct.unpack('<d',s.take(8))[0]
    def str(s): n=s.u16(); return s.take(n).decode()
def unframe(h):
    b=bytes.fromhex(h); n=struct.unpack('<I',b[:4])[0]; assert n==len(b)-4, 'lunghezza'; return b[4], R(b[5:])
t,r=unframe(o['hello']); v=(r.u16(),r.str(),r.str(),r.str(),r.str(),r.u16(),r.f32(),r.f32(),r.f32())
chk('hello', t==1 and v==(1,'ID-1','iPad (Safari)','Web','Safari 18.2',7,1194.0,834.0,2.0) and r.o==len(r.b))
t,r=unframe(o['pen']); n=r.u16(); ss=[]
for _ in range(n):
    ss.append(dict(seq=r.u32(),t=r.f64(),x=r.f32(),y=r.f32(),p=r.u16()/65535,alt=r.u16()/65535*math.pi/2,
                   az=r.u16()/65535*2*math.pi,roll=r.u16(),hov=r.u16(),fl=r.u8(),res=r.u8()))
s0,s1=ss
chk('pen size', t==4 and n==2 and r.o==len(r.b) and len(r.b)==2+64)
chk('pen s0', s0['seq']==5 and abs(s0['t']-123.456789)<1e-12 and s0['x']==0.25 and abs(s0['p']-0.5)<2e-5 and abs(s0['alt']-1.0)<1e-4 and abs(s0['az']-3.0)<2e-4 and s0['fl']==5)
chk('pen s1 clamp/wrap', abs(s1['p']-1)<1e-9 and abs(s1['alt']-math.pi/2)<1e-4 and abs(s1['az']-(2*math.pi-1))<2e-4 and s1['fl']==8)
t,r=unframe(o['gesture']); chk('gesture', t==5 and (r.u8(),r.f32(),r.f32(),r.f32(),r.u8())==(7,3.5,-12.0,1.0,2))
t,r=unframe(o['button']); chk('button', t==6 and (r.u16(),r.u8())==(7,1))
t,r=unframe(o['control']); chk('control', t==8 and (r.u8(),r.i32())==(0,2))
t,r=unframe(o['ping']); chk('ping', t==9 and (r.u32(),r.f64())==(42,1234.5))
t,r=unframe(o['pong']); chk('pong', t==10 and (r.u32(),r.f64(),r.f64())==(42,1234.5,99.25))
t,r=unframe(o['dev']); chk('deviceUpdate', t==12 and (r.u16(),r.f32(),r.f32())==(3,834.0,1194.0))
t,r=unframe(o['bye']); chk('bye utf8', t==13 and r.str()=='fine è')
t,r=unframe(o['ack']); chk('frameAck', t==15 and r.u32()==42 and r.o==len(r.b))

# Messaggi Mac -> iPad codificati in Python per il decoder JS
def W(): return bytearray()
def s(x): b=x.encode(); return struct.pack('<H',len(b))+b
def frame(t,p): return struct.pack('<I',len(p)+1)+bytes([t])+p
welcome=frame(2, struct.pack('<H',1)+s('M-1')+s('MacBook Pro di Jody')+b'\x01'+s(''))
cfg=frame(3, bytes([2])+s('Photoshop Retouching')+s('Studio Display')+struct.pack('<4f',0.1,0.05,0.8,0.9)+b'\x01\x00\x01'
          +struct.pack('<H',2)+struct.pack('<H',1)+s('Annulla')+s('arrow.uturn.backward')+b'\x00'
          +struct.pack('<H',8)+s('Alt')+s('option')+b'\x01'+b'\x00\x01\x01\x00\x01'+struct.pack('<f',3.5))
ping=frame(9, struct.pack('<Id',7,55.5))
stream=welcome+cfg+ping
open('mac_stream.hex','w').write(stream.hex())
cfg_display=frame(3, bytes([4])+s('Display')+s('Studio Display')+struct.pack('<4f',0,0.1,1,0.8)+b'\x01\x00\x01'
          +struct.pack('<H',1)+struct.pack('<H',1)+s('Annulla')+s('arrow.uturn.backward')+b'\x00'
          +b'\x00\x00\x01\x00\x01'+struct.pack('<f',3.0)+b'\x01'+s('')+struct.pack('<4f',0,0,1,1))
jpeg=bytes([0xFF,0xD8,0xFF,0xD9])
video=frame(14, struct.pack('<IdHHB',42,9.5,1600,1200,1)+struct.pack('<I',len(jpeg))+jpeg+struct.pack('<4f',0,0,1,1))
open('display_stream.hex','w').write((cfg_display+video).hex())
# Dopo uno zoom: stessa configurazione, area (0.25, 0.25, 0.5, 0.5)
cfg_zoom=frame(3, bytes([4])+s('Display')+s('Studio Display')+struct.pack('<4f',0,0.1,1,0.8)+b'\x01\x00\x01'
          +struct.pack('<H',1)+struct.pack('<H',1)+s('Annulla')+s('arrow.uturn.backward')+b'\x00'
          +b'\x00\x00\x01\x00\x01'+struct.pack('<f',3.0)+b'\x01'+s('')+struct.pack('<4f',0.25,0.25,0.5,0.5))
open('display_zoom.hex','w').write(cfg_zoom.hex())
print('ALL OK' if ok else 'SOME FAILED')
raise SystemExit(0 if ok else 1)
